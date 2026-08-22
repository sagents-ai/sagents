defmodule Sagents.Presence do
  @moduledoc """
  Convenience wrappers for Phoenix.Presence operations.

  This module provides thin wrappers around Phoenix.Presence to make presence tracking
  more convenient in agent-based applications. These functions always track the calling
  process (`self()`).

  Phoenix.Presence reaps an entry when the tracked process terminates, but that
  is a backstop rather than the mechanism. A process that tracks viewers of a
  conversation typically outlives the conversations it shows, and may be viewing
  several at once, so it has to release each entry when it stops viewing that
  conversation. `Sagents.ViewerPresence` does that bookkeeping; prefer it over
  calling `track/4` and `untrack/3` directly.

  ## Examples

      # Track presence in a LiveView mount
      if connected?(socket) do
        {:ok, ref} = Sagents.Presence.track(
          MyApp.Presence,
          "conversation:123",
          "user-1",
          %{name: "Alice"}
        )
      end

      # Track presence in multiple topics from the same process
      Sagents.Presence.track(MyApp.Presence, "conversation:123", "user-1")
      Sagents.Presence.track(MyApp.Presence, "conversation:456", "user-1")
  """

  @doc """
  Track presence for the calling process on the given topic and identifier.

  Tracks `self()`, so it must be called from the process you want to track.

  Phoenix.Presence removes the entry when that process terminates. A process
  that outlives what it is tracking presence for must still release the entry
  itself; see `Sagents.ViewerPresence`.

  ## Parameters

    - `presence_module` - The Presence module (e.g., MyApp.Presence)
    - `topic` - The topic string for presence tracking
    - `id` - Unique identifier for this presence entry (e.g., user_id)
    - `metadata` - Optional metadata map (default: empty map)

  ## Returns

    - `{:ok, ref}` - Presence tracked successfully
    - `{:error, reason}` - Failed to track presence

  ## Examples

      # In a LiveView after connected
      {:ok, ref} = Sagents.Presence.track(
        MyApp.Presence,
        "conversation:123",
        "user-1",
        %{joined_at: System.system_time(:second)}
      )

      # Track in multiple topics
      {:ok, _} = Sagents.Presence.track(MyApp.Presence, "topic:123", "user-1")
      {:ok, _} = Sagents.Presence.track(MyApp.Presence, "topic:456", "user-1")
  """
  def track(presence_module, topic, id, metadata \\ %{}) do
    presence_module.track(self(), topic, id, metadata)
  end

  @doc """
  Untrack presence for the calling process on the given topic and identifier.

  Untracks `self()`, so it must be called from the same process that originally
  tracked.

  Note that `Phoenix.Tracker` answers `:ok` to an untrack of a key it never
  tracked, so a wrong key reports success here while leaving the real entry in
  place. `Sagents.ViewerPresence` records the key that was tracked for exactly
  this reason.
  """
  def untrack(presence_module, topic, id) do
    presence_module.untrack(self(), topic, id)
  end

  @doc """
  List all presence entries for a topic.

  This is a convenience wrapper around the presence module's list function.
  """
  def list(presence_module, topic) do
    presence_module.list(topic)
  end

  @doc """
  Update presence metadata for a tracked entity.

  This atomically updates the metadata for an existing presence entry by merging
  in the new values. Must be called from the same process that originally tracked
  the presence (typically `self()`).

  Uses Phoenix.Presence's atomic update which sends a single presence_diff with
  `phx_ref_prev` set, allowing consumers to distinguish updates from leave+join.

  ## Parameters

    - `presence_module` - The Presence module (e.g., MyApp.Presence)
    - `topic` - The topic string for presence tracking
    - `id` - Unique identifier for this presence entry
    - `new_meta` - Map of new/updated metadata fields to merge

  ## Returns

    - `{:ok, ref}` - Presence updated successfully
    - `{:error, reason}` - Update failed (e.g., not tracked)

  ## Examples

      # Update agent status in presence (from the agent process)
      {:ok, _ref} = Sagents.Presence.update(
        MyApp.Presence,
        "agent_server:presence",
        "agent-123",
        %{status: :running}
      )
  """
  def update(presence_module, topic, id, new_meta) do
    presence_module.update(self(), topic, id, fn existing_meta ->
      Map.merge(existing_meta, new_meta)
    end)
  end
end
