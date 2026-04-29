# Subscriptions & Presence

This describes how processes subscribe to events from a running agent
(or filesystem) in Sagents, and how presence makes those subscriptions
resilient to producer restarts.

## Mental Model

Per-agent events are delivered **directly** from each `AgentServer` to its subscribers via [`Sagents.Publisher`](../lib/sagents/publisher.ex). A subscriber registers itself by calling the producer's `subscribe` API (`GenServer.call`), and from then on every event is delivered by plain `send/2` from the producer to the subscriber pid. There is no `Phoenix.PubSub` topic in the path — the producer's named process is the rendezvous point.

Each producer maintains its own subscriber list, partitioned into channels.
For an `AgentServer`, two channels exist:

| Channel | Carries |
|---------|---------|
| `:main` | Status changes, LLM deltas/messages, todos, tool events, shutdown |
| `:debug` | State snapshots, middleware actions, sub-agent events, LLM errors |

`FileSystemServer` exposes a single `:main` channel for file change events.

The producer monitors each subscriber, so subscriber departure cleans up the
producer's bookkeeping automatically. To detect producer death, the
subscriber side uses its own monitor on the producer pid (see
[Subscriber-Side APIs](#subscriber-side-apis)).

`Phoenix.PubSub` is used for only two narrow purposes:

1. **Agent-discovery presence** — agents that come online publish their
   presence on a known topic so subscribers can discover them and attach.
2. **Application-level viewer presence** — optional, for hosts that want
   the agent to shut down when no one is watching.

These are explained below.

## Subscriber-Side APIs

### Direct: `AgentServer.subscribe/1` and `subscribe_debug/1`

The raw producer-side API:

```elixir
{:ok, server_pid, monitor_ref} = AgentServer.subscribe("conversation-123")
{:ok, server_pid, monitor_ref} = AgentServer.subscribe_debug("conversation-123")

# Returns {:error, :process_not_found} if no AgentServer is running
# under that agent_id.
```

Events arrive at the subscriber as `{:agent, event}` (main) or `{:agent, {:debug, event}}` (debug).

```elixir
def handle_info({:agent, event}, socket) do
  {:noreply, handle_agent_event(event, socket)}
end
```

The producer monitors the subscriber, so a dying subscriber is removed
automatically. **It does not install the reverse monitor for you** — if you
want to detect producer death (e.g., to re-subscribe after a crash), call
`Process.monitor(server_pid)` on the returned pid yourself.

`AgentServer.unsubscribe/1` and `unsubscribe_debug/1` always return `:ok`,
even if the producer is no longer running.

`FileSystemServer.subscribe/1` and `unsubscribe/1` follow the same shape —
events arrive as `{:file_system, event}`.

### Recommended: `Sagents.Subscriber`

For long-lived hosts (LiveViews, GenServer bridges) that need crash-safe
subscriptions across an agent's full lifecycle, use
[`Sagents.Subscriber`](../lib/sagents/subscriber.ex). It provides
consumer-side bookkeeping over the raw API:

- Stores subscription metadata in a host-owned `subs()` map.
- **Installs `Process.monitor(server_pid)` on your behalf**, so the host
  receives `:DOWN` if the producer crashes.
- Tracks a `:pending` state when subscribing to an agent that isn't
  running yet — the subscription auto-upgrades to `:subscribed` once the
  agent appears (see [Agent-Discovery Presence](#agent-discovery-presence)).
- Provides `handle_publisher_down/3` and `handle_presence_diff/3` helpers
  that the host's `handle_info/2` clauses delegate to.

API surface:

```elixir
# Bookkeeping primitives (all take and return a subs map)
subs = Subscriber.subscribe_to_agent(subs, agent_id)            # :main channel
subs = Subscriber.subscribe_to_agent(subs, agent_id, :debug)
subs = Subscriber.subscribe_to_filesystem(subs, scope_key)
subs = Subscriber.unsubscribe_from_agent(subs, agent_id)
subs = Subscriber.unsubscribe_from_filesystem(subs, scope_key)

# Recovery handlers (call from host's handle_info/2)
{:matched, subs} | :no_match = Subscriber.handle_publisher_down(subs, ref, reason)
subs = Subscriber.handle_presence_diff(subs, Subscriber.presence_topic(), payload)

# Topic to subscribe to for agent-arrival events
topic = Subscriber.presence_topic()
```

The `subs()` map is opaque to callers — store it in your socket assigns or
GenServer state and pass it back into the next call.

`AgentServer.subscribe/1` is enough for short-lived or one-off subscribers.
Reach for `Sagents.Subscriber` when the host must survive an agent restart
or be ready to subscribe before the agent exists.

## Agent-Discovery Presence

When an `AgentServer` starts with the `presence_module:` option, it tracks
itself on the constant topic `"agent_server:presence"` and updates its
presence metadata on every status change. This is the mechanism that lets
subscribers learn an agent has come online so they can attach (or
re-attach after a restart).

```elixir
AgentServer.start_link(
  agent: agent,
  pubsub: {Phoenix.PubSub, MyApp.PubSub},  # required when presence_module is set
  presence_module: MyApp.Presence
)
```

Subscribers consume agent arrivals by subscribing to
`Sagents.Subscriber.presence_topic()` (which returns the same constant
string) via `Phoenix.PubSub.subscribe/2`, and then forwarding each
`presence_diff` broadcast to `Sagents.Subscriber.handle_presence_diff/3`.
For each entry in `payload.joins`, the subscriber upgrades any matching
`:pending` subscriptions to `:subscribed` and re-installs the producer
monitor.

This is what makes the load path safe: a LiveView opening a conversation
can call `Subscriber.subscribe_to_agent(subs, agent_id)` even if the agent
isn't running yet — the sub is recorded as `:pending`, and the next time
the agent starts, the `presence_diff` fulfillment closes the loop.

### Worked LiveView example

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view
  alias Sagents.Subscriber

  @impl true
  def mount(%{"id" => conversation_id}, _session, socket) do
    agent_id = "conversation-#{conversation_id}"

    socket =
      if connected?(socket) do
        # Subscribe to agent-arrival presence first, so we never miss a join.
        Phoenix.PubSub.subscribe(MyApp.PubSub, Subscriber.presence_topic())

        # Subscribe to the agent itself. If it isn't running yet, this is
        # recorded as :pending and resolved by the next presence_diff.
        subs = Subscriber.subscribe_to_agent(%{}, agent_id)
        assign(socket, sagents_subs: subs)
      else
        assign(socket, sagents_subs: %{})
      end

    {:ok, assign(socket, agent_id: agent_id)}
  end

  # Producer crashed — Sagents.Subscriber flips the entry back to :pending.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    subs = socket.assigns.sagents_subs

    socket =
      case Subscriber.handle_publisher_down(subs, ref, reason) do
        {:matched, new_subs} -> assign(socket, sagents_subs: new_subs)
        :no_match -> socket
      end

    {:noreply, socket}
  end

  # Agent came online — Sagents.Subscriber upgrades :pending → :subscribed.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", payload: payload},
        socket
      ) do
    new_subs =
      Subscriber.handle_presence_diff(
        socket.assigns.sagents_subs,
        Subscriber.presence_topic(),
        payload
      )

    {:noreply, assign(socket, sagents_subs: new_subs)}
  end

  # Actual agent events.
  @impl true
  def handle_info({:agent, event}, socket) do
    {:noreply, handle_agent_event(event, socket)}
  end
end
```

The two recovery clauses are six lines of dispatch. Apps that ship a
generator (like the demo) typically wrap them in a thin `AgentLiveHelpers`
module so the LiveView reads as one-liners. See
[`mix sagents.gen.live_helpers`](../lib/mix/tasks/sagents/gen/live_helpers.ex)
for the template.

## Multiple Subscribers

Multiple processes can subscribe to the same agent on the same channel.
Each gets its own monitor ref and receives every event delivered on that
channel:

```elixir
# Tab 1
{:ok, _pid, _ref} = AgentServer.subscribe("conversation-123")

# Tab 2 (same or different user)
{:ok, _pid, _ref} = AgentServer.subscribe("conversation-123")

# Both receive every {:agent, event} delivered on :main.
```

This enables multiple browser tabs on the same conversation, shared
conversations between users, and admin dashboards monitoring user
conversations.

## Event Reference

All events are wrapped as `{:agent, event}` on `:main`, or
`{:agent, {:debug, event}}` on `:debug`.

### Status events

```elixir
{:agent, {:status_changed, status, data}}
```

| Status | Data | Description |
|--------|------|-------------|
| `:idle` | `nil` | Agent ready, not executing |
| `:running` | `nil` | Execution in progress |
| `:interrupted` | `%InterruptData{}` | Waiting for HITL approval |
| `:paused` | `nil` | Infrastructure pause (e.g., node draining); state is persisted |
| `:cancelled` | `nil` | User cancelled execution |
| `:error` | `reason` | Execution failed |

```elixir
def handle_agent_event({:status_changed, status, data}, socket) do
  case {status, data} do
    {:running, nil} ->
      socket |> assign(status: :running) |> assign(streaming_content: "")

    {:idle, nil} ->
      assign(socket, status: :idle)

    {:interrupted, interrupt_data} ->
      socket
      |> assign(status: :interrupted, interrupt: interrupt_data)
      |> push_event("show_approval_modal", %{})

    {:error, reason} ->
      socket
      |> assign(status: :error)
      |> put_flash(:error, "Agent error: #{inspect(reason)}")

    {:cancelled, nil} ->
      assign(socket, status: :cancelled)
  end
end
```

### LLM message events

```elixir
{:agent, {:llm_deltas, [%MessageDelta{}, ...]}}   # streaming tokens
{:agent, {:llm_message, %Message{}}}              # complete message
{:agent, {:llm_token_usage, %TokenUsage{}}}       # token usage info
```

### TODO events

```elixir
{:agent, {:todos_updated, [%Todo{}, ...]}}
```

The TODO list is a complete snapshot, not a diff — replace the local list on each event.

### Tool events

```elixir
{:agent, {:tool_call_identified, tool_info}}
# tool_info contains: %{call_id, name, display_text, arguments}

{:agent, {:tool_execution_started, tool_info}}

{:agent, {:tool_execution_completed, call_id, %ToolResult{}}}

{:agent, {:tool_execution_failed, call_id, error}}
```

### Display message events

```elixir
{:agent, {:display_message_saved, display_message}}
{:agent, {:display_message_updated, display_message}}
```

Fired when a display message has been persisted to the database (requires
`DisplayMessagePersistence` to be configured).

### Shutdown event

```elixir
{:agent, {:agent_shutdown, %{reason: reason, metadata: map}}}
```

| Reason | Cause |
|--------|-------|
| `:inactivity` | Inactivity timeout expired |
| `:no_viewers` | Idle and no viewers in viewer-presence list (see [Viewer-Presence Shutdown](#viewer-presence-shutdown)) |
| `:manual` | Explicitly stopped via `AgentServer.stop/1` |
| `:crash` | Process crashed (rare; typically you'd see this via `:DOWN` first) |

### Debug events

Available on the `:debug` channel after `AgentServer.subscribe_debug/1`.

```elixir
{:agent, {:debug, {:agent_state_update, %State{}}}}
{:agent, {:debug, {:middleware_action, module, data}}}
{:agent, {:debug, {:llm_error, error}}}
{:agent, {:debug, {:subagent, subagent_id, event}}}
```

> The [`sagents_live_debugger`](https://github.com/sagents-ai/sagents_live_debugger)
> package consumes these events to provide a real-time debugging dashboard
> covering agent state, middleware actions, and sub-agent hierarchies.

## Publishing Custom Events From Middleware

Middleware can publish events on either channel via the AgentServer API:

```elixir
defmodule MyMiddleware do
  @behaviour Sagents.Middleware

  def after_model(state, _config) do
    AgentServer.publish_event_from(
      state.agent_id,
      {:my_custom_event, %{data: "something"}}
    )

    AgentServer.publish_debug_event_from(
      state.agent_id,
      {:middleware_action, __MODULE__, {:custom_action, "details"}}
    )

    {:ok, state}
  end
end
```

Both functions are non-blocking casts. With zero subscribers on the target
channel, the broadcast is a no-op.

## Viewer-Presence Shutdown

This is a separate, optional mechanism: it lets the AgentServer shut itself
down when the application says no one is watching. It is unrelated to the
[Agent-Discovery Presence](#agent-discovery-presence) layer above.

Pass `presence_tracking:` at start time, supplying the application's
presence module and the topic the host LiveView (or other client) tracks
its viewers on:

```elixir
AgentServer.start_link(
  agent: agent,
  pubsub: {Phoenix.PubSub, MyApp.PubSub},
  presence_tracking: [
    enabled: true,
    presence_module: MyApp.Presence,
    topic: "conversation:#{conversation_id}",
    check_delay: 1_000  # ms before shutdown after presence drops to zero
  ]
)
```

The agent then:

1. Subscribes to the supplied topic via `Phoenix.PubSub` to receive
   `presence_diff` broadcasts.
2. On each broadcast, checks whether `presence_module.list(topic)` is
   empty.
3. If status is `:idle` and the list is empty, schedules
   `:shutdown_no_viewers` after `check_delay`.
4. Subscribers receive `{:agent, {:agent_shutdown, %{reason: :no_viewers}}}`
   and the process terminates.

The host application is responsible for tracking and untracking its own
viewers — typically in `mount/3` and `terminate/2`:

```elixir
def mount(%{"id" => id}, _session, socket) do
  if connected?(socket) do
    {:ok, _ref} =
      MyApp.Presence.track(
        self(),
        "conversation:#{id}",
        socket.assigns.current_user.id,
        %{joined_at: DateTime.utc_now()}
      )
  end

  {:ok, socket}
end
```

For lifecycle details (inactivity timeout, manual stop, grace periods),
see [lifecycle.md](lifecycle.md).

## Event Ordering

Events are delivered in order per agent (each producer's `send/2` is
sequential), but:

- No ordering guarantee across different agents.
- Streaming deltas may batch multiple tokens.
- State updates are eventual (not transactional).

Recommended consumer patterns:

- Use `{:llm_message, msg}` for final message content rather than
  accumulating `{:llm_deltas, _}` (deltas are for live UI; the complete
  message is the source of truth).
- Treat `{:todos_updated, todos}` as a snapshot replacement.
- Always handle `{:agent_shutdown, _}` (and `:DOWN` if you installed your
  own monitor) so the UI can react to the agent going away.

## Best Practices

### Always check `connected?/1` in LiveView mount

Subscriptions cost a `GenServer.call` to the producer. Don't pay for them
during the disconnected initial render:

```elixir
def mount(_params, _session, socket) do
  socket =
    if connected?(socket) do
      assign(socket, sagents_subs: Subscriber.subscribe_to_agent(%{}, agent_id))
    else
      assign(socket, sagents_subs: %{})
    end

  {:ok, socket}
end
```

### Subscribe to presence_topic before subscribing to the agent

Order matters when an agent might be starting up concurrently. Subscribe
to `Sagents.Subscriber.presence_topic()` first, then to the agent — that
way, if the agent registers between your two calls, you still receive the
`presence_diff` and can fulfill any `:pending` entry.

### Let `Sagents.Subscriber` handle recovery for you

Don't roll your own `Process.monitor` + `presence_diff` loop. The
`handle_publisher_down/3` and `handle_presence_diff/3` helpers already
encode the `:pending ↔ :subscribed` state machine. Six lines of
`handle_info/2` dispatch is all the host needs.

### Explicit unsubscription when scope changes

Subscriptions are cleaned up automatically when the subscriber process
dies. But when a single LiveView switches between conversations, unsub
the previous one explicitly to free the producer's bookkeeping slot
sooner:

```elixir
def handle_event("close_conversation", _params, socket) do
  new_subs =
    Subscriber.unsubscribe_from_agent(
      socket.assigns.sagents_subs,
      socket.assigns.agent_id
    )

  {:noreply, assign(socket, sagents_subs: new_subs, agent_id: nil)}
end
```
