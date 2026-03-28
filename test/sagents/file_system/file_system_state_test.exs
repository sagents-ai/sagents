defmodule Sagents.FileSystem.FileSystemStateTest do
  use ExUnit.Case, async: true

  alias Sagents.FileSystem.FileSystemState
  alias Sagents.FileSystem.FileSystemConfig

  # Helper to add persistence config to state
  defp add_persistence_config(state, module, base_dir \\ "Memories", opts \\ []) do
    debounce_ms = Keyword.get(opts, :debounce_ms, 5000)
    storage_opts = Keyword.get(opts, :storage_opts, [])

    {:ok, config} =
      FileSystemConfig.new(%{
        base_directory: base_dir,
        persistence_module: module,
        debounce_ms: debounce_ms,
        storage_opts: storage_opts
      })

    {:ok, new_state} = FileSystemState.register_persistence(state, config)
    new_state
  end

  # Test persistence modules for persist_file routing tests
  defmodule TestPersistMetaRouting do
    @behaviour Sagents.FileSystem.Persistence
    alias Sagents.FileSystem.FileEntry

    def write_to_storage(entry, _opts), do: {:ok, FileEntry.mark_clean(entry)}
    def update_metadata_in_storage(entry, _opts), do: {:ok, FileEntry.mark_clean(entry)}
    def load_from_storage(_entry, _opts), do: {:error, :enoent}
    def delete_from_storage(_entry, _opts), do: :ok
    def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
  end

  defmodule TestPersistNoMetaCallback do
    @behaviour Sagents.FileSystem.Persistence
    alias Sagents.FileSystem.FileEntry

    def write_to_storage(entry, _opts), do: {:ok, FileEntry.mark_clean(entry)}
    # No update_metadata_in_storage defined
    def load_from_storage(_entry, _opts), do: {:error, :enoent}
    def delete_from_storage(_entry, _opts), do: :ok
    def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
  end

  describe "new/1" do
    test "creates state with empty files map" do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      assert {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})

      assert state.scope_key == {:agent, agent_id}
      assert state.files == %{}
      assert state.persistence_configs == %{}
      assert state.debounce_timers == %{}
    end
  end

  describe "write_file/4" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "writes a memory file", %{state: state} do
      path = "/scratch/test.txt"
      content = "test content"

      assert {:ok, _entry, new_state} = FileSystemState.write_file(state, path, content, [])

      # Verify file is in state
      assert Map.has_key?(new_state.files, path)
      entry = Map.get(new_state.files, path)
      assert entry.path == path
      assert entry.content == content
      assert entry.persistence == :memory
      assert entry.loaded == true
      assert entry.dirty_content == false
    end

    test "writes a new persisted file and persists immediately", %{state: state} do
      defmodule TestPersistence1 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistence1)

      path = "/Memories/file.txt"
      content = "persisted content"

      assert {:ok, _entry, new_state} = FileSystemState.write_file(state, path, content, [])

      # Verify file is in state
      assert Map.has_key?(new_state.files, path)
      entry = Map.get(new_state.files, path)
      assert entry.persistence == :persisted
      # New files are persisted immediately, so dirty is false
      assert entry.dirty_content == false
      assert entry.loaded == true

      # No debounce timer for new files (persisted immediately)
      refute Map.has_key?(new_state.debounce_timers, path)
    end

    test "updates an existing persisted file and schedules debounce timer", %{state: state} do
      defmodule TestPersistence1b do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistence1b)

      path = "/Memories/file.txt"

      # Create the file first (persists immediately)
      assert {:ok, _entry, state} = FileSystemState.write_file(state, path, "initial content", [])
      assert state.files[path].dirty_content == false

      # Update the existing file (should debounce)
      assert {:ok, _entry, new_state} =
               FileSystemState.write_file(state, path, "updated content", [])

      entry = Map.get(new_state.files, path)
      assert entry.persistence == :persisted
      assert entry.dirty_content == true
      assert entry.loaded == true

      # Verify debounce timer was created for the update
      assert Map.has_key?(new_state.debounce_timers, path)
      assert is_reference(new_state.debounce_timers[path])
    end

    test "rejects writes to readonly directories", %{state: state} do
      defmodule TestPersistence2 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      {:ok, config} =
        FileSystemConfig.new(%{
          base_directory: "readonly",
          persistence_module: TestPersistence2,
          readonly: true
        })

      {:ok, state} = FileSystemState.register_persistence(state, config)

      path = "/readonly/file.txt"
      content = "data"

      assert {:error, reason, _state} = FileSystemState.write_file(state, path, content, [])
      assert reason =~ "read-only"
    end
  end

  describe "move_file/3" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "moves a file to a new path", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/old", "content")
      {:ok, [moved], state} = FileSystemState.move_file(state, "/old", "/new")

      assert moved.path == "/new"
      assert moved.content == "content"
      refute Map.has_key?(state.files, "/old")
      assert Map.has_key?(state.files, "/new")
    end

    test "moves a directory and its children", %{state: state} do
      {:ok, _dir, state} = FileSystemState.create_directory(state, "/parent")
      {:ok, _file, state} = FileSystemState.write_file(state, "/parent/child", "child content")

      {:ok, moved, state} = FileSystemState.move_file(state, "/parent", "/renamed")

      paths = Enum.map(moved, & &1.path)
      assert "/renamed" in paths
      assert "/renamed/child" in paths
      refute Map.has_key?(state.files, "/parent")
      refute Map.has_key?(state.files, "/parent/child")
      assert Map.has_key?(state.files, "/renamed")
      assert Map.has_key?(state.files, "/renamed/child")
    end

    test "returns error for non-existent path", %{state: state} do
      assert {:error, :enoent, _state} = FileSystemState.move_file(state, "/nope", "/new")
    end

    test "returns error when target already exists", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/a", "a")
      {:ok, _entry, state} = FileSystemState.write_file(state, "/b", "b")

      assert {:error, :already_exists, _state} = FileSystemState.move_file(state, "/a", "/b")
    end

    test "no-op when old and new path are the same", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/same", "content")
      {:ok, [entry], state2} = FileSystemState.move_file(state, "/same", "/same")

      assert entry.path == "/same"
      assert state.files == state2.files
    end

    test "transfers debounce timers to new paths", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/timed", "content")

      # Simulate a pending debounce timer
      timer_ref = make_ref()
      state = %{state | debounce_timers: Map.put(state.debounce_timers, "/timed", timer_ref)}

      {:ok, _moved, state} = FileSystemState.move_file(state, "/timed", "/moved")

      refute Map.has_key?(state.debounce_timers, "/timed")
      assert Map.get(state.debounce_timers, "/moved") == timer_ref
    end

    test "returns error when moving between different persistence backends", %{state: state} do
      # Set up two different persistence configs
      state = add_persistence_config(state, TestPersistMetaRouting, "disk_files")
      state = add_persistence_config(state, TestPersistNoMetaCallback, "db_files")

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/disk_files/doc.txt", "content")

      assert {:error, message, _state} =
               FileSystemState.move_file(state, "/disk_files/doc.txt", "/db_files/doc.txt")

      assert message =~ "Cannot move files across different storage backends"
      assert message =~ "/disk_files"
    end

    test "allows move within the same persistence backend", %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting, "Memories")

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/old.txt", "content")

      assert {:ok, [moved], _state} =
               FileSystemState.move_file(state, "/Memories/old.txt", "/Memories/new.txt")

      assert moved.path == "/Memories/new.txt"
    end

    test "returns error when moving to a read-only directory", %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting, "writable")

      {:ok, readonly_config} =
        FileSystemConfig.new(%{
          base_directory: "readonly",
          persistence_module: TestPersistMetaRouting,
          readonly: true
        })

      {:ok, state} = FileSystemState.register_persistence(state, readonly_config)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/writable/doc.txt", "content")

      assert {:error, message, _state} =
               FileSystemState.move_file(state, "/writable/doc.txt", "/readonly/doc.txt")

      assert message =~ "Cannot move to read-only directory"
    end
  end

  describe "delete_file/2" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "deletes a memory file", %{state: state} do
      path = "/scratch/file.txt"

      {:ok, _entry, state} = FileSystemState.write_file(state, path, "data", [])
      assert Map.has_key?(state.files, path)

      assert {:ok, new_state} = FileSystemState.delete_file(state, path)
      refute Map.has_key?(new_state.files, path)
    end

    test "deletes a persisted file and cancels timer", %{state: state} do
      defmodule TestPersistence3 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistence3)

      path = "/Memories/file.txt"
      # Create the file (persists immediately, no timer)
      {:ok, _entry, state} = FileSystemState.write_file(state, path, "data", [])

      # Update the file to trigger a debounce timer
      {:ok, _entry, state} = FileSystemState.write_file(state, path, "updated data", [])

      # Verify timer exists for the update
      assert Map.has_key?(state.debounce_timers, path)

      assert {:ok, new_state} = FileSystemState.delete_file(state, path)

      # Verify file is gone
      refute Map.has_key?(new_state.files, path)

      # Verify timer was cancelled
      refute Map.has_key?(new_state.debounce_timers, path)
    end

    test "rejects delete from readonly directories", %{state: state} do
      defmodule TestPersistence4 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      {:ok, config} =
        FileSystemConfig.new(%{
          base_directory: "readonly",
          persistence_module: TestPersistence4,
          readonly: true
        })

      {:ok, state} = FileSystemState.register_persistence(state, config)

      path = "/readonly/file.txt"

      assert {:error, reason, _state} = FileSystemState.delete_file(state, path)
      assert reason =~ "read-only"
    end
  end

  describe "register_persistence/2" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "registers a new persistence config", %{state: state} do
      defmodule TestPersistence5 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      {:ok, config} =
        FileSystemConfig.new(%{
          base_directory: "user_files",
          persistence_module: TestPersistence5
        })

      assert {:ok, new_state} = FileSystemState.register_persistence(state, config)
      assert map_size(new_state.persistence_configs) == 1
      assert Map.has_key?(new_state.persistence_configs, "user_files")
    end

    test "prevents registering same base_directory twice", %{state: state} do
      defmodule TestPersistence6 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      {:ok, config1} =
        FileSystemConfig.new(%{
          base_directory: "user_files",
          persistence_module: TestPersistence6
        })

      {:ok, state} = FileSystemState.register_persistence(state, config1)

      {:ok, config2} =
        FileSystemConfig.new(%{
          base_directory: "user_files",
          persistence_module: TestPersistence6,
          debounce_ms: 10000
        })

      assert {:error, reason} = FileSystemState.register_persistence(state, config2)
      assert reason =~ "already has a registered persistence config"
    end
  end

  describe "default config without base_directory" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "default config catches all paths", %{state: state} do
      defmodule TestPersistenceDefault1 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      {:ok, config} =
        FileSystemConfig.new(%{
          default: true,
          persistence_module: TestPersistenceDefault1
        })

      {:ok, state} = FileSystemState.register_persistence(state, config)

      # Files at any path should be persisted via the default config
      assert {:ok, _entry, state} = FileSystemState.write_file(state, "/notes.txt", "notes", [])
      assert state.files["/notes.txt"].persistence == :persisted

      assert {:ok, _entry, state} =
               FileSystemState.write_file(state, "/deep/nested/file.md", "deep", [])

      assert state.files["/deep/nested/file.md"].persistence == :persisted
    end

    test "mixed: specific config + default without base_directory", %{state: state} do
      defmodule TestPersistenceDefault2 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      # Register specific config for "Memories"
      {:ok, specific_config} =
        FileSystemConfig.new(%{
          base_directory: "Memories",
          persistence_module: TestPersistenceDefault2
        })

      {:ok, state} = FileSystemState.register_persistence(state, specific_config)

      # Register default config without base_directory
      {:ok, default_config} =
        FileSystemConfig.new(%{
          default: true,
          persistence_module: TestPersistenceDefault2
        })

      {:ok, state} = FileSystemState.register_persistence(state, default_config)

      # Files in /Memories/ go to specific config (persisted)
      assert {:ok, _entry, state} =
               FileSystemState.write_file(state, "/Memories/note.txt", "memory", [])

      assert state.files["/Memories/note.txt"].persistence == :persisted

      # Files elsewhere go to default config (persisted)
      assert {:ok, _entry, state} =
               FileSystemState.write_file(state, "/other/file.txt", "other", [])

      assert state.files["/other/file.txt"].persistence == :persisted
    end

    test "default + readonly override", %{state: state} do
      defmodule TestPersistenceDefault3 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      # Default writable config
      {:ok, default_config} =
        FileSystemConfig.new(%{
          default: true,
          persistence_module: TestPersistenceDefault3
        })

      {:ok, state} = FileSystemState.register_persistence(state, default_config)

      # Readonly config for "Reference"
      {:ok, readonly_config} =
        FileSystemConfig.new(%{
          base_directory: "Reference",
          persistence_module: TestPersistenceDefault3,
          readonly: true
        })

      {:ok, state} = FileSystemState.register_persistence(state, readonly_config)

      # Writing to default path succeeds
      assert {:ok, _entry, state} = FileSystemState.write_file(state, "/notes.txt", "notes", [])
      assert state.files["/notes.txt"].persistence == :persisted

      # Writing to readonly path is rejected
      assert {:error, reason, _state} =
               FileSystemState.write_file(state, "/Reference/guide.pdf", "data", [])

      assert reason =~ "read-only"
    end
  end

  describe "stats/1" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "returns stats for empty filesystem", %{state: state} do
      stats = FileSystemState.stats(state)

      assert stats.total_files == 0
      assert stats.memory_files == 0
      assert stats.persisted_files == 0
      assert stats.dirty_files == 0
    end

    test "counts different file types correctly", %{state: state} do
      defmodule TestPersistence7 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistence7)

      # Write memory files
      {:ok, _entry, state} = FileSystemState.write_file(state, "/scratch/file1.txt", "data1", [])
      {:ok, _entry, state} = FileSystemState.write_file(state, "/scratch/file2.txt", "data2", [])

      # Write persisted files
      {:ok, _entry, state} = FileSystemState.write_file(state, "/Memories/file3.txt", "data3", [])
      {:ok, _entry, state} = FileSystemState.write_file(state, "/Memories/file4.txt", "data4", [])

      stats = FileSystemState.stats(state)

      # 4 files + 2 auto-created ancestor directories (/scratch, /Memories)
      assert stats.total_files == 6
      # 2 scratch files + auto-created /scratch directory
      assert stats.memory_files == 3
      # 2 Memories files + auto-created /Memories directory
      assert stats.persisted_files == 3
      # New files and directories are persisted immediately, so no dirty files
      assert stats.dirty_files == 0
    end
  end

  describe "reset/1" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "removes memory-only files", %{state: state} do
      # Write memory files
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/scratch/temp1.txt", "temp data 1", [])

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/scratch/temp2.txt", "temp data 2", [])

      # Verify files exist
      assert Map.has_key?(state.files, "/scratch/temp1.txt")
      assert Map.has_key?(state.files, "/scratch/temp2.txt")

      # Reset
      reset_state = FileSystemState.reset(state)

      # Memory files should be gone
      refute Map.has_key?(reset_state.files, "/scratch/temp1.txt")
      refute Map.has_key?(reset_state.files, "/scratch/temp2.txt")
      assert reset_state.files == %{}
    end

    test "cancels all debounce timers", %{state: state} do
      defmodule TestPersistence8 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistence8)

      # Create a persisted file (persists immediately, no timer)
      {:ok, _entry, state} = FileSystemState.write_file(state, "/Memories/file.txt", "data", [])

      # Update the file to trigger a debounce timer
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/file.txt", "updated", [])

      # Verify timer exists for the update
      assert Map.has_key?(state.debounce_timers, "/Memories/file.txt")
      timer_ref = state.debounce_timers["/Memories/file.txt"]
      assert is_reference(timer_ref)

      # Reset
      reset_state = FileSystemState.reset(state)

      # Timers should be cleared
      assert reset_state.debounce_timers == %{}
    end

    test "re-indexes persisted files from storage", %{state: state} do
      defmodule TestPersistence9 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok

        # Simulate files existing in storage
        def list_persisted_entries(_agent_id, _opts) do
          {:ok, e1} = Sagents.FileSystem.FileEntry.new_indexed_file("/Memories/existing1.txt")
          {:ok, e2} = Sagents.FileSystem.FileEntry.new_indexed_file("/Memories/existing2.txt")
          {:ok, [e1, e2]}
        end
      end

      state = add_persistence_config(state, TestPersistence9)

      # Initially, the files should be indexed from storage
      assert Map.has_key?(state.files, "/Memories/existing1.txt")
      assert Map.has_key?(state.files, "/Memories/existing2.txt")

      # Add some memory files
      {:ok, _entry, state} = FileSystemState.write_file(state, "/scratch/temp.txt", "temp", [])

      # Reset
      reset_state = FileSystemState.reset(state)

      # Memory files should be gone
      refute Map.has_key?(reset_state.files, "/scratch/temp.txt")

      # Persisted files should still be indexed (but unloaded)
      assert Map.has_key?(reset_state.files, "/Memories/existing1.txt")
      assert Map.has_key?(reset_state.files, "/Memories/existing2.txt")

      # Files should be marked as unloaded
      entry1 = reset_state.files["/Memories/existing1.txt"]
      assert entry1.loaded == false
      assert entry1.dirty_content == false
    end

    test "works with empty filesystem", %{state: state} do
      # Reset empty state
      reset_state = FileSystemState.reset(state)

      assert reset_state.files == %{}
      assert reset_state.debounce_timers == %{}
      assert reset_state.scope_key == state.scope_key
      assert reset_state.persistence_configs == state.persistence_configs
    end

    test "clears dirty flags and unloads modified persisted files", %{state: state} do
      defmodule TestPersistence10 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: :ok

        def load_from_storage(_entry, _opts) do
          # Return original content from storage
          {:ok, "original content from storage"}
        end

        def delete_from_storage(_entry, _opts), do: :ok

        def list_persisted_entries(_agent_id, _opts) do
          {:ok, entry} = Sagents.FileSystem.FileEntry.new_indexed_file("/Memories/file.txt")
          {:ok, [entry]}
        end
      end

      state = add_persistence_config(state, TestPersistence10)

      # The file is indexed from storage
      assert Map.has_key?(state.files, "/Memories/file.txt")

      # Modify the file (this would load and mark it dirty)
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/file.txt", "modified", [])

      # Verify it's dirty and loaded
      entry = state.files["/Memories/file.txt"]
      assert entry.dirty_content == true
      assert entry.loaded == true
      assert entry.content == "modified"

      # Reset
      reset_state = FileSystemState.reset(state)

      # File should still be indexed (persisted), but unloaded and not dirty
      assert Map.has_key?(reset_state.files, "/Memories/file.txt")
      reset_entry = reset_state.files["/Memories/file.txt"]
      assert reset_entry.loaded == false
      assert reset_entry.dirty_content == false
      # Content would be nil since it's unloaded
    end
  end

  describe "write_file preserves metadata" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "preserves custom metadata on content update", %{state: state} do
      defmodule TestPersistenceMetadata do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistenceMetadata)

      # Create file with custom metadata
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "initial",
          custom: %{"tags" => ["draft"]}
        )

      assert state.files["/Memories/doc.txt"].metadata.custom == %{"tags" => ["draft"]}

      # Update content — custom metadata should be preserved
      {:ok, entry, _state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "updated content", [])

      assert entry.content == "updated content"
      assert entry.metadata.custom == %{"tags" => ["draft"]}
    end

    test "returns the entry in the result", %{state: state} do
      {:ok, entry, _state} =
        FileSystemState.write_file(state, "/scratch/test.txt", "hello", [])

      assert entry.path == "/scratch/test.txt"
      assert entry.content == "hello"
      assert entry.entry_type == :file
    end
  end

  describe "list_entries/1" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "returns all entries sorted by path", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/z.txt", "z", [])
      {:ok, _entry, state} = FileSystemState.write_file(state, "/a.txt", "a", [])
      {:ok, _entry, state} = FileSystemState.write_file(state, "/m.txt", "m", [])

      entries = FileSystemState.list_entries(state)

      assert length(entries) == 3
      assert Enum.map(entries, & &1.path) == ["/a.txt", "/m.txt", "/z.txt"]
    end

    test "returns empty list for empty filesystem", %{state: state} do
      assert FileSystemState.list_entries(state) == []
    end
  end

  describe "update_custom_metadata/4" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "updates custom metadata on existing file", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/test.txt", "data", [])

      {:ok, updated, _state} =
        FileSystemState.update_custom_metadata(state, "/test.txt", %{"tags" => ["important"]})

      assert updated.metadata.custom == %{"tags" => ["important"]}
    end

    test "merges with existing custom metadata", %{state: state} do
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/test.txt", "data", custom: %{"author" => "Alice"})

      {:ok, updated, _state} =
        FileSystemState.update_custom_metadata(state, "/test.txt", %{"tags" => ["draft"]})

      assert updated.metadata.custom == %{"author" => "Alice", "tags" => ["draft"]}
    end

    test "returns error for nonexistent file", %{state: state} do
      assert {:error, :enoent, _state} =
               FileSystemState.update_custom_metadata(state, "/nope.txt", %{})
    end

    test "persists immediately by default", %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      # File is clean after immediate persist
      assert state.files["/Memories/doc.txt"].dirty_content == false

      # Update metadata — persists immediately by default
      {:ok, updated, state} =
        FileSystemState.update_custom_metadata(state, "/Memories/doc.txt", %{"tags" => ["a"]})

      # Entry should be clean (persisted immediately), no debounce timer
      assert updated.dirty_content == false
      assert updated.dirty_non_content == false
      refute Map.has_key?(state.debounce_timers, "/Memories/doc.txt")
    end

    test "sets dirty_non_content before persist on persisted file", %{state: state} do
      state = add_persistence_config(state, TestPersistNoMetaCallback)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      # File is clean after immediate persist
      assert state.files["/Memories/doc.txt"].dirty_non_content == false

      # With debounce, we can observe the dirty flags before persist fires
      {:ok, _updated, state} =
        FileSystemState.update_custom_metadata(state, "/Memories/doc.txt", %{"tags" => ["a"]},
          persist: :debounce
        )

      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == true
      assert entry.dirty_non_content == true
    end

    test "write_file does not set dirty_non_content", %{state: state} do
      state = add_persistence_config(state, TestPersistNoMetaCallback)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "initial", [])

      # Clean after immediate persist
      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_non_content == false

      # Content write sets dirty but not dirty_non_content
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "updated", [])

      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == true
      assert entry.dirty_non_content == false
    end

    test "persist: :debounce schedules timer instead of persisting immediately", %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      # Update metadata with debounce
      {:ok, _updated, state} =
        FileSystemState.update_custom_metadata(state, "/Memories/doc.txt", %{"tags" => ["a"]},
          persist: :debounce
        )

      # Entry should still be dirty — debounce timer pending
      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == true
      assert entry.dirty_non_content == true
      assert Map.has_key?(state.debounce_timers, "/Memories/doc.txt")
    end

    test "memory-only file is unaffected by persist option", %{state: state} do
      # No persistence config — file lives in memory only
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/scratch/tmp.txt", "data", [])

      {:ok, updated, state} =
        FileSystemState.update_custom_metadata(state, "/scratch/tmp.txt", %{"key" => "val"})

      # Metadata was applied but entry stays in memory (no persist, no timers)
      assert updated.metadata.custom == %{"key" => "val"}
      assert state.debounce_timers == %{}
    end

    test "immediate persist clears pending debounce timer",
         %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      # First update with debounce — schedules timer
      {:ok, _updated, state} =
        FileSystemState.update_custom_metadata(state, "/Memories/doc.txt", %{"a" => 1},
          persist: :debounce
        )

      assert Map.has_key?(state.debounce_timers, "/Memories/doc.txt")

      # Second update with default (immediate) — should persist and clear timer
      {:ok, _updated, state} =
        FileSystemState.update_custom_metadata(state, "/Memories/doc.txt", %{"b" => 2})

      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == false
      refute Map.has_key?(state.debounce_timers, "/Memories/doc.txt")
    end
  end

  describe "update_entry/4" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "updates title", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/test.txt", "data", [])

      {:ok, updated, _state} =
        FileSystemState.update_entry(state, "/test.txt", %{title: "New Title"})

      assert updated.title == "New Title"
    end

    test "updates id", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/test.txt", "data", [])

      {:ok, updated, _state} =
        FileSystemState.update_entry(state, "/test.txt", %{id: "abc-123"})

      assert updated.id == "abc-123"
    end

    test "updates file_type", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/test.txt", "data", [])

      {:ok, updated, _state} =
        FileSystemState.update_entry(state, "/test.txt", %{file_type: "json"})

      assert updated.file_type == "json"
    end

    test "updates multiple attrs at once", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/test.txt", "data", [])

      {:ok, updated, _state} =
        FileSystemState.update_entry(state, "/test.txt", %{
          title: "Doc",
          id: "x",
          file_type: "pdf"
        })

      assert updated.title == "Doc"
      assert updated.id == "x"
      assert updated.file_type == "pdf"
    end

    test "no-op when attrs match current values", %{state: state} do
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/test.txt", "data", title: "Same")

      {:ok, updated, new_state} =
        FileSystemState.update_entry(state, "/test.txt", %{title: "Same"})

      assert updated.title == "Same"
      # No dirty marking since nothing changed
      assert updated.dirty_content == false
      assert new_state.debounce_timers == %{}
    end

    test "returns error for nonexistent file", %{state: state} do
      assert {:error, :enoent, _state} =
               FileSystemState.update_entry(state, "/nope.txt", %{title: "X"})
    end

    test "returns error for readonly directory", %{state: state} do
      {:ok, config} =
        FileSystemConfig.new(%{
          base_directory: "readonly",
          persistence_module: TestPersistMetaRouting,
          readonly: true
        })

      {:ok, state} = FileSystemState.register_persistence(state, config)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/scratch/test.txt", "data", [])

      # Write a file outside readonly, then try to update one inside
      # Need to have a file in readonly first — but can't write to readonly.
      # So test the error path directly:
      assert {:error, msg, _state} =
               FileSystemState.update_entry(state, "/readonly/file.txt", %{title: "X"})

      # File doesn't exist in readonly, so we get enoent
      assert msg == :enoent
    end

    test "persists immediately by default", %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      {:ok, updated, state} =
        FileSystemState.update_entry(state, "/Memories/doc.txt", %{title: "Renamed"})

      assert updated.title == "Renamed"
      assert updated.dirty_content == false
      assert updated.dirty_non_content == false
      refute Map.has_key?(state.debounce_timers, "/Memories/doc.txt")
    end

    test "persist: :debounce schedules timer", %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      {:ok, _updated, state} =
        FileSystemState.update_entry(state, "/Memories/doc.txt", %{title: "Renamed"},
          persist: :debounce
        )

      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == true
      assert entry.dirty_non_content == true
      assert Map.has_key?(state.debounce_timers, "/Memories/doc.txt")
    end

    test "memory-only file: no persist, no timers", %{state: state} do
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/scratch/tmp.txt", "data", [])

      {:ok, updated, state} =
        FileSystemState.update_entry(state, "/scratch/tmp.txt", %{title: "Temp"})

      assert updated.title == "Temp"
      assert state.debounce_timers == %{}
    end

    test "ignores unknown keys in attrs", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/test.txt", "data", [])

      {:ok, updated, _state} =
        FileSystemState.update_entry(state, "/test.txt", %{
          title: "New",
          content: "hack",
          path: "/bad"
        })

      assert updated.title == "New"
      # content and path should be unchanged
      assert updated.content == "data"
      assert updated.path == "/test.txt"
    end
  end

  describe "persist_file/2" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "calls update_metadata_in_storage when dirty_non_content is true", %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      # Update metadata only (debounce so we can manually persist)
      {:ok, _updated, state} =
        FileSystemState.update_custom_metadata(state, "/Memories/doc.txt", %{"tags" => ["a"]},
          persist: :debounce
        )

      # Verify entry has dirty_non_content before persist
      assert state.files["/Memories/doc.txt"].dirty_non_content == true

      # Manually persist (simulating debounce fire)
      state = FileSystemState.persist_file(state, "/Memories/doc.txt")

      # After persist, entry should be clean
      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == false
      assert entry.dirty_non_content == false
    end

    test "calls write_to_storage when dirty_non_content is false", %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "initial", [])

      # Content write (not metadata-only)
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "updated", [])

      # dirty but NOT dirty_non_content
      assert state.files["/Memories/doc.txt"].dirty_content == true
      assert state.files["/Memories/doc.txt"].dirty_non_content == false

      state = FileSystemState.persist_file(state, "/Memories/doc.txt")

      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == false
    end

    test "content write after metadata update resets dirty_non_content and uses write_to_storage",
         %{state: state} do
      state = add_persistence_config(state, TestPersistMetaRouting)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "initial", [])

      # Metadata-only update sets dirty_non_content (debounce so it stays dirty)
      {:ok, _updated, state} =
        FileSystemState.update_custom_metadata(state, "/Memories/doc.txt", %{"tags" => ["a"]},
          persist: :debounce
        )

      assert state.files["/Memories/doc.txt"].dirty_non_content == true

      # Content write should reset dirty_non_content
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "new content", [])

      assert state.files["/Memories/doc.txt"].dirty_content == true
      assert state.files["/Memories/doc.txt"].dirty_non_content == false

      # Persist should use write_to_storage (full write), not update_metadata_in_storage
      state = FileSystemState.persist_file(state, "/Memories/doc.txt")

      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == false
      assert entry.content == "new content"
    end

    test "falls back to write_to_storage when module lacks update_metadata_in_storage",
         %{state: state} do
      state = add_persistence_config(state, TestPersistNoMetaCallback)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      # Metadata update — but module doesn't implement the callback (debounce so it stays dirty)
      {:ok, _updated, state} =
        FileSystemState.update_custom_metadata(state, "/Memories/doc.txt", %{"tags" => ["a"]},
          persist: :debounce
        )

      assert state.files["/Memories/doc.txt"].dirty_non_content == true

      # Should still succeed — falls back to write_to_storage
      state = FileSystemState.persist_file(state, "/Memories/doc.txt")

      entry = state.files["/Memories/doc.txt"]
      assert entry.dirty_content == false
    end
  end

  describe "create_directory/3" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "creates a directory entry", %{state: state} do
      {:ok, entry, state} =
        FileSystemState.create_directory(state, "/Characters", title: "Characters")

      assert entry.entry_type == :directory
      assert entry.title == "Characters"
      assert entry.content == nil
      assert Map.has_key?(state.files, "/Characters")
    end

    test "rejects duplicate paths", %{state: state} do
      {:ok, _entry, state} = FileSystemState.create_directory(state, "/Characters")

      assert {:error, :already_exists, _state} =
               FileSystemState.create_directory(state, "/Characters")
    end

    test "creates memory directory without persistence config", %{state: state} do
      {:ok, entry, _state} = FileSystemState.create_directory(state, "/temp")
      assert entry.persistence == :memory
    end

    test "creates persisted directory with persistence config", %{state: state} do
      defmodule TestPersistenceDir do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistenceDir)

      {:ok, entry, _state} =
        FileSystemState.create_directory(state, "/Memories/Chapters", title: "Chapters")

      assert entry.persistence == :persisted
      assert entry.dirty_content == false
    end
  end

  describe "index with list_persisted_entries" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "uses list_persisted_entries when available", %{state: state} do
      defmodule TestPersistenceRichIndex do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok

        def list_persisted_entries(_agent_id, _opts) do
          {:ok, dir} =
            Sagents.FileSystem.FileEntry.new_indexed_file("/Memories/Characters",
              title: "Characters",
              entry_type: :directory
            )

          {:ok, file} =
            Sagents.FileSystem.FileEntry.new_indexed_file("/Memories/Characters/Hero",
              title: "Hero"
            )

          {:ok, [dir, file]}
        end
      end

      state = add_persistence_config(state, TestPersistenceRichIndex)

      # Files should be indexed with metadata from list_persisted_entries
      dir = state.files["/Memories/Characters"]
      assert dir != nil
      assert dir.title == "Characters"
      assert dir.entry_type == :directory

      file = state.files["/Memories/Characters/Hero"]
      assert file != nil
      assert file.title == "Hero"
      assert file.entry_type == :file
    end
  end

  describe "ancestor_paths/1" do
    test "returns empty list for root-level files" do
      assert FileSystemState.ancestor_paths("/notes.txt") == []
    end

    test "returns single ancestor for one-level nesting" do
      assert FileSystemState.ancestor_paths("/Characters/Hero") == ["/Characters"]
    end

    test "returns ancestors shallowest to deepest" do
      assert FileSystemState.ancestor_paths("/Characters/Hero/Backstory") == [
               "/Characters",
               "/Characters/Hero"
             ]
    end

    test "handles deep nesting" do
      assert FileSystemState.ancestor_paths("/a/b/c/d/file") == [
               "/a",
               "/a/b",
               "/a/b/c",
               "/a/b/c/d"
             ]
    end
  end

  describe "ensure_ancestor_directories/2" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "creates missing ancestor directories for nested path", %{state: state} do
      state = FileSystemState.ensure_ancestor_directories(state, "/Characters/Hero/Backstory")

      # Both /Characters and /Characters/Hero should be created
      assert Map.has_key?(state.files, "/Characters")
      assert Map.has_key?(state.files, "/Characters/Hero")

      char_dir = state.files["/Characters"]
      assert char_dir.entry_type == :directory
      assert char_dir.title == "Characters"

      hero_dir = state.files["/Characters/Hero"]
      assert hero_dir.entry_type == :directory
      assert hero_dir.title == "Hero"
    end

    test "does nothing for root-level files", %{state: state} do
      new_state = FileSystemState.ensure_ancestor_directories(state, "/notes.txt")
      assert new_state.files == state.files
    end

    test "skips directories that already exist", %{state: state} do
      # Pre-create /Characters with custom metadata
      {:ok, existing_dir} =
        Sagents.FileSystem.FileEntry.new_directory("/Characters",
          title: "My Characters",
          custom: %{"position" => 1}
        )

      {:ok, state} = FileSystemState.register_files(state, [existing_dir])

      state =
        FileSystemState.ensure_ancestor_directories(state, "/Characters/Hero/Backstory")

      # Original directory should be preserved, not overwritten
      char_dir = state.files["/Characters"]
      assert char_dir.title == "My Characters"
      assert char_dir.metadata.custom == %{"position" => 1}

      # But the missing /Characters/Hero should be created
      assert Map.has_key?(state.files, "/Characters/Hero")
      assert state.files["/Characters/Hero"].title == "Hero"
    end

    test "auto-created directories are memory by default", %{state: state} do
      state = FileSystemState.ensure_ancestor_directories(state, "/Docs/Chapter1/Section1")

      assert state.files["/Docs"].persistence == :memory
      assert state.files["/Docs/Chapter1"].persistence == :memory
    end

    test "auto-created directories are persisted when under persistence config", %{state: state} do
      defmodule EnsureTestPersistence do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, entry}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, EnsureTestPersistence)

      state =
        FileSystemState.ensure_ancestor_directories(state, "/Memories/Characters/Hero")

      assert state.files["/Memories/Characters"].persistence == :persisted
    end
  end

  describe "write_file auto-creates ancestor directories" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "creates missing parent directories when writing a nested file", %{state: state} do
      assert {:ok, _entry, new_state} =
               FileSystemState.write_file(
                 state,
                 "/Audience/TargetAudience",
                 "Young adults 18-25"
               )

      # The file should exist
      assert Map.has_key?(new_state.files, "/Audience/TargetAudience")

      # The parent directory should have been auto-created
      assert Map.has_key?(new_state.files, "/Audience")
      dir = new_state.files["/Audience"]
      assert dir.entry_type == :directory
      assert dir.title == "Audience"
    end

    test "creates deeply nested ancestor directories", %{state: state} do
      assert {:ok, _entry, new_state} =
               FileSystemState.write_file(
                 state,
                 "/World/Geography/Countries/Eldoria",
                 "A vast kingdom"
               )

      assert Map.has_key?(new_state.files, "/World")
      assert Map.has_key?(new_state.files, "/World/Geography")
      assert Map.has_key?(new_state.files, "/World/Geography/Countries")

      assert new_state.files["/World"].title == "World"
      assert new_state.files["/World/Geography"].title == "Geography"
      assert new_state.files["/World/Geography/Countries"].title == "Countries"
    end

    test "does not overwrite existing directories when writing files", %{state: state} do
      # Create a directory with custom metadata first
      {:ok, _dir, state} =
        FileSystemState.create_directory(state, "/Characters",
          title: "My Characters",
          custom: %{"position" => 5}
        )

      # Now write a file under it — should not touch the existing directory
      {:ok, _entry, new_state} =
        FileSystemState.write_file(state, "/Characters/Hero", "The hero")

      dir = new_state.files["/Characters"]
      assert dir.title == "My Characters"
      assert dir.metadata.custom == %{"position" => 5}
    end
  end

  describe "list_entries synthesizes missing directories" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "synthesizes parent directory for orphaned file", %{state: state} do
      # Manually register a file without its parent directory
      # (simulating data loaded from a DB that predates ensure_ancestor_directories)
      {:ok, entry} =
        Sagents.FileSystem.FileEntry.new_memory_file("/Orphaned/Document", "content")

      {:ok, state} = FileSystemState.register_files(state, [entry])

      # list_entries should synthesize the missing /Orphaned directory
      entries = FileSystemState.list_entries(state)
      paths = Enum.map(entries, & &1.path)

      assert "/Orphaned" in paths
      assert "/Orphaned/Document" in paths

      orphaned_dir = Enum.find(entries, &(&1.path == "/Orphaned"))
      assert orphaned_dir.entry_type == :directory
      assert orphaned_dir.title == "Orphaned"
    end

    test "does not synthesize directories that already exist", %{state: state} do
      {:ok, dir} =
        Sagents.FileSystem.FileEntry.new_directory("/Existing", title: "My Folder")

      {:ok, file} =
        Sagents.FileSystem.FileEntry.new_memory_file("/Existing/Doc", "content")

      {:ok, state} = FileSystemState.register_files(state, [dir, file])

      entries = FileSystemState.list_entries(state)
      existing_dirs = Enum.filter(entries, &(&1.path == "/Existing"))

      # Should be exactly one entry, the explicit one
      assert length(existing_dirs) == 1
      assert hd(existing_dirs).title == "My Folder"
    end

    test "synthesizes multiple levels of missing directories", %{state: state} do
      {:ok, entry} =
        Sagents.FileSystem.FileEntry.new_memory_file("/A/B/C/deep_file", "content")

      {:ok, state} = FileSystemState.register_files(state, [entry])

      entries = FileSystemState.list_entries(state)
      paths = Enum.map(entries, & &1.path)

      assert "/A" in paths
      assert "/A/B" in paths
      assert "/A/B/C" in paths
      assert "/A/B/C/deep_file" in paths
    end

    test "synthesized directories are memory-only and not in state.files", %{state: state} do
      {:ok, entry} =
        Sagents.FileSystem.FileEntry.new_memory_file("/Ghost/file", "content")

      {:ok, state} = FileSystemState.register_files(state, [entry])

      # Synthesized directories should NOT be in state.files
      refute Map.has_key?(state.files, "/Ghost")

      # But should appear in list_entries
      entries = FileSystemState.list_entries(state)
      ghost_dir = Enum.find(entries, &(&1.path == "/Ghost"))
      assert ghost_dir != nil
      assert ghost_dir.persistence == :memory
    end
  end
end
