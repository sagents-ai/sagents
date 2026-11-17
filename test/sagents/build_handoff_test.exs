defmodule Sagents.BuildHandoffTest do
  use ExUnit.Case, async: false

  alias Sagents.BuildHandoff

  # Moves an entry's insert time `ms` into the past.
  defp backdate(ref, ms) do
    :ets.update_element(BuildHandoff, ref, {3, System.monotonic_time(:millisecond) - ms})
  end

  test "take/1 returns a build once" do
    ref = BuildHandoff.put(agent: :built, initial_state: :state)

    assert {:ok, [agent: :built, initial_state: :state]} = BuildHandoff.take(ref)
    assert :error = BuildHandoff.take(ref)
  end

  test "delete/1 removes a build" do
    ref = BuildHandoff.put(agent: :built)

    assert :ok = BuildHandoff.delete(ref)
    assert :error = BuildHandoff.take(ref)
  end

  test "delete/1 and take/1 accept what a start without a handoff carries" do
    assert :ok = BuildHandoff.delete(nil)
    assert :error = BuildHandoff.take(nil)
    assert :error = BuildHandoff.take(make_ref())
  end

  test "sweep/1 removes builds older than the given age and keeps newer ones" do
    old = BuildHandoff.put(agent: :old)
    backdate(old, 10_000)
    new = BuildHandoff.put(agent: :new)

    assert BuildHandoff.sweep(5_000) >= 1

    assert :error = BuildHandoff.take(old)
    assert {:ok, [agent: :new]} = BuildHandoff.take(new)
  end

  test "the owner sweeps on its own interval" do
    # A separate owner would collide with the named table, so this drives the
    # running one's timer message directly.
    ref = BuildHandoff.put(agent: :built)
    backdate(ref, 120_000)

    send(BuildHandoff, :sweep)
    _state = :sys.get_state(BuildHandoff)

    assert :error = BuildHandoff.take(ref)
  end

  describe "while the table is not running" do
    setup do
      :ok = Supervisor.terminate_child(Sagents.Supervisor, BuildHandoff)
      on_exit(fn -> Supervisor.restart_child(Sagents.Supervisor, BuildHandoff) end)
    end

    test "put/1 returns nil and take/1, delete/1 and sweep/1 do not raise" do
      assert nil == BuildHandoff.put(agent: :built)
      assert :error = BuildHandoff.take(make_ref())
      assert :ok = BuildHandoff.delete(make_ref())
      assert 0 == BuildHandoff.sweep()
    end
  end
end
