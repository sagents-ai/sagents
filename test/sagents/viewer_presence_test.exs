defmodule Sagents.ViewerPresenceTest do
  use ExUnit.Case, async: true

  alias Sagents.ViewerPresence

  # Records what it was asked to do and answers whatever the test queued.
  defmodule RecordingCoordinator do
    @behaviour Sagents.ViewerPresence

    def start_link do
      Elixir.Agent.start_link(fn -> %{calls: [], track_result: {:ok, make_ref()}} end)
    end

    def put_agent(pid), do: Process.put(:coordinator_agent, pid)

    def calls(pid), do: pid |> Elixir.Agent.get(& &1.calls) |> Enum.reverse()

    def stub_track(pid, result),
      do: Elixir.Agent.update(pid, &Map.put(&1, :track_result, result))

    @impl true
    def track_conversation_viewer(conversation_id, viewer_id, metadata) do
      pid = Process.get(:coordinator_agent)

      Elixir.Agent.get_and_update(pid, fn state ->
        {state.track_result,
         %{state | calls: [{:track, conversation_id, viewer_id, metadata} | state.calls]}}
      end)
    end

    @impl true
    def untrack_conversation_viewer(conversation_id, viewer_id) do
      pid = Process.get(:coordinator_agent)

      Elixir.Agent.update(
        pid,
        &%{&1 | calls: [{:untrack, conversation_id, viewer_id} | &1.calls]}
      )

      :ok
    end
  end

  setup do
    {:ok, pid} = RecordingCoordinator.start_link()
    RecordingCoordinator.put_agent(pid)
    %{coordinator: pid}
  end

  describe "track/4" do
    test "holds several conversations at once", %{coordinator: pid} do
      # The requirement this type exists for: one process viewing a panel of
      # conversations, each its own agent. Taking a second entry must not
      # release the first.
      held =
        %{}
        |> ViewerPresence.track(RecordingCoordinator, 1, "user-1")
        |> ViewerPresence.track(RecordingCoordinator, 2, "user-1")
        |> ViewerPresence.track(RecordingCoordinator, 3, "user-1")

      assert held == %{1 => "user-1", 2 => "user-1", 3 => "user-1"}

      assert RecordingCoordinator.calls(pid) == [
               {:track, 1, "user-1", %{}},
               {:track, 2, "user-1", %{}},
               {:track, 3, "user-1", %{}}
             ]
    end

    test "re-tracking what is already held does nothing at all", %{coordinator: pid} do
      # Not merely a saved call. An untrack-then-track is a leave broadcast, and
      # an idle agent that acts on it schedules the shutdown this entry prevents.
      held = ViewerPresence.track(%{}, RecordingCoordinator, 1, "user-1")
      assert ViewerPresence.track(held, RecordingCoordinator, 1, "user-1") == held

      assert RecordingCoordinator.calls(pid) == [{:track, 1, "user-1", %{}}]
    end

    test "the same conversation under a different viewer moves the entry", %{coordinator: pid} do
      # A re-auth, or an admin viewing as someone else. Presence keys by viewer,
      # so the old key would be left behind.
      held = ViewerPresence.track(%{1 => "user-1"}, RecordingCoordinator, 1, "user-2")

      assert held == %{1 => "user-2"}

      assert RecordingCoordinator.calls(pid) == [
               {:untrack, 1, "user-1"},
               {:track, 1, "user-2", %{}}
             ]
    end

    test "a nil viewer leaves what is held alone", %{coordinator: pid} do
      # A host that cannot name its viewer right now has not stopped viewing,
      # and Presence really does still hold the entry.
      held = %{1 => "user-1"}

      assert ViewerPresence.track(held, RecordingCoordinator, 1, nil) == held
      assert ViewerPresence.track(held, RecordingCoordinator, 2, nil) == held
      assert RecordingCoordinator.calls(pid) == []
    end

    test "a nil conversation is a no-op", %{coordinator: pid} do
      assert ViewerPresence.track(%{}, RecordingCoordinator, nil, "user-1") == %{}
      assert RecordingCoordinator.calls(pid) == []
    end

    test "records nothing when the track fails", %{coordinator: pid} do
      # The record means what Presence holds, never what the host intended. A
      # release aimed at an entry this process does not hold answers :ok while
      # leaving the real one in place.
      RecordingCoordinator.stub_track(pid, {:error, :nodedown})

      assert ViewerPresence.track(%{}, RecordingCoordinator, 1, "user-1") == %{}
    end

    test "an already-tracked entry counts as held", %{coordinator: pid} do
      # `Phoenix.Tracker` reports {:already_tracked, pid, topic, key} when this
      # process holds the entry already, which is what the caller wanted.
      RecordingCoordinator.stub_track(
        pid,
        {:error, {:already_tracked, self(), "conversation:1", "user-1"}}
      )

      assert ViewerPresence.track(%{}, RecordingCoordinator, 1, "user-1") == %{1 => "user-1"}
    end
  end

  describe "untrack/3" do
    test "releases one conversation and leaves the siblings held", %{coordinator: pid} do
      held = ViewerPresence.untrack(%{1 => "user-1", 2 => "user-1"}, RecordingCoordinator, 1)

      assert held == %{2 => "user-1"}
      assert RecordingCoordinator.calls(pid) == [{:untrack, 1, "user-1"}]
    end

    test "releases under the viewer id the entry was taken with", %{coordinator: pid} do
      # Recomputing the id is a guess about the past. Untracking a key that was
      # never tracked answers :ok while the real entry stays behind.
      ViewerPresence.untrack(%{1 => "user-before-reauth"}, RecordingCoordinator, 1)

      assert RecordingCoordinator.calls(pid) == [{:untrack, 1, "user-before-reauth"}]
    end

    test "holding nothing for the conversation is a no-op", %{coordinator: pid} do
      assert ViewerPresence.untrack(%{1 => "user-1"}, RecordingCoordinator, 99) == %{
               1 => "user-1"
             }

      assert ViewerPresence.untrack(%{}, RecordingCoordinator, nil) == %{}
      assert RecordingCoordinator.calls(pid) == []
    end
  end

  describe "untrack_all/2" do
    test "releases everything", %{coordinator: pid} do
      assert ViewerPresence.untrack_all(%{1 => "user-1", 2 => "user-2"}, RecordingCoordinator) ==
               %{}

      assert Enum.sort(RecordingCoordinator.calls(pid)) == [
               {:untrack, 1, "user-1"},
               {:untrack, 2, "user-2"}
             ]
    end

    test "holding nothing releases nothing", %{coordinator: pid} do
      assert ViewerPresence.untrack_all(%{}, RecordingCoordinator) == %{}
      assert RecordingCoordinator.calls(pid) == []
    end
  end

  describe "sync/3" do
    test "releases what left, takes what arrived, leaves the rest alone", %{coordinator: pid} do
      held =
        ViewerPresence.sync(%{1 => "u", 2 => "u"}, RecordingCoordinator, %{2 => "u", 3 => "u"})

      assert held == %{2 => "u", 3 => "u"}

      # Conversation 2 is in both sets and is not touched. Re-taking it would be
      # a leave broadcast an idle agent acts on.
      assert RecordingCoordinator.calls(pid) == [
               {:untrack, 1, "u"},
               {:track, 3, "u", %{}}
             ]
    end

    test "declaring the same set twice does nothing", %{coordinator: pid} do
      # What makes this safe to call from a path that runs on every render.
      desired = %{1 => "u", 2 => "u"}
      held = ViewerPresence.sync(%{}, RecordingCoordinator, desired)

      assert ViewerPresence.sync(held, RecordingCoordinator, desired) == held
      assert length(RecordingCoordinator.calls(pid)) == 2
    end

    test "an empty set releases everything", %{coordinator: pid} do
      assert ViewerPresence.sync(%{1 => "u"}, RecordingCoordinator, %{}) == %{}
      assert RecordingCoordinator.calls(pid) == [{:untrack, 1, "u"}]
    end

    test "a host that only ever syncs cannot accumulate entries", %{coordinator: pid} do
      # The incremental pair can leak, because no library knows when one of a
      # host's panels went away. Declaring the set removes the question.
      held =
        Enum.reduce(1..5, %{}, fn n, acc ->
          ViewerPresence.sync(acc, RecordingCoordinator, %{n => "u"})
        end)

      assert held == %{5 => "u"}

      assert Enum.count(RecordingCoordinator.calls(pid), &match?({:track, _, _, _}, &1)) == 5
      assert Enum.count(RecordingCoordinator.calls(pid), &match?({:untrack, _, _}, &1)) == 4
    end
  end

  # A coordinator shaped like a generated one, over a real Phoenix.Presence.
  defmodule RealCoordinator do
    @behaviour Sagents.ViewerPresence

    @impl true
    def track_conversation_viewer(conversation_id, viewer_id, metadata) do
      Sagents.Presence.track(
        Sagents.TestPresence,
        presence_topic(conversation_id),
        viewer_id,
        metadata
      )
    end

    @impl true
    def untrack_conversation_viewer(conversation_id, viewer_id) do
      Sagents.Presence.untrack(Sagents.TestPresence, presence_topic(conversation_id), viewer_id)
    end

    def presence_topic(conversation_id), do: "conversation:#{conversation_id}"
  end

  describe "against a real Phoenix.Presence" do
    # `Phoenix.Tracker.list/2` is a call into the shard process that serialized
    # the track and untrack, on the same topic, so these reads are strictly
    # ordered behind them. No polling and no sleeping is needed on one node.
    defp viewers(conversation_id) do
      Sagents.TestPresence.list(RealCoordinator.presence_topic(conversation_id))
    end

    defp unique_ids(count) do
      Enum.map(1..count, fn n -> "conv-#{n}-#{System.unique_integer([:positive])}" end)
    end

    test "one process holds entries on several conversations at once" do
      [a, b, c] = unique_ids(3)

      held =
        %{}
        |> ViewerPresence.track(RealCoordinator, a, "user-1")
        |> ViewerPresence.track(RealCoordinator, b, "user-1")
        |> ViewerPresence.track(RealCoordinator, c, "user-1")

      for id <- [a, b, c], do: assert(Map.has_key?(viewers(id), "user-1"))

      # Closing one panel leaves the others being viewed.
      held = ViewerPresence.untrack(held, RealCoordinator, b)

      assert viewers(b) == %{}
      assert Map.has_key?(viewers(a), "user-1")
      assert Map.has_key?(viewers(c), "user-1")

      assert ViewerPresence.untrack_all(held, RealCoordinator) == %{}
      assert viewers(a) == %{}
      assert viewers(c) == %{}
    end

    test "sync moves the viewed set without disturbing what stays" do
      [a, b, c] = unique_ids(3)

      held = ViewerPresence.sync(%{}, RealCoordinator, %{a => "user-1", b => "user-1"})
      held = ViewerPresence.sync(held, RealCoordinator, %{b => "user-1", c => "user-1"})

      assert viewers(a) == %{}
      assert Map.has_key?(viewers(b), "user-1")
      assert Map.has_key?(viewers(c), "user-1")

      ViewerPresence.untrack_all(held, RealCoordinator)
    end

    test "switching the single conversation a process views leaves nothing behind" do
      # The generated single-view helpers: leaving is a targeted untrack of the
      # conversation being left, and Presence tracks the pid, which survives it.
      [a, b] = unique_ids(2)

      held = ViewerPresence.track(%{}, RealCoordinator, a, "user-1")

      held =
        held
        |> ViewerPresence.untrack(RealCoordinator, a)
        |> ViewerPresence.track(RealCoordinator, b, "user-1")

      assert viewers(a) == %{}
      assert Map.has_key?(viewers(b), "user-1")

      ViewerPresence.untrack_all(held, RealCoordinator)
    end

    test "a second viewer of the same conversation is untouched by the first leaving" do
      # An agent stays alive while anyone is still watching, so one viewer
      # leaving must not clear the topic.
      [id] = unique_ids(1)
      test_pid = self()

      other =
        spawn_link(fn ->
          ViewerPresence.track(%{}, RealCoordinator, id, "user-2")
          send(test_pid, :tracked)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :tracked, 1_000

      held = ViewerPresence.track(%{}, RealCoordinator, id, "user-1")
      assert map_size(viewers(id)) == 2

      ViewerPresence.untrack_all(held, RealCoordinator)
      assert Map.keys(viewers(id)) == ["user-2"]

      send(other, :stop)
    end
  end
end
