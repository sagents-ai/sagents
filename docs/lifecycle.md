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
  pubsub: {Phoenix.PubSub, :my_pubsub}
)
```

### Start with Options

```elixir
{:ok, pid} = AgentServer.start_link(
  agent: agent,
  initial_state: state,
  pubsub: {Phoenix.PubSub, :my_pubsub},

  # Application context (propagated to sub-agents)
  agent_context: %{tenant_id: tenant_id, trace_id: trace_id},

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

```elixir
# Load saved state
{:ok, persisted_state} = MyApp.Conversations.load_agent_state(conversation_id)

# Create agent from code (middleware/tools always come from code)
{:ok, agent} = MyApp.AgentFactory.create_agent(agent_id: "conv-#{conversation_id}")

# Start with restored state
{:ok, pid} = AgentServer.start_link(
  agent: agent,
  initial_state: persisted_state,
  pubsub: {Phoenix.PubSub, :my_pubsub}
)
```

### Context Propagation to Sub-Agents

When `:agent_context` is provided, the context map is available in the AgentServer process
and in all tool functions (which run in `Task.async` and inherit the process dictionary).
When the agent spawns sub-agents, the SubAgent middleware automatically forks the context
so child agents receive the same values.

```elixir
# In a tool function, read the propagated context
defp my_scoped_query(_args, _context) do
  tenant_id = Sagents.AgentContext.fetch(:tenant_id)
  MyApp.Repo.all(from r in Record, where: r.tenant_id == ^tenant_id)
end
```

See `Sagents.AgentContext` for the full API.

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

For applications managing many conversations, use a Coordinator:

```elixir
defmodule MyApp.Agents.Coordinator do
  @moduledoc """
  Maps conversation IDs to agent processes.
  Handles starting agents on-demand with state restoration.
  """

  def start_conversation_session(conversation_id) do
    agent_id = "conversation-#{conversation_id}"

    case AgentServer.whereis(agent_id) do
      nil ->
        # Agent not running, start it
        start_agent(agent_id, conversation_id)

      pid ->
        # Already running
        {:ok, %{agent_id: agent_id, pid: pid, conversation_id: conversation_id}}
    end
  end

  defp start_agent(agent_id, conversation_id) do
    # Load persisted state (or create fresh)
    initial_state = load_or_create_state(conversation_id)

    # Create agent from code
    {:ok, agent} = MyApp.AgentFactory.create_agent(agent_id: agent_id)

    # Start agent server
    {:ok, pid} = AgentServer.start_link(
      agent: agent,
      initial_state: initial_state,
      pubsub: {Phoenix.PubSub, MyApp.PubSub},
      inactivity_timeout: 3_600_000,
      auto_save: [
        callback: fn _id, state ->
          MyApp.Conversations.save_agent_state(conversation_id, state)
        end
      ]
    )

    {:ok, %{agent_id: agent_id, pid: pid, conversation_id: conversation_id}}
  end

  defp load_or_create_state(conversation_id) do
    case MyApp.Conversations.load_agent_state(conversation_id) do
      {:ok, state} -> state
      {:error, :not_found} -> State.new!()
    end
  end
end
```

Usage in LiveView:

```elixir
def mount(%{"id" => conversation_id}, _session, socket) do
  # Start or connect to agent
  {:ok, session} = Coordinator.start_conversation_session(conversation_id)

  # Subscribe to events
  AgentServer.subscribe(session.agent_id)

  {:ok, assign(socket, agent_id: session.agent_id)}
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
