# Forking a Conversation

A fork is a new conversation seeded with a copy of another conversation's
message history. The parent keeps running. The fork gets its own `agent_id`, its
own stored row, its own process, and its own agent configuration.

That last point is what makes forking worth doing. Because configuration lives
in code and never in state, a fork inherits *history* without inheriting
*instructions*: it can be a narrower agent, with a different prompt, a smaller
tool set and a different middleware stack, that happens to remember everything
the parent knew.

The typical use is turning one broad conversation into several focused ones.
Each fork starts already informed, and none of them interleave in the parent's
transcript.

## The three functions

`Sagents.Fork` is pure: no LLM call, no process, no I/O.

| Function | Does |
|---|---|
| `Sagents.Fork.from_agent/2` | Reads a base from a running agent, refusing unless it is idle |
| `Sagents.Fork.prepare/2` | Turns a state or a stored payload into a clean base |
| `Sagents.Fork.to_stored/1` | Turns a base into the payload your persistence layer stores |

`from_agent/2` is `prepare/2` applied to a guarded export. The other two are
public because tests and hosts that already hold a state want them directly.

## The flow

Read one base, then fan out over it. Building N forks costs N list appends.

```elixir
alias Sagents.{Fork, Session, State}
alias LangChain.Message

# 1. One base, shared by every fork.
#
# `Session.start/3` is idempotent: it returns the running agent if there is
# one, and otherwise boots it from persisted state. Either way what comes back
# is idle, which is what `from_agent/2` requires.
{:ok, %{agent_id: parent_agent_id}} = Session.start(config, parent_conversation_id)
{:ok, base} = Fork.from_agent(parent_agent_id)

# 2. Fan out. No LLM call, no process started.
Enum.each(topics, fn topic ->
  {:ok, conversation} =
    MyApp.Conversations.create_conversation(scope, %{title: topic.title})

  {:ok, stored} =
    base
    |> State.add_messages([
      Message.new_user!(scope_prompt(topic)),
      Message.new_assistant!(topic.body)
    ])
    |> Fork.to_stored()

  {:ok, _agent_state} =
    MyApp.Conversations.save_agent_state(scope, conversation.id, stored)

  # The primed pair is invisible to the UI. Give the fork a visible opening
  # line by writing the display row yourself.
  {:ok, _} =
    MyApp.Conversations.append_text_message(scope, conversation.id, :assistant, topic.body)
end)
```

Nothing above starts an agent. **A fork is a stored row until someone opens it.**
When a user clicks into one, the ordinary path runs and the agent boots already
knowing everything the parent knew:

```elixir
{:ok, session} = Session.start(config, fork_conversation_id)
```

## Four things that surprise people

### `base` is reused, not consumed

It is an immutable `Sagents.State`, so `Sagents.State.add_messages/2` returns a
new state per topic and the forks cannot interfere with each other. This is why
`from_agent/2` is called once rather than once per fork: the server round trip is
the only expensive part, and the per-fork part is a list append.

### Write the state row directly, not through `Sagents.AgentPersistence`

That behaviour exists for a running agent to persist itself, and its
`persist_context` carries a `:lifecycle` drawn from a closed set — `:on_completion`,
`:on_cancel` and friends — with no member meaning "created by forking". There is
no agent here and no lifecycle event, so call your own context function. It
writes the same column, and the load path finds it on the next session start
without knowing how it got there.

### Primed messages are invisible until you make one visible

Display rows are written by a running `Sagents.AgentServer`. Nothing routes
through `Sagents.DisplayMessagePersistence` when no server is running, so
messages placed into stored state before boot go into model history only.

This is intended, and it is what you want for a priming *user* message, which is
plumbing the user should never see. It is usually **not** what you want for the
*assistant* message meant to open the new thread, which is why the example above
writes that display row explicitly. The asymmetry is deliberate and it is the
single most confusing part of forking.

### A fork renames itself unless you stop it

`Sagents.Middleware.ConversationTitle` gates on state metadata rather than on
your conversation row, and `prepare/2` blanks metadata. So a fork generates its
own title on its first run and overwrites whatever title you set when you created
the row.

If you are naming your forks, seed the gate per fork:

```elixir
base
|> State.put_metadata("conversation_title", topic.title)
|> State.put_metadata("conversation_title_triggered", true)
|> State.add_messages([...])
```

This is per-fork, so it belongs in the per-fork transform rather than in
`prepare/2`'s `:metadata` option, which runs once on the shared base. Leaving it
out is a legitimate choice: forks that should name themselves from their own
content simply do nothing.

## What a fork inherits

Messages, and by default nothing else.

| Carried | Note |
|---|---|
| Messages | In order, unchanged. The point of the exercise. |
| Todos | Only with `todos: :inherit`, or seeded with an explicit list. |
| Metadata | Only with `metadata: :inherit`, an explicit map, or `{:keep, keys}`. |

Everything else is dropped. That is not a conservative default, it is the
correct one: the metadata keys the library itself writes are all actively harmful
to inherit. A fork that keeps `"conversation_title"` and
`"conversation_title_triggered"` is permanently named after its parent, and a
fork that keeps the debug-log counter resumes a per-conversation count from the
parent's position. `:inherit` exists for the keys *your* application stores.

A pending interrupt is not inherited either. A parent paused mid-question does
not hand that question to its forks: `prepare/2` demotes every live interrupt
result unconditionally, so the fork boots idle rather than re-surfacing a
question the user has moved on from. Nothing is required of you, and preparing an
already-prepared base changes nothing.

## The source must be idle

`from_agent/2` refuses anything but `:idle`, returning
`{:error, {:agent_busy, status}}`.

Each message joins a server's rolling state as it is processed, not when the turn
finishes, so a snapshot taken mid-run can end on an assistant message whose
`tool_calls` have no matching results yet. Prime a user message onto that and the
fork's first provider call is malformed. The missing results cannot be
recovered — the turn that would produce them is still running — and inventing
them would fabricate an outcome the parent is about to produce for real. So this
is prevented rather than repaired.

The check lives inside the server because it cannot live anywhere else. Reading a
status and then exporting is two calls, and a message arriving between them starts
a run against the very snapshot about to be taken.
`Sagents.AgentServer.export_state_if_idle/1` does both in one round trip.

Every other status is refused for its own reason: `:interrupted` is a question
the parent still intends to answer, `:cancelled` and `:error` are turns that did
not finish, and `:paused` is an infrastructure hold whose task may still be live.
Being told which one it was, and deciding what to do, beats receiving a base whose
provenance you never saw.

### If no agent is running

`from_agent/2` returns `{:error, :not_running}` rather than exiting. Start the
session first — that loads the persisted state through the ordinary path and
yields an idle agent holding the freshest history that exists — then fork from
it.

This is also why there is no live-versus-stored decision to make. Persistence
writes at lifecycle points rather than continuously, so a stored payload can lag a
running conversation by several turns. There is one source, the live server, and
bringing it up is how you read the stored one.

### Do not fork from inside a tool

The state a tool receives is a build-time snapshot that does not contain the
assistant message carrying the tool's own call, and the agent is `:running` by
definition, so `from_agent/2` correctly refuses. Fork from a completion callback
instead.

## Already-malformed histories

`prepare/2` returns `{:error, {:unanswered_tool_calls, ids}}` when the history
contains a tool call with no matching result.

Being idle does not by itself guarantee a well-formed history. A run cancelled
mid-tool-call persists its rolling state including a fully-processed assistant
message whose results never arrived, and reloading that payload boots the agent
idle, because the boot check only looks for interrupts.

Such a conversation is already broken for the parent, which hits the same
provider rejection on its own next turn. Repairing it is not forking's job. But
reporting it here, rather than letting it become a provider error on the fork's
first message, costs one pass over the history and saves a baffling debugging
session.

## The filesystem does not fork

`Sagents.Middleware.FileSystem` resolves its scope at init: an explicit
`:filesystem_scope` if you give one, otherwise `{:agent, agent_id}`. The default
stack passes only the agent id. Files live in a `Sagents.FileSystemServer` keyed
by that scope, never in state.

**So a fork with a new `agent_id` gets an empty filesystem by default**, while
its inherited transcript discusses files by path. The agent calls a read tool on
a path from its own history and gets a not-found.

This is the most likely way a working fork looks broken, and no library function
can fix it, because the decision lives in your factory rather than in the state.
Forking deliberately does not touch the filesystem: it neither copies files into a
new scope nor sets one up.

There is one lever. Giving both agents the same `filesystem_scope` — say
`{:project, id}` — points them at one live process, so the fork reads what the
parent read. The consequence is that writes by any fork are visible to the parent
and to every sibling. That is right for a read-only corpus and wrong if forks
edit.

The choice also decides how many filesystem subscriptions a host showing several
forks needs. A fork on the default `{:agent, agent_id}` scope has its own
`Sagents.FileSystemServer`, so a page rendering file activity for three forks
holds three subscriptions in one mailbox and needs `tagged: true` (or its own
`tag:`) on each to tell `{:file_system, change_info}` messages apart. A shared
`:filesystem_scope` is one subscription and needs no tag.

## Subscribing to a fork

Opening a fork is the likeliest path in the system to a `:pending` subscription.
A fork is a stored row with no running process: nothing started an agent for it,
so `Sagents.Subscriber.subscribe_to_agent/3` records the subscription as
`:pending` and the next presence arrival revives it.

Tags survive that window. The tag is stored in the subscription entry rather
than only in the producer, so a subscription that goes out `:pending` and comes
back on a presence join returns carrying the tag it was created with, and the
panel that asked for `{:agent, {:fork, fork_id}, event}` keeps receiving that
shape rather than silently falling back to the bare envelope.

## Cache breakpoints

`cache_control: true` lives in `LangChain.Message.ContentPart` options and
round-trips through serialization, so it reaches every fork.

Because the base is copied rather than rewritten, every fork's prefix is
byte-identical by construction. Put the breakpoint on the tail of the base: it is
written once, by whichever fork runs first, and hit by all the rest.

## Relationships between forks are yours

The library returns state. It keeps no fork registry, tracks no parent/child
relationship, and offers no merge — those belong to your data model.

Siblings that need to know about each other are better served by a small digest
rendered from your own database each turn: smaller, current by construction, and
it does not re-create the interleaving problem forking exists to solve.
