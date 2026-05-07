# Agent Lifecycle Management

This document covers how agent processes are started, managed, and terminated.

## Process Lifecycle

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Created   │──▶│   Running   │──▶│  Shutdown   │
└─────────────┘    └──────┬──────┘    └─────────────┘
                          │
                          ▼
                   ┌─────────────┐
                   │ Interrupted │
                   └─────────────┘
```

### States

| State | Description |
|-------|-------------|
| `:idle` | Agent is ready, not executing |
| `:running` | Agent is executing (LLM call or tools) |
| `:interrupted` | Waiting for human approval |
| `:cancelled` | Execution was cancelled by user |
| `:error` | Execution failed |

## Starting an Agent

### Basic Start

```elixir
alias Sagents.{Agent, AgentServer, State}

# Create agent configuration
{:ok, agent} = Agent.new(%{
  agent_id: "my-agent",
  model: model,
  middleware: [TodoList, FileSystem]
})

# Create initial state
state = State.new!(%{
  messages: [Message.new_user!("Hello")]
})

# Start the AgentServer
{:ok, pid} = AgentServer.start_link(
  agent: agent,
  initial_state: state,
  # `:pubsub` is optional — only used to wire `Phoenix.Presence`
  # `presence_diff` broadcasts. Per-agent events are delivered
  # directly to subscriber pids via `Sagents.Publisher` regardless.
  pubsub: {Phoenix.PubSub, :my_pubsub}
)
```

### Start with Options

```elixir
{:ok, pid} = AgentServer.start_link(
  agent: agent,
  initial_state: state,
  pubsub: {Phoenix.PubSub, :my_pubsub},

  # Lifecycle options
  inactivity_timeout: 3_600_000,  # 1 hour (default: 5 minutes)

  # Presence tracking
  presence_tracking: [
    enabled: true,
    presence_module: MyApp.Presence,
    topic: "conversation:123"
  ],

  # Auto-save
  auto_save: [
    callback: &MyApp.save_agent_state/2,
    interval: 30_000  # Every 30 seconds
  ],

  # Message persistence
  conversation_id: conversation_id,
  save_new_message_fn: fn conv_id, message ->
    MyApp.Conversations.save_message(conv_id, message)
  end
)
```

### Start from Persisted State

The generated Coordinator delegates to `Sagents.Session.start/3`, which
handles the full restore pipeline (router → factory → state load → supervisor):

```elixir
{:ok, session} =
  MyApp.Agents.Coordinator.start_conversation_session(conversation_id,
    scope: scope,
    request_opts: [timezone: "America/Denver"]
  )
```

If you need the raw building blocks (e.g. for tests or non-conversation
agents), the contract is:

```elixir
# Load saved state via your AgentPersistence module
{:ok, state} =
  Sagents.State.load_or_new(MyApp.AgentPersistence, scope,
    %{agent_id: "conv-#{conversation_id}", conversation_id: conversation_id})

# Build %FactoryConfig{} (typically via your Router) and call the factory
{:ok, agent, _session_opts} =
  MyApp.AgentFactory.create_agent("conv-#{conversation_id}", factory_config)

# Start with restored state
{:ok, pid} = AgentServer.start_link(
  agent: agent,
  initial_state: state,
  pubsub: {Phoenix.PubSub, :my_pubsub}
)
```

## Inactivity Timeout

Agents automatically shut down after a period of inactivity to free resources.

### Configuration

```elixir
# Default: 5 minutes (300_000 ms)
AgentServer.start_link(
  agent: agent,
  inactivity_timeout: 300_000
)

# Custom: 1 hour
AgentServer.start_link(
  agent: agent,
  inactivity_timeout: 3_600_000
)

# Disable timeout (agent runs forever)
AgentServer.start_link(
  agent: agent,
  inactivity_timeout: nil  # or :infinity
)
```

### How It Works

1. Timer resets on any activity:
   - Message added
   - Execution started
   - Resume from interrupt
   - State accessed

2. When timer expires:
   - Agent saves state (if auto-save configured)
   - Broadcasts `{:agent_shutdown, %{reason: :inactivity}}`
   - Process terminates normally

3. Clients handle shutdown:

```elixir
def handle_info({:agent, {:agent_shutdown, metadata}}, socket) do
  case metadata.reason do
    :inactivity ->
      # Agent timed out, can restart on next user action
      {:noreply, assign(socket, agent_status: :inactive)}

    :no_viewers ->
      # All viewers left after completion
      {:noreply, assign(socket, agent_status: :inactive)}

    :manual ->
      # Explicitly stopped
      {:noreply, assign(socket, agent_status: :stopped)}
  end
end
```

## Presence-Based Shutdown

With Phoenix.Presence, agents know when clients are viewing them and can shut down intelligently.

### Setup

1. Create a Presence module:

```elixir
defmodule MyApp.Presence do
  use Phoenix.Presence,
    otp_app: :my_app,
    pubsub_server: MyApp.PubSub
end
```

2. Configure agent with presence tracking:

```elixir
{:ok, pid} = AgentServer.start_link(
  agent: agent,
  presence_tracking: [
    enabled: true,
    presence_module: MyApp.Presence,
    topic: "conversation:#{conversation_id}"
  ]
)
```

3. Track presence in LiveView:

```elixir
def mount(%{"id" => id}, _session, socket) do
  if connected?(socket) do
    # Track this viewer
    {:ok, _} = MyApp.Presence.track(
      self(),
      "conversation:#{id}",
      socket.assigns.current_user.id,
      %{joined_at: DateTime.utc_now()}
    )
  end

  {:ok, socket}
end
```

### Behavior

| Agent State | Viewers | Action |
|-------------|---------|--------|
| `:running` | Any | Keep running |
| `:idle` | > 0 | Keep running |
| `:idle` | 0 | Start grace period, then shutdown |
| `:interrupted` | Any | Keep running (waiting for approval) |

When an agent completes (`:idle`) and no viewers are present:
1. Broadcasts `{:agent_shutdown, %{reason: :no_viewers}}`
2. Saves state (if configured)
3. Terminates

### Grace Period

To avoid race conditions (viewer refreshing page), there's a short grace period:

```elixir
presence_tracking: [
  enabled: true,
  presence_module: MyApp.Presence,
  topic: "conversation:123",
  grace_period: 5_000  # 5 seconds (default)
]
```

## Manual Shutdown

### Stop an Agent

```elixir
# Graceful stop (saves state if configured)
AgentServer.stop("my-agent")

# Stop with custom reason
AgentServer.stop("my-agent", :custom_reason)
```

### Cancel Execution

```elixir
# Cancel current execution (if running)
AgentServer.cancel("my-agent")
# Broadcasts {:status_changed, :cancelled, nil}
```

## State Export and Import

### Export Current State

```elixir
# Get current state for persistence
state = AgentServer.export_state("my-agent")

# Save to database
MyApp.Conversations.save_agent_state(conversation_id, state)
```

### Auto-Save

Configure automatic state saving:

```elixir
AgentServer.start_link(
  agent: agent,
  auto_save: [
    # Called periodically and on shutdown
    callback: fn agent_id, state ->
      MyApp.Conversations.save_agent_state(agent_id, state)
    end,

    # Save interval (default: 60 seconds)
    interval: 30_000,

    # Also save after execution completes
    on_idle: true  # default: true
  ]
)
```

Auto-save triggers:
- Every `interval` milliseconds (if changed since last save)
- When execution completes (`:idle`)
- Before shutdown

## Supervision

### Default Supervision Tree

```
AgentsSupervisor (DynamicSupervisor)
│
└── AgentSupervisor ("my-agent")
    ├── FileSystemServer
    ├── AgentServer
    └── SubAgentsDynamicSupervisor
```

### Restart Strategy

By default, if AgentServer crashes:
1. Supervisor restarts it
2. In-memory state is lost
3. Must restore from persisted state

To customize:

```elixir
# In your application supervisor
children = [
  {Sagents.AgentsSupervisor, restart_strategy: :one_for_one}
]
```

### Isolated Failures

Each agent has its own supervisor, so:
- One agent crashing doesn't affect others
- SubAgent crashes don't crash the parent
- FileSystemServer crash restarts just that component

## Coordinator Pattern

For applications managing many conversations, the session-start lifecycle
(idempotent start, router consult, factory invocation, state seeding,
supervisor config, subscriber wiring) lives in `Sagents.Session`. The
generated `Coordinator` is a thin per-app bridge that declares config
and exposes user-editable customization slots:

```elixir
defmodule MyApp.Agents.Coordinator do
  @config %{
    factory_router: MyApp.Agents.FactoryRouter,
    agent_persistence: MyApp.Agents.AgentPersistence,
    display_message_persistence: MyApp.Agents.DisplayMessagePersistence,
    pubsub: {Phoenix.PubSub, MyApp.PubSub},
    presence_module: MyAppWeb.Presence,
    inactivity_timeout: :timer.minutes(60),
    agent_id_fun: &__MODULE__.conversation_agent_id/1
  }

  def start_conversation_session(conversation_id, opts \\ []),
    do: Sagents.Session.start(@config, conversation_id, opts)

  def ensure_agent_session_running(state, request_opts \\ []),
    do: Sagents.Session.ensure_running(@config, state, request_opts: request_opts)

  def conversation_agent_id(conversation_id),
    do: "conversation-#{conversation_id}"
end
```

Run `mix sagents.setup` to generate the Coordinator along with its paired
`Factory` + `FactoryConfig` + `FactoryRouter`. See `Sagents.FactoryRouter`
for routing among multiple factories.

Usage in LiveView:

```elixir
def mount(%{"id" => conversation_id}, _session, socket) do
  # Load path: subscribe whether or not the agent is running.
  # Sagents.Subscriber records :pending entries and auto-upgrades
  # to :subscribed via presence_diff once the agent appears.
  subs =
    Sagents.Subscriber.subscribe_to_agent(
      %{},
      Coordinator.conversation_agent_id(conversation_id)
    )

  {:ok, assign(socket, conversation_id: conversation_id, sagents_subs: subs)}
end

# Action path: when the user actually triggers work, ensure the agent
# is running and the LiveView is subscribed (atomically, via
# initial_subscribers, to avoid the boot-broadcast race).
def handle_event("send_message", %{"text" => text}, socket) do
  case Coordinator.ensure_agent_session_running(socket.assigns,
         timezone: socket.assigns.timezone
       ) do
    {:ok, changes} ->
      socket = assign(socket, changes)
      AgentServer.add_message(socket.assigns.agent_id, Message.new_user!(text))
      {:noreply, socket}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, inspect(reason))}
  end
end
```

## Health Checks

### Check Agent Status

```elixir
# Get current status
AgentServer.get_status("my-agent")
# => :idle | :running | :interrupted | :error

# Get detailed info
AgentServer.agent_info("my-agent")
# => %{
#   agent_id: "my-agent",
#   pid: #PID<0.1234.0>,
#   status: :idle,
#   message_count: 5,
#   has_interrupt: false,
#   uptime_ms: 123456
# }
```

### List Running Agents

```elixir
# All running agents
AgentServer.list_running_agents()
# => ["conversation-1", "conversation-2", "user-42"]

# Count
AgentServer.agent_count()
# => 3

# Pattern matching
AgentServer.list_agents_matching("conversation-*")
# => ["conversation-1", "conversation-2"]
```

## Telemetry

Sagents emits telemetry events for monitoring:

```elixir
# Agent lifecycle
[:sagents, :agent, :start]
[:sagents, :agent, :stop]
[:sagents, :agent, :crash]

# Execution
[:sagents, :execution, :start]
[:sagents, :execution, :stop]
[:sagents, :execution, :interrupt]

# LLM calls
[:sagents, :llm, :request]
[:sagents, :llm, :response]
[:sagents, :llm, :error]
```

Attach handlers:

```elixir
:telemetry.attach_many(
  "my-handler",
  [
    [:sagents, :agent, :start],
    [:sagents, :agent, :stop],
    [:sagents, :execution, :stop]
  ],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```
