defmodule Sagents.FileSystem.PersistenceIntegrationTest do
  use Sagents.BaseCase, async: false

  alias Sagents.FileSystemServer
  alias Sagents.FileSystem.Persistence.Disk
  alias Sagents.FileSystem.FileSystemConfig

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    # Note: Registry is started globally in test_helper.exs

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

    %{agent_id: agent_id, tmp_dir: tmp_dir}
  end

  # Helper to create persistence config for tests
  defp make_config(module, base_dir, tmp_dir, opts \\ []) do
    debounce_ms = Keyword.get(opts, :debounce_ms, 100)
    storage_opts = [path: tmp_dir] ++ Keyword.get(opts, :storage_opts, [])

    {:ok, config} =
      FileSystemConfig.new(%{
        base_directory: base_dir,
        persistence_module: module,
        debounce_ms: debounce_ms,
        storage_opts: storage_opts
      })

    config
  end

  describe "full persistence workflow" do
    test "new file persists to disk immediately", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Write a new file to persisted directory
      path = "/Memories/test.txt"
      content = "test content"
      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, content)

      # New file should be persisted immediately (dirty == false)
      entry = get_entry(agent_id, path)
      assert entry.content == content
      assert entry.dirty_content == false

      # Verify file exists on disk immediately (no debounce needed)
      disk_path = Path.join(tmp_dir, "test.txt")
      assert File.exists?(disk_path)
      assert File.read!(disk_path) == content
    end

    test "updates to existing file persist after debounce", %{
      agent_id: agent_id,
      tmp_dir: tmp_dir
    } do
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      path = "/Memories/test.txt"
      # Create file first (persists immediately)
      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, "initial")

      # Update the file
      assert {:ok, _entry} =
               FileSystemServer.write_file({:agent, agent_id}, path, "updated content")

      # File should be dirty after update
      entry = get_entry(agent_id, path)
      assert entry.dirty_content == true

      # Wait for debounce
      Process.sleep(150)

      # File should now be clean
      clean_entry = get_entry(agent_id, path)
      assert clean_entry.dirty_content == false

      # Verify updated content on disk
      disk_path = Path.join(tmp_dir, "test.txt")
      assert File.read!(disk_path) == "updated content"
    end

    test "rapid writes batch into single persist", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      # Track persistence calls
      test_pid = self()

      defmodule TrackingDisk do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(entry, opts) do
          send(:test_process, {:persisted, entry.path, System.monotonic_time()})
          Sagents.FileSystem.Persistence.Disk.write_to_storage(entry, opts)
        end

        def load_from_storage(entry, opts) do
          Sagents.FileSystem.Persistence.Disk.load_from_storage(entry, opts)
        end

        def delete_from_storage(entry, opts) do
          Sagents.FileSystem.Persistence.Disk.delete_from_storage(entry, opts)
        end

        def list_persisted_entries(agent_id, opts) do
          Sagents.FileSystem.Persistence.Disk.list_persisted_entries(agent_id, opts)
        end
      end

      Process.register(test_pid, :test_process)

      config = make_config(TrackingDisk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      path = "/Memories/rapid.txt"

      # First write creates the file (persists immediately)
      FileSystemServer.write_file({:agent, agent_id}, path, "version 1")
      # Consume the immediate persist message
      assert_received {:persisted, ^path, _time}

      # Subsequent writes are updates (debounced)
      for i <- 2..10 do
        FileSystemServer.write_file({:agent, agent_id}, path, "version #{i}")
        Process.sleep(10)
      end

      # Wait for debounce
      Process.sleep(150)

      # Should only have persisted once for all debounced updates
      assert_received {:persisted, ^path, _time}
      refute_received {:persisted, ^path, _time}
    end

    test "memory files are not persisted", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Write to non-persisted directory
      path = "/scratch/temp.txt"
      content = "temporary content"
      assert {:ok, _entry} = FileSystemServer.write_file({:agent, agent_id}, path, content)

      # File should be in ETS, memory-only (dirty cleared since no backend)
      entry = get_entry(agent_id, path)
      assert entry.dirty_content == false

      # Wait longer than debounce
      Process.sleep(150)

      # File should NOT exist on disk
      disk_path = Path.join(tmp_dir, "temp.txt")
      refute File.exists?(disk_path)
    end

    test "flush_all persists immediately", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      config = make_config(Disk, "Memories", tmp_dir, debounce_ms: 10000)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Create files (persisted immediately)
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "content1")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "content2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file3.txt", "content3")

      # New files are already persisted, dirty == 0
      {:ok, stats_clean} = FileSystemServer.stats({:agent, agent_id})
      assert stats_clean.dirty_files == 0

      # Update files to make them dirty
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "content1_v2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "content2_v2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file3.txt", "content3_v2")

      # Verify they're dirty
      {:ok, stats_before} = FileSystemServer.stats({:agent, agent_id})
      assert stats_before.dirty_files == 3

      # Flush all
      assert :ok = FileSystemServer.flush_all({:agent, agent_id})

      # Give time to process
      Process.sleep(100)

      # All should be clean now
      {:ok, stats_after} = FileSystemServer.stats({:agent, agent_id})
      assert stats_after.dirty_files == 0

      # All files should exist on disk with updated content
      for i <- 1..3 do
        disk_path = Path.join(tmp_dir, "file#{i}.txt")
        assert File.exists?(disk_path)
        assert File.read!(disk_path) == "content#{i}_v2"
      end
    end

    test "termination flushes pending writes", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      config = make_config(Disk, "Memories", tmp_dir, debounce_ms: 10000)

      {:ok, pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Create files (persisted immediately)
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "data1")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "data2")

      # Update files to make them dirty (debounce pending with long timer)
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "data1_v2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "data2_v2")

      # Stop the server immediately (should flush pending writes on terminate)
      GenServer.stop(pid, :normal)

      # Updated content should be on disk
      disk_path1 = Path.join(tmp_dir, "file1.txt")
      disk_path2 = Path.join(tmp_dir, "file2.txt")

      assert File.exists?(disk_path1)
      assert File.exists?(disk_path2)
      assert File.read!(disk_path1) == "data1_v2"
      assert File.read!(disk_path2) == "data2_v2"
    end

    test "delete removes file from disk immediately", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Write and persist file
      path = "/Memories/delete_me.txt"
      FileSystemServer.write_file({:agent, agent_id}, path, "content")

      # Wait for persist
      Process.sleep(150)

      disk_path = Path.join(tmp_dir, "delete_me.txt")
      assert File.exists?(disk_path)

      # Delete file
      assert :ok = FileSystemServer.delete_file({:agent, agent_id}, path)

      # Should be gone from ETS
      assert !FileSystemServer.file_exists?({:agent, agent_id}, path)

      # Should be gone from disk (no debounce on delete)
      refute File.exists?(disk_path)
    end
  end

  describe "lazy loading" do
    test "indexes persisted files on startup without loading content", %{
      agent_id: agent_id,
      tmp_dir: tmp_dir
    } do
      # First: create server, write files, persist, then stop
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, pid1} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file1.txt", "content1")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/file2.txt", "content2")

      Process.sleep(150)
      GenServer.stop(pid1, :normal)

      # Second: start new server (should index files)
      # Note: Lazy loading indexing would need to be implemented in FileSystemState.new/1
      # For now, this tests the disk backend's list_persisted_entries capability
      {:ok, entries} =
        Disk.list_persisted_entries(agent_id, path: tmp_dir, base_directory: "Memories")

      paths = Enum.map(entries, & &1.path)
      assert length(entries) == 2
      assert "/Memories/file1.txt" in paths
      assert "/Memories/file2.txt" in paths
    end
  end

  describe "custom memories directory" do
    test "uses custom memories_directory for persistence", %{
      agent_id: agent_id,
      tmp_dir: tmp_dir
    } do
      config = make_config(Disk, "persistent", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Files under /persistent/ should be persisted
      FileSystemServer.write_file({:agent, agent_id}, "/persistent/data.txt", "persisted")

      entry = get_entry(agent_id, "/persistent/data.txt")
      assert entry.dirty_content == false

      Process.sleep(150)

      disk_path = Path.join(tmp_dir, "data.txt")
      assert File.exists?(disk_path)
      assert File.read!(disk_path) == "persisted"

      # Files under /Memories/ should NOT be persisted with this config
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/temp.txt", "not persisted")

      entry2 = get_entry(agent_id, "/Memories/temp.txt")
      assert entry2.dirty_content == false

      Process.sleep(150)

      disk_path2 = Path.join(tmp_dir, "temp.txt")
      refute File.exists?(disk_path2)
    end
  end

  describe "nested directory persistence" do
    test "handles deeply nested file paths", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      path = "/Memories/year/2024/month/10/day/30/log.txt"
      content = "deep nested content"

      FileSystemServer.write_file({:agent, agent_id}, path, content)

      Process.sleep(150)

      disk_path = Path.join([tmp_dir, "year", "2024", "month", "10", "day", "30", "log.txt"])
      assert File.exists?(disk_path)
      assert File.read!(disk_path) == content
    end

    test "lists files from nested directories", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      files = [
        "/Memories/root.txt",
        "/Memories/dir1/file1.txt",
        "/Memories/dir1/subdir/file2.txt",
        "/Memories/dir2/file3.txt"
      ]

      for path <- files do
        FileSystemServer.write_file({:agent, agent_id}, path, "content")
      end

      Process.sleep(150)

      {:ok, listed_entries} =
        Disk.list_persisted_entries(agent_id, path: tmp_dir, base_directory: "Memories")

      listed_paths = Enum.map(listed_entries, & &1.path)
      assert length(listed_entries) == 4

      for path <- files do
        assert path in listed_paths
      end
    end
  end

  describe "concurrent SubAgent simulation" do
    test "multiple writers (simulating SubAgents) don't lose data", %{
      agent_id: agent_id,
      tmp_dir: tmp_dir
    } do
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Simulate 10 SubAgents writing concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            FileSystemServer.write_file(
              {:agent, agent_id},
              "/Memories/subagent_#{i}.txt",
              "result #{i}"
            )
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Wait for all debounces
      Process.sleep(200)

      # All files should be on disk
      {:ok, entries} =
        Disk.list_persisted_entries(agent_id, path: tmp_dir, base_directory: "Memories")

      assert length(entries) == 10

      for i <- 1..10 do
        disk_path = Path.join(tmp_dir, "subagent_#{i}.txt")
        assert File.exists?(disk_path)
        assert File.read!(disk_path) == "result #{i}"
      end
    end
  end

  describe "stats integration" do
    test "stats reflect persistence state correctly", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      config = make_config(Disk, "Memories", tmp_dir)

      {:ok, _pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Initial state
      {:ok, stats} = FileSystemServer.stats({:agent, agent_id})
      assert stats.total_files == 0
      assert stats.dirty_files == 0

      # Create files (new persisted files persist immediately)
      FileSystemServer.write_file({:agent, agent_id}, "/scratch/temp.txt", "temp")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/persist1.txt", "data1")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/persist2.txt", "data2")

      # New files are persisted immediately, so dirty_files == 0
      # 3 files (directories are no longer stored as entries)
      {:ok, stats_after_create} = FileSystemServer.stats({:agent, agent_id})
      assert stats_after_create.total_files == 3
      # 1 scratch file (no matching config)
      assert stats_after_create.memory_files == 1
      # 2 Memories files (matching config)
      assert stats_after_create.persisted_files == 2
      assert stats_after_create.dirty_files == 0

      # Update persisted files to make them dirty
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/persist1.txt", "data1_v2")
      FileSystemServer.write_file({:agent, agent_id}, "/Memories/persist2.txt", "data2_v2")

      # Check stats before debounce persist
      {:ok, stats_before} = FileSystemServer.stats({:agent, agent_id})
      assert stats_before.total_files == 3
      assert stats_before.dirty_files == 2

      # Wait for persist
      Process.sleep(150)

      # Check stats after persist
      {:ok, stats_after} = FileSystemServer.stats({:agent, agent_id})
      assert stats_after.total_files == 3
      assert stats_after.dirty_files == 0
    end
  end

  describe "error handling" do
    test "continues operation after persist failure", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      defmodule FailingPersistence do
        @behaviour Sagents.FileSystem.Persistence

        def write_to_storage(_entry, _opts) do
          {:error, :disk_full}
        end

        def load_from_storage(_entry, _opts), do: {:error, :enoent}
        def delete_from_storage(_entry, _opts), do: :ok
        def list_persisted_entries(_agent_id, _opts), do: {:ok, []}
      end

      config = make_config(FailingPersistence, "Memories", tmp_dir)

      {:ok, pid} =
        FileSystemServer.start_link(
          scope_key: {:agent, agent_id},
          configs: [config]
        )

      # Write should succeed (ETS write)
      assert {:ok, _entry} =
               FileSystemServer.write_file({:agent, agent_id}, "/Memories/file.txt", "content")

      # File should be in ETS
      entry = get_entry(agent_id, "/Memories/file.txt")
      assert entry.content == "content"

      # Wait for persist attempt (should fail but not crash)
      Process.sleep(150)

      # Server should still be alive
      assert Process.alive?(pid)

      # File should still be dirty (persist failed)
      entry_after = get_entry(agent_id, "/Memories/file.txt")
      assert entry_after.dirty_content == true
    end
  end
end
