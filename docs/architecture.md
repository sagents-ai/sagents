# Architecture Overview

This document describes the high-level architecture of Sagents and how its components work together.

## System Design Philosophy

Sagents is built on three core principles:

1. **OTP-Native**: Every agent is a supervised GenServer process, leveraging Erlang/OTP's battle-tested concurrency primitives
2. **Composable**: Capabilities are added through middleware
3. **Observable**: Real-time events flow directly from each agent to its subscribers via `Sagents.Publisher` (no Phoenix.PubSub topic in the path) for UI reactivity and debugging

## Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Application                         │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐ │
│  │  LiveView    │   │  Controller  │   │  Background Job      │ │
│  │  (ChatLive)  │   │              │   │                      │ │
│  └──────┬───────┘   └──────┬───────┘   └──────────┬───────────┘ │
└─────────┼──────────────────┼──────────────────────┼─────────────┘
          │                  │                      │
          │ AgentServer.subscribe(agent_id)         │
          │ (registers via Sagents.Publisher;       │
          │  events delivered to subscriber pids    │
          │  by direct send/2 — no PubSub topic)    │
          ▼                  ▼                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                        AgentSupervisor                          │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                       AgentServer                           ││
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  ││
│  │  │    Agent    │  │    State    │  │  Middleware Stack   │  ││
│  │  │  (config)   │  │  (runtime)  │  │  [M1, M2, M3, ...]  │  ││
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘  ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  SubAgentsDynamicSupervisor                                │ │
│  │  ┌───────────┐  ┌───────────┐                              │ │
│  │  │ SubAgent1 │  │ SubAgent2 │  ...                         │ │
│  │  └───────────┘  └───────────┘                              │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
          │ references by scope
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                   FileSystemSupervisor                          │
│  ┌─────────────────────┐  ┌─────────────────────┐               │
│  │  FileSystemServer   │  │  FileSystemServer   │  ...          │
│  │  ({:user, 1})       │  │  ({:project, 42})   │               │
│  └─────────────────────┘  └─────────────────────┘               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         LangChain                               │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │   LLMChain      │  │  ChatModels     │  │  Message        │  │
│  │  (execution)    │  │  (Anthropic,    │  │  ToolCall       │  │
│  │                 │  │   OpenAI, etc.) │  │  ToolResult     │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Key Design Decision**: FileSystemServer is supervised separately from AgentServer. This allows flexible scoping - for example, a project-scoped filesystem can be shared across multiple conversation-scoped agents. Agents reference filesystems by scope tuple (e.g., `{:user, 123}`, `{:project, 456}`), not by direct supervision.

## Core Components

### Agent

The `Agent` struct holds the **configuration** for an agent:

```elixir
%Agent{
  agent_id: "conversation-123",
  model: %ChatAnthropic{...},
  base_system_prompt: "You are helpful.",
  middleware: [{TodoList, []}, {FileSystem, [enabled_tools: [...]]}, ...],
  tools: [custom_tool],  # Additional tools beyond middleware
  callbacks: %{...}      # Event callbacks
}
```

Key design decision: The Agent is **immutable configuration**. It doesn't hold runtime state - that's the State struct's job.

### State

The `State` struct holds **runtime data** that changes during execution:

```elixir
%State{
  agent_id: "conversation-123",
  messages: [%Message{...}, ...],
  todos: [%Todo{...}, ...],
  metadata: %{...},
  interrupt: nil | %InterruptData{...}
}
```

State flows through the middleware stack and accumulates:
- Messages from user and LLM
- Tool call results
- TODO list updates
- Middleware-specific metadata

### AgentServer

The `AgentServer` is a GenServer that:

1. **Manages lifecycle** - Starts, stops, handles timeouts
2. **Coordinates execution** - Runs the middleware/LLM loop
3. **Broadcasts events** - Delivers to subscriber pids via `Sagents.Publisher`
4. **Handles interrupts** - Pauses for HITL (Human In The Loop) and resumes

```elixir
# Simplified execution loop
def handle_cast(:execute, state) do
  case execute_agent_loop(state) do
    {:ok, new_state} ->
      broadcast(:status_changed, :idle, nil)
      {:noreply, %{state | agent_state: new_state}}

    {:interrupt, new_state, interrupt_data} ->
      broadcast(:status_changed, :interrupted, interrupt_data)
      {:noreply, %{state | agent_state: new_state, interrupt: interrupt_data}}

    {:error, reason} ->
      broadcast(:status_changed, :error, reason)
      {:noreply, state}
  end
end
```

### Middleware

Middleware implements the `Sagents.Middleware` behaviour:

```elixir
@callback init(opts :: keyword()) :: {:ok, config :: map()} | {:error, reason}
@callback system_prompt(config) :: String.t() | nil
@callback tools(config) :: [Function.t()]
@callback before_model(state, config) :: {:ok, state} | {:interrupt, state, data}
@callback after_model(state, config) :: {:ok, state} | {:interrupt, state, data}
@callback handle_message(message, state, config) :: {:ok, state}
@callback on_server_start(state, config) :: {:ok, state}
```

Middleware is applied in order:
- `before_model`: First middleware runs first
- `after_model`: First middleware runs **last** (reversed order)

This creates a "sandwich" pattern where early middleware wraps later middleware.

## Data Flow

### Message Execution Flow

```
User sends message
        │
        ▼
┌───────────────────────────────────────┐
│  AgentServer.add_message/2            │
│  Triggers execute/1                   │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Middleware: before_model (in order)  │
│  - TodoList: No-op                    │
│  - Summarization: Check token count   │
│  - PatchToolCalls: Fix dangling calls │
│  - HITL: No-op (nothing to approve)   │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Build LLMChain                       │
│  - System prompt (base + middleware)  │
│  - Messages from state                │
│  - Tools from middleware              │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  LLMChain.run (streaming)             │
│  - Deltas → broadcast                 │
│  - Tool calls → execute tools         │
│  - Complete message → broadcast       │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Middleware: after_model (reverse)    │
│  - HITL: Check for protected calls    │  ← May INTERRUPT here
│  - PatchToolCalls: No-op              │
│  - Summarization: No-op               │
│  - TodoList: Broadcast todos          │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Loop continues if needs_response?    │
│  (agent made tool calls)              │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Execution complete                   │
│  - Status → :idle                     │
│  - State persisted (if configured)    │
└───────────────────────────────────────┘
```

### Interrupt Flow (Human-In-The-Loop)

```
Agent makes protected tool call (e.g., write_file)
        │
        ▼
┌───────────────────────────────────────┐
│  HITL Middleware: after_model         │
│  Detects protected tool call          │
│  Returns {:interrupt, state, data}    │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  AgentServer stores interrupt         │
│  Broadcasts {:status_changed,         │
│              :interrupted, data}      │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  LiveView shows approval UI           │
│  User reviews tool calls              │
│  User makes decisions                 │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  AgentServer.resume(agent_id,         │
│                     decisions)        │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  HITL Middleware: apply_decisions     │
│  - :approve → Execute tool            │
│  - :edit → Execute with new args      │
│  - :reject → Return rejection msg     │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Execution resumes from loop          │
└───────────────────────────────────────┘
```

### SubAgent Flow

```
Parent agent calls spawn_subagent tool
        │
        ▼
┌───────────────────────────────────────┐
│  SubAgent Middleware creates child    │
│  - New AgentServer under              │
│    SubAgentsDynamicSupervisor         │
│  - Inherits HITL permissions          │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  SubAgent executes independently      │
│  - Own message history                │
│  - Own tool execution                 │
│  - Can also interrupt for HITL        │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  If SubAgent interrupts:              │
│  - Interrupt propagates to parent     │
│  - Parent shows approval UI           │
│  - Approval flows back to SubAgent    │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  SubAgent completes                   │
│  - Returns result to parent           │
│  - SubAgent process terminates        │
└───────────────────────────────────────┘
```

## State Persistence

### What Gets Persisted

```elixir
# AgentState schema (serialized JSON)
%{
  "messages" => [...],           # Full message history
  "todos" => [...],              # Current TODO list
  "metadata" => %{               # Middleware state
    "conversation_title" => "Debug payment bug",
    "filesystem_files" => %{...}  # If using in-memory filesystem
  }
}
```

### What Comes From Code

The **Agent configuration** is NOT persisted. This includes:
- Model settings
- Middleware stack
- Tool definitions
- System prompts

This separation means you can:
- Update middleware without migrating stored data
- A/B test different agent configurations
- Keep secrets (API keys) out of the database

### Restoration Pattern

`Sagents.Session.start/3` (called by the generated Coordinator) handles
this end-to-end: it consults the configured `FactoryRouter`, calls the
factory with `(agent_id, %FactoryConfig{})`, loads persisted state via
your `AgentPersistence` module, and starts the supervisor:

```elixir
# Application code
{:ok, session} =
  Coordinator.start_conversation_session(conversation_id,
    scope: scope,
    request_opts: [timezone: "America/Denver"]
  )

# Internally (simplified)
{:ok, factory, config} = Router.resolve(scope, conversation_id, request_opts)
{:ok, agent, session_opts} = factory.create_agent(agent_id, config)
{:ok, state} = State.load_or_new(AgentPersistence, scope, %{...},
                                 fresh_state_attrs: session_opts[:fresh_state_attrs])
AgentsDynamicSupervisor.start_agent_sync(agent: agent, initial_state: state, ...)
```

The router is consulted on every start (including resume), so a restored
conversation always rebuilds with the factory it was originally created
with. `:fresh_state_attrs` is applied only when no persisted state is
found; restored state always wins.

## Registry and Discovery

Every agent process registers itself in `Sagents.Registry` at start, through the
`Sagents.ProcessRegistry` abstraction. That module hides which backend is in
play:

- `:local` — Elixir's `Registry` (single node, no extra dependency)
- `:horde` — `Horde.Registry` (cluster-wide, requires the `:horde` dependency)

```elixir
config :sagents, :distribution, :local   # default
config :sagents, :distribution, :horde
```

Registration is by keyed `:via` tuple rather than by bare agent id, so a
supervisor and the server inside it are separate entries:

```elixir
Sagents.ProcessRegistry.via_tuple({:agent_server, "conversation-1"})
Sagents.ProcessRegistry.via_tuple({:agent_supervisor, "conversation-1"})
```

Discovery:

```elixir
AgentServer.list_running_agents()
# => ["conversation-1", "conversation-2"]

AgentServer.fetch_pid("conversation-1")
# => {:ok, #PID<0.1234.0>}
```

### A lookup has three outcomes

A registry read can only be answered while the registry process on *this* node
is alive. It is not alive while the node is still starting `Sagents.Supervisor`,
and it is not alive after that supervisor has shut down while the BEAM drains
during a rolling deploy — a window that lasts as long as the platform's grace
period, and during which a load balancer may still be routing requests here.

So the API keeps three answers distinct:

```elixir
case AgentServer.fetch_pid(agent_id) do
  {:ok, pid} -> ...                        # running
  {:error, :not_running} -> ...            # the registry answered: nothing there
  {:error, :registry_unavailable} -> ...   # this node cannot answer at all
end
```

**`:registry_unavailable` must never collapse into "not running".** A caller
that reads "nothing is running" responds by starting an agent, so collapsing the
two lets a draining node start a second AgentServer for a conversation that
already has one elsewhere. Both would hold and persist state for it, with
nothing reporting the conflict.

Functions whose return shape cannot carry the condition raise
`Sagents.RegistryUnavailableError` instead of answering `nil`, `false`, `[]` or
`0` — `AgentServer.get_pid/1`, `AgentServer.list_running_agents/0` and
`Sagents.Session.running?/2` among them. Prefer the tuple-returning forms
(`AgentServer.fetch_pid/1`, `Sagents.Session.ensure_running/3`) anywhere a web
request can reach, and map `:registry_unavailable` to a retryable 503 rather
than a 500: the cluster can serve the request, just not on this node.

`Sagents.ready?/0` exposes the same signal for a readiness endpoint. See
[Deployments, draining, and readiness](deployment.md).

## Supervision Tree

```
Application Supervisor (your app)
│
├── MyApp.Repo
├── Phoenix.PubSub (:my_pubsub)
│
├── Sagents.Supervisor                          # strategy: :rest_for_one
│   │
│   ├── Sagents.Registry                        # Registry | Horde.Registry
│   ├── Sagents.RegistryWatcher
│   │
│   ├── Sagents.AgentsDynamicSupervisor
│   │   ├── AgentSupervisor ("conversation-1")
│   │   │   ├── AgentServer
│   │   │   └── SubAgentsDynamicSupervisor
│   │   │       ├── SubAgentServer
│   │   │       └── SubAgentServer
│   │   │
│   │   └── AgentSupervisor ("conversation-2")
│   │       └── ...
│   │
│   └── Sagents.FileSystem.FileSystemSupervisor
│       ├── FileSystemServer ({:user, 1})       # Scoped independently
│       ├── FileSystemServer ({:user, 2})
│       └── FileSystemServer ({:project, 42})   # Can be shared across agents
│
└── MyAppWeb.Endpoint                           # after Sagents.Supervisor, on purpose
```

### Why `:rest_for_one`

An AgentSupervisor and an AgentServer register their `:via` names once, at
start, and nothing re-registers them afterwards. A registry that came back empty
underneath them would leave them running but invisible to every lookup — so the
next request reads "nothing is running" and starts a *second* AgentServer for a
conversation that already has one, with both persisting state.

`:rest_for_one` expresses that dependency: a registry failure takes the dynamic
supervisors down with it, agents stop, and the next request re-creates them from
persisted state. That looks heavy-handed and is the point. Agent state is
durable, so a restart is recoverable; a silent duplicate is not.

`Sagents.RegistryWatcher` is listed immediately after the registry because
neither backend lets a registry failure reach `Sagents.Supervisor` on its own.
Both run the registered process under a supervisor of their own and restart it
internally with fresh, empty tables, so this supervisor never sees a failed
child. The watcher monitors the registered process directly and stops when it
dies, which is what puts the restart into the `:rest_for_one` chain.

### Why the Endpoint comes last

OTP shuts children down in reverse start order. Listed **after**
`Sagents.Supervisor`, the Endpoint stops accepting requests first and the
registry is still alive to serve whatever is in flight. Listed **before**, it
keeps serving requests after the registry is gone, and every one of them fails
until the BEAM exits.

Correct ordering narrows that window but does not close it, because the node
stays reachable for the platform's whole drain period. Wiring `Sagents.ready?/0`
into a readiness check is what closes it. See
[Deployments, draining, and readiness](deployment.md).

**Flexible Scoping**: FileSystemServer lives outside the AgentSupervisor tree, allowing different scoping strategies. For example:
- User-scoped filesystem: All of a user's conversations share the same files
- Project-scoped filesystem: Multiple users' conversations on the same project share files
- Conversation-scoped filesystem: Each conversation has isolated files

Agents reference their filesystem by scope tuple (e.g., `filesystem_scope: {:user, 123}`), and the FileSystem middleware looks up or starts the appropriate FileSystemServer.

## Error Handling

### Agent Crashes

If an AgentServer crashes:
1. Supervisor restarts it
2. State is lost (unless persisted)
3. Clients receive `{:agent_shutdown, %{reason: :crash}}`

To preserve state across crashes, enable auto-save:

```elixir
AgentServer.start_link(
  agent: agent,
  auto_save: [
    callback: &MyApp.save_state/2,
    interval: 30_000  # Save every 30 seconds
  ]
)
```

### Registry Failure

A registry process crashing is rare, but it has a defined outcome: the
`:rest_for_one` chain restarts the dynamic supervisors below it, agents on that
node stop, and the next request re-creates them from persisted state.

Two internal pieces make that restart land correctly, and you call neither:

- `Sagents.RegistryWatcher` connects the failure to the restart chain, because
  both backends restart the registered process internally.
- `Sagents.LocalRegistry` covers the `:local` backend, where the restart races
  the outgoing registry's partition process. That partition traps exits, because
  it links to every registered process, so it does not die with the registry: it
  terminates asynchronously and holds its registered name for a few milliseconds
  longer. A start landing inside that window fails with
  `{:already_started, pid}`, and a supervisor does not retry its way out of a
  failed restart — it would give up and take the whole tree with it.
  `Sagents.LocalRegistry` monitors the straggler, waits for it to exit, and
  retries.

### A Draining or Starting Node

The node's registry cannot answer lookups before `Sagents.Supervisor` has
started and after it has shut down. The second window is every rolling deploy,
and it lasts for the platform's whole grace period while the node is still
reachable.

Lookups report this as `{:error, :registry_unavailable}` or raise
`Sagents.RegistryUnavailableError` rather than answering with a plausible
default — see [A lookup has three outcomes](#a-lookup-has-three-outcomes-not-two).
It is not a race to retry through: on the affected node *every* call fails
identically until the BEAM exits, so recovery has to come from the request
landing on a different node.

### Node Departure in a Cluster (`:horde`)

Horde hands a departed node's processes to a survivor only once that survivor
has converged on the departure and marked the node's member entry dead. An agent
placed immediately before its node leaves is dropped rather than handed over;
one that has been running for a couple of seconds or more is redistributed
reliably. Whether the departure is graceful makes no difference.

A dropped agent is dropped **cleanly**: the registry and Horde's process CRDT
are both left with no entry for it, so there is no orphan and no duplicate, and
the next `Sagents.Session.ensure_running/3` starts it again from persisted
state. That is the same recovery path an inactivity shutdown uses.

The rule to design to: **treat redistribution as an optimization and the next
request as the guarantee.** Work that must happen should be driven by a request,
a job, or a supervisor you control, never by assuming Horde kept an agent alive
somewhere. See
[Taking a node out of the cluster](clustering.md#taking-a-node-out-of-the-cluster).

### LLM Errors

LLM API errors are handled gracefully:

```elixir
case LLMChain.run(chain) do
  {:ok, chain} ->
    # Success
    {:ok, extract_state(chain)}

  {:error, chain, reason} ->
    # Broadcast error, keep state intact
    broadcast(:status_changed, :error, reason)
    {:error, reason}
end
```

### Tool Execution Errors

Tool errors are returned to the LLM as tool results:

```elixir
# If tool function returns {:error, reason}
%ToolResult{
  tool_call_id: call_id,
  content: "Error: #{reason}",
  is_error: true
}
```

The LLM can then decide how to proceed (retry, ask user, etc.).

## Performance Considerations

### Memory

- Each agent process holds its full message history in memory
- Use Summarization middleware to compress long conversations
- FileSystem middleware can offload to persistence callbacks

### Concurrency

- Each agent is independent - no contention between conversations
- SubAgents run in parallel under the same supervisor
- Event delivery via `Sagents.Publisher` is non-blocking `send/2` per subscriber and doesn't block execution

### Startup Time

- Agent startup is fast (just GenServer.start_link)
- State restoration depends on storage backend
- Consider lazy-loading old messages if history is large
