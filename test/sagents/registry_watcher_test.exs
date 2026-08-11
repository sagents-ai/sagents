defmodule Sagents.RegistryWatcherTest do
  @moduledoc """
  Unit coverage for the watcher that puts a registry restart into
  `Sagents.Supervisor`'s `:rest_for_one` chain.

  These tests drive a watcher against a stand-in registry name rather than the
  live `Sagents.Registry` the suite depends on. The end-to-end behaviour, where
  the restart actually takes the agent supervisors down, is covered against real
  nodes in `test/sagents/horde/rolling_deploy_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Sagents.RegistryWatcher

  describe "monitoring" do
    test "stays up while the registry it watches is alive" do
      {name, _stand_in} = start_stand_in_registry()
      watcher = start_watcher(name)

      Process.sleep(200)

      assert Process.alive?(watcher)
    end

    test "stops when the watched process dies, so :rest_for_one restarts the chain" do
      {name, stand_in} = start_stand_in_registry()
      watcher = start_watcher(name)

      watcher_ref = Process.monitor(watcher)
      Process.exit(stand_in, :kill)

      assert_receive {:DOWN, ^watcher_ref, :process, ^watcher, reason}, 2_000

      # A {:shutdown, _} reason still restarts a :permanent child, and unlike a
      # bare error it is not reported as a crash. This is a handled condition.
      assert {:shutdown, {:registry_down, :killed}} = reason
    end

    test "waits rather than failing when the name is not claimed yet" do
      # A backend supervisor mid-restart of its own child leaves the name
      # briefly unclaimed. The watcher must poll through that rather than turn
      # it into a restart storm.
      name = unique_name()
      watcher = start_watcher(name)

      Process.sleep(300)
      assert Process.alive?(watcher)

      # Once something claims the name, it gets picked up and watched.
      stand_in = start_named_process(name)
      Process.sleep(300)
      assert Process.alive?(watcher)

      watcher_ref = Process.monitor(watcher)
      Process.exit(stand_in, :kill)

      assert_receive {:DOWN, ^watcher_ref, :process, ^watcher, {:shutdown, _}}, 2_000
    end

    test "ignores unrelated DOWN messages" do
      {name, _stand_in} = start_stand_in_registry()
      watcher = start_watcher(name)

      unrelated = spawn(fn -> Process.sleep(:infinity) end)
      send(watcher, {:DOWN, make_ref(), :process, unrelated, :normal})

      Process.sleep(200)
      assert Process.alive?(watcher)
    end
  end

  describe "supervision wiring" do
    test "Sagents.Supervisor supervises the registry chain :rest_for_one" do
      # The strategy is the mechanism the watcher depends on: without it, the
      # watcher's own restart would not take the dynamic supervisors with it.
      {:ok, {sup_flags, children}} = Sagents.Supervisor.init([])

      assert sup_flags.strategy == :rest_for_one

      ids = Enum.map(children, & &1.id)

      registry_index =
        Enum.find_index(ids, &(&1 in [Sagents.Registry, Sagents.Horde.RegistryImpl]))

      watcher_index = Enum.find_index(ids, &(&1 == Sagents.RegistryWatcher))

      agents_index =
        Enum.find_index(
          ids,
          &(&1 in [Sagents.AgentsDynamicSupervisor, Sagents.Horde.AgentsSupervisorImpl])
        )

      assert is_integer(registry_index), "no registry child found in #{inspect(ids)}"
      assert is_integer(watcher_index), "no watcher child found in #{inspect(ids)}"
      assert is_integer(agents_index), "no agents supervisor found in #{inspect(ids)}"

      # Order is load-bearing: the watcher must sit after the registry (so it
      # can watch it) and before the dynamic supervisors (so its restart takes
      # them down).
      assert registry_index < watcher_index
      assert watcher_index < agents_index
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp start_stand_in_registry do
    name = unique_name()
    {name, start_named_process(name)}
  end

  defp start_named_process(name) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(pid, name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  # Start a watcher pointed at `name`, unnamed and unlinked so its deliberate
  # stop does not take the test process with it.
  defp start_watcher(name) do
    {:ok, pid} = RegistryWatcher.start_link(name: nil, registry_name: name)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp unique_name, do: :"stand_in_registry_#{System.unique_integer([:positive])}"
end
