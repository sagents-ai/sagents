# Migration Guide: v0.20.x → v0.21.0

v0.21.0 changes the generated persistence code so that conversations list by
their latest message. The library itself does not change behavior: an existing
app keeps working after the dependency bump, exactly as before. Everything in
this guide is about **adopting** the change in code your app already owns.

- **[A `last_message_at` column](#1-add-the-column-and-fill-it-in).** A new
  column on your conversations table, filled in for existing rows. This is the
  one step that needs a decision from you: whether the fill-in goes in the
  schema migration or runs separately.
- **[Three small code changes](#2-add-the-field-to-your-conversation-schema)**
  in your generated schema and context: set the field on create, move it when
  a message is added, sort by it.
- **[A search of your own code](#5-check-your-own-code-for-updated_at-meaning-last-active)**
  for places that use `updated_at` to mean "last active".

Nothing here is caught by the compiler. Skipping this guide leaves your app as
it is, with the old ordering.

## What changed and why

The generated `list_conversations/2` ordered conversations by `updated_at`,
meaning "most recently active first". It did not work. Display messages live
in their own table, and adding one never touches the conversation row, so
`updated_at` only moves when the row itself is edited: a generated title
(seconds after creation), a metadata write, a rename. In practice the list
came out in creation order, and a user who went back to an older conversation
and kept chatting never saw it rise to the top.

The v0.21.0 templates add a dedicated column:

- `last_message_at` on `<prefix>conversations`, `NOT NULL`. It holds the time
  of the conversation's latest display message, or its creation time when it
  has none.
- `create_changeset/2` sets it. It is never cast from attrs.
- `append_display_message/3` inserts the message and moves the conversation's
  `last_message_at` to the message's `inserted_at`, in one transaction. The
  update only moves the time forward.
- `list_conversations/2` orders by `last_message_at`, then `id`.
- The owner index becomes `[owner_field, :last_message_at]`, and the generator
  no longer creates an index on `updated_at`.

`updated_at` keeps its ordinary meaning, "the row last changed". Renaming a
conversation, or a host feature such as favoriting or archiving, does not move
it in the list.

Why not reuse `updated_at`, or compute the latest message while listing? The
first would make every rename or favorite jump the conversation to the top. The
second makes every listing aggregate over all of an owner's messages before it
can sort and paginate. One small extra write per message costs less.

| What | Where it lands | Required? |
| --- | --- | --- |
| `last_message_at` column, filled in, `NOT NULL`, indexed | A new migration (or two, see step 1) | To adopt the change |
| The field and its `put_change` | Your `Conversation` schema | To adopt the change |
| The transaction version of `append_display_message/3` | Your conversations context | To adopt the change |
| The new `order_by` | Your conversations context | To adopt the change |
| `updated_at` used to mean "last active" | Your own code | **Check** |
| The relative time shown in a conversation list | Your UI | Optional |

## Read this before you start

**The library does not need this.** No Sagents module reads `last_message_at`.
The change lives entirely in your generated copies, so you can adopt it in
this release or a later one.

**The column needs existing rows filled in.** A fresh install creates it on an
empty table. Your table already has rows, and each needs a value before the
column can be `NOT NULL`. Step 1 gives two ways to do that; pick the one your
project's conventions allow.

**Order matters if you split the work.** PostgreSQL sorts NULLs **first** in a
`DESC` order. If `list_conversations/2` sorts by `last_message_at` while some
rows are still NULL, every unfilled conversation jumps to the top. Change the
sort (step 4) only after the fill-in has finished, or use the interim sort
given there.

**The new code tolerates unfilled rows.** The update in step 3 uses
`GREATEST`, which ignores NULLs in PostgreSQL. A message added to a
conversation the fill-in has not reached yet sets the column correctly. You can
deploy the code before the fill-in runs.

**The compiler will not help you.** Work the steps in order and run the
searches.

---

## Prerequisites

1. Start from a clean, committed workspace.
2. Update the dependency to `~> 0.21.0` and run `mix deps.get`.
3. Run `mix compile`. It will be clean. That is expected; nothing has been
   adopted yet.
4. Find your generated persistence modules and your table names. The defaults
   are `MyApp.Conversations`, `MyApp.Conversations.Conversation`, a
   `sagents_` table prefix, and a `user_id` owner field:

   ```
   grep -rn "def append_display_message" lib/
   grep -rn "def list_conversations" lib/
   grep -rn "schema \"" lib/ | grep conversations
   grep -rln "create table(:.*conversations" priv/repo/migrations/
   ```

   The examples below use `sagents_conversations`, `sagents_display_messages`,
   and `user_id`. Substitute your own prefix and owner field everywhere.

---

## Migration Steps

### 1. Add the column and fill it in

Every existing row gets the `inserted_at` of its latest display message, or the
conversation's own `inserted_at` when it has none. With every row filled, the
column can be `NOT NULL` and the sort needs no `COALESCE`.

> **Decide this first:** does your project put data changes in schema
> migrations? Many teams do not. A data migration can run for a long time on a
> large table, cannot be re-run on its own, and couples the schema history to
> the data. If your project has that rule, use **Option B**. If it does not and
> your conversations table is small, **Option A** is one file.

Generate the migration either way:

```
mix ecto.gen.migration add_last_message_at_to_sagents_conversations
```

#### Option A: one migration that does everything

This is what the `agents_demo` project in the Sagents repository uses.

```elixir
defmodule MyApp.Repo.Migrations.AddLastMessageAtToSagentsConversations do
  use Ecto.Migration

  def up do
    alter table(:sagents_conversations) do
      add :last_message_at, :utc_datetime_usec
    end

    flush()

    execute("""
    UPDATE sagents_conversations AS c
    SET last_message_at = COALESCE(
      (SELECT max(m.inserted_at)
       FROM sagents_display_messages AS m
       WHERE m.conversation_id = c.id),
      c.inserted_at
    )
    """)

    alter table(:sagents_conversations) do
      modify :last_message_at, :utc_datetime_usec, null: false
    end

    # The composite index serves both the listing and owner-only lookups, so
    # the single-column owner index is redundant. Keep the `updated_at` index
    # if your own code queries by it (see step 5).
    drop index(:sagents_conversations, [:user_id])
    drop index(:sagents_conversations, [:updated_at])
    create index(:sagents_conversations, [:user_id, :last_message_at])
  end

  def down do
    drop index(:sagents_conversations, [:user_id, :last_message_at])
    create index(:sagents_conversations, [:updated_at])
    create index(:sagents_conversations, [:user_id])

    alter table(:sagents_conversations) do
      remove :last_message_at
    end
  end
end
```

`up`/`down` is needed because the fill-in is raw SQL. The `flush()` makes the
column exist before the `UPDATE` runs. The subquery uses the generated
`[:conversation_id, :inserted_at, :sequence]` index on display messages, so
each row's lookup is an index scan.

If your app has no owner field (generated with `--owner-type none`), drop and
create `[:last_message_at]` alone instead of the owner indexes.

The fill-in reflects the messages that exist when the migration runs. If the
old code keeps serving requests until the new code starts (a rolling deploy),
a message added in that window does not move its conversation; the next
message under the new code does.

Then do steps 2 through 4 in the same change.

#### Option B: schema migration, separate fill-in, then the constraint

Three parts, deployed in this order.

**B1. Schema migration: add the column, nullable, with its index.**

```elixir
defmodule MyApp.Repo.Migrations.AddLastMessageAtToSagentsConversations do
  use Ecto.Migration

  def change do
    alter table(:sagents_conversations) do
      add :last_message_at, :utc_datetime_usec
    end

    create index(:sagents_conversations, [:user_id, :last_message_at])
  end
end
```

On a large, busy table, build the index without blocking writes:
`create index(..., concurrently: true)`, with `@disable_ddl_transaction true`
and `@disable_migration_lock true` in the module. Follow your project's
existing convention for concurrent indexes if it has one.

Deploy B1 together with steps 2 and 3. From then on, new conversations and
every new message set the column. Hold step 4 (or use its interim sort).

**B2. Fill in the existing rows, outside the migrations.**

Run this however your project runs data changes: a release task, a one-off
`mix` task, an Oban job, or a SQL console. It works in batches and only touches
rows that are still NULL, so it is safe to stop and re-run:

```elixir
defmodule MyApp.Release.FillLastMessageAt do
  @moduledoc """
  Sets `last_message_at` on conversations that have none: the `inserted_at` of
  the latest display message, or the conversation's own `inserted_at`.
  Re-runnable; each pass handles rows that are still NULL.
  """

  alias MyApp.Repo

  @batch_size 1_000

  def run do
    %{num_rows: count} =
      Repo.query!(
        """
        UPDATE sagents_conversations AS c
        SET last_message_at = COALESCE(
          (SELECT max(m.inserted_at)
           FROM sagents_display_messages AS m
           WHERE m.conversation_id = c.id),
          c.inserted_at
        )
        WHERE c.last_message_at IS NULL
          AND c.id IN (
            SELECT id FROM sagents_conversations
            WHERE last_message_at IS NULL
            LIMIT $1
          )
        """,
        [@batch_size]
      )

    if count > 0, do: run(), else: :ok
  end
end
```

A conversation that receives a message while this runs is already set by the
step 3 code and is skipped. That is what the outer
`c.last_message_at IS NULL` is for: when an `UPDATE` waits on a row another
transaction changed, PostgreSQL re-checks the conditions on that row before
writing it, but not the ones inside the `IN (...)` subquery. Without it, the
fill-in could overwrite a fresh value with an older one.

Confirm it finished before B3:

```sql
SELECT count(*) FROM sagents_conversations WHERE last_message_at IS NULL;
-- 0
```

**B3. Schema migration: the constraint and the index cleanup.**

```elixir
defmodule MyApp.Repo.Migrations.RequireLastMessageAtOnSagentsConversations do
  use Ecto.Migration

  def change do
    alter table(:sagents_conversations) do
      modify :last_message_at, :utc_datetime_usec,
        null: false,
        from: {:utc_datetime_usec, null: true}
    end

    drop index(:sagents_conversations, [:user_id])
    drop index(:sagents_conversations, [:updated_at])
  end
end
```

If B2 has not finished, this migration fails on the NULL rows rather than
corrupting anything. Run B2 again and retry.

On a very large table, `SET NOT NULL` scans the whole table under an exclusive
lock. If that is a concern, add a `CHECK (last_message_at IS NOT NULL) NOT
VALID` constraint, `VALIDATE` it in a later migration, and then set NOT NULL,
which PostgreSQL 12+ does without a scan once a valid check constraint exists.

Deploy step 4 (the final sort) with or after B3.

---

### 2. Add the field to your `Conversation` schema

```elixir
schema "sagents_conversations" do
  # ...
  field :metadata, :map, default: %{}

  # When the latest message was added; the "recent" sort. Kept apart from
  # `updated_at`, which messages never touch (they live in their own table)
  # and which renaming or other row edits move.
  field :last_message_at, :utc_datetime_usec

  timestamps(type: :utc_datetime_usec)
end
```

Set it in `create_changeset/2`, the same way the owner field is set:

```elixir
def create_changeset(owner_id, attrs) do
  %Conversation{}
  |> cast(attrs, [:title, :version, :metadata])
  |> put_change(:user_id, owner_id)
  |> put_change(:last_message_at, DateTime.utc_now())
  |> common_validations()
end
```

**Do not** add `:last_message_at` to either `cast` list. The system sets it;
callers of `update_conversation/2` must not be able to move it. A new, empty
conversation gets the creation time, so it appears at the top of the list,
which is what a user expects after starting a new chat.

If anything else in your app inserts conversation rows without
`create_changeset/2` (seeds, fixtures, `insert_all`), it must set the field
too, or the insert fails on `NOT NULL`:

```
grep -rn "Conversation{" lib/ priv/repo/ test/support/ --include="*.ex*"
grep -rn "insert_all(.*[Cc]onversation" lib/ priv/ test/
```

---

### 3. Move `last_message_at` when a message is added

Replace `append_display_message/3` in your conversations context and add the
private helper beside it:

```elixir
# Before
def append_display_message(%Scope{} = scope, conversation_id, attrs) do
  with :ok <- authorize_conversation(scope, conversation_id) do
    conversation_id
    |> DisplayMessage.create_changeset(attrs)
    |> Repo.insert()
  end
end

# After
def append_display_message(%Scope{} = scope, conversation_id, attrs) do
  with :ok <- authorize_conversation(scope, conversation_id) do
    Repo.transaction(fn ->
      with {:ok, message} <-
             conversation_id
             |> DisplayMessage.create_changeset(attrs)
             |> Repo.insert(),
           {1, _returned} <-
             touch_last_message_at(scope, conversation_id, message.inserted_at) do
        message
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {0, _returned} -> Repo.rollback(:not_found)
      end
    end)
  end
end

# Moves `last_message_at` forward to `at`, never back. Messages for one
# conversation can be written from more than one process, and their
# transactions can commit out of order.
#
# Filtered by scope as well as id even though the caller has authorized the
# conversation: a bulk update keyed only on an id is the one place a mistake
# could write across owners. `update_all` leaves `updated_at` alone, so "last
# message" and "row last changed" stay separate.
defp touch_last_message_at(%Scope{} = scope, conversation_id, at) do
  Conversation
  |> scope_query(scope)
  |> where([c], c.id == ^conversation_id)
  |> update([c],
    set: [
      last_message_at:
        fragment("GREATEST(?, ?)", c.last_message_at, type(^at, :utc_datetime_usec))
    ]
  )
  |> Repo.update_all([])
end
```

What to know about it:

- **The return values do not change:** `{:ok, message}`, `{:error, changeset}`,
  or `{:error, :not_found}`. The generated `DisplayMessagePersistence` module
  and `append_text_message/4` call it unchanged, so every message the framework
  saves (user, assistant, tool, and synthetic rows) moves the conversation.
- **It uses your own `scope_query/2`.** If you customized it (a project or
  organization filter, for example), the update inherits that filter. If your
  `scope_query/2` adds a `join`, Ecto turns the `update_all` into
  `UPDATE ... FROM`, which PostgreSQL supports; run the tests in step 6 to be
  sure.
- **A failed insert moves nothing.** The message and the timestamp commit
  together.
- **It uses the message's own `inserted_at`**, so the two times match exactly.

If your app inserts display messages anywhere else, bypassing
`append_display_message/3`, those inserts do not move the conversation. Find
them:

```
grep -rn "DisplayMessage.create_changeset\|insert_all(.*DisplayMessage" lib/
```

Route them through `append_display_message/3`, or call the same update after
them.

---

### 4. Sort by `last_message_at`

In `list_conversations/2`:

```elixir
# Before
|> order_by([c], desc: c.updated_at)

# After
|> order_by([c], desc: c.last_message_at, desc: c.inserted_at)
```

When two conversations have the same `last_message_at` (two new, empty ones
created in the same instant, or rows the fill-in gave the same time), the
newer conversation comes first. A random UUID primary key would order them
arbitrarily.

Update the function's `@doc` to say results are ordered by latest message.

**If you chose Option B** and this ships before the fill-in finishes, use an
interim sort so unfilled rows do not jump to the top, and switch to the line
above with step B3:

```elixir
|> order_by([c], desc_nulls_last: c.last_message_at, desc: c.updated_at)
```

Do the same for any other "recent" sort you added, for example a `:sort`
option with a `:recent` mode.

One consequence to know about: rows now move while a user browses. A
conversation that gets a message during `:offset` paging moves to the top, so
the next page can repeat or skip one row. That already happened whenever a
title was saved; it is not a reason to change your paging.

---

### 5. Check your own code for `updated_at` meaning "last active"

The generated code no longer uses `updated_at` for activity. Your code may:

```
grep -rn "updated_at" lib/ --include="*.ex*" | grep -iv "timestamps"
```

For each hit on a conversation, decide what it means:

- **"Last active"** (a "last message" label in a list, stale-conversation
  cleanup, "inactive for 30 days" filters, activity reports): use
  `last_message_at`. A cleanup job filtering on `updated_at < ^cutoff` deletes
  conversations that are still in use.
- **"Row last edited"** (audit, sync, cache invalidation): leave it.

If anything you keep queries `updated_at`, keep its index: skip the
`drop index(..., [:updated_at])` line in step 1.

**Optional, for a conversation list UI.** If your list shows a relative time
("5 minutes ago") from `updated_at`, show `last_message_at` instead. If your
LiveView keeps the list in a stream and the open conversation should rise to
the top as messages arrive, move it when a `{:display_message_saved, msg}`
event arrives, using `msg.inserted_at`. A stream insert of an item already in
the stream updates it in place, so delete it first:

```elixir
conversation = %{socket.assigns.conversation | last_message_at: msg.inserted_at}

socket
|> assign(:conversation, conversation)
|> stream_delete(:conversation_list, conversation)
|> stream_insert(:conversation_list, conversation, at: 0)
```

---

### 6. Add tests

Your generated context is your code, and only your test suite runs it against
your database. Cases worth having in your conversations context test:

- A new conversation has `last_message_at` set.
- A new message sets `last_message_at` to that message's `inserted_at`.
- Adding a message to the oldest of three conversations puts it first in
  `list_conversations/2`.
- Renaming a conversation does not change `last_message_at` or the order.
- `update_conversation/2` given a `last_message_at` ignores it.
- An invalid message returns `{:error, %Ecto.Changeset{}}` and leaves
  `last_message_at` unchanged.
- Another owner's scope gets `{:error, :not_found}`, stores no message, and
  moves nothing.
- With `last_message_at` set ahead of now, a new message does not move it back.

Set times directly in tests instead of sleeping between inserts:

```elixir
defp set_last_message_at(%Conversation{id: id}, offset_seconds) do
  at = DateTime.add(DateTime.utc_now(), offset_seconds, :second)

  {1, _returned} =
    Conversation
    |> where([c], c.id == ^id)
    |> Repo.update_all(set: [last_message_at: at])

  :ok
end
```

Existing tests that asserted the list order follows `updated_at`, or that a
rename moves a conversation to the top, now fail. That is the intended change;
update them.

---

## Verifying the migration

A green suite does not prove existing rows were filled correctly. Check the
data.

### Check 1: every row is filled, and filled correctly

```sql
-- Expect 0
SELECT count(*) FROM sagents_conversations WHERE last_message_at IS NULL;

-- Expect 0: rows whose value is behind their latest message
SELECT count(*)
FROM sagents_conversations AS c
WHERE c.last_message_at < (
  SELECT max(m.inserted_at)
  FROM sagents_display_messages AS m
  WHERE m.conversation_id = c.id
);
```

### Check 2: a message moves its conversation

Open an older conversation, send a message, wait for the answer, and reload
the conversation list. It is first. Then in `iex -S mix`:

```elixir
scope = # your scope for that user
MyApp.Conversations.list_conversations(scope, limit: 3)
|> Enum.map(&{&1.title, &1.last_message_at, &1.updated_at})
```

`last_message_at` on the first row matches the answer's time; `updated_at`
does not move.

| What you see | Cause |
| --- | --- |
| The conversation does not move | Step 3 not done, or a message path bypasses `append_display_message/3` |
| Old conversations all at the top | Step 4 deployed before the fill-in finished (Option B) |
| `null value in column "last_message_at"` on create | A conversation insert that skips `create_changeset/2` (step 2) |
| Renaming moves a conversation | A "recent" sort still on `updated_at` (steps 4 and 5) |

### Check 3: read the inventory back

```
grep -rn "last_message_at" lib/ priv/repo/migrations/
```

It finds the migration (or migrations), the schema field and `put_change`,
`touch_last_message_at/3`, the sort, and whatever you changed in step 5.

---

## Recommended approach for generated files

Steps 2 through 4 are template changes. Step 1's migration and steps 5 and 6
are yours; no template covers an existing database.

**If your generated modules are close to stock,** start from a clean
workspace, re-run `mix sagents.setup` with the same options used originally,
accept the overwrites, and diff your customizations back in. The v0.21.0
templates contain steps 2 through 4. **Then delete the migration the generator
just wrote.** It creates every persistence table from scratch and fails
against an existing database. Write the step 1 migration instead.

**If they have drifted,** apply the steps by hand. They are small.

**Either way, the templates are the authority.** They ship inside the package,
so the exact upstream delta is two commands away:

```
# Use the version you are upgrading from.
mix hex.package fetch sagents 0.20.1 --unpack --output /tmp/sagents-old
diff -u /tmp/sagents-old/priv/templates/sagents.gen.persistence/context.ex.eex \
        deps/sagents/priv/templates/sagents.gen.persistence/context.ex.eex
```

Repeat for `sagents.gen.persistence/conversation.ex.eex` and
`sagents.gen.persistence/migration.exs.eex`. The migration template shows the
column and indexes a fresh install gets, which is what your step 1 migration
should end with.

**Either way, do step 5 and Check 1.** The `updated_at` search finds behavior
in your own code that no template reaches, and the data check is the only
evidence the fill-in worked.
