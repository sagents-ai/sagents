# Migration Guide: v0.14.x → v0.15.0

## What changed and why

One process subscribed to two agents cannot tell their events apart.

Every main-channel event is `{:agent, event}`, and `Sagents.Publisher` fans out
with a direct `send/2`, so there is no sender, no topic, and no payload field to
recover identity from. Two agents streaming concurrently interleave, so there is
no ordering either, and `%LangChain.MessageDelta{}` carries no agent id. A
process holding two subscriptions receives a correct stream of events about
which it can decide nothing.

That matters more than a misrendered panel. A `:status_changed` is often a
workflow trigger, so an `:idle` from one agent satisfies a clause written for
another sharing the mailbox, and an action fires against an agent that did not
finish.

A subscription can now carry a **tag**, and every event delivered on it names
its source:

```elixir
# Unchanged. Still {:agent, event}.
Subscriber.subscribe_to_agent(subs, agent_id)

# Library-supplied identity: {:agent, agent_id, event}
Subscriber.subscribe_to_agent(subs, agent_id, tagged: true)

# Host-supplied routing key: {:agent, card_id, event}
Subscriber.subscribe_to_agent(subs, agent_id, tag: card_id)
```

| Channel | Untagged | Tagged |
| --- | --- | --- |
| `:main` | `{:agent, event}` | `{:agent, tag, event}` |
| `:debug` | `{:agent, {:debug, event}}` | `{:agent, tag, {:debug, event}}` |
| filesystem | `{:file_system, change_info}` | `{:file_system, tag, change_info}` |

The tag lives in the **subscription**, not in the agent. Two hosts watching the
same agent can address it differently, and one of them can stay untagged. That
is not a detail: it is what lets you adopt this without coordinating with any
other consumer of the same agents.

`nil` is a legal tag. The option is read as "was `:tag` given", not "is the
value truthy".

The shape covers every delivery on a subscription: live broadcasts, the status
snapshot sent at subscribe time, events broadcast during the agent's boot when
the subscription was seeded through `:initial_subscribers`, and the
re-subscription that follows a producer crash. A subscription that starts
`:pending` because its agent is not running yet comes back carrying its tag.

Two consumer-side helpers also learned to report *which* subscription an event
concerns, on request. See step 5.

## Read this before you start

**The tagging work breaks nothing and is entirely opt-in.** A subscription that
asks for no tag receives byte-identical messages on every channel, so you can
upgrade the dependency, change no host code, and every event arrives exactly as
it did in v0.14.x.

**One change in this release is required, and it has nothing to do with
tagging.** `Agent.new/2` raises when one of its options is passed in the
attributes map, the deprecation v0.14.3 warned about. It raises at runtime, so
`mix compile` stays clean and the failure appears when an agent is built. Do
[the one required change](#the-one-required-change-agentnew2-options) first.
Everything under Migration Steps is optional after that.

> #### The failure mode you are working against {: .warning}
>
> `Phoenix.LiveView.Channel` calls `view.handle_info/2` whenever the view
> exports it at all.
>
> A host with **no** catch-all raises `FunctionClauseError` on the first event
> of an unexpected shape and crashes loudly, which you will notice in the first
> minute.
>
> A host **with** a catch-all silently swallows every event. The app stays up,
> the agents run, the state persists, the database fills with messages, and the
> UI never updates. Nothing appears in the logs. The more defensively written
> host is the one that gets the silent failure.
>
> Find out which you are before you change anything. This is step 0 and it is
> not optional.

**A partial migration is worse than none.** Every path that subscribes to a
given agent must agree on the tag. A publisher keeps one entry per
`{channel, pid}`, so whichever path subscribes last decides the envelope. A load
path that tags and an action path that does not gives a conversation whose event
shape changes the first time the user does something, which is the same silent
freeze arriving several clicks in rather than immediately.

In a generated app that means **two** files, not one: `AgentLiveHelpers`
(the load path) and your `Coordinator` (the action path, through
`Sagents.Session`). Steps 2 and 3 are a pair. Do not ship one without the other.

**The compiler will not help you.** The modules that change are the ones
`mix sagents.setup` generated into your app. They are your copies; a dependency
bump does not touch them. This migration is search-driven. Work the steps in
order and run the searches.

---

## Prerequisites

1. Start from a clean, committed workspace.
2. Update the dependency to `~> 0.15.0` and run `mix deps.get`. v0.15.0
   requires `langchain >= 0.14.1`. If your app pins `langchain` below that,
   resolution fails until you raise your own requirement.
3. Run `mix compile`. **It will be clean.** That is expected, not evidence that
   there is nothing to do, and not evidence that you are finished afterwards.
   The required change raises at runtime, so `mix test` is what surfaces it, and
   only where a test actually builds the agent whose options are misplaced.
4. Locate your generated modules. Default names are `AgentSubscriberSession`,
   `AgentLiveHelpers`, and `Coordinator`:

   ```
   grep -rln "Sagents.Session\|Sagents.Subscriber\|Sagents.AgentUtils" lib/ --include="*.ex"
   ```

---

## The one required change: Agent.new/2 options

`Agent.new/2` and `Agent.new!/2` raise `ArgumentError` when any of these six
options appears in the attributes map instead of the second argument:

```
:replace_default_middleware
:todo_opts
:filesystem_opts
:summarization_opts
:subagent_opts
:interrupt_on
```

v0.14.3 logged a warning here and announced the raise for this release.
`Ecto.Changeset.cast/3` drops keys it does not recognize, so an option placed
among the attributes was discarded and the agent was built with a configuration
other than the one asked for. `replace_default_middleware` left the full default
stack in place, and an `interrupt_on` config never reached `HumanInTheLoop`,
leaving tools ungated that were meant to require approval.

Find the call sites:

```
grep -rnE "replace_default_middleware|todo_opts|filesystem_opts|summarization_opts|subagent_opts|interrupt_on" lib test
```

Every hit is one of two things. Already in the second argument, which is correct
and needs nothing. Or inside the attributes map, which now raises:

```elixir
# Raises ArgumentError
Agent.new(%{model: model, replace_default_middleware: true, middleware: [MyMiddleware]})

# Correct
Agent.new(%{model: model, middleware: [MyMiddleware]}, replace_default_middleware: true)
```

A factory generated by `mix sagents.setup` has passed these in the second
argument since v0.10.0, so a stock factory needs no change and a drifted one
needs checking only where it was edited by hand. Hand-written agent construction
is where misplaced options live, and test support files are their usual second
home, which is why the search above covers `test` as well as `lib`.

**Fixing a call site changes behavior,** because the option takes effect once it
is read. With `replace_default_middleware` honored, the default middleware
(TodoList, FileSystem, SubAgent, Summarization, PatchToolCalls) is absent along
with its tools and system prompt text, so a test that counted on them may start
failing. That failure is the fix working, not a regression. With `interrupt_on`
honored, invalid values such as `:always` fail `HumanInTheLoop` initialization;
use `true`, `false`, or a config map.

The raise names every misplaced key it found, so one run reports the whole list
for that call site rather than one key at a time.

---

## Migration Steps

### 0. Find out whether your host fails loudly or silently

Run this first, once per LiveView or GenServer that receives agent events:

```
grep -rn "def handle_info(_\|def handle_info(_msg\|def handle_info(_message\|def handle_info(msg, \|def handle_info(other" lib/ --include="*.ex"
```

A hit is a catch-all. It means every mistake in steps 3 and 4 produces a UI that
stops updating, with a healthy application underneath and clean logs.

You do not have to delete it. A catch-all is often load-bearing for LiveView
internals and third-party broadcasts. What matters is that you now know a green
test run and a booting app prove nothing, and that you must run the verification
in the last section rather than trusting the absence of errors.

If it helps, narrow it for the duration of the migration so agent events fall
through to a crash instead:

```elixir
# Temporary, for the length of this migration.
def handle_info({:agent, _} = msg, _socket), do: raise("untagged agent event: #{inspect(msg)}")
def handle_info(_msg, socket), do: {:noreply, socket}
```

Then take the guard out once the verification passes.

---

### 1. Inventory every subscribing path and every receiving clause

```
grep -rn "subscribe_to_agent\|subscribe_to_filesystem\|AgentServer.subscribe" lib/ --include="*.ex"
grep -rn "Sagents.Session.ensure_running\|Sagents.Session.resume\|Sagents.Session.dismiss" lib/ --include="*.ex"
grep -rn "handle_info({:agent\|handle_info({:file_system" lib/ --include="*.ex"
```

The first two lists must end up agreeing with each other. The third is every
clause you will rewrite.

`Sagents.Session.ensure_running/3` subscribes. So do `resume/4` and `dismiss/3`,
which both route through it. That is easy to miss because none of them is named
"subscribe", and it is exactly the path that flips a tagged conversation back to
the bare envelope partway through.

---

### 2. Declare the tag policy once, on the `Coordinator`

One attribute, applied to every call that subscribes. Putting it in a single
place is the point: three call sites that each spell out `tagged: true` are three
places for them to drift.

```elixir
  @presence_module MyAppWeb.Presence

  # How this application addresses agent events. `tagged: true` delivers every
  # event as `{:agent, agent_id, event}` instead of `{:agent, event}`, so a
  # process that grows a second subscription can tell the two apart.
  #
  # Every path that subscribes must pass this. A publisher keeps one entry per
  # {channel, pid}, so whichever path subscribes last decides the envelope: a
  # load path that tags and an action path that does not produce a conversation
  # whose event shape changes the first time the user does something.
  @subscribe_opts [tagged: true]

  @config %{
    # ... unchanged ...
  }
```

Then thread it into all three:

```elixir
# Before
def ensure_agent_session_running(state, request_opts \\ []),
  do: Sagents.Session.ensure_running(@config, state, request_opts: request_opts)

def resume_agent_session(state, resume_data, request_opts \\ []),
  do: Sagents.Session.resume(@config, state, resume_data, request_opts: request_opts)

def dismiss_agent_session(state, request_opts \\ []),
  do: Sagents.Session.dismiss(@config, state, request_opts: request_opts)

# After
def ensure_agent_session_running(state, request_opts \\ []),
  do:
    Sagents.Session.ensure_running(
      @config,
      state,
      [request_opts: request_opts] ++ @subscribe_opts
    )

def resume_agent_session(state, resume_data, request_opts \\ []),
  do:
    Sagents.Session.resume(
      @config,
      state,
      resume_data,
      [request_opts: request_opts] ++ @subscribe_opts
    )

def dismiss_agent_session(state, request_opts \\ []),
  do:
    Sagents.Session.dismiss(
      @config,
      state,
      [request_opts: request_opts] ++ @subscribe_opts
    )
```

If your coordinator has other functions that reach `Sagents.Session`, they need
the same treatment. The inventory from step 1 is the list.

---

### 3. Tag the load path in `AgentLiveHelpers`

```elixir
# Before
defp subscribe_to_agent(socket, agent_id) do
  subs = socket.assigns[:sagents_subs] || %{}
  new_subs = Subscriber.subscribe_to_agent(subs, agent_id)
  assign(socket, :sagents_subs, new_subs)
end

# After
# Every event on this subscription arrives as `{:agent, agent_id, event}`.
# A socket showing one conversation could match the bare `{:agent, event}`
# instead; naming the source means a second subscription can be added later
# without reworking the clauses that already exist.
#
# `Coordinator` tags its session calls the same way. Both paths must agree:
# the publisher keeps one entry per {channel, pid}, so whichever subscribes
# last decides the envelope, and a tag on only one of them is an envelope
# that changes shape partway through a conversation.
defp subscribe_to_agent(socket, agent_id) do
  subs = socket.assigns[:sagents_subs] || %{}
  new_subs = Subscriber.subscribe_to_agent(subs, agent_id, tagged: true)
  assign(socket, :sagents_subs, new_subs)
end
```

Keep the surrounding lines exactly as they are. Only the call gains the option.

---

### 4. Rewrite every receiving clause

Every `handle_info` clause matching `{:agent, ...}` gains one element. This is
mechanical, and the risk is entirely in missing one:

```elixir
# Before
def handle_info({:agent, {:status_changed, :running, nil}}, socket) do
def handle_info({:agent, {:llm_deltas, deltas}}, socket) do
def handle_info({:agent, {:todos_updated, todos}}, socket) do

# After
def handle_info({:agent, _agent_id, {:status_changed, :running, nil}}, socket) do
def handle_info({:agent, _agent_id, {:llm_deltas, deltas}}, socket) do
def handle_info({:agent, _agent_id, {:todos_updated, todos}}, socket) do
```

A regex handles the whole file:

```
# Preview first.
grep -rn "handle_info({:agent, " lib/ --include="*.ex"

# Then apply, per file.
sed -i 's|handle_info({:agent, |handle_info({:agent, _agent_id, |g' lib/my_app_web/live/chat_live.ex
```

Re-run the `grep` afterwards and read every remaining hit. Anything still on two
elements is either a clause you missed or a deliberately untagged subscription
in a different process.

**Bind the id rather than discarding it** in any clause where the host already
recovers the agent from somewhere else. A clause like
`{:conversation_title_generated, new_title, agent_id}` carries the id in its
payload, and the envelope now carries the same value. Keep whichever one the
body already uses and leave the other as `_agent_id`. Do not write the same
variable name twice in one pattern to assert they are equal: if they ever differ
the clause simply stops matching, which is the silent failure again.

Leave the `:DOWN` and `presence_diff` clauses alone. Those wrap the helpers,
whose signatures do not change.

---

### 5. Take the reporting return shapes in `AgentSubscriberSession`

Optional, and worth doing anyway. Both helpers return the single-subscription
shape unless asked, so `report: true` is what makes the generated host already
correct on the day it holds several subscriptions.

```elixir
# Before
def handle_publisher_down(state, ref, reason \\ :noproc) do
  subs = Map.get(state, :sagents_subs, %{})

  case Subscriber.handle_publisher_down(subs, ref, reason) do
    {:matched, new_subs} -> %{sagents_subs: new_subs, agent_alive?: false}
    :no_match -> %{}
  end
end

# After
def handle_publisher_down(state, ref, reason \\ :noproc) do
  subs = Map.get(state, :sagents_subs, %{})

  case Subscriber.handle_publisher_down(subs, ref, reason, report: true) do
    # The entry is now `:pending`; the next presence arrival re-subscribes.
    # Interrupt state is deliberately untouched: a crashed agent with a
    # restorable interrupt boots straight back into `:interrupted`, and one
    # without boots `:idle` and the ordinary status handler clears the UI.
    #
    # `sub_key` names the subscription that went down. This session state
    # holds one conversation, so it is unused here. A host holding several
    # matches on it and leaves its siblings' streaming state alone: a crash
    # in one agent must not blank a panel that is still mid-response.
    {:matched, _sub_key, new_subs} -> %{sagents_subs: new_subs, agent_alive?: false}
    :no_match -> %{}
  end
end
```

```elixir
# Before
def handle_presence_diff(state, payload) do
  subs = Map.get(state, :sagents_subs, %{})
  new_subs = Subscriber.handle_presence_diff(subs, Subscriber.presence_topic(), payload)
  %{sagents_subs: new_subs}
end

# After
def handle_presence_diff(state, payload) do
  subs = Map.get(state, :sagents_subs, %{})

  # `revived` names the subscriptions that just came back. A host holding
  # several flips exactly those panels from offline to live. Only the map
  # goes back into state: `sagents_subs` is a map on every path that reads
  # it, and storing the reporting tuple instead is what makes the *next*
  # diff fail.
  {new_subs, _revived} =
    Subscriber.handle_presence_diff(subs, Subscriber.presence_topic(), payload, report: true)

  %{sagents_subs: new_subs}
end
```

> #### Store the map, never the tuple {: .warning}
>
> `sagents_subs` is read as a map on every path that touches it. Writing
> `%{sagents_subs: Subscriber.handle_presence_diff(subs, topic, payload, report: true)}`
> stores a `{map, list}` tuple, and the *next* presence diff is the one that
> fails, several seconds and one event later, inside the library.
>
> `subs` is guarded as a map on every clause, so Elixir 1.19's type checker
> rejects the mistake at compile time. If you are on an older Elixir you get a
> `FunctionClauseError` at your own call site instead of a `BadMapError` from
> inside `Sagents.Subscriber`. Either way, destructure at the call.

---

### 6. Fix test doubles that stub the old arity

This one has no compile signal and no test failure at the point of the mistake.

```
grep -rn "subscribe_to_agent\|handle_presence_diff\|handle_publisher_down" test/ --include="*.exs"
```

`Mimic` matches on arity. A stub written for `subscribe_to_agent/2` does not
error when the code starts calling `subscribe_to_agent/3`: it stops matching and
falls through to the **real** function. The test then asserts against a real
subscription it never intended to make, and the failure it eventually reports
describes the wrong thing.

```elixir
# Before
Sagents.Subscriber
|> expect(:subscribe_to_agent, fn subs, agent_id ->
  assert subs == %{}
  assert agent_id == "agent-123"
  sample_subs
end)

# After
Sagents.Subscriber
|> expect(:subscribe_to_agent, fn subs, agent_id, opts ->
  assert subs == %{}
  assert agent_id == "agent-123"
  assert opts == [tagged: true]
  sample_subs
end)
```

Assert on `opts`. It is the only thing in the suite that pins the two paths from
step 2 and step 3 to the same policy.

Also check any test that builds a `sagents_subs` fixture by hand. Entries now
carry a `:tag` key. Fixtures without it still work, because every reader
tolerates a missing key, but a test asserting on a whole entry with `==` will
fail against a real subscription.

---

### 7. Filesystem subscriptions, if you have any

Same options, same shape. `tagged: true` addresses events with `scope_key`:

```elixir
subs = Subscriber.subscribe_to_filesystem(subs, scope_key, tagged: true)

def handle_info({:file_system, _scope_key, {:file_written, path}}, socket) do
```

You need this only if one process subscribes to more than one filesystem scope.
That happens when a host shows several agents whose middleware took the default
`{:agent, agent_id}` scope. Agents sharing an explicit `:filesystem_scope` are
one subscription and need no tag.

---

### 8. What you do not have to touch

**Other consumers of the same agents.** The tag belongs to the subscription, so
a library or a separate LiveView that subscribes to an agent you now watch
tagged keeps receiving the bare `{:agent, event}`, and keeps working with no
change and no coordinated release. `sagents_live_debugger` is the common case:
it subscribes untagged from its own process, and it holds `:main` and `:debug`
subscriptions to agents your app tags. Nothing in it changes.

**Anything calling the arity-3 helpers.** `handle_publisher_down/3` and
`handle_presence_diff/3` return exactly what they returned in v0.14.x. That is
what makes step 5 optional rather than forced, and it is what keeps third-party
packages working.

**Your own producers on `use Sagents.Publisher`,** unless you want tags. The
signature changes are all trailing arguments with defaults:

```elixir
Sagents.Publisher.State.add/3      → add/4       # trailing tag, defaults :untagged
Sagents.Publisher.State.seed/2     → seed/3      # trailing default_identity
Sagents.Publisher.subscribe/3      → subscribe/4 # trailing tag
Sagents.Publisher.broadcast/3      → broadcast/4 # trailing per-subscriber envelope fun
```

---

### 9. If your host views several agents at once

This is what the release is for, and none of the steps above assume it. A split
view, a dashboard with a row per running agent, or a panel of threads each
backed by its own forked agent are all one process holding a set of
subscriptions.

Supply your own key rather than `tagged: true` wherever you have one. Routing on
`agent_id` means keeping an `agent_id => element` map purely to undo the
library's choice, and consulting it once per streaming delta:

```elixir
subs =
  Enum.reduce(notes, %{}, fn note, acc ->
    Subscriber.subscribe_to_agent(acc, note.agent_id, tag: {:note, note.id})
  end)

def handle_info({:agent, {:note, note_id}, event}, socket) do
  send_update(ThreadComponent, id: note_id, agent_event: event)
  {:noreply, socket}
end
```

Take `report: true` on both recovery helpers here, so a crash or a revival flips
exactly one panel and leaves its siblings' in-flight state alone. A crash in one
agent must not blank a panel that is still mid-response.

Read the tag back out of the subs map with `Subscriber.tag_for/2` when you have
a `sub_key` and need the routing key it was created with.

Two things to design around:

**Render collapsed threads without an agent.** Thirty findings on a page do not
mean thirty subscriptions. A closed thread is a plain function component over
stored messages; open a session only when the reader opens the thread. One
`ensure_running` per collapsed card means thirty agent processes, thirty sets of
mount-time reads, and thirty viewer-presence entries pinning agents nobody is
reading.

**Viewer presence is a separate set.** It has no addressing limit of its own.
See `AgentSubscriberSession.sync_tracked_viewers/2`, added in v0.14.0, and
prefer it over the incremental pair wherever the viewed set is derivable from
state you already keep.

---

## Verifying the migration

The compiler cannot confirm any of this, and neither can a green test run on a
host with a catch-all. Both of the checks below are necessary.

### Check 1: prove one test is load-bearing

Pick a test that asserts on something an agent event drives, a todo list, a
streamed message, a status badge. Then put **one** clause back to the untagged
shape and confirm the test goes red:

```
sed -i 's|handle_info({:agent, _agent_id, {:todos_updated|handle_info({:agent, {:todos_updated|' lib/my_app_web/live/chat_live.ex
mix test test/my_app_web/live/chat_live_todos_test.exs
```

It must fail. If it passes, your suite is describing your control flow rather
than the delivery, and it will not catch a clause you missed. Restore the clause
and confirm it goes green again.

This takes a minute and it is the only evidence that anything else you run means
something.

### Check 2: exercise the action path in a browser

Steps 2 and 3 are a pair, and a suite that only loads conversations never proves
they agree. With the app running:

1. Open a conversation. The transcript renders, so the load path is tagged
   correctly.
2. **Send a message.** This is `ensure_agent_session_running/2`, which
   re-subscribes. Watch the response stream in.
3. Reload, then answer an interrupt or dismiss a halt if your app has them.
   Those are `resume_agent_session/3` and `dismiss_agent_session/2`.

A UI that renders on open and then freezes when you send is the signature of a
tagged load path and an untagged action path. Go back to step 2.

### Check 3: read the inventory back

```
grep -rn "subscribe_to_agent\|Sagents.Session.ensure_running\|Sagents.Session.resume\|Sagents.Session.dismiss" lib/ --include="*.ex"
grep -rn "handle_info({:agent" lib/ --include="*.ex"
```

Every subscribing call carries the tag, or is a deliberately untagged
subscription in a different process that you can name. Every receiving clause
has three elements, or belongs to one of those untagged subscriptions.

---

## Recommended approach for generated files

Steps 2, 3 and 5 are template changes. Steps 0, 1, 4, 6, 7 and 9 are host code,
and no template covers those.

**If your generated modules are close to stock**, start from a clean workspace,
re-run `mix sagents.setup` with the same options used originally, accept the
overwrites, and diff your customizations back in. The v0.15.0 templates contain
steps 2, 3 and 5.

**If they have drifted**, apply the steps by hand.

**Either way, the templates are the authority.** They ship inside the package,
so the exact upstream delta is two commands away:

```
mix hex.package fetch sagents 0.14.0 --unpack --output /tmp/sagents-old
diff -u /tmp/sagents-old/priv/templates/coordinator.ex.eex \
        deps/sagents/priv/templates/coordinator.ex.eex
```

Repeat for `agent_live_helpers.ex.eex` and `agent_subscriber_session.ex.eex`.

**Either way, do step 4 and both verification checks.** No generator has ever
written your `handle_info` clauses, and on a host with a catch-all they are the
half of this migration that fails without telling you.

For details on the design, see
[docs/subscriptions_and_presence.md](docs/subscriptions_and_presence.md) and
[docs/forking.md](docs/forking.md).
