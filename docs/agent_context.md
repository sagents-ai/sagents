# AgentContext and State.metadata — Usage Guide

Sagents provides two mechanisms for attaching data to agents. They serve
different purposes and should not be confused. This guide explains when to use
each, and how to update your code.

## Quick decision

Ask yourself: **does this value need to survive after the process dies?**

- **Yes** → use `State.metadata` (persisted to the database, restored on
  restart)
- **No** → use `AgentContext` (lives in the process dictionary, propagated to
  sub-agents automatically)

## When to use AgentContext

Use `AgentContext` for ambient, application-level values that every agent and
tool in the hierarchy needs to read but that have no reason to be stored in the
database. These values originate at the application boundary (your LiveView,
controller, or background job) and flow downward through the entire agent tree.

**Examples**: `tenant_id`, `user_id`, `trace_id`, OpenTelemetry span context,
feature flags, session tokens.

### How to pass it

Pass `:agent_context` when starting your agent supervisor:

```elixir
AgentSupervisor.start_link(
  agent: agent,
  agent_context: %{tenant_id: tenant_id, user_id: current_user.id}
)
```

### How to read it (in tools)

```elixir
defp my_tool_function(_args, _context) do
  tenant_id = AgentContext.fetch(:tenant_id)
  MyApp.Repo.all(from r in Record, where: r.tenant_id == ^tenant_id)
end
```

### How to read it (in middleware)

```elixir
def before_model(state, _config) do
  user_id = AgentContext.fetch(:user_id)
  Logger.metadata(user_id: user_id)
  {:ok, state}
end
```

### Writing to AgentContext at runtime

If middleware or tools need to add derived values during execution:

```elixir
AgentContext.put(:request_id, "req-123")
AgentContext.merge(%{correlation_id: "corr-456", region: "us-east-1"})
```

These writes only affect the current process's dictionary and are not persisted.

## When to use State.metadata

Use `State.metadata` for values that are part of the conversation's persistent
state. These are serialized to JSONB via `StateSerializer` and survive process
restarts, Horde redistribution, and conversation restoration.

**Examples**: generated conversation title, middleware working state (e.g., "has
this middleware already run its one-time setup?"), user preferences set during
the conversation.

### How to read/write it (in middleware)

```elixir
def before_model(state, _config) do
  case State.get_metadata(state, "conversation_title") do
    nil ->
      # First time — trigger title generation
      {:ok, State.put_metadata(state, "title_triggered", true)}
    _title ->
      {:ok, state}
  end
end
```

### Important constraints

- **Use string keys** for metadata values. They are serialized to JSONB, which
  requires string keys. Atom keys will work at runtime but may cause issues on
  deserialization.
- **Never store non-serializable values** (PIDs, references, functions) in
  metadata. They will be lost on serialization. Use `AgentContext` with restore
  functions for such values.

## Migrating existing code

### If you were storing tenant_id / user_id in State.metadata

**Before** (works but wrong store):

```elixir
# At agent start
state = State.new!(%{metadata: %{"tenant_id" => tenant_id}})

# In a tool
tenant_id = context[:state].metadata["tenant_id"]
```

**After** (recommended):

```elixir
# At agent start
AgentSupervisor.start_link(
  agent: agent,
  agent_context: %{tenant_id: tenant_id}
)

# In a tool
tenant_id = AgentContext.fetch(:tenant_id)
```

Why: tenant_id doesn't need to be persisted to the database, and `AgentContext`
propagates automatically to sub-agents without threading the state struct
through every function.

### If you were passing context through custom_context manually

**Before** (manual threading):

```elixir
# Building chain with manual context
custom_context = %{tenant_id: tenant_id, trace_id: trace_id}
chain = LLMChain.new!(%{...}) |> LLMChain.update_custom_context(custom_context)
```

**After** (automatic propagation):

```elixir
# Set once at the boundary
AgentSupervisor.start_link(
  agent: agent,
  agent_context: %{tenant_id: tenant_id, trace_id: trace_id}
)

# Available everywhere — tools, middleware, sub-agents
AgentContext.fetch(:tenant_id)
```

### If you have middleware using on_fork_context for OTel or Logger

No changes needed. `on_fork_context/2` continues to work as before. The new
`put/2` and `merge/1` functions are additive — existing
`init/get/fetch/fork/fork_with_middleware` APIs are unchanged.

## Summary table

|                               | `AgentContext`                              | `State.metadata`                             |
| ----------------------------- | ------------------------------------------- | -------------------------------------------- |
| **Storage**                   | Process dictionary                          | Ecto field on `State`                        |
| **Persisted to DB?**          | No                                          | Yes (serialized to JSONB)                    |
| **Survives restart?**         | No                                          | Yes                                          |
| **Propagated to sub-agents?** | Yes (automatic via fork)                    | Yes (inherited from parent)                  |
| **Access pattern**            | `AgentContext.fetch(:key)`                  | `State.get_metadata(state, key)`             |
| **Requires state param?**     | No                                          | Yes                                          |
| **Use for**                   | tenant_id, trace_id, user_id, feature flags | conversation_title, middleware working state |
