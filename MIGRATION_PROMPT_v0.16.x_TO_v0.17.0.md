# Migration Guide: v0.16.x → v0.17.0

## What changed and why

A conversation had no record of which work belonged to which human message.
One request can span several runs (a slash command whose tool queues a
follow-up run), many model turns, tool calls, sub-agents and summarization, and
it can pause for an `ask_user` answer or a HITL approval along the way. Without
a link between the request and that work, a UI cannot fold a finished request's
work behind its answer, and a host cannot bill per request. Token usage was
visible only per message, and sub-agent and summarization usage was not
recorded anywhere durable.

A **user request** is one human message and all the work done for it.
Requests are numbered per conversation, starting at 1, and every message
carries the number it was produced under:

- `Sagents.State.user_request_seq` holds the current number and is persisted
  with the agent state.
- Every message carries its number in `metadata[:user_request_seq]`.
- Only a new human message advances the number. Answering `ask_user`,
  approving or rejecting a tool call, and any other resume continue the same
  request. A message a tool queues continues the current request.
- When a request ends, `Sagents.AgentServer` reports it: to a new optional
  `Sagents.DisplayMessagePersistence.complete_user_request/3` callback, and to
  subscribers as `{:user_request_completed, report}`. The report carries the
  status (`:completed`, `:error`, `:cancelled`, `:superseded`), the final
  answer and its display rows, counts, and the summed token usage including
  sub-agents and summarization.

For a host on the generated persistence layer, that means two new display
message columns, a new ledger table with one row per finished request, three
new context functions, and an implementation of the new callback. The
generator writes all of it for a new install. **An existing install gets none
of it from a dependency bump,** because the generated files are your copies.
That is what this guide is for.

| What | Where it lands | Required? |
| --- | --- | --- |
| `user_request_seq`, `user_request_final` columns | `display_messages` table | Only if you want the numbers stored |
| `user_requests` ledger table | New table | Only if you want the ledger |
| New events on the main channel | Your `handle_info` clauses | **Yes, if you have no catch-all** |
| `complete_user_request/3` | Your `DisplayMessagePersistence` | No, optional callback |

## Read this before you start

**Most of this is opt-in. One step is not.** AgentServer now broadcasts two new
main-channel events, `{:user_request_started, %{seq: seq}}` and
`{:user_request_completed, report}`. A LiveView or GenServer that subscribes to
an agent and has **no catch-all `handle_info`** raises `FunctionClauseError` on
the first of them, which arrives as soon as a user sends a message. Do
[step 0](#0-handle-the-two-new-events) first.

**Order matters in the database steps.** Apply the migration before you deploy
the schema change:

- A `DisplayMessage` schema that declares `user_request_seq` before the column
  exists makes **every** display message insert fail. AgentServer logs the
  failure and carries on, so the agent keeps working while the transcript
  silently stops being saved.
- The reverse, a migrated database with an unchanged schema, is harmless but
  silent: `cast/3` drops the `"user_request_seq"` key the persistence module
  sends, and no row ever gets a number.

Steps 1 and 2 are a pair, in that order.

**Nothing is backfilled.** Rows written before the upgrade have no number, and
messages restored from older saved state restore with request number 0. An
existing conversation's next request is numbered 1. Its earlier rows carry no
number, so nothing collides, and a UI that groups by number treats them as
ungrouped rows, exactly as it rendered them before.

**The compiler will not help you.** The generated modules are your copies, and
`complete_user_request/3` is an optional callback, so nothing warns when it is
missing. This migration is search-driven. Work the steps in order and run the
searches.

---

## Prerequisites

1. Start from a clean, committed workspace.
2. Update the dependency to `~> 0.17.0` and run `mix deps.get`.
3. Run `mix compile`. It will be clean. That is expected, not evidence that
   there is nothing to do.
4. Find your generated persistence modules and your table prefix. The defaults
   are `MyApp.Conversations`, `MyApp.Conversations.DisplayMessage`,
   `MyApp.Agents.DisplayMessagePersistence`, and the `sagents_` prefix:

   ```
   grep -rln "@behaviour Sagents.DisplayMessagePersistence" lib/
   grep -rn "schema \".*display_messages\"" lib/
   ```

   The table name in the second result gives your prefix. Every table name in
   this guide uses `sagents_`; substitute yours.

---

## Migration Steps

### 0. Handle the two new events

Find every process that receives agent events and check for a catch-all:

```
grep -rn "handle_info({:agent" lib/ --include="*.ex"
grep -rn "def handle_info(_\|def handle_info(_msg\|def handle_info(msg, \|def handle_info(other" lib/ --include="*.ex"
```

A module in the first list that does not appear in the second crashes on the
new events. Add clauses for them, in the envelope that module already uses:

```elixir
# Untagged subscriptions: {:agent, event}
def handle_info({:agent, {:user_request_started, _info}}, socket), do: {:noreply, socket}
def handle_info({:agent, {:user_request_completed, _report}}, socket), do: {:noreply, socket}

# Tagged subscriptions (the generated AgentLiveHelpers): {:agent, agent_id, event}
def handle_info({:agent, _agent_id, {:user_request_started, _info}}, socket),
  do: {:noreply, socket}

def handle_info({:agent, _agent_id, {:user_request_completed, _report}}, socket),
  do: {:noreply, socket}
```

A module that has a catch-all needs nothing here; the events are swallowed as
any other unhandled event is. Step 6 shows what to do with them once the rest is
in place.

`{:user_request_completed, report}` is broadcast **before** the
`{:status_changed, :idle, nil}` that ends a run, so a handler that reloads the
transcript there renders the finished request in the same update that
re-enables the input.

---

### 1. Add the upgrade migration

The generated migration creates these columns and the table for a new install.
For an existing one, add a migration of your own:

```
mix ecto.gen.migration add_user_requests
```

```elixir
defmodule MyApp.Repo.Migrations.AddUserRequests do
  use Ecto.Migration

  def change do
    alter table(:sagents_display_messages) do
      # The user request the row belongs to, and whether it is that
      # request's final answer
      add :user_request_seq, :integer
      add :user_request_final, :boolean, default: false, null: false
    end

    # Grouping a transcript by user request
    create index(:sagents_display_messages, [:conversation_id, :user_request_seq])

    # One row per finished user request
    create table(:sagents_user_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:sagents_conversations, on_delete: :delete_all, type: :binary_id),
          null: false

      add :seq, :integer, null: false
      # "completed", "error", "cancelled", "superseded"
      add :status, :string, null: false
      add :completed_at, :utc_datetime_usec, null: false
      add :assistant_message_count, :integer, default: 0, null: false
      add :tool_calls, :map, default: %{}
      add :token_usage, :map, default: %{}
      # Set by the host, for billing by outcome. Never written by sagents.
      add :classification, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sagents_user_requests, [:conversation_id, :seq])
  end
end
```

The `user_request_seq` column is nullable on purpose: existing rows, and rows
saved before a conversation's first human message, have no number.

**On a large `display_messages` table,** adding the index inside the
migration's transaction locks writes for as long as the build takes. Move it to
a separate migration with `@disable_ddl_transaction true`,
`@disable_migration_lock true`, and `create index(..., concurrently: true)`.

Run `mix ecto.migrate` and deploy it before step 2 reaches production.

---

### 2. Add the fields to your `DisplayMessage` schema

```elixir
# Before
    field :status, :string, default: "completed"
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)

# After
    field :status, :string, default: "completed"
    field :metadata, :map, default: %{}
    # The user request (one human message and all the work done for it) this
    # row belongs to. nil for rows written before user requests were tracked.
    field :user_request_seq, :integer
    # True on the rows of the user request's final answer: the rows a UI keeps
    # visible when it collapses the rest of the user request's work.
    field :user_request_final, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
```

Then add both fields to **both** `cast` lists, in `create_changeset/2` and in
`changeset/2`:

```elixir
    |> cast(attrs, [
      :message_type,
      :content,
      :tool_call_id,
      :content_type,
      :sequence,
      :status,
      :metadata,
      :user_request_seq,
      :user_request_final
    ])
```

Missing one of the two lists is the silent case: inserts go through
`create_changeset/2`, so leaving it out there means no row is ever numbered.

---

### 3. Add the `UserRequest` schema

Create `lib/my_app/conversations/user_request.ex`, next to your other schemas:

```elixir
defmodule MyApp.Conversations.UserRequest do
  @moduledoc """
  One row per finished user request: one human message and the work done for
  it. Written from `Sagents.DisplayMessagePersistence.complete_user_request/3`.

  The same user request can be reported more than once (a run continued without
  a new human message), so rows are upserted by conversation and `seq`.
  `classification` is never written by sagents; set it to bill by outcome.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias MyApp.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(completed error cancelled superseded)

  schema "sagents_user_requests" do
    belongs_to :conversation, Conversation

    field :seq, :integer
    # "completed", "error", "cancelled", or "superseded"
    field :status, :string
    field :completed_at, :utc_datetime_usec
    field :assistant_message_count, :integer, default: 0
    # %{"tool_name" => count}
    field :tool_calls, :map, default: %{}
    # %{"input" => integer, "output" => integer}
    field :token_usage, :map, default: %{}
    # Set by the host, for billing by outcome. Not written by sagents.
    field :classification, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(%UserRequest{} = user_request, attrs) do
    user_request
    |> cast(attrs, [
      :seq,
      :status,
      :completed_at,
      :assistant_message_count,
      :tool_calls,
      :token_usage,
      :classification
    ])
    |> validate_required([:conversation_id, :seq, :status, :completed_at])
    |> validate_number(:seq, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:conversation_id, :seq])
    |> foreign_key_constraint(:conversation_id)
  end
end
```

`conversation_id` is set on the struct by the context, never cast from attrs.

---

### 4. Add the context functions

In your conversations context, add the alias next to the other schema aliases:

```elixir
  alias MyApp.Conversations.UserRequest
```

Then add the three functions. They use the context's existing
`authorize_conversation/2`, so they enforce the same scope as everything else
in it:

```elixir
  @doc """
  Records a finished user request and marks its final answer's display rows.

  Upserts by conversation and `seq`, because a user request can be reported
  more than once. `final_row_ids` replaces any rows marked final for this
  user request before. A `classification` the host set on the row survives a
  repeated report.
  """
  def complete_user_request(%Scope{} = scope, conversation_id, attrs, final_row_ids) do
    with :ok <- authorize_conversation(scope, conversation_id) do
      seq = Map.fetch!(attrs, :seq)

      Repo.transaction(fn ->
        changeset =
          %UserRequest{conversation_id: conversation_id}
          |> UserRequest.changeset(attrs)

        case Repo.insert(changeset,
               on_conflict:
                 {:replace_all_except, [:id, :conversation_id, :seq, :classification, :inserted_at]},
               conflict_target: [:conversation_id, :seq],
               returning: true
             ) do
          {:ok, user_request} ->
            mark_final_rows(conversation_id, seq, final_row_ids)
            user_request

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  defp mark_final_rows(conversation_id, seq, final_row_ids) do
    DisplayMessage
    |> where([m], m.conversation_id == ^conversation_id and m.user_request_seq == ^seq)
    |> Repo.update_all(set: [user_request_final: false])

    if final_row_ids != [] do
      DisplayMessage
      |> where([m], m.conversation_id == ^conversation_id and m.id in ^final_row_ids)
      |> Repo.update_all(set: [user_request_final: true])
    end

    :ok
  end

  @doc """
  Returns the IDs of a user request's trailing assistant text rows: the rows
  after its last row of any other kind. Used when the final answer's rows were
  not reported. A final answer has no tool calls, so its rows come last.

  A trailing row of another kind (a todo snapshot, a notification) ends the
  scan and yields no rows, which leaves the user request's work uncollapsed
  rather than collapsing the wrong rows.
  """
  def trailing_answer_row_ids(%Scope{} = scope, conversation_id, seq) do
    case authorize_conversation(scope, conversation_id) do
      :ok ->
        DisplayMessage
        |> where([m], m.conversation_id == ^conversation_id and m.user_request_seq == ^seq)
        |> order_by([m], desc: m.inserted_at, desc: m.sequence)
        |> Repo.all()
        |> Enum.take_while(&(&1.message_type == "assistant" and &1.content_type in ~w(text thinking)))
        |> Enum.filter(&(&1.content_type == "text"))
        |> Enum.map(& &1.id)

      {:error, :not_found} ->
        []
    end
  end

  @doc """
  Lists the recorded user requests of a conversation, keyed by `seq`.
  """
  def user_requests_by_seq(%Scope{} = scope, conversation_id) do
    case authorize_conversation(scope, conversation_id) do
      :ok ->
        UserRequest
        |> where([r], r.conversation_id == ^conversation_id)
        |> Repo.all()
        |> Map.new(&{&1.seq, &1})

      {:error, :not_found} ->
        %{}
    end
  end
```

`classification` is excluded from the upsert's replacement so a value your
billing code wrote survives the same request being reported again.

---

### 5. Update your `DisplayMessagePersistence` module

Three changes. The first two store the number on every row; the third records
finished requests.

**a. Store the number in `save_message/3`.** The `context` argument now carries
`:user_request_seq`. Add it to the attrs built for each display item:

```elixir
# Before
        attrs = %{
          "message_type" => Atom.to_string(item.message_type),
          "content_type" => Atom.to_string(item.type),
          "content" => item.content,
          "sequence" => index
        }

# After
        attrs = %{
          "message_type" => Atom.to_string(item.message_type),
          "content_type" => Atom.to_string(item.type),
          "content" => item.content,
          "sequence" => index,
          "user_request_seq" => user_request_seq(context)
        }
```

If your `save_message/3` ignores its context (`_context`), rename the argument.

**b. Store it in `save_synthetic_message/3`.** Synthetic rows (an `ask_user`
answer, a cancel notice, a todo snapshot) belong to a request too:

```elixir
# Before
  def save_synthetic_message(scope, attrs, %{conversation_id: conversation_id}) do
    MyApp.Conversations.append_display_message(scope, conversation_id, attrs)
  end

# After
  def save_synthetic_message(scope, attrs, %{conversation_id: conversation_id} = context) do
    attrs = put_user_request_seq(attrs, user_request_seq(context))
    MyApp.Conversations.append_display_message(scope, conversation_id, attrs)
  end
```

Synthetic attrs arrive with atom keys from the framework and may arrive with
string keys from your own middleware. A changeset rejects a map that mixes the
two, which is why the helper below matches the key style it is given rather than
always adding an atom key.

**c. Implement `complete_user_request/3`, and add the helpers:**

```elixir
  @doc """
  Records a finished user request and marks the display rows of its final
  answer, so a UI can fold the rest of the user request's work away.

  Only the answer's text rows are marked; a thinking row stays with the work.
  When the answer's rows are not known (the server restarted during the
  user request), the user request's trailing assistant text rows are used.
  """
  @impl true
  def complete_user_request(_scope, _report, %{conversation_id: nil}), do: :ok

  def complete_user_request(scope, report, %{conversation_id: conversation_id}) do
    final_row_ids =
      case report.final_rows do
        rows when is_list(rows) ->
          rows
          |> Enum.filter(&(&1.content_type == "text"))
          |> Enum.map(& &1.id)

        nil ->
          MyApp.Conversations.trailing_answer_row_ids(scope, conversation_id, report.seq)
      end

    attrs = %{
      seq: report.seq,
      status: Atom.to_string(report.status),
      completed_at: report.completed_at,
      assistant_message_count: report.assistant_message_count,
      tool_calls: report.tool_calls,
      token_usage: usage_to_map(report.token_usage)
    }

    case MyApp.Conversations.complete_user_request(scope, conversation_id, attrs, final_row_ids) do
      {:ok, _user_request} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # 0 means the row arrived before any human message; it is stored as nil.
  defp user_request_seq(%{user_request_seq: seq}) when is_integer(seq) and seq > 0, do: seq
  defp user_request_seq(_context), do: nil

  # Synthetic attrs arrive with atom or string keys, and a changeset rejects a
  # map that mixes the two.
  defp put_user_request_seq(attrs, seq) do
    if Enum.any?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, "user_request_seq", seq)
    else
      Map.put(attrs, :user_request_seq, seq)
    end
  end

  defp usage_to_map(%LangChain.TokenUsage{input: input, output: output}),
    do: %{"input" => input, "output" => output}

  defp usage_to_map(_usage), do: %{}
```

`final_rows` are the rows your own `save_message/3` returned for the final
answer, so they are your `DisplayMessage` structs. They are `nil` when the
server restarted during the request, which is what the trailing-rows fallback
covers.

The same request can be reported more than once (a run continued after
`AgentServer.reset/1` or `restore_state/2`), which is why the context upserts.
Treat the last report as the current one.

**Skipping 5c is supported.** The callback is optional: without it, rows still
carry their numbers (5a and 5b), subscribers still receive
`{:user_request_completed, report}`, and no ledger row is written.

---

### 6. Use it in your UI (optional)

With the steps above in place, the transcript can be grouped by request. The
agents_demo does it with three pieces you can copy:

- **Grouping.** `AgentsDemoWeb.UserRequestGroups.build/2` takes the rows from
  `load_display_messages/2` and the map from `user_requests_by_seq/2`. A row's
  number alone decides its group, and **rows keep their display order.** Each
  group is three consecutive runs: the opening user rows, the work, and the
  final answer onward. Do not sort user rows to the top of a group: an
  `ask_user` answer is a user row in the middle of the work, and moving it puts
  the answer ahead of the question.
- **Stream groups, not rows.** A row lives inside its group, so
  `{:display_message_saved, _}` and `{:display_message_updated, _}` reload the
  groups rather than inserting the row.
- **Reload on completion.** Replace the no-op `{:user_request_completed, _}`
  clause from step 0 with a reload. Because it arrives before `:idle`, the
  finished request folds in the same render that re-enables the input.

A group whose request has a ledger row is complete, and its work can be folded
behind a "Worked for ..." summary. A group without one is still running, or was
recorded before this upgrade, and should render everything.

---

### 7. Check hand-written code that the change reaches

None of these fail to compile. Search for each.

**Code that builds a `%State{}` field by field.**

```
grep -rn "%Sagents.State{\|%State{" lib/ --include="*.ex"
```

`State.merge_states/2`, `State.reset/1`, and forks carry `user_request_seq`
across. Your own code that constructs a fresh state from selected fields of an
old one, rather than updating it, drops the number back to 0. The next human
message is then numbered 1 again in a conversation whose rows and ledger
already hold 1, and the ledger upsert overwrites that earlier request's record.
Copy the field across, or update the existing struct instead of building a new
one.

**Tools that run an agent of their own.** A tool that calls `Agent.execute/3`
for nested work should pass the request number it was called under, so that
work is attributed to the request that caused it:

```elixir
Agent.execute(agent, state, user_request_seq: context.user_request_seq)
```

Sub-agents started through `Sagents.Middleware.SubAgent` already do this.

**Tests that assert on the callback context map.** The context passed to
`DisplayMessagePersistence` callbacks gains `:user_request_seq`. A test double
asserting the whole map with `==` fails; one matching on the keys it needs does
not.

```
grep -rn "conversation_id: .*agent_id: \|agent_id: .*conversation_id: " test/ --include="*.exs"
```

**Code that reads message metadata from restored history.** The serializer now
round-trips four more keys: `:user_request_seq`, `:usage`, `:subagent_usage`,
and `:summary`. Code that expected restored messages to carry only
`:streaming_error` and `:stop_details`, or none, sees them. Saved state grows
by a few small fields per assistant message.

---

### 8. Behavior changes that need no code

**Summarization messages are flagged.** The two messages that replace older
history carry `metadata[:summary] == true`, and the assistant one carries the
summarizer's usage. Code that identified them by content can match on the flag
instead.

**Sub-agents report usage per message.** The `subagent_completed` debug event's
`token_usage` is the sub-agent's total across its run, not its last message's.
The parent records the usage on its `task` tool message as
`metadata[:subagent_usage]`.

**A run that errors or crashes stops its sub-agents,** the way a cancel does.
Before, a `task` tool that outlasted LangChain's `async_tool_timeout` left its
sub-agent running and calling the model after the parent's run had ended.

**`AgentServer.reset/1` keeps the request number.** Numbering is per
conversation, and your stored rows and ledger keep the earlier numbers after a
reset.

---

## Verifying the migration

The compiler confirms none of this, and a green suite does not prove rows are
numbered. Check the data.

### Check 1: a request is recorded end to end

With the migration applied, send one message that uses a tool, wait for the
answer, then in `iex -S mix`:

```elixir
scope = # your scope for that user
conversation_id = # the conversation

MyApp.Conversations.load_display_messages(scope, conversation_id)
|> Enum.map(&{&1.message_type, &1.content_type, &1.user_request_seq, &1.user_request_final})

MyApp.Conversations.user_requests_by_seq(scope, conversation_id)
```

Expect:

- every row from that exchange carries the same `user_request_seq`,
- exactly the answer's text row has `user_request_final: true`,
- one ledger entry with `status: "completed"`, the tool in `tool_calls`, and a
  non-empty `token_usage`.

| What you see | Cause |
| --- | --- |
| `user_request_seq` is `nil` on new rows | Step 2's `create_changeset/2` cast list, or step 5a |
| No ledger entry | Step 5c missing, or `complete_user_request/3` logged an error |
| Display rows stopped being saved | Schema deployed before the migration (step 1) |
| Process crashed on sending a message | Step 0 |

### Check 2: an answer stays with its request

If your app uses `ask_user` or HITL, send a message that triggers one, answer
it, and repeat Check 1. The answer row and everything after it carry the **same**
number as the message that started the request, and the ledger has one entry for
it, not two.

### Check 3: read the inventory back

```
grep -rn "user_request_seq" lib/ --include="*.ex"
grep -rn "complete_user_request" lib/ --include="*.ex"
grep -rn "user_request_started\|user_request_completed" lib/ --include="*.ex"
```

The first finds the schema, both cast lists, and both persistence functions.
The second finds the callback and the context function. The third finds a
clause for each event in every process from step 0 that has no catch-all.

---

## Recommended approach for generated files

Steps 2 through 5 are template changes. Steps 0, 6, and 7 are host code, which
no template covers.

**If your generated modules are close to stock,** start from a clean workspace,
re-run `mix sagents.setup` with the same options used originally, accept the
overwrites, and diff your customizations back in. The v0.17.0 templates
contain steps 2 through 5. **Then delete the migration
the generator just wrote.** It creates every persistence table from scratch and
fails against an existing database. Step 1's upgrade migration is the one you
want.

**If they have drifted,** apply the steps by hand.

**Either way, the templates are the authority.** They ship inside the package,
so the exact upstream delta is two commands away:

```
# Use the version you are upgrading from.
mix hex.package fetch sagents 0.16.2 --unpack --output /tmp/sagents-old
diff -u /tmp/sagents-old/priv/templates/display_message_persistence.ex.eex \
        deps/sagents/priv/templates/display_message_persistence.ex.eex
```

Repeat for `sagents.gen.persistence/context.ex.eex` and
`sagents.gen.persistence/display_message.ex.eex`.
`sagents.gen.persistence/user_request.ex.eex` is new, and
`sagents.gen.persistence/migration.exs.eex` shows the target schema that step 1
reaches by upgrade.

**Either way, do step 0 and Check 1.** The event clauses are the one place
this upgrade can take a running app down, and the data check is the only
evidence the rest is wired.

For details on the design, see
[docs/persistence.md](docs/persistence.md),
[docs/subscriptions_and_presence.md](docs/subscriptions_and_presence.md), and
the `Sagents.UserRequest` moduledoc.
