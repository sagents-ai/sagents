defmodule Sagents.Publisher.State do
  @moduledoc """
  Subscriber bookkeeping for a `Sagents.Publisher` producer.

  Tracks subscribers across one or more channels and maintains a reverse
  index from monitor ref → `{pid, channel}` so `{:DOWN, ref, ...}` messages
  can be cleaned up in O(1) without iterating channels.

  Subscriber lookup by pid within a channel is also O(1), so duplicate
  subscribe calls dedupe trivially (returning the existing monitor ref
  rather than starting a second monitor).

  Each subscription also carries a `t:tag/0` recording how its events are
  addressed. A process holding several subscriptions at once needs the
  envelope to name the subscription; one that holds a single subscription
  does not, and pays nothing for the option.
  """

  @typedoc "A channel identifier."
  @type channel :: atom()

  @typedoc """
  How events are addressed to one subscription.

  `:untagged` delivers the bare envelope the producer builds for everyone.
  `{:tag, value}` delivers an envelope carrying `value`, so a process holding
  several subscriptions can attribute each event to one of them.

  The value is wrapped rather than stored bare so that `nil` is a usable tag.
  """
  @type tag :: :untagged | {:tag, term()}

  @typedoc "One subscription: the producer's monitor on the subscriber, plus its envelope shape."
  @type entry :: %{ref: reference(), tag: tag()}

  defstruct channels: %{}, monitors: %{}

  @type t :: %__MODULE__{
          # channel => %{pid => entry}
          channels: %{channel() => %{pid() => entry()}},
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
  Resolve subscription options into a `t:tag/0`.

  - `tag: value` addresses events with the host's own routing key. `nil` is a
    legal value.
  - `tagged: true` addresses events with `default_identity`, the identity the
    producer knows itself by (an agent id, a filesystem scope key).
  - Neither delivers the bare envelope.

  `:tag` wins when both are given.

  ## Examples

      iex> Sagents.Publisher.State.resolve_tag([], "agent-1")
      :untagged

      iex> Sagents.Publisher.State.resolve_tag([tagged: true], "agent-1")
      {:tag, "agent-1"}

      iex> Sagents.Publisher.State.resolve_tag([tag: :card_7], "agent-1")
      {:tag, :card_7}

      iex> Sagents.Publisher.State.resolve_tag([tag: nil], "agent-1")
      {:tag, nil}
  """
  @spec resolve_tag(keyword(), term()) :: tag()
  def resolve_tag(opts, default_identity) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :tag) -> {:tag, Keyword.get(opts, :tag)}
      Keyword.get(opts, :tagged, false) -> {:tag, default_identity}
      true -> :untagged
    end
  end

  @doc """
  Turn a `t:tag/0` back into the option list that produces it.

  Round-trips a stored tag through a public subscribe function, which is what
  re-subscribing a revived subscription needs.

  ## Examples

      iex> Sagents.Publisher.State.tag_to_opts(:untagged)
      []

      iex> Sagents.Publisher.State.tag_to_opts({:tag, :card_7})
      [tag: :card_7]
  """
  @spec tag_to_opts(tag()) :: keyword()
  def tag_to_opts(:untagged), do: []
  def tag_to_opts({:tag, value}), do: [tag: value]

  @doc """
  Bulk-seed subscribers from a list of `{channel, pid}` or
  `{channel, pid, opts}` tuples.

  Useful in producer `init/1` to enroll subscribers passed as
  `:initial_subscribers` *before* the GenServer starts handling messages.
  This closes the race between "agent started" and "subscriber missed
  initial events" (e.g., the `:status_changed` and `:node_transferred`
  broadcasts emitted from `handle_continue/2`).

  `opts` accepts `:tag` and `:tagged`, resolved against `default_identity`
  by `resolve_tag/2`, so a seeded subscription is addressed exactly as one
  established through the producer's own `subscribe` function.

  Each entry establishes a monitor exactly as `add/4` would. Duplicates
  within the list are deduped per-channel — the existing monitor is
  reused, and the last entry's tag is the one that stands.

  Returns the updated state.
  """
  @spec seed(t(), [{channel(), pid()} | {channel(), pid(), keyword()}], term()) :: t()
  def seed(%__MODULE__{} = state, entries, default_identity \\ nil) when is_list(entries) do
    Enum.reduce(entries, state, fn entry, acc ->
      {channel, pid, tag} = normalize_seed_entry(entry, default_identity)
      {_ref, new_acc} = add(acc, channel, pid, tag)
      new_acc
    end)
  end

  defp normalize_seed_entry({channel, pid}, _default)
       when is_atom(channel) and is_pid(pid) do
    {channel, pid, :untagged}
  end

  defp normalize_seed_entry({channel, pid, opts}, default)
       when is_atom(channel) and is_pid(pid) and is_list(opts) do
    {channel, pid, resolve_tag(opts, default)}
  end

  @doc """
  Add a subscriber pid to a channel with the given envelope shape.

  Idempotent for registration — a pid already subscribed to the channel keeps
  its monitor and its existing ref is returned. The tag is restated, because
  the most recent call is the one saying how this mailbox wants its events
  shaped.

  Returns `{ref, new_state}`.
  """
  @spec add(t(), channel(), pid(), tag()) :: {reference(), t()}
  def add(%__MODULE__{} = state, channel, pid, tag \\ :untagged)
      when is_atom(channel) and is_pid(pid) do
    channel_subs = Map.get(state.channels, channel, %{})

    case Map.fetch(channel_subs, pid) do
      {:ok, %{ref: existing_ref} = existing} ->
        new_channel_subs = Map.put(channel_subs, pid, %{existing | tag: tag})
        {existing_ref, %{state | channels: Map.put(state.channels, channel, new_channel_subs)}}

      :error ->
        ref = Process.monitor(pid)
        new_channel_subs = Map.put(channel_subs, pid, %{ref: ref, tag: tag})
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
      {nil, _subs} ->
        state

      {%{ref: ref}, new_channel_subs} ->
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
      {nil, _monitors} ->
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
  Subscriber entries for a channel as `%{pid => entry}`.

  Producers broadcasting a per-subscriber envelope iterate this rather than
  `subscribers/2`.
  """
  @spec subscriber_entries(t(), channel()) :: %{pid() => entry()}
  def subscriber_entries(%__MODULE__{} = state, channel) when is_atom(channel) do
    Map.get(state.channels, channel, %{})
  end

  @doc """
  The envelope shape for one subscription. `:untagged` when the pid is not
  subscribed to the channel, which is the shape a producer would use anyway.
  """
  @spec tag_for(t(), channel(), pid()) :: tag()
  def tag_for(%__MODULE__{} = state, channel, pid) do
    case state.channels |> Map.get(channel, %{}) |> Map.get(pid) do
      %{tag: tag} -> tag
      nil -> :untagged
    end
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
