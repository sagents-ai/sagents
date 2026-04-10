# Tool Context and State: Passing Data to Tools

This document explains how runtime data flows to tool functions in Sagents, the distinction between the two context channels, and how they behave across main agents and SubAgents.

## Overview

When an LLM decides to call a tool, the tool function receives two arguments:

```elixir
fn args, context ->
  # args: the LLM-provided arguments (parsed from JSON)
  # context: runtime data from the agent system
end
```

The `context` map is built by the agent system and contains data from two distinct sources: **tool_context** and **state**. Understanding the difference is essential for writing tools that work correctly in both main agents and SubAgents.

## The Two Context Channels

### `tool_context` -- Static, External Environment

`tool_context` is caller-supplied data set once when the agent is created. It represents the environment the agent runs in -- which user, which project, which tenant. Think of it like environment variables for a process.

```elixir
# Set at agent creation time
{:ok, agent} = Agent.new(%{
  model: model,
  tool_context: %{user_id: 42, tenant: "acme", current_scope: scope}
})
```

In practice, the Coordinator sets `tool_context` when starting a conversation session:

```elixir
# In Coordinator.start_conversation_session/2
tool_context = Map.put(tool_context, :current_scope, user_scope)
factory_opts = Keyword.put(opts, :tool_context, tool_context)
```

**Characteristics:**
- Set once at agent creation, never changes during execution
- Read-only from the tool's perspective
- Merged flat into the `context` map -- accessed as top-level keys
- Not persisted or serialized (it's a virtual field on the Agent struct)

**Access pattern in tools:**
```elixir
fn _args, context ->
  context.user_id        #=> 42
  context.tenant         #=> "acme"
  context.current_scope  #=> %Scope{user: %User{...}}
end
```

### `state.metadata` -- Dynamic, Internal State

`state.metadata` is a mutable key-value store within the agent's `State` struct. Middleware and tools can read and write it during execution. It evolves over the lifetime of a conversation and is persisted across sessions.

**Set by middleware during execution:**
```elixir
# ConversationTitle middleware sets a title after generating one
def after_model(state, _config) do
  {:ok, State.put_metadata(state, "conversation_title", title)}
end

# DebugLog middleware tracks message counts across LLM cycles
def before_model(state, _config) do
  count = State.get_metadata(state, "debug_log.msg_count", 0)
  {:ok, State.put_metadata(state, "debug_log.msg_count", count + 1)}
end
```

**Set by tools returning updated state:**
```elixir
function: fn _args, context ->
  updated_state = State.put_metadata(context.state, "last_search_query", query)
  {:ok, "Results: ...", updated_state}
end
```

**Characteristics:**
- Mutable -- middleware and tools can read and write it
- Evolves during agent execution
- Persisted and restored across sessions via `StateSerializer`
- Nested inside the `State` struct within `context`

**Access pattern in tools:**
```elixir
fn _args, context ->
  context.state.metadata["conversation_title"]  #=> "My Chat"
  context.state.metadata["custom_key"]          #=> value set by middleware
end
```

## The Full `context` Map

When `Agent.build_chain` constructs the LLMChain, it builds `custom_context` by merging `tool_context` flat into the map alongside internal keys:

```elixir
# From agent.ex ~line 730
custom_context =
  Map.merge(
    agent.tool_context || %{},
    %{
      state: state,
      parent_middleware: agent.middleware,
      parent_tools: agent.tools,
      # The original map is preserved for clean SubAgent extraction
      tool_context: agent.tool_context || %{}
    }
  )
```

Internal keys (`:state`, `:parent_middleware`, `:parent_tools`, `:tool_context`) always take precedence on collision -- if your `tool_context` includes a key named `:state`, the internal `State` struct wins.

A tool function sees:

```elixir
fn args, context ->
  # From tool_context (flat, top-level)
  context.user_id            #=> 42
  context.current_scope      #=> %Scope{...}

  # From state (nested)
  context.state              #=> %State{agent_id: "...", metadata: %{...}, ...}
  context.state.metadata     #=> %{"conversation_title" => "My Chat"}

  # Internal (always present)
  context.parent_middleware  #=> [%MiddlewareEntry{}, ...]
  context.parent_tools       #=> [%Function{}, ...]
  context.tool_context       #=> %{user_id: 42, ...} (original map, used by SubAgent middleware)
end
```

> **Note:** The `:tool_context` key in `custom_context` holds the original tool_context map.
> This is an internal detail used by the SubAgent middleware to cleanly extract and forward
> tool_context to child agents. Tool functions should access their data via the flat keys
> (e.g., `context.user_id`), not via `context.tool_context`.

## Writing Tools That Work in Both Agents and SubAgents

### Reading static environment data

Use `tool_context` for data that comes from outside the agent system and doesn't change during execution:

```elixir
def build do
  Function.new!(%{
    name: "get_project",
    description: "Fetch project details",
    parameters_schema: %{
      type: "object",
      properties: %{id: %{type: "string"}},
      required: ["id"]
    },
    function: fn %{"id" => id}, context ->
      # tool_context key -- same in main agent and SubAgent
      Projects.get_project(context.current_scope, id)
    end
  })
end
```

### Reading dynamic middleware-managed data

Use `state.metadata` for data that middleware sets during execution:

```elixir
function: fn _args, context ->
  title = State.get_metadata(context.state, "conversation_title", "Untitled")
  {:ok, "Current conversation: #{title}"}
end
```

### Updating state from a tool

Tools can return an updated `State` as a third element in the result tuple:

```elixir
function: fn %{"query" => query}, context ->
  results = SearchService.search(query)
  updated_state = State.put_metadata(context.state, "last_search", query)
  {:ok, format_results(results), updated_state}
end
```

## When to Use Which

| Use case | Channel | Example |
|----------|---------|---------|
| User identity / auth scope | `tool_context` | `context.current_scope` |
| Tenant or project ID | `tool_context` | `context.tenant` |
| Conversation title | `state.metadata` | `context.state.metadata["conversation_title"]` |
| Middleware tracking data | `state.metadata` | `context.state.metadata["debug_log.msg_count"]` |
| Data a tool writes for later tools | `state.metadata` | `State.put_metadata(state, "key", val)` |

**Rule of thumb:** If it's set by the caller and never changes, use `tool_context`. If it's set or updated during execution, use `state.metadata`.

## SubAgent Context Propagation

Both context channels should propagate from parent agent to SubAgent so that tools see the same data regardless of where they execute.

### How it works

When the SubAgent middleware spawns a SubAgent, it extracts both channels from the parent's runtime context:

1. **`tool_context`** is stored as an explicit `:tool_context` key inside `custom_context` by `Agent.build_chain`. The SubAgent middleware reads this key directly (`context.tool_context`) and passes it to the SubAgent constructor, which merges it flat into the SubAgent's own `custom_context` and stores it again as `:tool_context` for further nesting.
2. **`state.metadata`** is copied from the parent's `State` into the SubAgent's fresh `State`.

The SubAgent gets its own isolated `State` (fresh `agent_id`, empty messages, empty todos) but inherits the parent's metadata snapshot and tool_context. This preserves the structural distinction:

```elixir
# In a SubAgent tool -- same access patterns as main agent
fn _args, context ->
  context.user_id                              #=> 42 (from parent's tool_context)
  context.state.metadata["conversation_title"] #=> "My Chat" (from parent's metadata)
  context.state.agent_id                       #=> "parent-1-sub-12345" (SubAgent's own)
end
```

### What does NOT propagate

- **Messages**: SubAgents start with a fresh message history (system prompt + instructions only)
- **Todos**: SubAgents have their own empty todo list
- **Agent ID**: Each SubAgent gets a unique ID derived from the parent's

This ensures SubAgents are isolated execution units that share the parent's environment context but maintain their own conversational state.
