# Architecture Overview

This document describes the high-level architecture of Sagents and how its components work together.

## System Design Philosophy

Sagents is built on three core principles:

1. **OTP-Native**: Every agent is a supervised GenServer process, leveraging Erlang/OTP's battle-tested concurrency primitives
2. **Composable**: Capabilities are added through middleware
3. **Observable**: Real-time events flow through PubSub for UI reactivity and debugging

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
          ▼                  ▼                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Phoenix.PubSub                          │
│         Real-time events: status, messages, todos, etc.         │
└─────────────────────────────────────────────────────────────────┘
          ▲                  ▲                      ▲
          │                  │                      │
┌─────────┴──────────────────┴──────────────────────┴─────────────┐
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
3. **Broadcasts events** - Publishes to PubSub subscribers
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

### Context Propagation

`AgentContext` provides process-local context that flows through the entire agent hierarchy without
threading it through every function call:

```
Application (LiveView / Controller / Job)
        │
        │  agent_context: %{tenant_id: 42, trace_id: "abc"}
        ▼
┌───────────────────────────────────────┐
│  AgentSupervisor.start_link/1         │
│  Forwards :agent_context to children  │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  AgentServer.init/1                   │
│  AgentContext.init(context)           │
│  → stored in process dictionary       │
└───────────────────────────────────────┘
        │
        │  Task.async (inherits PD)
        ▼
┌───────────────────────────────────────┐
│  Agent.execute / Tool functions       │
│  AgentContext.get()                   │
│  → %{tenant_id: 42, trace_id: "abc"} │
└───────────────────────────────────────┘
        │
        │  AgentContext.fork/1 (snapshot)
        ▼
┌───────────────────────────────────────┐
│  SubAgentServer.init/1                │
│  AgentContext.init(forked_context)    │
│  → same context in child process      │
└───────────────────────────────────────┘
```

Context is stored in the process dictionary for zero-cost reads. At process boundaries
(spawning sub-agents), `AgentContext.fork/1` creates a snapshot that is explicitly passed
to the child. See `Sagents.AgentContext` for the full API.

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

```elixir
# Load persisted state
{:ok, persisted_state} = Conversations.load_agent_state(conversation_id)

# Create fresh agent from code
{:ok, agent} = AgentFactory.create_agent(agent_id: "conv-#{conversation_id}")

# Combine: code config + persisted state
{:ok, pid} = AgentServer.start_link(
  agent: agent,
  initial_state: persisted_state,
  pubsub: {Phoenix.PubSub, :my_pubsub}
)
```

## Registry and Discovery

Agents register with a named `Registry`:

```elixir
# Registration happens in AgentServer.start_link
Registry.register(Sagents.Registry, agent_id, %{})

# Discovery
AgentServer.list_running_agents()
# => ["conversation-1", "conversation-2"]

AgentServer.whereis("conversation-1")
# => #PID<0.1234.0>
```

## Supervision Tree

```
Application Supervisor
│
├── Phoenix.PubSub (:my_pubsub)
│
├── Sagents.Registry
│
├── Sagents.FileSystemSupervisor (DynamicSupervisor)
│   ├── FileSystemServer ({:user, 1})      # Scoped independently
│   ├── FileSystemServer ({:user, 2})
│   └── FileSystemServer ({:project, 42})  # Can be shared across agents
│
└── Sagents.AgentsDynamicSupervisor (DynamicSupervisor)
    │
    ├── AgentSupervisor ("conversation-1")
    │   ├── AgentServer
    │   └── SubAgentsDynamicSupervisor
    │       ├── SubAgentServer
    │       └── SubAgentServer
    │
    ├── AgentSupervisor ("conversation-2")
    │   └── ...
    │
    └── ...
```

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
- PubSub broadcasts are async and don't block execution

### Startup Time

- Agent startup is fast (just GenServer.start_link)
- State restoration depends on storage backend
- Consider lazy-loading old messages if history is large
