defmodule Sagents.Publisher.State do
  @moduledoc """
  Subscriber bookkeeping for a `Sagents.Publisher` producer.

  Tracks subscribers across one or more channels and maintains a reverse
  index from monitor ref → `{pid, channel}` so `{:DOWN, ref, ...}` messages
  can be cleaned up in O(1) without iterating channels.

  Subscriber lookup by pid within a channel is also O(1), so duplicate
  subscribe calls dedupe trivially (returning the existing monitor ref
  rather than starting a second monitor).
  """

  @typedoc "A channel identifier."
  @type channel :: atom()

  defstruct channels: %{}, monitors: %{}

  @type t :: %__MODULE__{
          # channel => %{pid => monitor_ref}
          channels: %{channel() => %{pid() => reference()}},
          # monitor_ref => {pid, channel}
          monitors: %{reference() => {pid(), channel()}}
        }

  @doc """
  Build a fresh publisher state with the given channel atoms pre-initialized
  to empty subscriber maps.

  Channels are auto-created on first subscribe, but pre-declaring them makes
  the supported set explicit at the host module level.
  """
  @spec new([channel()]) :: t()
  def new(channels \\ [:main]) when is_list(channels) do
    channel_map = Map.new(channels, fn ch when is_atom(ch) -> {ch, %{}} end)
    %__MODULE__{channels: channel_map, monitors: %{}}
  end

  @doc """
  Bulk-seed subscribers from a list of `{channel, pid}` tuples.

  Useful in producer `init/1` to enroll subscribers passed as
  `:initial_subscribers` *before* the GenServer starts handling messages.
  This closes the race between "agent started" and "subscriber missed
  initial events" (e.g., the `:status_changed` and `:node_transferred`
  broadcasts emitted from `handle_continue/2`).

  Each entry establishes a monitor exactly as `add/3` would. Duplicates
  within the list are deduped per-channel — the existing monitor is
  reused for the second occurrence.

  Returns the updated state.
  """
  @spec seed(t(), [{channel(), pid()}]) :: t()
  def seed(%__MODULE__{} = state, entries) when is_list(entries) do
    Enum.reduce(entries, state, fn {channel, pid}, acc
                                   when is_atom(channel) and is_pid(pid) ->
      {_ref, new_acc} = add(acc, channel, pid)
      new_acc
    end)
  end

  @doc """
  Add a subscriber pid to a channel.

  Idempotent — if the pid is already subscribed to the channel, the existing
  monitor ref is returned and no new monitor is set up.

  Returns `{ref, new_state}`.
  """
  @spec add(t(), channel(), pid()) :: {reference(), t()}
  def add(%__MODULE__{} = state, channel, pid) when is_atom(channel) and is_pid(pid) do
    channel_subs = Map.get(state.channels, channel, %{})

    case Map.fetch(channel_subs, pid) do
      {:ok, existing_ref} ->
        {existing_ref, state}

      :error ->
        ref = Process.monitor(pid)
        new_channel_subs = Map.put(channel_subs, pid, ref)
        new_channels = Map.put(state.channels, channel, new_channel_subs)
        new_monitors = Map.put(state.monitors, ref, {pid, channel})
        {ref, %{state | channels: new_channels, monitors: new_monitors}}
    end
  end

  @doc """
  Remove a subscriber pid from a channel.

  Demonitors the existing monitor (with `:flush` to drop any in-flight DOWN).
  No-op if the pid is not subscribed.
  """
  @spec remove_pid(t(), channel(), pid()) :: t()
  def remove_pid(%__MODULE__{} = state, channel, pid) when is_atom(channel) and is_pid(pid) do
    channel_subs = Map.get(state.channels, channel, %{})

    case Map.pop(channel_subs, pid) do
      {nil, _} ->
        state

      {ref, new_channel_subs} ->
        Process.demonitor(ref, [:flush])
        new_channels = Map.put(state.channels, channel, new_channel_subs)
        new_monitors = Map.delete(state.monitors, ref)
        %{state | channels: new_channels, monitors: new_monitors}
    end
  end

  @doc """
  Remove a subscriber by monitor ref (for `:DOWN` cleanup).

  Returns `{:ok, new_state}` if the ref was tracked, `:error` otherwise.
  """
  @spec remove_ref(t(), reference()) :: {:ok, t()} | :error
  def remove_ref(%__MODULE__{} = state, ref) when is_reference(ref) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        :error

      {{pid, channel}, new_monitors} ->
        channel_subs = Map.get(state.channels, channel, %{}) |> Map.delete(pid)
        new_channels = Map.put(state.channels, channel, channel_subs)
        {:ok, %{state | channels: new_channels, monitors: new_monitors}}
    end
  end

  @doc """
  List subscriber pids for a channel.
  """
  @spec subscribers(t(), channel()) :: [pid()]
  def subscribers(%__MODULE__{} = state, channel) when is_atom(channel) do
    state.channels
    |> Map.get(channel, %{})
    |> Map.keys()
  end

  @doc """
  Total number of subscriptions across all channels (useful for tests/metrics).
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{} = state), do: map_size(state.monitors)

  @doc """
  Whether a pid is subscribed to a channel.
  """
  @spec subscribed?(t(), channel(), pid()) :: boolean()
  def subscribed?(%__MODULE__{} = state, channel, pid) do
    state.channels |> Map.get(channel, %{}) |> Map.has_key?(pid)
  end
end
