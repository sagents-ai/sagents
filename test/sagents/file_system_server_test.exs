defmodule Sagents.FileSystemServerTest do
  use Sagents.BaseCase

  alias Sagents.FileSystemServer
  alias Sagents.FileSystem.FileEntry
  alias Sagents.FileSystem.FileSystemConfig

  # Mock persistence modules for testing
  defmodule MockPersistence do
    @behaviour Sagents.FileSystem.Persistence

    def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
    def load_from_storage(_entry, _opts), do: {:error, :enoent}
    def delete_from_storage(_entry, _opts), do: :ok
    def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
  end

  defmodule TestModule do
    @behaviour Sagents.FileSystem.Persistence

    def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
    def load_from_storage(_entry, _opts), do: {:error, :enoent}
    def delete_from_storage(_entry, _opts), do: :ok
    def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
  end

  setup do
    # Note: Registry is started globally in test_helper.exs
    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Cleanup any running FileSystemServer
      # Wrap in try-catch because Registry might be gone already during cleanup
      try do
        case FileSystemServer.whereis({:agent, agent_id}) do
          nil -> :ok
          pid -> GenServer.stop(pid, :normal)
        end
      rescue
        ArgumentError -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    %{agent_id: agent_id}
  end

  # Helper to create persistence config for tests
  defp make_config(module, base_dir, opts \\ []) do
    debounce_ms = Keyword.get(opts, :debounce_ms, 100)
    storage_opts = Keyword.get(opts, :storage_opts, [])

    {:ok, config} =
      FileSystemConfig.new(%{
        base_directory: base_dir,
        persistence_module: module,
        debounce_ms: debounce_ms,
        storage_opts: storage_opts
      })

    config
  end

  describe "start_link/1" do
    test "starts with minimal config", %{agent_id: agent_id} do
      assert {:ok, pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})
      assert Process.alive?(pid)
    end

    test "starts with persistence configuration", %{agent_id: agent_id} do
      config =
        make_config(MockPersistence, "Memories",
          debounce_ms: 1000,
          storage_opts: [path: "/tmp/test"]
        )

      opts = [
        scope_key: {:agent, agent_id},
        configs: [config]
      ]

      assert {:ok, pid} = FileSystemServer.start_link(opts)
      assert Process.alive?(pid)

      # Verify configuration
      configs = FileSystemServer.get_persistence_configs({:agent, agent_id})
      assert map_size(configs) == 1
      assert %{"Memories" => loaded_config} = configs
      assert loaded_config.persistence_module == MockPersistence
    end

    test "requires agent_id", %{agent_id: _agent_id} do
      assert_raise KeyError, fn ->
        FileSystemServer.start_link([])
      end
    end

    test "can be found via whereis", %{agent_id: agent_id} do
      assert FileSystemServer.whereis({:agent, agent_id}) == nil

      {:ok, pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      assert FileSystemServer.whereis({:agent, agent_id}) == pid
    end
  end

  describe "write_file/4" do
    test "writes a memory file", %{agent_id: agent_id} do
      {:ok, pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      path = "/scratch/test.txt"
      content = "test content"

      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, content)

      # Verify file exists via API
      assert FileSystemServer.file_exists?({:agent, agent_id}, path)
      assert {:ok, %{content: ^content}} = FileSystemServer.read_file({:agent, agent_id}, path)

      # Verify internal state
      state = :sys.get_state(pid)
      entry = Map.get(state.files, path)
      assert entry.path == path
      assert entry.content == content
      assert entry.loaded == true
      # Memory-only — nothing to flush
      assert entry.dirty_content == false
    end

    test "writes to unconfigured directory as memory-only", %{
      agent_id: agent_id
    } do
      {:ok, pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      path = "/Memories/important.txt"
      content = "important data"

      # No persistence config for /Memories/, so should be memory-only
      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, content)

      # No persistence config matched, so the file lives in memory only
      # (the state machine has nothing to persist it to)
      state = :sys.get_state(pid)
      entry = Map.get(state.files, path)
      assert entry.dirty_content == false
    end

    test "writes new persisted file and persists immediately", %{agent_id: agent_id} do
      defmodule TestPersistence do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config = make_config(TestPersistence, "Memories")

      {:ok, pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      path = "/Memories/file.txt"
      content = "persisted content"

      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, content)

      # New file should be persisted immediately (dirty == false)
      state = :sys.get_state(pid)
      entry = Map.get(state.files, path)
      assert entry.dirty_content == false
      assert entry.loaded == true
    end

    test "updates existing persisted file and schedules debounce timer", %{agent_id: agent_id} do
      defmodule TestPersistenceUpdate do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config = make_config(TestPersistenceUpdate, "Memories")

      {:ok, pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      path = "/Memories/file.txt"

      # Create file first (persists immediately)
      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, "initial")
      state = :sys.get_state(pid)
      assert Map.get(state.files, path).dirty_content == false

      # Update existing file (should debounce)
      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, "updated")
      state = :sys.get_state(pid)
      entry = Map.get(state.files, path)
      assert entry.dirty_content == true

      # Wait for debounce timer to fire
      Process.sleep(150)

      # File should now be clean
      state = :sys.get_state(pid)
      clean_entry = Map.get(state.files, path)
      assert clean_entry.dirty_content == false
    end

    test "updates existing file and resets debounce timer", %{agent_id: agent_id} do
      test_pid = self()

      defmodule TestPersistence2 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, opts) do
          # Get test_pid from opts
          case Keyword.get(opts, :test_pid) do
            nil -> :ok
            test_pid -> send(test_pid, {:persisted, System.monotonic_time()})
          end

          {:ok, %{entry | dirty_content: false}}
        end

        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config = make_config(TestPersistence2, "Memories", storage_opts: [test_pid: test_pid])

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      path = "/Memories/file.txt"

      # Create file first (persists immediately)
      FileSystemServer.write_file({:agent, agent_id}, path, "v1")
      # Consume the immediate persist message for the new file
      assert_received {:persisted, _time}

      # Now update multiple times rapidly (these should debounce)
      Process.sleep(50)
      FileSystemServer.write_file({:agent, agent_id}, path, "v2")
      Process.sleep(50)
      FileSystemServer.write_file({:agent, agent_id}, path, "v3")

      # Should only persist once after all updates complete
      Process.sleep(150)

      # Should receive only one persist call for the debounced updates
      assert_received {:persisted, _time}
      refute_received {:persisted, _time}
    end

    test "writes with custom mime_type", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      path = "/data.json"
      content = ~s({"key": "value"})

      opts = [mime_type: "application/json"]

      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, content, opts)

      entry = get_entry(agent_id, path)
      assert entry.metadata.mime_type == "application/json"
    end
  end

  describe "delete_file/2" do
    test "deletes memory file", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      path = "/scratch/file.txt"
      FileSystemServer.write_file({:agent, agent_id}, path, "data")
      assert FileSystemServer.file_exists?({:agent, agent_id}, path)

      assert :ok = FileSystemServer.delete_file({:agent, agent_id}, path)
      assert !FileSystemServer.file_exists?({:agent, agent_id}, path)
    end

    test "deletes persisted file and cancels timer", %{agent_id: agent_id} do
      test_pid = self()

      defmodule TestPersistence3 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}

        def load_from_storage(_entry, _opts), do: {:error, :enoent}

        def delete_from_storage(_entry, opts) do
          # Get test_pid from opts
          case Keyword.get(opts, :test_pid) do
            nil -> :ok
            test_pid -> send(test_pid, :deleted_from_storage)
          end

          :ok
        end

        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config =
        make_config(TestPersistence3, "Memories",
          debounce_ms: 5000,
          storage_opts: [test_pid: test_pid]
        )

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      path = "/Memories/file.txt"
      # Create file (persists immediately, dirty == false)
      FileSystemServer.write_file({:agent, agent_id}, path, "data")

      # Update the file to make it dirty (pending persist)
      FileSystemServer.write_file({:agent, agent_id}, path, "updated data")
      {:ok, stats} = FileSystemServer.stats({:agent, agent_id})
      assert stats.dirty_files == 1

      # Delete the file
      assert :ok = FileSystemServer.delete_file({:agent, agent_id}, path)

      # Verify storage deletion was called
      assert_received :deleted_from_storage

      # Verify file is gone from ETS
      assert !FileSystemServer.file_exists?({:agent, agent_id}, path)

      # Verify no dirty files remain
      {:ok, stats} = FileSystemServer.stats({:agent, agent_id})
      assert stats.dirty_files == 0
    end

    test "deletes non-existent file returns ok", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      assert {:error, "File not found"} =
               FileSystemServer.delete_file({:agent, agent_id}, "/nonexistent.txt")
    end
  end

  describe "flush_all/1" do
    test "persists all dirty files immediately", %{agent_id: agent_id} do
      test_pid = self()

      defmodule TestPersistence4 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, opts) do
          # Get test_pid from opts
          case Keyword.get(opts, :test_pid) do
            nil -> :ok
            test_pid -> send(test_pid, {:flushed, entry.path})
          end

          {:ok, %{entry | dirty_content: false}}
        end

        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config =
        make_config(TestPersistence4, "Memories",
          debounce_ms: 10000,
          storage_opts: [test_pid: test_pid]
        )

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Create files (persisted immediately)
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "data1")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "data2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file3.txt", "data3")

      # Consume the immediate persist messages for new files
      assert_received {:flushed, "/Memories/file1.txt"}
      assert_received {:flushed, "/Memories/file2.txt"}
      assert_received {:flushed, "/Memories/file3.txt"}

      # Update files to make them dirty
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "data1_v2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "data2_v2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file3.txt", "data3_v2")

      # Verify files are dirty (timers pending)
      {:ok, stats_before} = FileSystemServer.stats({:agent, agent_id})
      assert stats_before.dirty_files == 3

      # Flush all
      assert :ok = FileSystemServer.flush_all({:agent, agent_id})

      # Should receive persist calls for all dirty files
      assert_received {:flushed, "/Memories/file1.txt"}
      assert_received {:flushed, "/Memories/file2.txt"}
      assert_received {:flushed, "/Memories/file3.txt"}

      # Give it time to process
      Process.sleep(50)

      # Verify all files are now clean and no timers pending
      {:ok, stats_after} = FileSystemServer.stats({:agent, agent_id})
      assert stats_after.dirty_files == 0
    end
  end

  describe "stats/1" do
    test "returns filesystem statistics", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      # Empty filesystem
      {:ok, stats} = FileSystemServer.stats({:agent, agent_id})
      assert stats.total_files == 0
      assert stats.memory_files == 0
      assert stats.persisted_files == 0
      assert stats.loaded_files == 0
      assert stats.not_loaded_files == 0
      assert stats.dirty_files == 0
      assert stats.total_size == 0
    end

    test "counts different file types correctly", %{agent_id: agent_id} do
      defmodule TestPersistence5 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config = make_config(TestPersistence5, "Memories", debounce_ms: 5000)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Write memory files
      FileSystemServer.write_file({:agent, agent_id}, "/scratch/file1.txt", "data1")
      FileSystemServer.write_file({:agent, agent_id}, "/scratch/file2.txt", "data2")

      # Write persisted files
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file3.txt", "data3")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file4.txt", "data4")

      {:ok, stats} = FileSystemServer.stats({:agent, agent_id})

      # 4 files (directories are no longer stored as entries)
      assert stats.total_files == 4
      # 2 scratch files (no matching config)
      assert stats.memory_files == 2
      # 2 Memories files (matching config)
      assert stats.persisted_files == 2
      assert stats.loaded_files == 4
      assert stats.not_loaded_files == 0
      # New files are persisted immediately, so no dirty files
      assert stats.dirty_files == 0
      assert stats.total_size == byte_size("data1data2data3data4")
    end
  end

  describe "get_persistence_configs/1" do
    test "returns persistence configurations", %{agent_id: agent_id} do
      config = make_config(TestModule, "data", storage_opts: [path: "/test"])

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      configs = FileSystemServer.get_persistence_configs({:agent, agent_id})

      assert map_size(configs) == 1
      assert %{"data" => loaded_config} = configs
      assert loaded_config.persistence_module == TestModule
      assert loaded_config.storage_opts[:path] == "/test"
      assert loaded_config.base_directory == "data"
    end

    test "returns empty map when no persistence configured", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      configs = FileSystemServer.get_persistence_configs({:agent, agent_id})

      assert configs == %{}
    end
  end

  describe "terminate/2" do
    test "flushes pending writes on termination", %{agent_id: agent_id} do
      defmodule TestPersistence6 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts) do
          send(:test_process, {:flushed_on_terminate, entry.path})
          {:ok, %{entry | dirty_content: false}}
        end

        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      Process.register(self(), :test_process)

      config = make_config(TestPersistence6, "Memories", debounce_ms: 10000)

      {:ok, pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Create files (persisted immediately)
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "data1")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "data2")

      # Consume the immediate persist messages for new files
      assert_received {:flushed_on_terminate, "/Memories/file1.txt"}
      assert_received {:flushed_on_terminate, "/Memories/file2.txt"}

      # Update files to make them dirty (debounce pending)
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "data1_v2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "data2_v2")

      # Stop the server (should flush pending writes)
      GenServer.stop(pid, :normal)

      # Should have received flush calls for dirty updates
      assert_received {:flushed_on_terminate, "/Memories/file1.txt"}
      assert_received {:flushed_on_terminate, "/Memories/file2.txt"}
    end
  end

  describe "configurable memories directory" do
    test "uses custom memories_directory from storage_opts", %{agent_id: agent_id} do
      defmodule TestPersistence7 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, _opts), do: {:ok, %{entry | dirty_content: false}}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config = make_config(TestPersistence7, "persistent")

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Files under /persistent/ should be persisted (dirty cleared after write)
      FileSystemServer.write_file({:agent, agent_id}, "/persistent/file.txt", "data")
      entry = get_entry(agent_id, "/persistent/file.txt")
      assert entry.dirty_content == false

      # Files under /Memories/ should be memory-only with this config
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file.txt", "data")
      entry2 = get_entry(agent_id, "/Memories/file.txt")
      assert entry2.dirty_content == false
    end
  end

  describe "register_files/2" do
    test "registers a single file entry", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      # Create a file entry
      {:ok, entry} = FileEntry.new_file("/test/data.txt", "test content")

      # Register it
      assert :ok = FileSystemServer.register_files({:agent, agent_id}, entry)

      # Should be able to read it immediately
      assert {:ok, entry} = FileSystemServer.read_file({:agent, agent_id}, "/test/data.txt")
      assert entry.content == "test content"
    end

    test "registers multiple file entries", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      # Create multiple file entries
      {:ok, entry1} = FileEntry.new_file("/test/file1.txt", "content1")
      {:ok, entry2} = FileEntry.new_file("/test/file2.txt", "content2")
      {:ok, entry3} = FileEntry.new_file("/test/file3.txt", "content3")

      # Register them all at once
      assert :ok = FileSystemServer.register_files({:agent, agent_id}, [entry1, entry2, entry3])

      # All should be readable
      assert {:ok, %{content: "content1"}} =
               FileSystemServer.read_file({:agent, agent_id}, "/test/file1.txt")

      assert {:ok, %{content: "content2"}} =
               FileSystemServer.read_file({:agent, agent_id}, "/test/file2.txt")

      assert {:ok, %{content: "content3"}} =
               FileSystemServer.read_file({:agent, agent_id}, "/test/file3.txt")
    end

    test "registers indexed files for lazy loading", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      # Create indexed file entries (not loaded)
      {:ok, entry1} = FileEntry.new_indexed_file("/data/lazy1.txt")
      {:ok, entry2} = FileEntry.new_indexed_file("/data/lazy2.txt")

      # Register them
      assert :ok = FileSystemServer.register_files({:agent, agent_id}, [entry1, entry2])

      # Files should exist but not be loaded
      e1 = get_entry(agent_id, "/data/lazy1.txt")
      assert e1.loaded == false
      assert e1.content == nil

      e2 = get_entry(agent_id, "/data/lazy2.txt")
      assert e2.loaded == false
      assert e2.content == nil
    end
  end

  describe "subscriber events (direct send)" do
    setup do
      agent_id = "pubsub_test_agent_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        try do
          case FileSystemServer.whereis({:agent, agent_id}) do
            nil -> :ok
            pid -> GenServer.stop(pid, :normal)
          end
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      %{agent_id: agent_id}
    end

    test "subscribe returns error when process not found" do
      assert {:error, :process_not_found} = FileSystemServer.subscribe({:agent, "nonexistent"})
    end

    test "unsubscribe is a no-op when process not found" do
      assert :ok = FileSystemServer.unsubscribe({:agent, "nonexistent"})
    end

    test "subscribe returns server pid and monitor ref", %{agent_id: agent_id} do
      {:ok, server_pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      assert {:ok, ^server_pid, ref} = FileSystemServer.subscribe({:agent, agent_id})
      assert is_reference(ref)
    end

    test "broadcasts file_updated on write", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      {:ok, _pid, _ref} = FileSystemServer.subscribe({:agent, agent_id})

      {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "content")

      assert_receive {:file_system, {:file_updated, path}}, 100
      assert path == "/test.txt"
    end

    test "broadcasts file_deleted on delete", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "content")

      {:ok, _pid, _ref} = FileSystemServer.subscribe({:agent, agent_id})

      :ok = FileSystemServer.delete_file({:agent, agent_id}, "/test.txt")

      assert_receive {:file_system, {:file_deleted, path}}, 100
      assert path == "/test.txt"
    end

    test "broadcasts correct path on write", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, "/z.txt", "z")
      {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, "/a.txt", "a")

      {:ok, _pid, _ref} = FileSystemServer.subscribe({:agent, agent_id})

      {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, "/m.txt", "m")

      assert_receive {:file_system, {:file_updated, path}}, 100
      assert path == "/m.txt"
    end

    test "can unsubscribe from events", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      {:ok, _pid, _ref} = FileSystemServer.subscribe({:agent, agent_id})
      :ok = FileSystemServer.unsubscribe({:agent, agent_id})

      {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "content")

      refute_receive {:file_system, _}, 50
    end

    test "does not broadcast on write error", %{agent_id: agent_id} do
      defmodule ReadOnlyPersistence do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts), do: {:error, :readonly}
        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config =
        FileSystemConfig.new!(%{
          base_directory: "ReadOnly",
          persistence_module: ReadOnlyPersistence,
          readonly: true
        })

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      {:ok, _pid, _ref} = FileSystemServer.subscribe({:agent, agent_id})

      {:error, _} =
        FileSystemServer.write_file({:agent, agent_id}, "/ReadOnly/test.txt", "content")

      refute_receive {:file_system, _}, 50
    end

    test "initial_subscribers receive events without a subscribe-after-start race",
         %{agent_id: agent_id} do
      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          initial_subscribers: [{:main, self()}]
        )

      # No explicit subscribe call — the seeded subscriber should already be enrolled.
      {:ok, _entry} =
        FileSystemServer.write_file({:agent, agent_id}, "/seeded.txt", "content")

      assert_receive {:file_system, {:file_updated, "/seeded.txt"}}, 100
    end

    test "subscriber crash auto-cleans subscription", %{agent_id: agent_id} do
      {:ok, server_pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      sub =
        spawn(fn ->
          FileSystemServer.subscribe({:agent, agent_id})

          receive do
            :stop -> :ok
          end
        end)

      # Synchronize: wait until the server has processed the subscribe call
      _ = :sys.get_state(server_pid)
      assert Sagents.Publisher.State.count(:sys.get_state(server_pid).publisher) == 1

      Process.exit(sub, :kill)

      # Synchronize again: a follow-up call serializes after the :DOWN handler
      _ = :sys.get_state(server_pid)
      _ = :sys.get_state(server_pid)
      assert Sagents.Publisher.State.count(:sys.get_state(server_pid).publisher) == 0
    end
  end

  describe "concurrent operations" do
    test "handles multiple writes to different files", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      # Simulate concurrent writes
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            FileSystemServer.write_file({:agent, agent_id}, "/file#{i}.txt", "data#{i}")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Verify all files exist
      for i <- 1..10 do
        entry = get_entry(agent_id, "/file#{i}.txt")
        assert entry.content == "data#{i}"
      end
    end
  end

  describe "read_file/2" do
    test "reads memory file directly from ETS", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      # Write a memory file
      {:ok, _entry} =
        FileSystemServer.write_file({:agent, agent_id}, "/scratch/notes.txt", "My notes")

      # Read should work immediately
      assert {:ok, %{content: "My notes"}} =
               FileSystemServer.read_file({:agent, agent_id}, "/scratch/notes.txt")
    end

    test "returns error for nonexistent file", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      assert {:error, :enoent} =
               FileSystemServer.read_file({:agent, agent_id}, "/nonexistent.txt")
    end

    test "lazy loads persisted file on first read", %{agent_id: agent_id} do
      # Create a fake persistence module that tracks when files are loaded
      test_pid = self()

      # Create a shared ETS table for fake storage
      storage_table = :ets.new(:test_storage_8, [:set, :public])
      :ets.insert(storage_table, {"/Memories/data.txt", "persisted content"})

      defmodule TestPersistence8 do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, opts) do
          # Store in ETS to simulate persistence
          storage_table = Keyword.get(opts, :storage_table)
          :ets.insert(storage_table, {entry.path, entry.content})
          {:ok, %{entry | dirty_content: false}}
        end

        def load_from_storage(%{path: path} = entry, opts) do
          # Notify test when load happens
          test_pid = Keyword.get(opts, :test_pid)
          storage_table = Keyword.get(opts, :storage_table)

          if test_pid, do: send(test_pid, {:loaded, path})

          # Load from ETS
          case :ets.lookup(storage_table, path) do
            [{^path, content}] ->
              {:ok, %{entry | content: content, loaded: true, dirty_content: false}}

            [] ->
              {:error, :enoent}
          end
        end

        def delete_from_storage(_entry, _opts), do: :ok

        def list_persisted_entries(_agent_id, opts) do
          # Return entries from ETS
          storage_table = Keyword.get(opts, :storage_table)

          entries =
            :ets.tab2list(storage_table)
            |> Enum.map(fn {path, _} ->
              {:ok, entry} = Sagents.FileSystem.FileEntry.new_indexed_file(path)
              entry
            end)

          {:ok, entries}
        end
      end

      config =
        make_config(TestPersistence8, "Memories",
          storage_opts: [test_pid: test_pid, storage_table: storage_table]
        )

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # File should be indexed but NOT loaded
      entry = get_entry(agent_id, "/Memories/data.txt")
      assert entry.loaded == false
      assert entry.content == nil

      # We should NOT have received a load message yet
      refute_received {:loaded, _}

      # Now read the file - this should trigger lazy loading
      assert {:ok, entry} = FileSystemServer.read_file({:agent, agent_id}, "/Memories/data.txt")
      assert entry.content == "persisted content"

      # Should have received load message
      assert_receive {:loaded, "/Memories/data.txt"}, 100

      # File should now be loaded
      loaded_entry = get_entry(agent_id, "/Memories/data.txt")
      assert loaded_entry.loaded == true
      assert loaded_entry.content == "persisted content"

      # Cleanup
      :ets.delete(storage_table)
    end

    test "supports concurrent reads from ETS without GenServer bottleneck", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      # Write files
      for i <- 1..20 do
        {:ok, _entry} =
          FileSystemServer.write_file({:agent, agent_id}, "/file#{i}.txt", "content#{i}")
      end

      # Simulate concurrent reads
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            FileSystemServer.read_file({:agent, agent_id}, "/file#{i}.txt")
          end)
        end

      # All reads should succeed
      results = Task.await_many(tasks)

      for {result, i} <- Enum.zip(results, 1..20) do
        expected = "content#{i}"
        assert {:ok, %{content: ^expected}} = result
      end
    end

    test "supports concurrent reads after files are loaded", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      # Write multiple files
      for i <- 1..5 do
        {:ok, _entry} =
          FileSystemServer.write_file({:agent, agent_id}, "/file#{i}.txt", "content#{i}")
      end

      # Concurrent reads should all succeed
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            FileSystemServer.read_file({:agent, agent_id}, "/file#{i}.txt")
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed with correct content
      for {result, i} <- Enum.zip(results, 1..5) do
        expected = "content#{i}"
        assert {:ok, %{content: ^expected}} = result
      end
    end
  end

  describe "list_entries/1" do
    test "returns all entries sorted by path", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      FileSystemServer.write_file({:agent, agent_id}, "/z.txt", "z")
      FileSystemServer.write_file({:agent, agent_id}, "/a.txt", "a")

      entries = FileSystemServer.list_entries({:agent, agent_id})

      assert length(entries) == 2
      assert Enum.map(entries, & &1.path) == ["/a.txt", "/z.txt"]
    end

    test "returns empty list for nil scope" do
      assert FileSystemServer.list_entries(nil) == []
    end
  end

  describe "read_file returns FileEntry" do
    test "returns full FileEntry with content", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "hello")

      assert {:ok, entry} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      assert %FileEntry{} = entry
      assert entry.content == "hello"
      assert entry.loaded == true
    end
  end

  describe "write_file returns FileEntry" do
    test "returns the created entry", %{agent_id: agent_id} do
      {:ok, _pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      assert {:ok, entry} =
               FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "data")

      assert %FileEntry{} = entry
      assert entry.content == "data"
      assert entry.path == "/test.txt"
    end
  end

  describe "trap_exit and linked ports" do
    test "ignores {:EXIT, port, _} when a linked port closes", %{agent_id: agent_id} do
      sh = System.find_executable("sh")
      assert sh, "sh executable required for this test"

      {:ok, fs_pid} = FileSystemServer.start_link(scope_key: {:agent, agent_id})

      port =
        Port.open({:spawn_executable, sh}, [
          :binary,
          args: ["-c", "exit 0"]
        ])

      assert is_port(port)
      assert Port.connect(port, fs_pid)
      Port.close(port)

      assert Process.alive?(fs_pid)
      assert {:ok, {:agent, ^agent_id}} = FileSystemServer.get_scope(fs_pid)
    end
  end
end
