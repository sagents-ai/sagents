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
      assert entry.loaded == true
      # No persistence config matched, so dirty flag is irrelevant; the
      # state machine never tries to flush a memory-only file.
      refute Map.has_key?(new_state.debounce_timers, path)
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

    test "moves all files under a path prefix", %{state: state} do
      {:ok, _file1, state} = FileSystemState.write_file(state, "/parent/child", "child content")
      {:ok, _file2, state} = FileSystemState.write_file(state, "/parent/other", "other content")

      {:ok, moved, state} = FileSystemState.move_file(state, "/parent", "/renamed")

      paths = Enum.map(moved, & &1.path)
      assert "/renamed/child" in paths
      assert "/renamed/other" in paths
      refute Map.has_key?(state.files, "/parent/child")
      refute Map.has_key?(state.files, "/parent/other")
      assert Map.has_key?(state.files, "/renamed/child")
      assert Map.has_key?(state.files, "/renamed/other")
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
      # Default config matched, so write was persisted (dirty cleared)
      assert state.files["/notes.txt"].dirty_content == false

      assert {:ok, _entry, state} =
               FileSystemState.write_file(state, "/deep/nested/file.md", "deep", [])

      assert state.files["/deep/nested/file.md"].dirty_content == false
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

      assert state.files["/Memories/note.txt"].dirty_content == false

      # Files elsewhere go to default config (persisted)
      assert {:ok, _entry, state} =
               FileSystemState.write_file(state, "/other/file.txt", "other", [])

      assert state.files["/other/file.txt"].dirty_content == false
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
      assert state.files["/notes.txt"].dirty_content == false

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

      # 4 files total (directories are no longer stored as entries)
      assert stats.total_files == 4
      # 2 scratch files (no matching config)
      assert stats.memory_files == 2
      # 2 Memories files (matching config)
      assert stats.persisted_files == 2
      # New files are persisted immediately, so no dirty files
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

      # Create file with a specific mime_type
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "initial", mime_type: "text/plain")

      assert state.files["/Memories/doc.txt"].metadata.mime_type == "text/plain"

      # Update content — mime_type should be preserved
      {:ok, entry, _state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "updated content", [])

      assert entry.content == "updated content"
      assert entry.metadata.mime_type == "text/plain"
    end

    test "returns the entry in the result", %{state: state} do
      {:ok, entry, _state} =
        FileSystemState.write_file(state, "/scratch/test.txt", "hello", [])

      assert entry.path == "/scratch/test.txt"
      assert entry.content == "hello"
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
          {:ok, file} =
            Sagents.FileSystem.FileEntry.new_indexed_file("/Memories/Characters/Hero")

          {:ok, [file]}
        end
      end

      state = add_persistence_config(state, TestPersistenceRichIndex)

      file = state.files["/Memories/Characters/Hero"]
      assert file != nil
      assert file.loaded == false
    end
  end
end
