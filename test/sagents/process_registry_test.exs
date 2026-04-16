defmodule Sagents.ProcessRegistryTest do
  # :global tests change Application env; keep serial to avoid races with other cases.
  use ExUnit.Case, async: false

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

  describe "global distribution" do
    setup do
      prev = Application.get_env(:sagents, :distribution)
      Application.put_env(:sagents, :distribution, :global)

      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:sagents, :distribution)
        else
          Application.put_env(:sagents, :distribution, prev)
        end
      end)

      :ok
    end

    test "via_tuple/1 uses :global via" do
      result = ProcessRegistry.via_tuple({:agent_server, "g-1"})
      assert {:via, :global, {Sagents.Registry, {:agent_server, "g-1"}}} = result
    end

    test "lookup/1 finds registered process" do
      key = {:test_global, "lookup-#{System.unique_integer([:positive])}"}
      name = ProcessRegistry.via_tuple(key)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      assert [{^pid, _}] = ProcessRegistry.lookup(key)

      Agent.stop(pid)
    end

    test "select/1 returns ids for agent-style match_spec" do
      id = "agent-sel-#{System.unique_integer([:positive])}"
      key = {:agent_server, id}
      name = ProcessRegistry.via_tuple(key)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      results =
        ProcessRegistry.select([
          {{{:agent_server, :"$1"}, :_, :_}, [], [:"$1"]}
        ])

      assert id in results

      Agent.stop(pid)
    end

    test "select/1 returns scope and pid for filesystem match_spec" do
      scope = {:user, System.unique_integer([:positive])}
      key = {:filesystem_server, scope}
      name = ProcessRegistry.via_tuple(key)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      results =
        ProcessRegistry.select([
          {
            {{:filesystem_server, :"$1"}, :"$2", :_},
            [],
            [{{:"$1", :"$2"}}]
          }
        ])

      assert {scope, pid} in results

      Agent.stop(pid)
    end

    test "keys/1 reverse-lookup" do
      key = {:test_keys, "keys-#{System.unique_integer([:positive])}"}
      name = ProcessRegistry.via_tuple(key)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      assert [^key] = ProcessRegistry.keys(pid)

      Agent.stop(pid)
    end

    test "count/0 includes sagents global registrations" do
      before = ProcessRegistry.count()
      key = {:test_count, "c-#{System.unique_integer([:positive])}"}
      name = ProcessRegistry.via_tuple(key)
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      assert ProcessRegistry.count() == before + 1

      Agent.stop(pid)
    end

    test "registry_module/0 returns :global" do
      assert ProcessRegistry.registry_module() == :global
    end

    test "child_spec/1 returns placeholder Task spec" do
      spec = ProcessRegistry.child_spec([])
      assert %{id: {Sagents.ProcessRegistry, :global_placeholder}} = spec
      assert {Task, :start_link, [_fun]} = spec.start
      assert spec[:restart] == :temporary
    end
  end
end
