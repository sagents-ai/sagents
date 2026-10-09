defmodule Sagents.PresenceWriterTest do
  use ExUnit.Case, async: false

  alias Sagents.PresenceWriter

  # A Phoenix.Presence stand-in that records every call it receives. An update
  # for the key "gate" blocks the caller (the writer) until the test releases
  # it, which stands in for a tracker shard that is backed up.
  defmodule RecordingPresence do
    def start_link(test_pid) do
      Agent.start_link(fn -> %{test_pid: test_pid, tracked: %{}, calls: []} end, name: __MODULE__)
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def track(pid, topic, key, meta) do
      record({:track, key, meta})
      Agent.update(__MODULE__, &put_in(&1.tracked[{pid, topic, key}], meta))
      {:ok, make_ref()}
    end

    def update(pid, topic, key, meta) do
      if key == "gate" do
        send(Agent.get(__MODULE__, & &1.test_pid), {:gate_waiting, self()})

        receive do
          :release -> :ok
        end
      end

      record({:update, key, meta})

      Agent.get_and_update(__MODULE__, fn state ->
        if Map.has_key?(state.tracked, {pid, topic, key}) do
          {{:ok, make_ref()}, put_in(state.tracked[{pid, topic, key}], meta)}
        else
          {{:error, :nopresence}, state}
        end
      end)
    end

    def untrack(pid, topic, key) do
      record({:untrack, key})
      Agent.update(__MODULE__, &%{&1 | tracked: Map.delete(&1.tracked, {pid, topic, key})})
      :ok
    end

    defp record(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})
  end

  defmodule FailingPresence do
    def update(_pid, _topic, "exits", _meta), do: exit({:timeout, {GenServer, :call, []}})
    def update(_pid, _topic, "raises", _meta), do: raise(ArgumentError, "no tracker")
    def update(_pid, _topic, _key, _meta), do: {:error, :nopresence}
    def track(_pid, _topic, _key, _meta), do: {:ok, make_ref()}
  end

  setup do
    start_supervised!(%{id: RecordingPresence, start: {RecordingPresence, :start_link, [self()]}})
    :ok
  end

  test "a put for an entry the tracker lacks tracks it" do
    PresenceWriter.put(RecordingPresence, self(), "t", "a", %{status: :idle})
    PresenceWriter.flush()

    assert [{:update, "a", _meta}, {:track, "a", %{status: :idle}}] = RecordingPresence.calls()
  end

  test "a put for a tracked entry updates it" do
    PresenceWriter.put(RecordingPresence, self(), "t", "a", %{status: :idle})
    PresenceWriter.flush()
    PresenceWriter.put(RecordingPresence, self(), "t", "a", %{status: :running})
    PresenceWriter.flush()

    assert {:update, "a", %{status: :running}} = List.last(RecordingPresence.calls())
  end

  test "writes queued behind a slow call are folded into the latest one per entry" do
    PresenceWriter.put(RecordingPresence, self(), "t", "gate", %{n: 0})
    assert_receive {:gate_waiting, writer}, 1_000

    for n <- 1..5, do: PresenceWriter.put(RecordingPresence, self(), "t", "a", %{n: n})
    PresenceWriter.remove(RecordingPresence, self(), "t", "b")

    send(writer, :release)
    PresenceWriter.flush()

    calls = Enum.reject(RecordingPresence.calls(), &match?({_action, "gate", _meta}, &1))
    assert [{:update, "a", %{n: 5}}, {:track, "a", %{n: 5}}, {:untrack, "b"}] = calls
  end

  test "a put for a local pid that has exited is skipped" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    PresenceWriter.put(RecordingPresence, dead, "t", "a", %{})
    PresenceWriter.flush()

    assert RecordingPresence.calls() == []
  end

  test "a write that exits or raises is dropped and the writer carries on" do
    writer = GenServer.whereis(PresenceWriter)

    ExUnit.CaptureLog.capture_log(fn ->
      PresenceWriter.put(FailingPresence, self(), "t", "exits", %{})
      PresenceWriter.put(FailingPresence, self(), "t", "raises", %{})
      PresenceWriter.flush()
    end)

    assert GenServer.whereis(PresenceWriter) == writer
    PresenceWriter.put(RecordingPresence, self(), "t", "a", %{})
    PresenceWriter.flush()
    assert [{:update, "a", _meta}, {:track, "a", _tracked_meta}] = RecordingPresence.calls()
  end
end
