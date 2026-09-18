defmodule Sagents.Subscriber do
  @moduledoc """
  Consumer-side helpers for `Sagents.Publisher` producers.

  Captures the boilerplate of:

    1. Subscribing to a producer by *id* rather than pid.
    2. Monitoring the producer so we know when it dies.
    3. Watching `Phoenix.Presence` arrivals for that id (to handle crash-restart
       with a new pid, or Horde migration to a new node).
    4. Re-subscribing automatically when the producer reappears.
    5. Cleaning up on caller exit (best-effort — the producer's monitor on the
       caller will clean us up anyway).

  Targets two consumer shapes:

    * **Plain GenServer / process** — call `subscribe_to_agent/2` and friends
      directly; pair with `handle_publisher_down/3` and `handle_presence_diff/3`
      from your `handle_info/2`.
    * **LiveView (or anything with a socket)** — `use Sagents.Subscriber`
      injects `handle_info/2` clauses for `:DOWN` and Phoenix presence diffs
      that delegate to those helpers.

  ## Subscription handle

  Each active subscription is tracked in the caller's local `subs` map (kept on
  the LiveView socket under `socket.private.sagents_subs`, or threaded through
  manually for plain-process callers).

  Map shape:

      %{
        {:agent, agent_id} => %{
          channel: :main | :debug,
          tag: :untagged | {:tag, term()},
          server_pid: pid() | nil,
          monitor_ref: reference() | nil,
          client_ref: reference() | nil,
          state: :subscribed | :pending
        },
        {:filesystem, scope_key} => %{...}
      }

  States:

    * `:subscribed` — we have a live subscription on `server_pid`, monitored.
    * `:pending` — we want to subscribe but the producer isn't running. Will
      retry on the next presence arrival.

  ## Addressing events

  A subscription's events are delivered bare by default:

      {:agent, {:status_changed, :running, nil}}

  which is unambiguous for a process holding one subscription and undecidable
  for a process holding two. Nothing else recovers the identity: the fan-out is
  a direct `send/2`, so there is no sender and no topic; two agents streaming
  concurrently interleave, so there is no ordering; and `%LangChain.MessageDelta{}`
  and `%LangChain.TokenUsage{}` carry no agent id.

  Tag the subscription, and every event on it names its source:

      # {:agent, agent_id, event}
      Subscriber.subscribe_to_agent(subs, agent_id, tagged: true)

      # {:agent, card_id, event} — the host's own routing key
      Subscriber.subscribe_to_agent(subs, agent_id, tag: card_id)

  Supply your own key wherever you have one. A host routing events to UI
  elements would otherwise keep an `agent_id => element` map purely to undo the
  library's choice, and consult it once per streaming delta.

  The shape covers every delivery on that subscription: live broadcasts, the
  status snapshot sent at subscribe time, events broadcast during the agent's
  boot when the subscription was seeded through `:initial_subscribers`, and the
  re-subscription that follows a producer crash. The `:debug` channel is
  `{:agent, tag, {:debug, event}}` and the filesystem channel is
  `{:file_system, tag, change_info}`.

  ## Observing several producers

  This is what the subs map is for: it is keyed per producer, so
  `%{{:agent, "a"} => ..., {:agent, "b"} => ...}` is an ordinary value. A split
  view, a dashboard with a row per running agent, and a panel of threads each
  backed by its own forked agent are all this shape.

  Tag every subscription when you do it. The cost of not tagging is not only a
  misrendered panel: a `:status_changed` is often a workflow trigger, and an
  `:idle` from one agent satisfies a clause written for another sharing the
  mailbox, so an action fires against an agent that did not finish.

  A host holding several subscriptions also wants to know *which* one a
  recovery event concerns. Both recovery helpers report that on request:

      {:matched, sub_key, new_subs} =
        Subscriber.handle_publisher_down(subs, ref, reason, report: true)

      {new_subs, revived_keys} =
        Subscriber.handle_presence_diff(subs, topic, payload, report: true)

  Without `report: true` both return exactly what a single-subscription host
  already matches on, so the identity is opt-in the same way the tag is.

  A host that would rather keep one subscription per process has two ways to
  get there: pass a dedicated proxy pid to `subscribe_to_agent/3` via
  `:subscriber_pid`, or give each conversation its own LiveView with
  `live_render/3`. Both are ordinary uses of this module. Tagging is what a
  single process holding the set needs.

  ## Departure vs arrival

  Monitors are reliable for departure (`:DOWN` fires within a scheduler tick of
  process death, even cross-node when the connection drops). Phoenix.Presence is
  reliable for arrival (`presence_diff` with `joins`). We never depend on
  `presence_diff.leaves` — if it's delayed, we keep the `:subscribed` state
  until `:DOWN` fires, which it will.
  """

  require Logger

  alias Sagents.AgentServer
  alias Sagents.FileSystemServer
  alias Sagents.Publisher

  @type sub_key :: {:agent, String.t()} | {:filesystem, term()}
  @type sub_entry :: %{
          channel: atom(),
          tag: Publisher.State.tag(),
          server_pid: pid() | nil,
          monitor_ref: reference() | nil,
          client_ref: reference() | nil,
          state: :subscribed | :pending
        }
  @type subs :: %{sub_key() => sub_entry()}

  @presence_topic "agent_server:presence"

  # ---------------------------------------------------------------------------
  # __using__ — LiveView / GenServer consumer
  # ---------------------------------------------------------------------------

  defmacro __using__(_opts) do
    quote do
      import Sagents.Subscriber,
        only: [
          subscribe_to_agent: 3,
          subscribe_to_agent: 4,
          subscribe_to_filesystem: 3,
          tag_for: 2,
          unsubscribe_from_agent: 2,
          unsubscribe_from_filesystem: 2
        ]

      # No handle_info clauses are auto-injected — call
      # Sagents.Subscriber.handle_info/3 from the host's handle_info clauses
      # explicitly. This avoids `defoverridable` collisions with LiveView's
      # generated handle_info/2 and keeps routing predictable for the host.
    end
  end

  # ---------------------------------------------------------------------------
  # Subscribe / unsubscribe (caller-side)
  # ---------------------------------------------------------------------------

  @doc """
  Subscribe the calling process to an agent's events, threading the
  subscription map through.

  Returns the updated subs map. If the agent is not currently running, the
  subscription is recorded in `:pending` state and will become live as soon
  as the agent appears in Phoenix.Presence on the agent presence topic.

  ## Options

  - `:channel` — `:main` (default) or `:debug`.
  - `:subscriber_pid` — the pid to receive events. Defaults to `self()`.
  - `:tag` — address this subscription's events with the given value, so they
    arrive as `{:agent, tag, event}` instead of `{:agent, event}`. `nil` is a
    legal tag.
  - `:tagged` — when `true`, address them with `agent_id`.

  An atom in place of the options list is read as `:channel`.

  ## Several subscriptions, one mailbox

  The subs map is keyed per producer, so holding subscriptions to several
  agents at once is what it is built for. Tag them: the bare envelope names no
  sender, so two agents streaming into one process interleave with nothing to
  tell them apart, and a `:status_changed` from one is indistinguishable from
  the same event out of the other.

      subs =
        %{}
        |> Subscriber.subscribe_to_agent(main_agent_id, tag: :main_chat)
        |> Subscriber.subscribe_to_agent(note_agent_id, tag: {:note, note_id})

      def handle_info({:agent, :main_chat, event}, socket), do: ...
      def handle_info({:agent, {:note, id}, event}, socket), do: ...

  The tag is stored in the subscription entry, so a subscription that starts
  `:pending` and is revived by a presence arrival comes back carrying it.
  """
  @spec subscribe_to_agent(subs(), String.t(), :main | :debug | keyword()) :: subs()
  def subscribe_to_agent(subs, agent_id, opts_or_channel \\ [])

  def subscribe_to_agent(subs, agent_id, channel) when is_atom(channel) do
    subscribe_to_agent(subs, agent_id, channel: channel)
  end

  def subscribe_to_agent(subs, agent_id, opts) when is_list(opts) do
    channel = Keyword.get(opts, :channel, :main)
    subscriber_pid = Keyword.get(opts, :subscriber_pid) || self()

    # Resolved here as well as inside AgentServer.subscribe/3 so the subs entry
    # records the same shape the producer will deliver. resolve_tag/2 is pure
    # and takes the same two inputs in both places.
    tag = Publisher.State.resolve_tag(opts, agent_id)

    key = {:agent, agent_id}

    do_subscribe(subs, key, channel, tag, fn ->
      AgentServer.subscribe(agent_id, opts_with_defaults(opts, channel, subscriber_pid))
    end)
  end

  @doc """
  Subscribe `subscriber_pid` to an agent's channel, threading the subscription
  map through.

  `subscribe_to_agent/3` subscribes the calling process. Use this arity when the
  process receiving the events is a different one, such as a host running one
  receiver per conversation. Main-channel events arrive as `{:agent, event}` and
  do not name the agent that sent them, so a single process holding two
  subscriptions cannot separate them; a receiver per agent can.

  Events go to `subscriber_pid`. The returned subs map, and the producer monitor
  recorded in it, belong to the calling process, which is therefore the process
  that must run `handle_publisher_down/3` and `handle_presence_diff/3`.

  > #### A revived subscription moves to the caller {: .warning}
  >
  > An entry rests at `:pending` when no agent is running at subscribe time, and
  > returns there when the producer goes down. `handle_presence_diff/3` revives a
  > pending entry by subscribing the process that calls it, and the entry does
  > not record `subscriber_pid`, so a revived subscription made with this arity
  > delivers to the caller rather than to the original receiver. Subscribe from
  > the receiving process itself wherever that is reachable.
  """
  @spec subscribe_to_agent(subs(), String.t(), :main | :debug, pid()) :: subs()
  def subscribe_to_agent(subs, agent_id, channel, subscriber_pid)
      when channel in [:main, :debug] do
    subscribe_to_agent(subs, agent_id, channel: channel, subscriber_pid: subscriber_pid)
  end

  defp opts_with_defaults(opts, channel, subscriber_pid) do
    opts
    |> Keyword.put(:channel, channel)
    |> Keyword.put(:subscriber_pid, subscriber_pid)
  end

  @doc """
  Subscribe the calling process to filesystem change events for `scope_key`.

  Takes the same `:tag` / `:tagged` options as `subscribe_to_agent/3`;
  `tagged: true` addresses events with `scope_key`. Tagged events arrive as
  `{:file_system, tag, change_info}`.
  """
  @spec subscribe_to_filesystem(subs(), term(), :main | keyword()) :: subs()
  def subscribe_to_filesystem(subs, scope_key, opts_or_channel \\ [])

  def subscribe_to_filesystem(subs, scope_key, channel) when is_atom(channel) do
    subscribe_to_filesystem(subs, scope_key, channel: channel)
  end

  def subscribe_to_filesystem(subs, scope_key, opts) when is_list(opts) do
    channel = Keyword.get(opts, :channel, :main)
    tag = Publisher.State.resolve_tag(opts, scope_key)
    key = {:filesystem, scope_key}

    do_subscribe(subs, key, channel, tag, fn ->
      # Resolve the pid rather than handing Publisher a `:via` tuple, for the
      # reason given on `Sagents.AgentServer.subscribe/3`: the via resolution
      # inside `GenServer.call` raises out of `:ets` on a node whose registry
      # is gone, past Publisher's `catch :exit`.
      case FileSystemServer.fetch_pid(scope_key) do
        {:ok, pid} -> Publisher.subscribe(pid, channel, nil, tag)
        {:error, :not_running} -> {:error, :process_not_found}
        {:error, :registry_unavailable} = error -> error
      end
    end)
  end

  @doc """
  Unsubscribe from an agent. Tears down monitor and pending state.
  """
  @spec unsubscribe_from_agent(subs(), String.t()) :: subs()
  def unsubscribe_from_agent(subs, agent_id) do
    do_unsubscribe(subs, {:agent, agent_id}, fn channel ->
      AgentServer.unsubscribe(agent_id, channel)
    end)
  end

  @doc """
  Unsubscribe from a filesystem.
  """
  @spec unsubscribe_from_filesystem(subs(), term()) :: subs()
  def unsubscribe_from_filesystem(subs, scope_key) do
    do_unsubscribe(subs, {:filesystem, scope_key}, fn channel ->
      case FileSystemServer.fetch_pid(scope_key) do
        {:ok, pid} -> Publisher.unsubscribe(pid, channel)
        {:error, _reason} -> :ok
      end
    end)
  end

  defp do_subscribe(subs, key, channel, tag, subscribe_fun) do
    case subscribe_fun.() do
      {:ok, server_pid, monitor_ref} ->
        # Also monitor the server pid from our side so we get a :DOWN if the
        # producer crashes — even if the producer's own monitor on us was
        # already cleaned up before the crash propagated.
        client_ref = Process.monitor(server_pid)

        Map.put(subs, key, %{
          channel: channel,
          tag: tag,
          server_pid: server_pid,
          monitor_ref: monitor_ref,
          client_ref: client_ref,
          state: :subscribed
        })

      # No producer to subscribe to, or no registry on this node able to find
      # one. Both rest at `:pending`, which the next presence arrival revives.
      # The tag is recorded here too: revival rebuilds the subscription from
      # this entry, and a tag missing from it comes back as a bare envelope on
      # a panel that asked for a tagged one.
      #
      # Folding `:registry_unavailable` in here is safe in a way it is not
      # elsewhere: nothing starts a producer off the back of a pending entry.
      # The dangerous conflation is "cannot answer" read as "nothing is
      # running" by a caller whose response is to start one. A pending
      # subscription just waits.
      {:error, reason} when reason in [:process_not_found, :registry_unavailable] ->
        Map.put(subs, key, %{
          channel: channel,
          tag: tag,
          server_pid: nil,
          monitor_ref: nil,
          client_ref: nil,
          state: :pending
        })
    end
  end

  defp do_unsubscribe(subs, key, unsubscribe_fun) do
    case Map.get(subs, key) do
      nil ->
        subs

      %{channel: channel, client_ref: client_ref} ->
        if client_ref, do: Process.demonitor(client_ref, [:flush])
        unsubscribe_fun.(channel)
        Map.delete(subs, key)
    end
  end

  # ---------------------------------------------------------------------------
  # Inbound message handlers (call from host's handle_info)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the `Phoenix.Presence` topic string the agent presence layer uses.

  Subscribe to this topic with `Phoenix.PubSub.subscribe/2` to receive
  `presence_diff` broadcasts that drive auto-resubscription.
  """
  @spec presence_topic() :: String.t()
  def presence_topic, do: @presence_topic

  @doc """
  Handle a `:DOWN` from one of the producer pids we subscribed to.

  Returns `{:matched, new_subs}` if the ref belonged to a tracked subscription
  (now flipped to `:pending`, keeping its channel and tag for the presence
  arrival that revives it), otherwise `:no_match`.

  ## Options

  - `:report` — when `true`, returns `{:matched, sub_key, new_subs}` instead.

  `sub_key` is what a host with several subscriptions needs: it says which
  panel went offline, so the host can leave every sibling's state alone rather
  than blanking a panel that is still mid-response. Read the tag back with
  `tag_for/2` when the host routes on tags rather than keys.

  It is opt-in for the same reason a tag is. A host holding one subscription
  already knows which one went down, and the bare shape is what its existing
  `case` matches on.

      # One subscription. Nothing to disambiguate.
      {:matched, new_subs} = Subscriber.handle_publisher_down(subs, ref, reason)

      # Several. Flip exactly the panel that went offline.
      {:matched, key, new_subs} =
        Subscriber.handle_publisher_down(subs, ref, reason, report: true)
  """
  @spec handle_publisher_down(subs(), reference(), term(), keyword()) ::
          {:matched, subs()} | {:matched, sub_key(), subs()} | :no_match
  def handle_publisher_down(subs, ref, reason, opts \\ [])

  def handle_publisher_down(subs, ref, _reason, opts)
      when is_map(subs) and is_reference(ref) and is_list(opts) do
    report? = Keyword.get(opts, :report, false)

    Enum.find_value(subs, :no_match, fn {key, entry} ->
      if entry[:client_ref] == ref do
        new_entry = %{entry | server_pid: nil, monitor_ref: nil, client_ref: nil, state: :pending}
        new_subs = Map.put(subs, key, new_entry)

        if report?, do: {:matched, key, new_subs}, else: {:matched, new_subs}
      else
        nil
      end
    end)
  end

  @doc """
  The tag a subscription was established with, unwrapped.

  Returns `{:ok, tag}` for a tagged subscription, `:untagged` for one taking
  the bare envelope, and `:error` when the key is not in the map.
  """
  @spec tag_for(subs(), sub_key()) :: {:ok, term()} | :untagged | :error
  def tag_for(subs, key) do
    case Map.get(subs, key) do
      %{tag: {:tag, value}} -> {:ok, value}
      %{tag: :untagged} -> :untagged
      nil -> :error
    end
  end

  @doc """
  Handle a `Phoenix.Presence` diff for the agent presence topic.

  `joins` whose key matches a `:pending` agent subscription triggers a
  re-subscribe, carrying that subscription's original channel and tag.

  Returns the (possibly updated) subs map.

  ## Options

  - `:report` — when `true`, returns `{new_subs, revived_keys}` instead.

  `revived_keys` names the subscriptions that just came back, so a host holding
  several flips exactly those panels from offline to live rather than guessing
  which one the diff was about. It is empty when nothing matched.

      # One subscription. The diff either revived it or did nothing.
      new_subs = Subscriber.handle_presence_diff(subs, topic, payload)

      # Several. Only these panels are live again.
      {new_subs, revived} =
        Subscriber.handle_presence_diff(subs, topic, payload, report: true)

  Entries that cannot be re-subscribed stay `:pending` rather than being
  dropped, so a later diff can still revive them, and they are not reported as
  revived. That covers a node whose own registry is unavailable: the presence
  topic is cluster-wide, so this fires for agents booting anywhere in the
  cluster, including while this node drains and can resolve nothing.

  `subs` is guarded as a map on every clause, including the one that ignores
  the payload. Feeding the `report: true` result back in on the next diff is
  the mistake this catches, and without the guard it surfaces as a
  `BadMapError` raised two events later from inside this module.
  """
  @spec handle_presence_diff(subs(), String.t(), map(), keyword()) ::
          subs() | {subs(), [sub_key()]}
  def handle_presence_diff(subs, topic, payload, opts \\ [])

  def handle_presence_diff(subs, @presence_topic, %{joins: joins}, opts)
      when is_map(subs) and is_map(joins) and is_list(opts) do
    if Sagents.ready?() do
      Map.keys(joins)
      |> Enum.reduce({subs, []}, &revive_pending/2)
      |> shape_diff_result(opts)
    else
      # Every re-subscribe would resolve to `:pending` anyway, which is what
      # these entries already are. Skipping the work matters because a host
      # calls this from `handle_info` for a cluster-wide topic: without the
      # guard a draining node probes its dead registry once per joining agent,
      # per broadcast, for the length of the drain.
      Logger.debug("presence diff ignored: registry unavailable on this node")
      shape_diff_result({subs, []}, opts)
    end
  end

  def handle_presence_diff(subs, _topic, _payload, opts) when is_map(subs) and is_list(opts) do
    shape_diff_result({subs, []}, opts)
  end

  defp shape_diff_result({subs, revived}, opts) do
    if Keyword.get(opts, :report, false), do: {subs, Enum.reverse(revived)}, else: subs
  end

  # Re-subscribe one joining agent if we are holding a `:pending` entry for it.
  # Round-tripping the stored tag back through `tag_to_opts/1` reuses the public
  # subscribe path, so revival and first subscription cannot drift apart, and
  # `tag: nil` survives the trip.
  defp revive_pending(agent_id, {acc, revived}) do
    key = {:agent, agent_id}

    case Map.get(acc, key) do
      %{state: :pending, channel: channel, tag: tag} ->
        opts = [channel: channel] ++ Publisher.State.tag_to_opts(tag)
        new_acc = subscribe_to_agent(acc, agent_id, opts)

        if match?(%{state: :subscribed}, Map.get(new_acc, key)) do
          {new_acc, [key | revived]}
        else
          {new_acc, revived}
        end

      _other ->
        {acc, revived}
    end
  end
end
