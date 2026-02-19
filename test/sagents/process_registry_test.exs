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

      assert [{^pid, _}] = ProcessRegistry.lookup(key)

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

  describe "child_spec/1" do
    test "returns a valid child spec for default registry" do
      spec = ProcessRegistry.child_spec([])
      assert {Registry, [keys: :unique, name: Sagents.Registry]} = spec
    end
  end
end
