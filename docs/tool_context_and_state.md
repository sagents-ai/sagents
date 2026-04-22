# Tool Context and State: Passing Data to Tools

This document explains how runtime data flows to tool functions in Sagents, the three context channels a tool sees, and how they behave across main agents and SubAgents.

## Overview

When an LLM decides to call a tool, the tool function receives two arguments:

```elixir
fn args, context ->
  # args: the LLM-provided arguments (parsed from JSON)
  # context: runtime data from the agent system
end
```

The `context` map is built by the agent system from three distinct sources: **scope**, **tool_context**, and **state**. Each has a different lifetime and a different purpose. Understanding them is essential for writing tools that work correctly in both main agents and SubAgents.

## The Three Context Channels

### `scope` -- Tenant / Auth Identity (first-class)

`scope` is the integrator-defined struct (e.g. `%MyApp.Accounts.Scope{}`) that identifies *who* the agent is running on behalf of. It's the canonical channel for tenancy and authorization data and it has its own dedicated field on the Agent struct.

```elixir
# Set at agent creation time via the dedicated :scope key
{:ok, agent} = Agent.new(%{
  model: model,
  scope: %MyApp.Accounts.Scope{user: current_user, org_id: 42}
})
```

In practice, the Coordinator forwards scope from the LiveView socket to the Factory, which sets it on the Agent:

```elixir
# In Coordinator.start_conversation_session/2
{:ok, agent} = Factory.create_agent(
  agent_id: agent_id,
  scope: scope,                     # <- dedicated channel, not tool_context
  filesystem_scope: filesystem_scope,
  tool_context: tool_context
)
```

**Characteristics:**

- First-class: `agent.scope` is a named field, not a magic key in a grab-bag.
- Opaque to sagents: the library doesn't inspect its contents. The integrator defines what lives inside.
- Not serialized: scope is session/runtime state, belonging to the *caller starting the agent right now*, not to the persisted conversation. On restore, scope comes from the fresh Coordinator invocation, not from anything loaded out of the database.
- **Never stash scope in `State.metadata` or other persisted surfaces** — that would leak across sessions.
- Sagents auto-merges `agent.scope` into the tool `custom_context` under the canonical top-level key `:scope`. Tool code reads `context.scope`.
- The same scope is also passed as the *first positional argument* to persistence-behaviour callbacks (`persist_state/3`, `save_message/3`, etc.). Scope appears in the same shape at every layer.

**Access pattern in tools:**

```elixir
fn _args, context ->
  context.scope  #=> %MyApp.Accounts.Scope{user: %User{...}, org_id: 42}
end
```

**Collision rule:** if `tool_context` contains a `:scope` key, sagents overrides it with `agent.scope` when building `custom_context`. Sagents owns that key. Don't put scope in `tool_context`.

#### Keep scope lean

The scope struct crosses process boundaries every time it reaches the Agent — LiveView process → Coordinator call → AgentServer GenServer → (for sub-agents) SubAgent processes → (for every tool invocation) the LLMChain's tool-call executor. In Erlang/Elixir, message passing between processes **copies** the term. A "scope" that embeds fully-loaded Ecto structs with preloaded associations (e.g., a `%User{}` with loaded `:organization`, `:memberships`, `:preferences`, `:api_keys`) gets copied in its entirety on every hop.

For agents this cost adds up: a long-running conversation can cross those boundaries hundreds of times, and the BEAM has to copy the whole graph each time even if the tool only reads `scope.user.id`.

If your application's Phoenix `Scope` is heavy, consider defining a **minimal agent-scoped struct** to pass to the agent instead of the full app scope:

```elixir
defmodule MyApp.Accounts.AgentScope do
  @moduledoc """
  Slim projection of `MyApp.Accounts.Scope` for passing to sagents.

  Contains only the fields tool functions and persistence queries actually
  read — not the full preloaded user graph.
  """
  defstruct [:user_id, :user_email, :org_id, :role]

  def from_scope(%MyApp.Accounts.Scope{} = scope) do
    %__MODULE__{
      user_id: scope.user.id,
      user_email: scope.user.email,
      org_id: scope.org && scope.org.id,
      role: scope.role
    }
  end
end

# At the LiveView / Coordinator call site:
Coordinator.start_conversation_session(conversation_id,
  scope: MyApp.Accounts.AgentScope.from_scope(socket.assigns.current_scope),
  filesystem_scope: filesystem_scope
)
```

Then your generated context's `scope_query/2` and `get_owner_id/1` helpers target fields on the slim struct (`scope.user_id`) instead of the full one (`scope.user.id`).

This is *not* required — the default generated code assumes the full Phoenix Scope and works fine for most applications. It's worth doing when (a) your Scope preloads deep associations, (b) you run long conversations with many tool invocations, or (c) profiling shows scope-copy cost on hot paths. If in doubt, start with the full Scope and slim it down if it becomes a measured problem.

### `tool_context` -- Static, Caller-Supplied Grab-Bag

`tool_context` is the integrator's own map of non-scope, caller-supplied data. It's for data that the agent's tools need but that doesn't have its own dedicated channel: feature flags, request-correlation IDs, a tenant-display-name to render in responses, etc.

```elixir
# Set at agent creation time
{:ok, agent} = Agent.new(%{
  model: model,
  scope: scope,                                    # tenant identity -- its own channel
  tool_context: %{feature_flags: flags, tenant_name: "Acme"}
})
```

**Characteristics:**

- Set once at agent creation, never changes during execution.
- Read-only from the tool's perspective.
- Merged flat into the `context` map — accessed as top-level keys.
- Not persisted or serialized (virtual field on the Agent struct).
- **Not for scope** — scope has its own channel. `tool_context` was the old transport; it is not any more.

**Access pattern in tools:**

```elixir
fn _args, context ->
  context.feature_flags  #=> %{new_search: true}
  context.tenant_name    #=> "Acme"
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

- Mutable — middleware and tools can read and write it.
- Evolves during agent execution.
- Persisted and restored across sessions via `StateSerializer`.
- Nested inside the `State` struct within `context`.

**Access pattern in tools:**

```elixir
fn _args, context ->
  context.state.metadata["conversation_title"]  #=> "My Chat"
  context.state.metadata["custom_key"]          #=> value set by middleware
end
```

## The Full `context` Map

When `Agent.build_chain` constructs the LLMChain, it merges the three channels (plus a few internal keys) into a single `custom_context`:

```elixir
# From agent.ex
custom_context =
  Map.merge(
    agent.tool_context || %{},
    %{
      state: state,
      parent_middleware: agent.middleware,
      parent_tools: agent.tools,
      # The original tool_context is preserved for clean SubAgent extraction
      tool_context: agent.tool_context || %{},
      # First-class scope channel -- sagents owns this key, so it always wins
      # on collision with anything an integrator put in tool_context.
      scope: agent.scope
    }
  )
```

Internal keys (`:state`, `:parent_middleware`, `:parent_tools`, `:tool_context`, `:scope`) always take precedence on collision — if your `tool_context` includes a key named `:scope` or `:state`, the internal value wins.

A tool function sees:

```elixir
fn args, context ->
  # From scope (flat, top-level, canonical)
  context.scope              #=> %Scope{...}

  # From tool_context (flat, top-level -- whatever the caller put in)
  context.feature_flags      #=> %{new_search: true}
  context.tenant_name        #=> "Acme"

  # From state (nested)
  context.state              #=> %State{agent_id: "...", metadata: %{...}, ...}
  context.state.metadata     #=> %{"conversation_title" => "My Chat"}

  # Internal (always present)
  context.parent_middleware  #=> [%MiddlewareEntry{}, ...]
  context.parent_tools       #=> [%Function{}, ...]
  context.tool_context       #=> %{feature_flags: ..., tenant_name: "Acme"}
                             #   (original map, used by SubAgent middleware)
end
```

> **Note:** The `:tool_context` key in `custom_context` holds the original tool_context map (without scope). This is an internal detail used by SubAgent middleware to cleanly extract and forward tool_context to child agents. Tool functions should access their data via the flat keys (e.g., `context.feature_flags`), not via `context.tool_context`.

## Writing Tools That Work in Both Agents and SubAgents

### Reading the tenant scope

Scope is always at `context.scope`, regardless of whether the tool runs in a main agent or a SubAgent:

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
      # Same access in main agent and SubAgent
      Projects.get_project(context.scope, id)
    end
  })
end
```

### Reading caller-supplied tool_context

Use `tool_context` for data that comes from outside the agent system and doesn't change during execution:

```elixir
function: fn _args, context ->
  if context.feature_flags[:new_search] do
    new_search_impl()
  else
    legacy_search_impl()
  end
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
  results = SearchService.search(context.scope, query)
  updated_state = State.put_metadata(context.state, "last_search", query)
  {:ok, format_results(results), updated_state}
end
```

## When to Use Which

| Use case | Channel | Example |
|----------|---------|---------|
| User identity / auth / tenant | `scope` (dedicated) | `context.scope` |
| Feature flags, request IDs, tenant display name | `tool_context` | `context.feature_flags` |
| Conversation title | `state.metadata` | `context.state.metadata["conversation_title"]` |
| Middleware tracking data | `state.metadata` | `context.state.metadata["debug_log.msg_count"]` |
| Data a tool writes for later tools | `state.metadata` | `State.put_metadata(state, "key", val)` |

**Rules of thumb:**

- Tenant identity → `:scope`. Always. It has its own channel because the whole system treats it specially (persistence callbacks see it as a positional arg, not a map key).
- Caller-supplied but non-tenant → `:tool_context`. Set at creation, static across the agent's lifetime.
- Set or updated during execution → `state.metadata`. Middleware publishes, tools read or write.

## SubAgent Context Propagation

All three channels should propagate from parent agent to SubAgent so that tools see the same data regardless of where they execute.

### How it works

When the SubAgent middleware spawns a SubAgent, it extracts each channel from the parent's runtime context:

1. **`scope`** is carried on the parent `agent.scope` field. The SubAgent middleware reads it (via the parent's `custom_context.scope`, which `Agent.build_chain` set) and assigns it to the SubAgent's own `agent.scope`. Sagents then re-merges it into the SubAgent's `custom_context` under the same canonical `:scope` key. Persistence callbacks on the SubAgent (if configured) see it as arg #1, same as the parent.
2. **`tool_context`** is stored as an explicit `:tool_context` key inside the parent's `custom_context` by `Agent.build_chain`. The SubAgent middleware reads this key directly and passes it to the SubAgent constructor, which merges it flat into the SubAgent's own `custom_context` and stores it again as `:tool_context` for further nesting.
3. **`state.metadata`** is copied from the parent's `State` into the SubAgent's fresh `State`.

The SubAgent gets its own isolated `State` (fresh `agent_id`, empty messages, empty todos) but inherits the parent's scope, tool_context, and metadata snapshot. This preserves the structural distinction:

```elixir
# In a SubAgent tool -- same access patterns as main agent
fn _args, context ->
  context.scope                                #=> %Scope{...} (from parent's scope)
  context.feature_flags                        #=> %{...} (from parent's tool_context)
  context.state.metadata["conversation_title"] #=> "My Chat" (from parent's metadata)
  context.state.agent_id                       #=> "parent-1-sub-12345" (SubAgent's own)
end
```

### What does NOT propagate

- **Messages**: SubAgents start with a fresh message history (system prompt + instructions only).
- **Todos**: SubAgents have their own empty todo list.
- **Agent ID**: Each SubAgent gets a unique ID derived from the parent's.

This ensures SubAgents are isolated execution units that share the parent's environment context (scope, tool_context, metadata) but maintain their own conversational state.

## Migration Notes (from the pre-scope-channel API)

Earlier versions of sagents used `tool_context[:current_scope]` as the convention for threading tenant scope into tool functions. That convention was upgraded to a first-class channel with its own Agent field and its own positional argument on persistence callbacks.

If you wrote tools against the old pattern, here are the mechanical replacements:

| Before | After |
|--------|-------|
| `tool_context: %{current_scope: scope, ...}` at agent creation | `scope: scope, tool_context: %{...}` (two separate keys) |
| `Map.put(tool_context, :current_scope, user_scope)` in Coordinator | Pass `:scope` directly to Factory/Coordinator; drop the manual merge |
| `context.current_scope` in tool function | `context.scope` |
| `context.tool_context[:current_scope]` in MessagePreprocessor callback | `context.scope` (scope is now a top-level context key) |
| `persist_state(agent_id, data, lifecycle)` callback | `persist_state(scope, data, context)` — scope is arg #1; `agent_id` and `lifecycle` are in the context map |
| `save_message(conv_id, message)` callback | `save_message(scope, message, context)` — scope is arg #1; `conversation_id` is in the context map |
| `Conversations.load_display_messages(conv_id)` | `Conversations.load_display_messages(scope, conv_id)` |

The upgrade is a hard break — there are no deprecation shims. A grep for `current_scope` in your own code (excluding Phoenix's `socket.assigns.current_scope`, which is unrelated) should surface every call site that needs updating.
