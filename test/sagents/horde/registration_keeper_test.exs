defmodule Sagents.Horde.RegistrationKeeperTest do
  @moduledoc """
  A name the Horde registry drops while its owner is still running is
  restored. The drop is made the way a node departure's prune makes it: the
  key is deleted from the registry's CRDT directly, without the owner exiting
  or unregistering.
  """
  use ExUnit.Case, async: false

  alias Sagents.Horde.RegistrationKeeper

  setup context do
    suffix = System.unique_integer([:positive])
    registry = :"keeper_test_registry_#{suffix}"
    keeper = :"keeper_test_keeper_#{suffix}"

    # The keeper first, as in Sagents.Supervisor: the registry sends to it by name.
    start_supervised!({RegistrationKeeper, name: keeper, registry: registry})

    start_supervised!(
      {Horde.Registry, name: registry, keys: :unique, listeners: [keeper], members: [registry]}
    )

    test_pid = self()
    handler_id = "keeper-test-#{suffix}"

    :telemetry.attach(
      handler_id,
      [:sagents, :registry, :restored],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:restored, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Map.put(context, :registry, registry)
  end

  # A process holding `key` in `registry` until told to stop.
  defp start_owner(registry, key, opts \\ []) do
    test_pid = self()

    pid =
      spawn(fn ->
        if Keyword.get(opts, :trap_exit, false), do: Process.flag(:trap_exit, true)
        {:ok, _registry} = Horde.Registry.register(registry, key, nil)
        send(test_pid, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^pid}, 1_000
    pid
  end

  # What the registry does to a departed node's names: delete the key from the
  # CRDT, regardless of which process currently holds it.
  defp drop_from_crdt(registry, key) do
    DeltaCrdt.drop(:"#{registry}.Crdt", [{:key, key}], :infinity)
  end

  test "restores a kept name whose owner is still running", %{registry: registry} do
    key = {:agent_supervisor, "agent-1"}
    owner = start_owner(registry, key)

    drop_from_crdt(registry, key)

    assert_receive {:restored, %{count: 1}, %{key: ^key, pid: ^owner}}, 1_000
    assert Horde.Registry.lookup(registry, key) == [{owner, nil}]
  end

  test "restores every kept kind of name", %{registry: registry} do
    for kind <- [:agent_server, :sub_agents_supervisor, :sub_agent, :filesystem_server] do
      key = {kind, "id-#{kind}"}
      owner = start_owner(registry, key)

      drop_from_crdt(registry, key)

      assert_receive {:restored, _measurements, %{key: ^key, pid: ^owner}}, 1_000
    end
  end

  test "does not restore a name whose owner has exited", %{registry: registry} do
    key = {:agent_server, "agent-2"}
    owner = start_owner(registry, key)
    ref = Process.monitor(owner)

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}

    refute_receive {:restored, _measurements, _metadata}, 200
    assert Horde.Registry.lookup(registry, key) == []
  end

  test "leaves a name that another process now holds", %{registry: registry} do
    key = {:agent_server, "agent-3"}
    # Trapping exits keeps the first owner alive when it loses the name, so the
    # keeper's decision rests on who holds the name, not on the owner dying.
    first = start_owner(registry, key, trap_exit: true)
    second = spawn(fn -> Process.sleep(:infinity) end)

    # Another process taking the name, as a conflict resolution would.
    DeltaCrdt.put(
      :"#{registry}.Crdt",
      {:key, key},
      {{registry, node()}, second, nil},
      :infinity
    )

    refute_receive {:restored, _measurements, _metadata}, 200
    assert Horde.Registry.lookup(registry, key) == [{second, nil}]
    assert Process.alive?(first)
  end

  test "leaves names that are not kept", %{registry: registry} do
    key = {:membership_test, "marker"}
    _owner = start_owner(registry, key)

    drop_from_crdt(registry, key)

    refute_receive {:restored, _measurements, _metadata}, 200
    assert Horde.Registry.lookup(registry, key) == []
  end

  describe "listener_names/0" do
    test "names the keeper only while it is running" do
      assert RegistrationKeeper.listener_names() == []

      start_supervised!({RegistrationKeeper, []}, id: :default_keeper)

      assert RegistrationKeeper.listener_names() == [RegistrationKeeper]
    end
  end
end
