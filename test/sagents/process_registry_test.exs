defmodule Sagents.ProcessRegistryTest do
  use ExUnit.Case, async: true

  alias Sagents.ProcessRegistry

  describe "via_tuple/1" do
    test "returns a via tuple using the configured registry module" do
      result = ProcessRegistry.via_tuple({:agent_server, "test-123"})
      assert {:via, Registry, {Sagents.Registry, {:agent_server, "test-123"}}} = result
    end
  end

  describe "lookup/1" do
    test "returns empty list for unregistered key" do
      assert [] = ProcessRegistry.lookup({:agent_server, "nonexistent"})
    end

    test "returns pid for registered process" do
      key = {:test_process, "lookup-#{System.unique_integer([:positive])}"}
      name = ProcessRegistry.via_tuple(key)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      assert [{^pid, _value}] = ProcessRegistry.lookup(key)

      Agent.stop(pid)
    end
  end

  describe "select/1" do
    test "selects matching entries" do
      key = {:test_select, "select-#{System.unique_integer([:positive])}"}
      name = ProcessRegistry.via_tuple(key)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      results =
        ProcessRegistry.select([
          {{{:test_select, :"$1"}, :_, :_}, [], [:"$1"]}
        ])

      assert is_list(results)

      Agent.stop(pid)
    end
  end

  describe "count/0" do
    test "returns a non-negative integer" do
      assert ProcessRegistry.count() >= 0
    end
  end

  describe "registry_module/0" do
    test "returns Registry by default" do
      assert ProcessRegistry.registry_module() == Registry
    end
  end

  describe "watched_name/0" do
    test "names the partition rather than the registry under the local backend" do
      # `Registry.start_link/1` registers a `Registry.Supervisor` under
      # `Sagents.Registry`, but the ETS tables holding registrations belong to
      # its partition child. The supervisor can restart that partition with
      # empty tables and keep its own name and pid, so watching the name would
      # miss the failure. This is what `Sagents.RegistryWatcher` monitors.
      assert ProcessRegistry.watched_name() == Sagents.Registry.PIDPartition0
      refute ProcessRegistry.watched_name() == ProcessRegistry.registry_name()
    end

    test "the named process exists and owns the registry's tables" do
      partition = Process.whereis(ProcessRegistry.watched_name())

      assert is_pid(partition), "expected #{inspect(ProcessRegistry.watched_name())} to be alive"

      # It traps exits because it links to every registered process, which is
      # both why it outlives its supervisor briefly and why registered
      # processes survive its death rather than dying with it.
      assert Process.info(partition, :trap_exit) == {:trap_exit, true}
    end
  end

  describe "child_spec/1" do
    test "returns a valid child spec for default registry" do
      spec = ProcessRegistry.child_spec([])

      # Started through Sagents.LocalRegistry rather than Registry directly, so
      # a restart that races the outgoing registry's terminating partition
      # retries instead of taking Sagents.Supervisor down with it.
      assert %{
               id: Sagents.Registry,
               start:
                 {Sagents.LocalRegistry, :start_link, [[keys: :unique, name: Sagents.Registry]]},
               type: :supervisor
             } = spec
    end
  end
end
