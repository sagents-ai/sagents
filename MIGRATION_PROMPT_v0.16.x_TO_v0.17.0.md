# Migration Guide: v0.16.x → v0.17.0

v0.17.0 has two independent changes. Do both parts.

- **[Part 1: User requests](#part-1-user-requests).** New numbering of the work
  behind each human message, new events, and an optional ledger. Mostly
  template and database changes in your generated persistence layer.
- **[Part 2: Agent resilience and durable approvals](#part-2-agent-resilience-and-durable-approvals).**
  Presence can no longer crash agents, a restarted agent reads current state,
  and HITL approvals survive the agent process. No template or database
  changes, but new error values, a new persistence lifecycle, and a different
  shape for an interrupted HITL state that hand-written code and tests can
  depend on.

Neither part is caught by the compiler. Both are search-driven.

# Part 1: User requests

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

**Part 2 has three things that break at runtime rather than compile time,**
all covered in its steps:
[a `persist_state/3` that matches on `context.lifecycle`](#p23-handle-the-on_resume-lifecycle-in-persist_state3)
without a fallback makes every HITL approval fail,
[a `case` on lifecycle call results](#p22-handle-error-outcome_unknown-reason)
without a fallback raises `CaseClauseError` on the new error value, and
[a test that `expect`s `Sagents.Presence.update/4`](#p26-update-tests)
fails because the AgentServer no longer calls it.

**Most of Part 1 is opt-in. One step is not.** AgentServer now broadcasts two new
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


---

# Part 2: Agent resilience and durable approvals

## What changed and why

A production host saw agents crash-loop for days and lose the results of tool
calls users had approved under certain conditions. One incident chained several defects, and v0.17.0
fixes all of them:

- **Presence could crash an agent.** Every `Phoenix.Tracker` write and `list`
  is a `GenServer.call` with a 5 second timeout, and every agent's discovery
  entry lives on one tracker shard. When that shard backed up, an agent's own
  presence call timed out and the exit killed it, sometimes mid-resume after an
  approved tool had started. Agents now hand presence writes to
  `Sagents.PresenceWriter`, a per-node process started by `Sagents.Supervisor`,
  and never wait on the tracker. A failed write is logged and dropped.
- **A restarted agent went back in time.** `AgentSupervisor` loaded persisted
  state once and every AgentServer restart booted from that snapshot, then
  persisted it over newer turns. The AgentServer now loads in its own `init/1`
  on every start.
- **"Not running" was ambiguous.** A call to an agent that crashed while
  handling it returned `{:error, :agent_not_running}`, which
  `Sagents.Session.resume/4` read as "asleep", so it woke the agent and resumed
  again. Such calls now return `{:error, {:outcome_unknown, reason}}`.
- **HITL approvals did not survive the process.** A pending approval was not
  recorded in the conversation, so a restart came back `:idle`. Nothing was
  persisted while approved tools ran, so a restart lost both the approval and
  the result of a side effect that had happened. Pending approvals are now
  recorded as placeholder tool results, and a checkpoint is persisted before
  approved tools start.

| What | Where it reaches your code | Action needed? |
| --- | --- | --- |
| `{:error, {:outcome_unknown, reason}}` from lifecycle calls | Code that calls `AgentServer` / `Session` / your Coordinator, and your error copy | **Yes**: at least the user-facing message (P2.2) |
| New `:on_resume` persistence lifecycle | Your `AgentPersistence.persist_state/3` | **Yes, if it matches on `context.lifecycle`** |
| `load_state/2` on every AgentServer start | Your `AgentPersistence.load_state/2` | Check its error returns |
| Interrupted HITL state ends with a placeholder tool message | Code that reads `state.messages` or resumes HITL by hand | Check |
| Presence writes are asynchronous | Tests and presence mocks | **Yes, if tests stub or read agent presence** |
| `Phoenix.Presence` start order | Your `application.ex` | Check |
| `recovery:` option on `interrupt_on` | Your agent factory | No, opt-in |

Nothing here touches the database or the generated templates. A host on stock
generated code needs the error message from P2.2 and its test updates from
P2.6; for the rest, the searches should come back clean.

---

## Part 2 Steps

### P2.1 Check the start order of your `Phoenix.Presence`

`Sagents.PresenceWriter` stops after your agents and applies the presence
writes they make on the way down, which needs the tracker still running. Start
your Presence **before** `Sagents.Supervisor`, as
[docs/deployment.md](docs/deployment.md) already shows:

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyAppWeb.Presence,      # before Sagents.Supervisor
  Sagents.Supervisor,
  MyAppWeb.Endpoint
]
```

```
grep -rn "Presence\|Sagents.Supervisor" lib/*/application.ex
```

Getting it backwards is not a crash. Agents shutting down with the node leave
their discovery entries behind until the other nodes notice the node is gone,
which shows up as agents briefly listed on a node that has already stopped.

---

### P2.2 Handle `{:error, {:outcome_unknown, reason}}`

The lifecycle calls (`AgentServer.execute/1`, `cancel/1`,
`dismiss_interrupt/1`, `resume/2`, `add_message/3`, `reset/1`, and the
`Sagents.Session` functions built on them) return an error value whose meaning
is new:

| Value | Meaning | Safe to start the agent and repeat? |
| --- | --- | --- |
| `{:error, :agent_not_running}` | The request never reached a running agent | Yes |
| `{:error, {:outcome_unknown, reason}}` | The agent took the call and then failed: it crashed while handling it, the call timed out, or its node went away | **No.** It may have taken effect. After a `resume` that approved a tool, the tool may be running |
| `{:error, :registry_unavailable}` | This node cannot look agents up (draining) | Unchanged |

In v0.16 every one of those failures came back as `:agent_not_running`. Find
the code that acts on results:

```
grep -rn "agent_not_running" lib/ --include="*.ex"
grep -rn "AgentServer\.\(execute\|cancel\|dismiss_interrupt\|resume\|add_message\|reset\)(" lib/ --include="*.ex"
grep -rn "Session\.\(resume\|dismiss\)\|resume_agent_session\|dismiss_agent_session" lib/ --include="*.ex"
```

For each result:

1. **A `case` with no fallback clause** raises `CaseClauseError` on the new
   value. Add a clause.
2. **A clause that restarts the agent and retries on `:agent_not_running`**
   (a hand-written Coordinator does this) keeps working for that value. Do not
   extend it to `:outcome_unknown`. `Session.resume/4` already passes it
   through without waking or retrying.
3. **What to show the user.** Do not invite the user to try again. For a
   resume, a restarted agent broadcasts its true status (`:running`,
   `:interrupted`, or `:idle`) on boot, and your ordinary status handling
   updates the UI from that.

   The generated `flash_session_error/3` in your `AgentLiveHelpers` shows
   each action's `:user_message`, which for a HITL decision is "That decision
   could not be submitted. Please try again." That is wrong for this case.
   Add a clause ahead of its catch-all:

   ```elixir
   @outcome_unknown_message "We could not confirm that went through. It may still be in progress."

   def flash_session_error(socket, reason, copy) do
     label = Keyword.fetch!(copy, :log_label)

     case reason do
       :registry_unavailable ->
         Logger.warning("#{label}: this node is draining, its Sagents registry is unavailable")
         put_flash(socket, :error, @draining_message)

       # The agent took the request and then failed. It may be in effect, so
       # never suggest repeating it. The agent's next status event settles the UI.
       {:outcome_unknown, _detail} = other ->
         Logger.error("#{label}: #{inspect(other)}")
         put_flash(socket, :error, @outcome_unknown_message)

       other ->
         Logger.error("#{label}: #{inspect(other)}")
         put_flash(socket, :error, Keyword.fetch!(copy, :user_message))
     end
   end
   ```

The 5 second calls (`add_message/3`, `cancel/1`, `dismiss_interrupt/1`,
`reset/1`) also return `:outcome_unknown` on a timeout. `execute/1` and
`resume/2` wait indefinitely and return it only when the agent dies.

---

### P2.3 Handle the `:on_resume` lifecycle in `persist_state/3`

`persist_state/3` is now called with `context.lifecycle == :on_resume`
**synchronously, before approved tool calls start**, to record that they are
running. A `persist_state/3` that matches on the lifecycle without a fallback
raises on it, which crashes the agent inside every HITL approval: the tools
never run and the approval never goes through.

```
grep -rn "lifecycle" lib/ --include="*.ex"
```

The generated `AgentPersistence` only logs the lifecycle and needs nothing.
A hand-written one should:

- treat `:on_resume` as an ordinary save of the state it is given, and
- keep a fallback clause, since lifecycles can be added again.

Two properties now matter more than before, because a restarted agent reads
back what was last persisted (step P2.4):

- **Return `:ok` only once the write is durable.** A write that is queued and
  acknowledged early can be overtaken by the restart's read.
- **Keep it fast.** The `:on_resume` save delays the start of the approved
  tools by its duration.

---

### P2.4 Check `load_state/2`

The AgentServer now calls `load_state/2` in its own `init/1` on **every start**,
including a restart by its supervisor. Before, `AgentSupervisor` called it once,
when it started.

- **`{:error, :not_found}` means "start fresh"** with the `:initial_state`
  you passed. Any other `{:error, reason}`, or a raise, **fails the start**
  (`{:stop, {:load_failed, reason}}`), so that a fallback state is never
  persisted over a conversation that could not be read. Return `:not_found`
  only when that is what you mean.
- **It runs in the AgentServer process.** Tests that grant Ecto sandbox access
  to specific pids must cover it; shared mode needs nothing.
- **Keep it fast.** `start_agent_sync/1` can now return while the load is in
  progress. Calls made then wait until the load finishes, and one with a 5
  second timeout (`add_message/3`) returns `:outcome_unknown` if the load
  takes longer.

```
grep -rn "def load_state" lib/ --include="*.ex"
```

The generated `load_state/2` returns only `{:ok, state}` or
`{:error, :not_found}` and needs nothing.

A Coordinator that loads state itself and passes it as `:initial_state`
alongside `:agent_persistence` behaves as before: the persisted state wins,
and `:initial_state` is used only when nothing is persisted.

---

### P2.5 Check code that reads an interrupted HITL state

When `HumanInTheLoop` asks for approval, the conversation now ends with a
**tool message of placeholder results**, one per tool call of the assistant
message, each with `is_interrupt: true`, the content
`"Waiting for a human to review this tool call."`, and the approval's
`interrupt_data`. In v0.16 it ended with the assistant message and its
unanswered tool calls.

```
grep -rn "List.last(.*messages)\|tool_calls" lib/ --include="*.ex" | grep -v "deps/"
grep -rn "execute_tool_calls_with_decisions\|check_pre_tool_hitl" lib/ --include="*.ex"
```

- **Read pending calls from `interrupt_data.action_requests`,** not from the
  last message. Code that took `List.last(state.messages).tool_calls` now gets
  a tool message.
- **Resume through `Agent.resume/4`, `AgentServer.resume/2`, or
  `Session.resume/4`.** They replace the placeholders with the real results.
  Code that resumes at chain level with
  `LLMChain.execute_tool_calls_with_decisions/3` must drop the trailing
  placeholder message first, or every call ends up with two results.
- **Rendering from `state.messages`** (`get_state/1`, `export_state/1`) shows
  the placeholders. Skip tool results with `is_interrupt: true`. Display
  messages are unaffected: placeholders are never saved as display rows.
- **A custom execution mode** that calls `Sagents.Mode.Steps.check_pre_tool_hitl/2`
  gets the placeholders automatically.

The restored interrupt is identical to the one originally raised. Code that
compared a restored HITL interrupt to the live one, or relied on a
`:tool_call_id` key added at restore, sees the same map either way.

---

### P2.6 Update tests

```
grep -rn "Sagents.Presence\|presence_module" test/ --include="*.exs"
grep -rn "agent_not_running" test/ --include="*.exs"
grep -rn "lifecycle" test/ --include="*.exs"
```

- **Stubs or expectations on `Sagents.Presence.update/4`.** The AgentServer no
  longer calls `Sagents.Presence` for its own discovery entry, and its boot no
  longer logs `"Failed to update presence status"`, which is what log-strict
  suites stubbed it to silence. Remove the stubs. A Mimic `expect` now fails
  `verify_on_exit!`, because it is never called.
- **Presence mocks.** The writer calls your `presence_module` as
  `update(pid, topic, key, metadata_map)`, falls back to
  `track(pid, topic, key, metadata_map)` when `update` answers
  `{:error, :nopresence}`, and calls `untrack(pid, topic, key)` on an orderly
  stop. A mock whose `update/4` only accepts a function, or never answers
  `:nopresence`, means nothing gets tracked. The failures are logged as
  warnings, not raised.
- **Reading agent presence right after an agent call.** Writes are
  asynchronous now. Call `Sagents.PresenceWriter.flush/0` before reading; it
  returns once every pending write is applied. (Without `Sagents.Supervisor`
  running, writes are applied synchronously and need no flush.)
- **Tests that kill an agent mid-call** and assert `:agent_not_running` now get
  `{:error, {:outcome_unknown, :killed}}`.
- **Tests that assert the shape of an interrupted HITL state** (the last
  message is the assistant's) now see the placeholder tool message (P2.5).
- **Persistence test doubles** whose `load_state/2` returns an error other than
  `:not_found` now fail the agent's start (P2.4). Ones that assert on the exact
  list of lifecycles see `:on_resume` during HITL tests.

---

### P2.7 Choose a recovery policy for gated tools (optional)

An approved tool can be interrupted by the agent stopping after it started and
before its result was persisted. The next boot applies the tool's
`:recovery` policy, set per tool in `interrupt_on`:

- `:report_unknown` (default): the call gets an error result telling the model
  it was approved and started, but its outcome is unknown and should be
  checked before running it again. It is never re-run on its own.
- `:reexecute`: the boot re-runs the batch with the recorded decisions. Use
  only for tools that are safe to repeat, for example idempotent by
  `context.tool_call_id`, which every tool receives.

```elixir
interrupt_on: %{
  "set_thermostat" => %{allowed_decisions: [:approve, :reject], recovery: :reexecute},
  "send_payment" => true
}
```

A batch is re-run only when every started call in it is `:reexecute`. A call
that needed no approval but was in the same batch counts as `:report_unknown`.
An unknown policy makes `Agent.new/2` return an error (`Agent.new!/2` raises).

---

### P2.8 Bind a `:pending_resume` you pass yourself (optional)

`Session.resume/4` wakes a sleeping agent with the answer as `:pending_resume`,
and now also passes `:pending_resume_for`: the tool call ids of the interrupt
the user answered, read from the host state's `:interrupt_data` (generated
hosts keep it there). The woken agent applies the answer only if it is waiting
on exactly those calls, and otherwise discards it with a warning and stays
`:interrupted`, so a stale answer can never approve a different, later
question.

Code that passes `:pending_resume` itself, to `Session.start/3`,
`Session.ensure_running/3`, or `AgentSupervisor`, should pass the ids too:

```elixir
pending_resume: decisions,
pending_resume_for: Sagents.AgentUtils.interrupt_tool_call_ids(interrupt_data)
```

Without it the answer is applied to whatever interrupt is pending, as in
v0.16.

```
grep -rn "pending_resume" lib/ --include="*.ex"
```

---

### P2.9 Behavior changes that need no code

- **Presence failures are warnings now,** `"Presence ... failed and was
  dropped"`, never a crash. While presence is degraded, an idle agent whose
  viewer list cannot be read stays up until its inactivity timeout rather
  than stopping on an unknown count.
- **A crashed agent does not untrack itself.** The tracker removes the entry
  when it sees the process exit, so the `presence_diff` leave arrives a moment
  later than an explicit untrack would.
- **A restarted agent resumes the latest persisted conversation,** and a
  message queued when the previous process stopped (`pending_message`) is now
  restored on supervised restarts and Horde moves too, and drains as usual.
- **HITL approvals survive a restart.** `{:agent_shutdown, %{interrupt_restorable: true}}`
  is now accurate for them, so a host that keeps the prompt on screen across
  a nap (`AgentUtils.shutdown_session_changes/2`) keeps HITL prompts that
  work when answered.
- **Middleware callbacks fire for approved tool executions.** A middleware's
  `on_tool_execution_completed` (and the other tool callbacks) now sees the
  calls a human approved; in v0.16 it missed them. Remove any workaround that
  recorded approved results separately, or they are counted twice.
- **A run that finishes while the agent shuts down is persisted**
  (`:on_completion` or `:on_interrupt`), instead of being dropped.
- **Sending a message after a run that ended in `:error` or `:cancelled`**
  turns any leftover interrupt placeholders into "the user did not respond"
  results, as sending one while `:interrupted` always has.
- **Nothing is backfilled.** A conversation saved by v0.16 with an approval
  pending has no placeholders, and still boots `:idle` after the upgrade.

---

## Verifying Part 2

### Check P2-A: a clean boot

Start the app and open a conversation. The log has no
`"Failed to update presence status"` warning, which v0.16 logged on every agent
start.

### Check P2-B: an approval survives the agent process

With `agent_persistence` configured and a tool gated by `interrupt_on`, trigger
an approval in the UI, then in `iex -S mix`:

```elixir
agent_id = "conversation-#{conversation_id}"
{:ok, pid} = Sagents.AgentServer.fetch_pid(agent_id)
Process.exit(pid, :kill)

# The supervisor restarts it from persisted state.
Sagents.AgentServer.get_status(agent_id)
# => :interrupted
```

Approve in the UI. The tool runs once, and the conversation holds one result
for the call.

| What you see | Cause |
| --- | --- |
| `:idle` after the restart | No `agent_persistence`, or the approval was raised before the upgrade |
| Approving crashes the agent, the tool never runs | P2.3: `persist_state/3` raises on `:on_resume` |
| Agent fails to start: `{:load_failed, _}` | P2.4: `load_state/2` returned an error other than `:not_found` |

### Check P2-C: presence trouble does not reach the agent (dev only)

Suspend your Presence's tracker shard (never in production):

```elixir
:sys.suspend(:"Elixir.MyAppWeb.Presence_shard0")
# Send a message, approve a tool: the agent keeps working.
# Expect "Presence ... failed and was dropped" warnings after 5 seconds.
:sys.resume(:"Elixir.MyAppWeb.Presence_shard0")
```

### Check P2-D: read the inventory back

```
grep -rn "agent_not_running\|outcome_unknown" lib/ --include="*.ex"
grep -rn "lifecycle" lib/ --include="*.ex"
grep -rn "Sagents.Presence" test/ --include="*.exs"
```

The first lists every place that acts on a call failure, each with a decision
for `:outcome_unknown` (P2.2). The second shows no lifecycle match without a
fallback (P2.3). The third shows no remaining stub of `Sagents.Presence.update/4`
(P2.6).

For details, see
[docs/subscriptions_and_presence.md](docs/subscriptions_and_presence.md),
[docs/persistence.md](docs/persistence.md),
[docs/middleware.md](docs/middleware.md#interrupts-that-come-before-any-tool-runs),
the "Failed Calls" section of the `Sagents.AgentServer` moduledoc, and the
"Recovery" and "Durability" sections of the `Sagents.Middleware.HumanInTheLoop`
moduledoc.
