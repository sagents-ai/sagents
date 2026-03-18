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
      assert entry.dirty == false
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
      assert entry.dirty == false
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
      assert state.files[path].dirty == false

      # Update the existing file (should debounce)
      assert {:ok, _entry, new_state} = FileSystemState.write_file(state, path, "updated content", [])

      entry = Map.get(new_state.files, path)
      assert entry.persistence == :persisted
      assert entry.dirty == true
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

      assert {:ok, _entry, state} = FileSystemState.write_file(state, "/deep/nested/file.md", "deep", [])
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
      assert {:ok, _entry, state} = FileSystemState.write_file(state, "/other/file.txt", "other", [])
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

      assert stats.total_files == 4
      assert stats.memory_files == 2
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
      {:ok, _entry, state} = FileSystemState.write_file(state, "/scratch/temp1.txt", "temp data 1", [])
      {:ok, _entry, state} = FileSystemState.write_file(state, "/scratch/temp2.txt", "temp data 2", [])

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
      {:ok, _entry, state} = FileSystemState.write_file(state, "/Memories/file.txt", "updated", [])

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
      assert entry1.dirty == false
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
      {:ok, _entry, state} = FileSystemState.write_file(state, "/Memories/file.txt", "modified", [])

      # Verify it's dirty and loaded
      entry = state.files["/Memories/file.txt"]
      assert entry.dirty == true
      assert entry.loaded == true
      assert entry.content == "modified"

      # Reset
      reset_state = FileSystemState.reset(state)

      # File should still be indexed (persisted), but unloaded and not dirty
      assert Map.has_key?(reset_state.files, "/Memories/file.txt")
      reset_entry = reset_state.files["/Memories/file.txt"]
      assert reset_entry.loaded == false
      assert reset_entry.dirty == false
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

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty: false}}
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
      {:ok, entry, state} =
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

  describe "update_metadata/4" do
    setup do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"
      {:ok, state} = FileSystemState.new(scope_key: {:agent, agent_id})
      %{state: state}
    end

    test "updates custom metadata on existing file", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/test.txt", "data", [])

      {:ok, updated, _state} =
        FileSystemState.update_metadata(state, "/test.txt", %{"tags" => ["important"]})

      assert updated.metadata.custom == %{"tags" => ["important"]}
    end

    test "merges with existing custom metadata", %{state: state} do
      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/test.txt", "data",
          custom: %{"author" => "Alice"}
        )

      {:ok, updated, _state} =
        FileSystemState.update_metadata(state, "/test.txt", %{"tags" => ["draft"]})

      assert updated.metadata.custom == %{"author" => "Alice", "tags" => ["draft"]}
    end

    test "updates title via opts", %{state: state} do
      {:ok, _entry, state} = FileSystemState.write_file(state, "/test.txt", "data", [])

      {:ok, updated, _state} =
        FileSystemState.update_metadata(state, "/test.txt", %{}, title: "New Title")

      assert updated.title == "New Title"
    end

    test "returns error for nonexistent file", %{state: state} do
      assert {:error, :enoent, _state} =
               FileSystemState.update_metadata(state, "/nope.txt", %{})
    end

    test "marks persisted file dirty", %{state: state} do
      defmodule TestPersistenceUpdateMeta do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistenceUpdateMeta)

      {:ok, _entry, state} =
        FileSystemState.write_file(state, "/Memories/doc.txt", "data", [])

      # File is clean after immediate persist
      assert state.files["/Memories/doc.txt"].dirty == false

      # Update metadata
      {:ok, updated, state} =
        FileSystemState.update_metadata(state, "/Memories/doc.txt", %{"tags" => ["a"]})

      assert updated.dirty == true
      # Debounce timer should be scheduled
      assert Map.has_key?(state.debounce_timers, "/Memories/doc.txt")
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

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      state = add_persistence_config(state, TestPersistenceDir)

      {:ok, entry, _state} =
        FileSystemState.create_directory(state, "/Memories/Chapters", title: "Chapters")

      assert entry.persistence == :persisted
      assert entry.dirty == false
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

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty: false}}
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
end
