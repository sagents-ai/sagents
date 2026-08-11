defmodule Sagents.LocalRegistryTest do
  @moduledoc """
  Covers the name-reuse race that a `:local` registry restart has to survive.

  `Registry.Partition` traps exits, so it outlives an abnormal exit of the
  `Registry.Supervisor` registered as `Sagents.Registry` by a few milliseconds
  while it terminates, still holding its own registered name. A `:rest_for_one`
  restart lands inside that window, and a plain `Registry.start_link/1` there
  fails with `{:already_started, pid}`. A supervisor does not recover from a
  failed restart, so that failure would take the whole `Sagents.Supervisor`
  tree down and keep it down.
  """
  use ExUnit.Case, async: false

  describe "start_link/1" do
    test "starts a registry normally" do
      name = unique_name()
      assert {:ok, pid} = Sagents.LocalRegistry.start_link(keys: :unique, name: name)
      assert Process.whereis(name) == pid

      on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    end

    test "retries past a partition name still held by the previous registry" do
      # start_link/1 links the registry here, and we are about to kill it.
      Process.flag(:trap_exit, true)

      name = unique_name()
      {:ok, first} = Sagents.LocalRegistry.start_link(keys: :unique, name: name)

      partition = Process.whereis(Module.concat(name, "PIDPartition0"))
      assert Process.info(partition, :trap_exit) == {:trap_exit, true}

      # Brutally kill the registry and restart it the moment it is gone, which
      # is exactly what :rest_for_one does. Waiting for the DOWN frees the
      # registry's own name but not the partition's — the partition traps exits
      # and is still terminating — so a bare Registry.start_link/1 here fails
      # with {:already_started, partition}.
      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 2_000
      assert Process.alive?(partition), "the partition should still be terminating"

      assert {:ok, second} = Sagents.LocalRegistry.start_link(keys: :unique, name: name)
      assert second != first
      assert Process.whereis(name) == second

      # The new registry is usable, not merely started.
      assert {:ok, _owner} = Registry.register(name, :some_key, :value)
      assert [{self_pid, :value}] = Registry.lookup(name, :some_key)
      assert self_pid == self()

      on_exit(fn -> if Process.alive?(second), do: Supervisor.stop(second) end)
    end
  end

  describe "Sagents.Supervisor with the local backend" do
    @tag :slow
    test "survives a registry crash and restarts the chain under it" do
      # This has to drive the real Sagents.Supervisor, because the failure being
      # covered is that supervisor giving up. The suite-wide one is linked to
      # the process that started it in test_helper.exs, so its death would abort
      # the whole run. Retire it with a :normal exit, which does not propagate,
      # and run a detached replacement that is linked to nothing — the same
      # trick ClusterTestHelper.start_supervisor/0 uses. on_exit puts an equally
      # detached tree back, because every later test needs one.
      :ok = Supervisor.stop(Sagents.Supervisor, :normal)
      sup = start_detached_supervisor()

      on_exit(fn ->
        if pid = Process.whereis(Sagents.Supervisor) do
          Supervisor.stop(pid, :normal)
        end

        start_detached_supervisor()
      end)

      before = child_pids()

      registry = Process.whereis(Sagents.Registry)
      ref = Process.monitor(registry)
      sup_ref = Process.monitor(sup)
      Process.exit(registry, :kill)
      assert_receive {:DOWN, ^ref, :process, ^registry, :killed}, 2_000

      refute_receive {:DOWN, ^sup_ref, :process, ^sup, _reason}, 2_000
      assert Process.alive?(sup)

      # :rest_for_one: the registry and everything listed after it is replaced.
      after_ = wait_for_restart(before)

      assert Map.keys(before) == Map.keys(after_)

      for {id, old_pid} <- before do
        assert after_[id] != old_pid, "#{inspect(id)} should have been restarted"
      end

      # And the replacement registry actually answers.
      assert Sagents.ProcessRegistry.available?()
      assert Sagents.ProcessRegistry.fetch({:agent_server, "nobody"}) == {:error, :not_registered}
    end
  end

  # Start Sagents.Supervisor linked to a throwaway process that immediately
  # unlinks it, so the tree outlives this test and its death takes nothing with
  # it. That is what lets the test observe a supervisor giving up rather than
  # being killed by it.
  defp start_detached_supervisor do
    parent = self()

    spawn(fn ->
      {:ok, pid} = Sagents.Supervisor.start_link(name: Sagents.Supervisor)
      Process.unlink(pid)
      send(parent, {:detached_supervisor, pid})
    end)

    receive do
      {:detached_supervisor, pid} -> pid
    after
      5_000 -> flunk("Sagents.Supervisor did not start")
    end
  end

  defp child_pids do
    Sagents.Supervisor
    |> Supervisor.which_children()
    |> Map.new(fn {id, pid, _type, _mods} -> {id, pid} end)
  end

  defp wait_for_restart(before, attempts \\ 50) do
    current = child_pids()

    cond do
      attempts == 0 ->
        current

      map_size(current) == map_size(before) and
          Enum.all?(current, fn {id, pid} -> is_pid(pid) and before[id] != pid end) ->
        current

      true ->
        Process.sleep(50)
        wait_for_restart(before, attempts - 1)
    end
  end

  defp unique_name do
    Module.concat(__MODULE__, "R#{System.unique_integer([:positive])}")
  end
end
