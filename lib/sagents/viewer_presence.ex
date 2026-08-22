defmodule Sagents.ViewerPresence do
  @moduledoc """
  Bookkeeping for the viewer-presence entries a subscriber process holds.

  `Sagents.Presence.track/4` tracks `self()`, and `Phoenix.Presence` reaps an
  entry when the tracked process dies. A LiveView (or any other subscriber
  process) outlives the conversations it is showing, so process exit is a
  backstop rather than the mechanism: a process that stops viewing a
  conversation has to hand that entry back explicitly.

  That matters because `Sagents.AgentServer` reads the viewer list to decide an
  idle agent may *not* shut down yet. An entry left on a conversation nobody is
  looking at any more pins that agent for the full inactivity timeout.

  ## A process holds a set, not a slot

  One process can view any number of conversations at once: a split view, a
  dashboard with a row per running agent, a panel of note threads each hosting
  its own forked conversation. So what this module threads through is a map of
  everything `Phoenix.Presence` holds for the calling process, and hosts keep it
  beside their other session state:

      state = %{tracked_viewers: %{}}

      held = ViewerPresence.track(state.tracked_viewers, MyApp.Coordinator, 42, user_id)
      held = ViewerPresence.track(held, MyApp.Coordinator, 43, user_id)

      # Done with one of them.
      held = ViewerPresence.untrack(held, MyApp.Coordinator, 42)

      # Done with all of them: a reset, a closed panel, a navigation away.
      held = ViewerPresence.untrack_all(held, MyApp.Coordinator)

  The viewer id is recorded per conversation rather than once for the process.
  A re-auth partway through a session changes what the host would compute now,
  but each entry has to be released under the id it was actually taken with.

  ## `sync/3` is the shape that cannot leak

  `track/4` and `untrack/3` are incremental: a host that opens a conversation
  and forgets to close it accumulates an entry, and no library can know when one
  of its panels went away.

  `sync/3` inverts that. The host declares the set it is currently viewing and
  this module diffs it against what is held, releasing what is gone and taking
  what is new. Re-declaring the same set does nothing at all, so it is both
  idempotent and safe to call from a render path:

      # Whatever this socket was viewing, it is viewing exactly these now.
      held = ViewerPresence.sync(held, MyApp.Coordinator, %{42 => user_id, 43 => user_id})

  Prefer it wherever the viewed set is derivable from state the host already
  keeps. Idempotence is not just tidiness here: an untrack followed by a track
  of the same conversation is a leave broadcast, and an idle agent that acts on
  it schedules the very shutdown the entry exists to prevent.

  ## The record means what Presence holds

  Never what the host intended. A track that fails records nothing, because a
  release aimed at an entry this process does not hold reports `:ok` while
  leaving the real entry in place. `Phoenix.Tracker` answers `:ok` to an untrack
  of a key it never tracked, so a record that drifts from reality fails silently
  here and surfaces as an agent that would not shut down somewhere else
  entirely.
  """

  require Logger

  @typedoc "A conversation being viewed, in the host's terms."
  @type conversation_id :: term()

  @typedoc "Who is viewing, in the host's terms: a user id, a session token, a guest id."
  @type viewer_id :: term()

  @typedoc """
  Every entry `Phoenix.Presence` holds for the calling process, by conversation.
  """
  @type held :: %{optional(conversation_id()) => viewer_id()}

  @doc """
  Track `viewer_id` as a viewer of `conversation_id`.

  Implemented by every generated coordinator over its own `Phoenix.Presence`
  module and conversation topic.
  """
  @callback track_conversation_viewer(conversation_id(), viewer_id(), metadata :: map()) ::
              {:ok, reference() | binary()} | {:error, term()}

  @doc """
  Stop tracking `viewer_id` as a viewer of `conversation_id`.
  """
  @callback untrack_conversation_viewer(conversation_id(), viewer_id()) :: :ok

  @doc """
  Add `conversation_id` to what this process is viewing.

  Holding it already under the same viewer is a no-op, so this is safe to call
  on a path that re-enters a conversation already open. Holding it under a
  different viewer releases that entry first, since Presence keys by viewer and
  the old key would otherwise be left behind.

  A nil `viewer_id` tracks nothing and leaves any existing entry alone: a host
  that cannot name its viewer right now has not stopped viewing.
  """
  @spec track(held(), module(), conversation_id(), viewer_id()) :: held()
  def track(held, coordinator, conversation_id, viewer_id)

  def track(held, _coordinator, nil, _viewer_id), do: held

  def track(held, _coordinator, _conversation_id, nil), do: held

  def track(held, coordinator, conversation_id, viewer_id) do
    case Map.fetch(held, conversation_id) do
      {:ok, ^viewer_id} ->
        held

      {:ok, _other_viewer} ->
        held
        |> untrack(coordinator, conversation_id)
        |> put_tracked(coordinator, conversation_id, viewer_id)

      :error ->
        put_tracked(held, coordinator, conversation_id, viewer_id)
    end
  end

  @doc """
  Remove `conversation_id` from what this process is viewing.

  Releases the entry under the viewer id it was taken with, which is why that id
  is recorded rather than recomputed. Holding nothing for `conversation_id` is a
  no-op.
  """
  @spec untrack(held(), module(), conversation_id()) :: held()
  def untrack(held, coordinator, conversation_id)

  def untrack(held, _coordinator, nil), do: held

  def untrack(held, coordinator, conversation_id) do
    case Map.fetch(held, conversation_id) do
      {:ok, viewer_id} ->
        coordinator.untrack_conversation_viewer(conversation_id, viewer_id)
        Map.delete(held, conversation_id)

      :error ->
        held
    end
  end

  @doc """
  Release every entry this process holds.

  For a host that stops viewing everything at once: a reset, a closed panel, a
  navigation away. Always returns an empty map.
  """
  @spec untrack_all(held(), module()) :: held()
  def untrack_all(held, coordinator) do
    Enum.reduce(Map.keys(held), held, &untrack(&2, coordinator, &1))
  end

  @doc """
  Make what this process holds match `desired` exactly.

  Releases the conversations that are no longer in the set, takes the ones that
  are new, and leaves the unchanged ones untouched. Declaring the same set twice
  does nothing, which is what makes this the shape that cannot leak: the host
  states what it is viewing rather than remembering to undo what it did.
  """
  @spec sync(held(), module(), held()) :: held()
  def sync(held, coordinator, desired) do
    departed = Enum.reject(Map.keys(held), &Map.has_key?(desired, &1))
    remaining = Enum.reduce(departed, held, &untrack(&2, coordinator, &1))

    Enum.reduce(desired, remaining, fn {conversation_id, viewer_id}, acc ->
      track(acc, coordinator, conversation_id, viewer_id)
    end)
  end

  defp put_tracked(held, coordinator, conversation_id, viewer_id) do
    case coordinator.track_conversation_viewer(conversation_id, viewer_id, %{}) do
      {:ok, _ref} ->
        Map.put(held, conversation_id, viewer_id)

      # This process already holds the entry, which is all the caller wanted.
      {:error, {:already_tracked, _pid, _topic, _key}} ->
        Map.put(held, conversation_id, viewer_id)

      {:error, reason} ->
        Logger.warning(
          "Failed to track viewer #{inspect(viewer_id)} on conversation " <>
            "#{inspect(conversation_id)}: #{inspect(reason)}"
        )

        held
    end
  end
end
