# Migration Guide: v0.6.0 → v0.7.0

## What changed and why

v0.7.0 introduces a first-class `scope` channel across all Sagents integration boundaries. Previously, multi-tenant applications had to thread their scope (user, organization, tenant) through `tool_context` as a workaround. Now `scope` is a named field on `Agent`, propagated automatically to every persistence callback and available in tool functions as `context.scope`.

The practical impact: every `@impl` module for the four persistence/callback behaviours gains `scope` as a new first positional argument. This makes the tenant context impossible to accidentally drop and enables clean pattern matching (`%MyApp.Scope{} = scope`) directly in function heads.

---

## Prerequisites

Before making any code changes:

1. Update the sagents dependency to the latest version:
   ```
   mix deps.update sagents
   ```
2. Run `mix deps.get` to fetch the updated dependency.
3. Run `mix compile` — the compiler will emit deprecation warnings pointing to every callback signature that needs updating. Use those warnings as a checklist to guide the migration steps below.

---

## Migration Steps

### 1. Add `scope` as the first argument to all `@impl` functions

**`AgentPersistence`**
```
persist_state(state_data, context)    →  persist_state(scope, state_data, context)
load_state(agent_id)                  →  load_state(scope, context)
```

**`DisplayMessagePersistence`**
```
save_message(message, context)                              →  save_message(scope, message, context)
update_tool_status(status, tool_info, context)              →  update_tool_status(scope, status, tool_info, context)
resolve_tool_result(tool_call_id, result_content, context)  →  resolve_tool_result(scope, tool_call_id, result_content, context)
```

**`FileSystemCallbacks`**
```
on_write(file_path, content, context)  →  on_write(scope, file_path, content, context)
on_read(file_path, context)            →  on_read(scope, file_path, context)
on_delete(file_path, context)          →  on_delete(scope, file_path, context)
on_list(context)                       →  on_list(scope, context)
```

**`MessagePreprocessor`**
```
preprocess(message, context)  →  preprocess(scope, message, context)
```

---

### 2. Update `AgentPersistence.persist_state` context pattern matches

`load_state` previously took a bare `agent_id` string. It now takes a context map. `persist_state`'s context argument changed from a plain atom to a map with a `:lifecycle` key.

```elixir
# Before
def persist_state(_agent_id, state_data, :on_completion), do: ...
def persist_state(_agent_id, state_data, _context), do: ...
def load_state(agent_id), do: ...

# After
def persist_state(_scope, state_data, %{lifecycle: :on_completion}), do: ...
def persist_state(_scope, state_data, _context), do: ...
def load_state(_scope, %{agent_id: agent_id, conversation_id: _conversation_id}), do: ...
```

---

### 3. Set `scope` on the Agent struct in every factory

`scope` does **not** flow automatically from `start_conversation_session` to callbacks — it must be explicitly set on the Agent struct inside each factory module. Without this step the migration compiles cleanly but `scope` is `nil` in every callback.

```elixir
# In every module that calls Agent.new / Agent.new!
def create_agent(opts) do
  scope = Keyword.get(opts, :scope)   # extract from opts passed by Coordinator
  # ...

  Agent.new(%{
    agent_id: agent_id,
    scope: scope,                      # ← required: this is the actual mechanism
    model: ...,
    # ...
  })
end
```

Do this for **every** factory in your application (`Factory`, `OnboardingClassifyFactory`, any other agent factory).

---

### 4. Pass `scope:` when calling `Coordinator.start_conversation_session`

```elixir
# Before
Coordinator.start_conversation_session(conversation_id,
  filesystem_scope: {:user, current_scope.user.id}
)

# After
Coordinator.start_conversation_session(conversation_id,
  scope: current_scope,
  filesystem_scope: {:user, current_scope.user.id}
)
```

Sagents reads `agent.scope` and passes it to all persistence callbacks and injects it as `context.scope` inside every tool function. Do not also put `scope` in `:tool_context` — Sagents injects it directly and will override any `:scope` key in `tool_context`.

---

### 5. Update direct (non-`@impl`) calls to persistence callbacks

The `@impl` modules are not the only call sites. Any orchestration code (coordinators, admin scripts, seeders) that calls persistence callbacks directly also needs updating. These produce **runtime** errors, not compile-time warnings, so they won't appear in the compiler checklist.

Common example — a coordinator that calls `load_state` directly before starting an agent:

```elixir
# Before
load_result = MyApp.AgentPersistence.load_state(agent_id)

# After
load_result = MyApp.AgentPersistence.load_state(scope, %{
  agent_id: agent_id,
  conversation_id: conversation_id
})
```

Search your codebase for direct calls to `AgentPersistence`, `DisplayMessagePersistence`, `MessagePreprocessor`, and `FileSystemCallbacks` modules outside of the behaviour implementations.

---

### 6. Update test files that call callbacks directly

Unit tests that invoke `@impl` callbacks directly will fail with `UndefinedFunctionError` at runtime — they do not produce compile-time warnings. For each affected callback, add `nil` as the first `scope` argument:

```elixir
# Before
{:ok, display, llm} = MyPreprocessor.preprocess(message, context)

# After
{:ok, display, llm} = MyPreprocessor.preprocess(nil, message, context)
```

Search your test files for calls to the affected modules and update the arity. Using `nil` for scope in tests is correct unless you are specifically testing scope-dependent behaviour, in which case pass a real scope struct.

### 7. Audit tool functions for scope access pattern

Tool functions (the lambdas inside `LangChain.Function.new!`) receive a `context` map. With v0.7.0, `context.scope` is automatically injected from `agent.scope`. However, **only tools that previously accessed scope via `tool_context` need to change** — the other patterns are unaffected.

Run this search to find every tool function lambda in your project:

```
grep -rn "LangChain.Function.new!\|Function.new!" lib/ --include="*.ex" -l
```

For each tool, classify which pattern the lambda uses:

| Pattern | Signature / access | Action required |
|---|---|---|
| **Old `tool_context` workaround** | `context.current_scope`, `context.tool_context[:scope]`, or any scope injected by the Coordinator into `tool_context` | **Migrate** — replace with `context.scope` |
| **Closure capture** | `filesystem_scope`, `project_id`, etc. captured in the enclosing `build/1` function | None |
| **Middleware-injected field** | `context.project_id`, `context.agent_id`, or other fields injected by a Middleware module | None |
| **Context ignored** | `_context`, all values come from closure | None |

**The only pattern requiring migration** is the old workaround where the Coordinator manually put the scope into `tool_context` (e.g. `tool_context = Map.put(tool_context, :current_scope, scope)`) so tools could read it as `context.current_scope`. Those tools must be updated:

```elixir
# Before — scope was manually injected into tool_context by the Coordinator
fn args, context ->
  scope = context.current_scope
  MyApp.do_something(scope, args)
end

# After — scope is now injected automatically as context.scope
fn args, context ->
  scope = context.scope
  MyApp.do_something(scope, args)
end
```

If your Coordinator previously had code like:

```elixir
tool_context = Map.put(tool_context, :current_scope, user_scope)
```

remove that line — it is no longer needed and the `:current_scope` key in `tool_context` will no longer be populated.

Tools using closure capture, middleware-injected fields, or ignoring context entirely require no changes.

---

## Recommended approach for generated files

Start from a clean, committed workspace, re-run `mix sagents.setup` with the same options used originally, accept the file overwrites, then use your diff tool to merge any customizations back in. The generator handles all generated files; the only manual work is updating your hand-written `@impl` modules as described above.
