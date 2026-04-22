# State Persistence

This document covers saving and restoring agent conversations.

## Overview

Sagents separates **configuration** from **state**:

| Component | Stored In | Contains |
|-----------|-----------|----------|
| Configuration | Code | Model, middleware, tools, prompts |
| State | Database | Messages, todos, metadata |

This separation means:
- You can update middleware without migrating data
- Agent capabilities are version-controlled with code
- Secrets (API keys) stay out of the database

## Data Model

### What Gets Persisted

```elixir
# State structure (stored as JSONB in agent_states.state_data)
%State{
  agent_id: "conversation-123",     # Links to conversation
  messages: [...],                  # Full conversation history
  todos: [...],                     # Current TODO list
  metadata: %{                      # Middleware-specific data
    "conversation_title" => "...",
    "preferences" => %{...}
  },
  interrupt: nil                    # Pending HITL (if any)
}
```

### What Stays in Code

```elixir
# Agent configuration
%Agent{
  model: %ChatAnthropic{...},      # LLM configuration
  middleware: [...],                # Middleware stack
  tools: [...],                     # Additional tools
  base_system_prompt: "...",        # System prompt
  scope: %Scope{...}                # Tenant scope (session/runtime state; NOT persisted)
}
```

> **Note on scope:** `agent.scope` is session/runtime state belonging to the
> caller who started the agent right now, not to the persisted conversation.
> It is deliberately excluded from serialization. On restore, scope comes from
> the fresh Coordinator invocation, not from anything loaded out of the
> database. Never stash scope into `State.metadata` — that would leak across
> sessions.

## Code Generator

### Basic Usage

```bash
mix sagents.setup MyApp.Conversations --scope MyApp.Accounts.Scope
```

This generates:
- `lib/my_app/conversations.ex` — Context module (scope-filtered CRUD, display messages, tool-call lifecycle)
- `lib/my_app/conversations/conversation.ex` — Conversation schema
- `lib/my_app/conversations/agent_state.ex` — State schema
- `lib/my_app/conversations/display_message.ex` — UI message schema
- `lib/my_app/agents/factory.ex` — Agent factory (model + middleware)
- `lib/my_app/agents/coordinator.ex` — Session management and agent lifecycle
- `lib/my_app/agents/agent_persistence.ex` — `Sagents.AgentPersistence` implementation
- `lib/my_app/agents/display_message_persistence.ex` — `Sagents.DisplayMessagePersistence` implementation
- `priv/repo/migrations/..._create_sagents_tables.exs` — Migration

### With Options

```bash
mix sagents.setup MyApp.Conversations \
  --scope MyApp.Accounts.Scope \
  --owner-type user \
  --owner-field user_id \
  --owner-module MyApp.Accounts.User \
  --table-prefix sagents_
```

Options:
- `--scope` — Application scope module (required)
- `--owner-type` — Owner type (`user`, `account`, `team`, `org`, `none`)
- `--owner-field` — Foreign key field name (default: `user_id`)
- `--owner-module` — Owner schema module (inferred from `--owner-type` if omitted)
- `--table-prefix` — Database table prefix (default: `sagents_`)
- `--factory` / `--coordinator` / `--pubsub` / `--presence` — Module name overrides

See `mix help sagents.setup` for the full option list.

## Generated Schemas

### Conversation

```elixir
defmodule MyApp.Conversations.Conversation do
  use Ecto.Schema

  schema "sagents_conversations" do
    belongs_to :user, MyApp.Accounts.User, foreign_key: :user_id, type: :id

    has_one :agent_state, MyApp.Conversations.AgentState
    has_many :display_messages, MyApp.Conversations.DisplayMessage

    field :title, :string
    field :version, :integer, default: 1
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end
end
```

Tenant isolation is enforced through the owner foreign key (`user_id` by default) and the context's `scope_query/2` helper, not through a generic `:scope` column.

### AgentState

```elixir
defmodule MyApp.Conversations.AgentState do
  use Ecto.Schema

  schema "sagents_agent_states" do
    belongs_to :conversation, MyApp.Conversations.Conversation

    field :state_data, :map   # Serialized State struct (JSONB)
    field :version, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
```

### DisplayMessage

```elixir
defmodule MyApp.Conversations.DisplayMessage do
  use Ecto.Schema

  schema "sagents_display_messages" do
    belongs_to :conversation, MyApp.Conversations.Conversation

    field :message_type, :string      # "user", "assistant", "tool", "system"
    field :content, :map              # Flexible JSONB storage
    field :content_type, :string      # "text", "thinking", "image", "tool_call", etc.
    field :sequence, :integer, default: 0
    field :status, :string, default: "completed"
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
```

DisplayMessages are multi-content-type: one logical assistant turn can produce several rows (thinking + text + tool_call), ordered by `(inserted_at, sequence)`. See the schema's moduledoc for the valid `content_type` values and their expected `content` shapes.

## Context Module

The generated context provides scope-filtered CRUD. Every public function takes a `%Scope{}` as its first argument. Wrong-scope callers receive `{:error, :not_found}`.

```elixir
defmodule MyApp.Conversations do
  # Conversation CRUD
  def create_conversation(scope, attrs)
  def get_conversation(scope, id)
  def get_conversation!(scope, id)
  def update_conversation(conversation, attrs)
  def delete_conversation(conversation)
  def delete_conversation(scope, id)
  def list_conversations(scope, opts \\ [])
  def search_messages(scope, term)

  # Agent state
  def save_agent_state(scope, conversation_id, state)
  def load_agent_state(scope, conversation_id)
  def load_todos(scope, conversation_id)

  # Display messages
  def append_display_message(scope, conversation_id, attrs)
  def append_text_message(scope, conversation_id, message_type, text)
  def load_display_messages(scope, conversation_id, opts \\ [])

  # Tool-call lifecycle
  def mark_tool_executing(scope, call_id)
  def complete_tool_call(scope, call_id, metadata)
  def fail_tool_call(scope, call_id, error_info)
  def interrupt_tool_call(scope, call_id, info)
  def cancel_tool_call(scope, call_id)
  def record_hitl_decision(scope, call_id, decision)
  def resolve_interrupted_tool_result(scope, tool_call_id, content)
end
```

## Usage Patterns

### Creating a Conversation

```elixir
# scope is whatever your Scope module builds, typically from the caller's session
scope = socket.assigns.current_scope

{:ok, conversation} = MyApp.Conversations.create_conversation(scope, %{title: "New Chat"})
```

### Starting an Agent with Persistence

The generated `Coordinator` module handles this end-to-end. You do not implement persistence wiring yourself — the Coordinator starts an `AgentSupervisor` with `:agent_persistence` and `:display_message_persistence` set to your generated behaviour implementations, and sagents threads scope through them.

```elixir
# In a LiveView handle_event
filesystem_scope = {:user, socket.assigns.current_scope.user.id}

{:ok, session} =
  MyApp.Agents.Coordinator.start_conversation_session(
    conversation_id,
    scope: socket.assigns.current_scope,
    filesystem_scope: filesystem_scope
  )

# session = %{agent_id: "conversation-123", pid: pid, conversation_id: ...}
```

Internally the Coordinator:
1. Calls `AgentPersistence.load_state(scope, %{agent_id: ..., conversation_id: ...})` to restore saved state (or starts fresh on `{:error, :not_found}`).
2. Creates the Agent via the Factory with `scope:` set on `agent.scope`.
3. Starts the `AgentSupervisor` with `:agent_persistence` and `:display_message_persistence` configured.

From that point, AgentServer invokes the callbacks automatically at the right lifecycle points — no callback-function wiring required at the call site.

### How Persistence Callbacks Fire

`AgentServer` holds the `:agent_persistence` and `:display_message_persistence` module references in its state. At each lifecycle point it calls the behaviour:

| Trigger | Callback |
|---------|----------|
| Agent state should be snapshotted (idle, shutdown, post-interrupt) | `AgentPersistence.persist_state(scope, state_data, context)` |
| New message produced (user, assistant, tool) | `DisplayMessagePersistence.save_message(scope, message, context)` |
| Tool execution starts / completes / fails / interrupts / cancels | `DisplayMessagePersistence.update_tool_status(scope, status, tool_info, context)` |
| Sub-agent resumes and produces the final tool result | `DisplayMessagePersistence.resolve_tool_result(scope, tool_call_id, content, context)` |

In every callback, `scope` is the first positional argument — sourced from `server_state.agent.scope`. The `context` map carries `:agent_id`, `:conversation_id`, and (for `persist_state`) `:lifecycle`.

See the moduledocs of `Sagents.AgentPersistence` and `Sagents.DisplayMessagePersistence` for the full behaviour contract.

### Manual Save

```elixir
# Grab current serialized state (map; safe to store as JSONB)
state_data = AgentServer.export_state(agent_id)

# Persist through your context, with the correct scope
MyApp.Conversations.save_agent_state(scope, conversation_id, state_data)
```

### Loading Conversations for UI

```elixir
# List user's conversations
conversations =
  MyApp.Conversations.list_conversations(scope, limit: 20, offset: 0)

# Load a single conversation + messages
conversation = MyApp.Conversations.get_conversation!(scope, id)
display_messages = MyApp.Conversations.load_display_messages(scope, id)

# Load just the todos (no need to start the agent)
todos = MyApp.Conversations.load_todos(scope, id)
```

If you try to load a conversation the scope doesn't own, `get_conversation/2` returns `{:error, :not_found}`, `get_conversation!/2` raises `Ecto.NoResultsError`, and `load_display_messages/3` returns `[]`.

## Display Messages

Display messages are a UI-friendly representation of the conversation.

### Why Separate from State?

1. **Performance**: Don't deserialize full state just to show the message list.
2. **Flexibility**: Multi-content-type rendering (thinking + text + image + tool_call as separate rows) that doesn't map cleanly to the LLM message shape.
3. **History**: Keep display messages even if the agent's internal state is summarized.

### Saving Display Messages

Saving is handled by the generated `DisplayMessagePersistence` module; AgentServer calls `save_message/3` on every new LangChain message. You don't wire this up — `mix sagents.setup` did.

If you need to append a message manually (e.g., a system notification from a LiveView event):

```elixir
# Via the convenience helper for text
MyApp.Conversations.append_text_message(
  scope,
  conversation_id,
  :assistant,
  "Task complete."
)

# Or with a full attrs map for other content types
MyApp.Conversations.append_display_message(scope, conversation_id, %{
  message_type: "assistant",
  content_type: "text",
  content: %{"text" => "Hi there!"},
  metadata: %{"token_usage" => %{input: 12, output: 34}}
})
```

### Loading for UI

```elixir
def handle_params(%{"conversation_id" => id}, _uri, socket) do
  scope = socket.assigns.current_scope
  conversation = MyApp.Conversations.get_conversation!(scope, id)
  messages = MyApp.Conversations.load_display_messages(scope, id)

  {:noreply,
   socket
   |> assign(:conversation, conversation)
   |> stream(:messages, messages, reset: true)}
end
```

## Serialization

### State Serialization

```elixir
# State.to_serialized/1 produces a plain map (safe for JSONB)
%{
  "messages" => [
    %{"role" => "user", "content" => "Hello", "metadata" => %{}},
    %{"role" => "assistant", "content" => "Hi there!", "tool_calls" => [], "metadata" => %{}}
  ],
  "todos" => [
    %{"id" => "todo-1", "content" => "Task description", "status" => "completed"}
  ],
  "metadata" => %{
    "conversation_title" => "Greeting",
    "custom_data" => %{...}
  }
}
```

### State Deserialization

```elixir
{:ok, state} = State.from_serialized(agent_id, serialized_data)
```

The `agent_id` is required because it's not stored in the serialized data — it's the conversation's identity, supplied by the restoring caller.

### Custom Serialization

Middleware can define custom serialization via `state_schema/0`:

```elixir
defmodule MyMiddleware do
  @behaviour Sagents.Middleware

  @impl true
  def state_schema do
    [
      my_data: %{
        serialize: fn data -> Base.encode64(:erlang.term_to_binary(data)) end,
        deserialize: fn str -> :erlang.binary_to_term(Base.decode64!(str)) end
      }
    ]
  end
end
```

## Migration Patterns

### Adding New Middleware

When adding middleware to existing agents, the middleware itself should handle missing state gracefully rather than migrating stored agent state. This keeps migration logic colocated with the middleware and avoids touching persisted data:

```elixir
defmodule MyNewMiddleware do
  @behaviour Sagents.Middleware

  @impl true
  def init(config), do: {:ok, config}

  @impl true
  def before_model(state, _config) do
    # Initialize state if this middleware hasn't been used before
    state =
      case State.get_metadata(state, :my_feature) do
        nil -> State.put_metadata(state, :my_feature, default_value())
        _ -> state
      end

    {:ok, state}
  end

  defp default_value, do: %{initialized: true, data: []}
end
```

This approach is preferred because:
- Migration logic lives with the middleware, not the persistence layer.
- No database migrations needed when adding middleware.
- Each middleware is responsible for its own defaults.
- Existing conversations seamlessly gain new capabilities.

### Changing Middleware Configuration

Since middleware config is in code, just update the code:

```elixir
# Before
{FileSystem, [enabled_tools: ["ls", "read_file"]]}

# After - existing states work fine
{FileSystem, [enabled_tools: ["ls", "read_file", "write_file"]]}
```

### Removing Middleware

Orphaned metadata is harmless and can be left in place:

```elixir
# Before
middleware: [TodoList, OldMiddleware, FileSystem]

# After - OldMiddleware's metadata stays in state but is ignored
middleware: [TodoList, FileSystem]
```

The unused metadata has no effect on agent behavior and will naturally disappear as conversations expire or are deleted.

## Scope Pattern

Sagents uses the Phoenix `Scope` pattern. The integrator defines a scope struct; sagents treats it as opaque and passes it through as the first positional argument to every context function.

```elixir
defmodule MyApp.Accounts.Scope do
  alias MyApp.Accounts.User

  defstruct [:user, :org]

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user_in_org(user, org), do: %__MODULE__{user: user, org: org}
end
```

The generated context contains a `scope_query/2` helper that turns a scope into an Ecto `where` clause. The default assumes your Scope has a field matching `--owner-type` (e.g., `:user`) with a struct containing an `:id`:

```elixir
# Default generated implementation
defp scope_query(query, %Scope{} = scope) do
  owner_id = get_owner_id(scope)
  from q in query, where: q.user_id == ^owner_id
end

defp get_owner_id(%Scope{user: user}), do: user.id
```

Customize `scope_query/2` (and `scope_conversation_query/2` for queries already joined to Conversation) if your Scope has a different shape — for example, multi-tenant by organization:

```elixir
defp scope_query(query, %Scope{org: %{id: org_id}}) do
  from q in query,
    join: u in assoc(q, :user),
    where: u.organization_id == ^org_id
end
```

## Best Practices

### 1. Always Pass Scope

```elixir
# Good
Conversations.get_conversation(scope, id)
Conversations.load_display_messages(scope, id)

# Compiles but blows up at runtime — every generated function pattern-matches %Scope{}
Conversations.get_conversation(id)
```

### 2. Let the Generated Persistence Modules Do the Work

`mix sagents.setup` wires `AgentPersistence` and `DisplayMessagePersistence` into the Coordinator for you. Agents started through the Coordinator get automatic state snapshots (on idle, on shutdown, post-interrupt) and message/tool-call persistence. You should rarely need to call `save_agent_state/3` directly.

### 3. Handle Missing State Gracefully on Restore

The generated `AgentPersistence.load_state/2` already returns `{:error, :not_found}` for both "no row exists" and "row exists but belongs to a different scope." Callers should treat both the same way:

```elixir
case Conversations.load_agent_state(scope, id) do
  {:ok, state_data} ->
    {:ok, state} = State.from_serialized(agent_id, state_data["state"])
    state

  {:error, :not_found} ->
    # Fresh state — normal for new conversations or wrong-scope access
    State.new!(%{})
end
```

### 4. Clean Up Old Conversations

```elixir
# Periodic cleanup job
def cleanup_old_conversations do
  cutoff = DateTime.add(DateTime.utc_now(), -30, :day)

  MyApp.Conversations.Conversation
  |> where([c], c.updated_at < ^cutoff)
  |> Repo.delete_all()
end
```

`AgentState` and `DisplayMessage` rows cascade-delete via the foreign-key constraint on `conversation_id` (the migration sets `on_delete: :delete_all`).

### 5. Never Persist Scope

`agent.scope` is excluded from serialization on purpose. If you find yourself reaching for `State.put_metadata(state, :scope, scope)` to "remember" it across restores, stop — that would leak scope across sessions. Scope must come from the fresh caller on every agent start, via `Coordinator.start_conversation_session(id, scope: current_scope, ...)`.
