# Migration Guide: v0.13.x → v0.14.0

## What changed and why

A subscriber process that switches between conversations leaves its
viewer-presence entry behind on the one it left.

`Sagents.Presence.track/4` tracks `self()`. A LiveView is the same process for
every conversation it shows, so an entry taken when conversation A opened
survives the switch to B, and to C, and to every conversation after that.
`Sagents.AgentServer` reads the viewer list to decide an idle agent may *not*
shut down yet, so each stale entry pins an agent for the full inactivity
timeout: an agent nobody is watching, holding memory and its restored state,
until the timer that the entry exists to defeat finally runs out anyway.

`Phoenix.Presence` does reap an entry when the tracked process dies, which is
why this is easy to miss. Closing the tab cleans up perfectly. So the leak is
invisible in every way a developer normally exercises the app, and shows up in
production only as agents that outlive their viewers.

The release names the missing concept. `Sagents.ViewerPresence` records what
Presence actually holds for the calling process, keyed per conversation:

```elixir
%{conversation_id => viewer_id}
```

Recording it matters more than it first appears. `Phoenix.Tracker` answers `:ok`
to an untrack of a key it never tracked, so a release aimed at the wrong viewer
id reports success while leaving the real entry in place. A host that recomputes
the viewer id at leave time (after a re-auth, say) releases nothing and is told
it worked.

It is a **set**, not a slot. One process can hold an entry per conversation,
which is the groundwork for hosts that show several agents at once: a split
view, a dashboard with a row per running agent, a panel of threads each backed
by its own forked conversation.

Separately, `AgentServer` no longer trusts a no-viewers shutdown decision made
`check_delay` earlier. That fix is internal and needs no host action.

## Read this before you start

**Nothing in this release breaks your application.** Upgrade the dependency,
change no host code, and your app compiles clean, passes every test, and behaves
exactly as v0.13.2 did, except that the timer fix above arrives for free. The
leak is also still there. Everything below is opt-in work to fix it.

**The compiler will not help you, with one exception.** The functions that
changed live in modules `mix sagents.setup` generated into your app. They are
your copies; a dependency bump does not touch them. The exception is worth
knowing because it is the opposite of intuition:

| what you do | signal |
| --- | --- |
| regenerate nothing | none. Clean compile, green tests, leak intact |
| regenerate `AgentSubscriberSession` only | **warning.** `AgentLiveHelpers` still calls `maybe_track_viewer/2`, now undefined |
| regenerate everything | correct, if you have not customized the files |
| apply by hand | none. Work the steps |

So a clean compile is not evidence you are done. This migration is
**search-driven**. Work the steps in order and run the searches.

**Do not re-run `mix sagents.setup` as the default route.** These files are meant
to be customized and you have customized them. See the final section.

---

## Prerequisites

1. Start from a clean, committed workspace.
2. Update the dependency to `~> 0.14.0` and run `mix deps.get`.
3. Run `mix compile`. **It will be clean.** That is expected, not evidence that
   there is nothing to do.
4. Locate your generated modules. They are wherever `mix sagents.setup` put
   them; the default names are `AgentSubscriberSession`, `AgentLiveHelpers`, and
   `Coordinator`:

   ```
   grep -rln "Sagents.Session\|Sagents.Subscriber\|Sagents.AgentUtils" lib/ --include="*.ex"
   ```

5. Confirm you have the function this migration replaces. If this finds nothing,
   your app predates viewer presence and only steps 6 and 8 apply:

   ```
   grep -rn "maybe_track_viewer" lib/ --include="*.ex" --include="*.heex"
   ```

Steps 1 and 2 must be applied before steps 3 through 6: the LiveView helpers
call the session functions that step 2 creates.

---

## Migration Steps

### 1. Add the viewer-presence record to `AgentSubscriberSession`

Two edits. Add the alias:

```elixir
alias Sagents.AgentUtils
alias Sagents.StreamingSession
alias Sagents.Subscriber
alias Sagents.ViewerPresence        # ← add
```

and the state key, in `init_session_state/0`:

```elixir
def init_session_state do
  %{
    # ... every existing key, unchanged ...
    sagents_subs: %{},
    # Every viewer-presence entry `Phoenix.Presence` holds for this process,
    # as `%{conversation_id => viewer_id}`. Presence tracks `self()`, and this
    # process outlives the conversations it shows, so entries are handed back
    # on the way out rather than left for process exit to reap. Recording the
    # viewer id per conversation is what lets a leaving path release an entry
    # under the id it was taken with, which a re-auth may have changed.
    #
    # A map rather than a single slot because one process can view any number
    # of conversations at once: a split view, a dashboard row per agent, a
    # panel of threads each backed by its own forked agent.
    tracked_viewers: %{}
  }
end
```

---

### 2. Replace `maybe_track_viewer/2` with the four state-threading functions

**Delete the old function entirely.** It calls the coordinator for its side
effect and returns `:ok`, recording nothing, which is the defect. Leaving it in
place beside the new functions gives you two ways to take an entry, one of which
no leaving path can release.

```elixir
# Before. Delete all of this
def maybe_track_viewer(_conversation_id, nil), do: :ok

def maybe_track_viewer(conversation_id, user_id) do
  case Coordinator.track_conversation_viewer(conversation_id, user_id) do
    {:ok, _ref} -> :ok
    {:error, {:already_tracked, _topic, _key, _meta}} -> :ok
    {:error, reason} ->
      Logger.warning("Failed to track presence: #{inspect(reason)}")
      :ok
  end
end
```

Replace `Coordinator` below with your coordinator's alias throughout.

```elixir
# After. Each returns the changes to merge into the host's state.

@doc """
Add `conversation_id` to what this process is viewing.

`Coordinator` reads the viewer list to decide an idle agent may *not* shut down
yet, so an entry left on a conversation nobody is looking at any more pins that
agent for the full inactivity timeout. Every path that adds one needs a path
that gives it back.

Adding does not release anything else. A host showing several conversations at
once holds an entry per conversation, and the one it just opened says nothing
about the others.

`viewer_id` may be nil, for a host with no identified viewer. Nothing is
tracked and any existing entry is left alone.

Returns the changes to merge into the host's state.
"""
def add_tracked_viewer(state, conversation_id, viewer_id) do
  %{
    tracked_viewers:
      ViewerPresence.track(tracked_viewers(state), Coordinator, conversation_id, viewer_id)
  }
end

@doc """
Remove `conversation_id` from what this process is viewing.

Releases the entry under the viewer id it was taken with. Holding nothing for
`conversation_id` is a no-op.

Returns the changes to merge into the host's state.
"""
def remove_tracked_viewer(state, conversation_id) do
  %{
    tracked_viewers:
      ViewerPresence.untrack(tracked_viewers(state), Coordinator, conversation_id)
  }
end

@doc """
Release every viewer-presence entry this process holds.

For a host that stops viewing everything at once: a reset, a closed panel, a
navigation away.

Returns the changes to merge into the host's state.
"""
def clear_tracked_viewers(state) do
  %{tracked_viewers: ViewerPresence.untrack_all(tracked_viewers(state), Coordinator)}
end

@doc """
Make what this process holds match `desired` exactly.

`desired` is `%{conversation_id => viewer_id}`. Releases the conversations no
longer in the set, takes the ones that are new, and leaves the unchanged ones
untouched.

Returns the changes to merge into the host's state.
"""
def sync_tracked_viewers(state, desired) do
  %{tracked_viewers: ViewerPresence.sync(tracked_viewers(state), Coordinator, desired)}
end

defp tracked_viewers(state), do: Map.get(state, :tracked_viewers) || %{}
```

`tracked_viewers/1` tolerating a missing key is deliberate: a LiveView already
mounted when you deploy has a state map built by the old `init_session_state/0`,
and it must not crash on its next navigation.

The error handling that `maybe_track_viewer/2` did by hand now lives in
`Sagents.ViewerPresence`, which additionally records nothing when a track fails.
That is the point: a record that claims an entry this process does not hold
produces a release that reports `:ok` and changes nothing.

---

### 3. Add the two leave paths to `AgentLiveHelpers`

The existing `unsubscribe_current_agent/1` stays exactly as it is. These wrap it.

```elixir
# This socket shows nothing afterwards, so every viewer entry it holds goes
# back. `init_agent_state/1` rewrites the record on the next line, and an
# entry dropped from the record without being released is one Presence keeps
# for the life of this process.
defp leave_all_conversations(socket) do
  socket = unsubscribe_current_agent(socket)
  assign(socket, AgentSubscriberSession.clear_tracked_viewers(socket.assigns))
end

# Leaving one conversation for another. The release is targeted at the
# conversation being left rather than at everything held, so a host that also
# views others from this process keeps those entries.
defp leave_current_conversation(socket) do
  socket = unsubscribe_current_agent(socket)

  assign(
    socket,
    AgentSubscriberSession.remove_tracked_viewer(
      socket.assigns,
      socket.assigns[:conversation_id]
    )
  )
end
```

Then point `reset_conversation/1` at the first one:

```elixir
def reset_conversation(socket) do
  socket =
    if connected?(socket) do
      leave_all_conversations(socket)      # ← was unsubscribe_current_agent(socket)
    else
      socket
    end

  init_agent_state(socket)
end
```

The two are not interchangeable. `reset_conversation/1` is the path where the
socket stops showing anything, and `init_agent_state/1` on the next line
overwrites `tracked_viewers` with a fresh `%{}`. An entry dropped from the record
without being released is one Presence holds for the life of the process with
nothing left that knows its key.

---

### 4. Funnel every open through one private `enter/4`

Rename `maybe_unsubscribe_previous/2` and change what it calls:

```elixir
# Before
defp maybe_unsubscribe_previous(socket, conversation_id) do
  if connected?(socket) && socket.assigns[:conversation_id] &&
       socket.assigns.conversation_id != conversation_id do
    unsubscribe_current_agent(socket)
  else
    socket
  end
end

# After
#
# Guarded so the socket does not unsubscribe from, and stop viewing, the agent
# it is about to use. Every path that opens a conversation goes through
# `enter/4`, which calls this first, and that funnel is what keeps an entry
# from being taken without the previous one being handed back.
defp maybe_leave_previous_conversation(socket, conversation_id) do
  if connected?(socket) && socket.assigns[:conversation_id] &&
       socket.assigns.conversation_id != conversation_id do
    leave_current_conversation(socket)
  else
    socket
  end
end
```

Add the funnel itself:

```elixir
# The one way in. Both entry points hand over the id to key everything on:
# `enter_conversation/3` uses the conversation's own id, while the load path
# keeps the id it was called with so a host comparing `:conversation_id`
# against a route param still matches.
defp enter(socket, conversation, conversation_id, user_id) do
  agent_id = Coordinator.conversation_agent_id(conversation_id)

  socket
  |> maybe_leave_previous_conversation(conversation_id)
  |> assign(:conversation, conversation)
  |> assign(:conversation_id, conversation_id)
  |> assign(:agent_id, agent_id)
  |> maybe_subscribe_and_track(agent_id, conversation_id, user_id)
end
```

And make `maybe_subscribe_and_track/4` record what it took:

```elixir
# Before
defp maybe_subscribe_and_track(socket, agent_id, conversation_id, user_id) do
  if connected?(socket) do
    socket = subscribe_to_agent(socket, agent_id)
    AgentSubscriberSession.maybe_track_viewer(conversation_id, user_id)
    socket
  else
    socket
  end
end

# After
defp maybe_subscribe_and_track(socket, agent_id, conversation_id, user_id) do
  if connected?(socket) do
    socket = subscribe_to_agent(socket, agent_id)

    assign(
      socket,
      AgentSubscriberSession.add_tracked_viewer(socket.assigns, conversation_id, user_id)
    )
  else
    socket
  end
end
```

The old version discarded the result of tracking, which is the shape of the bug:
an entry taken with nothing anywhere recording that it was.

---

### 5. Read the conversation before leaving the current one

In `do_load_conversation/3`, the order of the first two operations changes.

```elixir
# Before
try do
  socket = maybe_unsubscribe_previous(socket, conversation_id)

  conversation = conversations.get_conversation!(scope, conversation_id)
  agent_id = Coordinator.conversation_agent_id(conversation_id)

  socket = maybe_subscribe_and_track(socket, agent_id, conversation_id, user_id)
  # ...

# After
try do
  # The read comes first so a conversation that is not there leaves the
  # socket exactly where it was. Leaving the open conversation before
  # knowing the new one exists takes the subscription off an agent that is
  # still on screen, and the thread goes dead while still looking fine.
  conversation = conversations.get_conversation!(scope, conversation_id)

  socket = enter(socket, conversation, conversation_id, user_id)
  agent_id = socket.assigns.agent_id
  # ...
```

Then **delete** the three assigns further down the body that `enter/4` now does:

```elixir
socket =
  socket
  |> assign(:conversation, conversation)      # ← delete
  |> assign(:conversation_id, conversation_id)  # ← delete
  |> assign(:agent_id, agent_id)              # ← delete
  |> assign(:todos, saved_todos)
  # ... the rest stays
```

Leaving them is harmless but misleading: it re-asserts values `enter/4` already
owns, and the next reader will not know which one is authoritative.

The `Sagents.ready?/0` guard on the public `load_conversation/3`, and the
`rescue Ecto.NoResultsError` clause, both stay untouched.

---

### 6. Add `enter_conversation/3`

This is the step that fixes create-and-navigate paths, and it is the one most
likely to be skipped because nothing in the existing code points at it.

```elixir
@doc """
Open a conversation the caller already holds, without a database read.

For the paths that create a conversation, or are handed one, and therefore
never reach `load_conversation/3`. Those paths assign `:conversation_id`
themselves before navigating, so a same-id guard on the load path can
short-circuit and never see the conversation at all. Routing them here is
what keeps their viewer presence entries from accumulating, one per
conversation opened per session.

Subscribing here is safe on a create path, where the agent does not exist
yet: `Sagents.AgentServer.subscribe/3` answers `{:error, :process_not_found}`
rather than raising, `Sagents.Subscriber` records the subscription as
`:pending`, and it upgrades to `:subscribed` once the agent appears.

## Options

- `:user_id` - the viewer to track. Omit it and nothing is tracked, but the
  previous entry is still released.
"""
def enter_conversation(socket, conversation, opts \\ []) do
  enter(socket, conversation, conversation.id, Keyword.get(opts, :user_id))
end
```

A create path that deliberately subscribed *later* — relying on
`initial_subscribers` when it starts the session, to avoid missing events from
an opening message — keeps working and needs no special handling. Subscriptions
are keyed on the agent, so entering here and enrolling again at session start
converge on one subscription rather than two. Worth stating because such a path
usually carries a comment explaining why it subscribes late, which reads like a
reason not to route it through `enter_conversation/3`.

---

### 7. Declare the behaviour on the `Coordinator`

Two lines, and not merely tidiness: the `Coordinator` is passed as a *module*
to every `Sagents.ViewerPresence` call the steps above introduce, so the
behaviour is the only thing that checks it can answer what those calls will ask
of it. Without it a renamed or re-arity'd function fails at runtime, on the
presence path, which is the path least likely to be exercised by a test.

```elixir
defmodule MyApp.Coordinator do
  @moduledoc "..."

  @behaviour Sagents.ViewerPresence      # ← add

  @presence_module MyAppWeb.Presence
  # ...

  @impl Sagents.ViewerPresence           # ← add
  def track_conversation_viewer(conversation_id, viewer_id, metadata \\ %{}) do

  @impl Sagents.ViewerPresence           # ← add
  def untrack_conversation_viewer(conversation_id, viewer_id) do
```

Neither function body changes. Keep `list_conversation_viewers/1` and
`presence_topic/1` as they are; step 10 uses the first one.

---

### 8. Audit host code for the two things no template can fix

This is the step with no automatic signal at all, and the one that decides
whether the migration actually worked. A single hand-rolled track in host code
reintroduces the leak with every helper above correctly in place.

**8a. Direct coordinator calls.**

```
grep -rn "track_conversation_viewer\|untrack_conversation_viewer" lib/ --include="*.ex" --include="*.heex"
```

Expected results after this migration: hits in `coordinator.ex` only — the two
definitions, plus the docstring cross-reference the v0.14.0 template adds to
`untrack_conversation_viewer/2`. Nothing anywhere else.

`AgentSubscriberSession` is included in that. It hands the `Coordinator` to
`Sagents.ViewerPresence` as a module and never names these functions itself, so
a hit inside it means the old `maybe_track_viewer/2` survived step 2 — which is
the "two ways to take an entry, one of which no leaving path can release" state
that step warns about.

Every other hit is a call site to convert:

```elixir
# Before, in a LiveView
Coordinator.track_conversation_viewer(conversation_id, user_id)

# After
socket =
  assign(
    socket,
    AgentSubscriberSession.add_tracked_viewer(socket.assigns, conversation_id, user_id)
  )
```

A bare `track_conversation_viewer/3` in `mount/3` is the classic instance. It
looks correct, and it is precisely the entry that nothing releases.

Check what each call site does with the return value while you are there. A
hand-rolled call is usually written as `{:ok, _ref} = track_conversation_viewer(...)`,
which raises `MatchError` the first time the same viewer is tracked twice —
`{:error, {:already_tracked, _topic, _key, _meta}}` is an ordinary answer, and
handling it is one of the things `maybe_track_viewer/2` existed to do. Going
around a helper drops the error handling that motivated it, not just the
bookkeeping.

**8b. Direct `:conversation_id` assigns.**

```
grep -rn "assign(:conversation_id\|assign(socket, :conversation_id" lib/ --include="*.ex" --include="*.heex"
```

Deliberately narrow. Widening it to a bare `conversation_id:` matches every
changeset field, query binding and keyword argument in the application — on a
real codebase that is dozens of lines around the handful that matter, and the
ones that matter are the ones skimmed past.

Only `enter/4` in the generated helpers should remain. Every other hit is a
LiveView that assigns the id itself and then navigates, usually on a create
path:

```elixir
# Before. The id is assigned here, so load_conversation/3's same-id guard
# short-circuits on arrival and the conversation is never entered properly
{:ok, conversation} = Conversations.create_conversation(scope, params)

socket
|> assign(:conversation_id, conversation.id)
|> push_navigate(to: ~p"/chat/#{conversation.id}")

# After
{:ok, conversation} = Conversations.create_conversation(scope, params)

socket
|> AgentLiveHelpers.enter_conversation(conversation, user_id: scope.user.id)
|> push_navigate(to: ~p"/chat/#{conversation.id}")
```

Note the ordering trap in the "before": because `:conversation_id` already
matches, `maybe_leave_previous_conversation/2` decides there is nothing to
leave, so the *previous* conversation's entry is stranded too. One create path
can leak two entries.

**Two rules to state in your own code review from here on:**

- Never assign `:conversation_id` directly. Open through `load_conversation/3`
  or `enter_conversation/3`, leave through `reset_conversation/1`.
- Never call the coordinator's viewer-presence functions from host code. The
  session record exists so a leaving path can release an entry without a viewer
  id it may no longer have, and calling behind that record makes the two drift.

---

### 9. If your host views several conversations at once

Skip this step if every socket shows one conversation. The helpers above already
model that case.

A host with a split view, a dashboard row per running agent, or a panel of
threads each backed by its own agent works the set directly on its own state
map, beside whatever the helpers do for its primary conversation:

```elixir
# Whatever this process was viewing, it is viewing exactly these now.
changes =
  AgentSubscriberSession.sync_tracked_viewers(socket.assigns, %{
    main_id => user_id,
    note_a_id => user_id,
    note_b_id => user_id
  })

socket = assign(socket, changes)
```

**Prefer `sync_tracked_viewers/2` over the incremental pair** wherever the viewed
set is derivable from state the host already keeps. The incremental pair can
accumulate entries, because nothing in the library knows when one of your panels
went away, and declaring the set removes the question. It is also idempotent:
re-declaring the same set issues no calls at all, which matters because an
untrack followed by a track of the same conversation is a leave broadcast, and an
idle agent that acts on it schedules the very shutdown the entry exists to
prevent. That makes it safe on a render path.

**One limit to design around today.** Main-channel events arrive as a bare
`{:agent, event}` and do not name the agent that sent them, so two agents
streaming into one mailbox are not separable. Route each conversation's events
through its own subscriber process (pass it to
`Sagents.Subscriber.subscribe_to_agent/4`) or its own LiveView. Viewer presence
has no such limit: entries are per topic and one process holds as many as it
likes.

---

### 10. Add the tests that catch a regression

Nothing existing should fail. The functions are new, and the ones they replaced
returned `:ok` unconditionally, so few hosts assert on them. If you stubbed
`maybe_track_viewer/2` with Mimic, that stub now covers a function nobody calls;
delete it.

Worth adding, in rough order of value:

- **Switching conversations leaves nothing behind.** The core assertion. Enter A,
  enter B, then assert `Coordinator.list_conversation_viewers("A")` is empty and
  B's has one entry. This is the test that fails if step 4's funnel regresses.
- **Reset releases everything.** Enter a conversation, call
  `reset_conversation/1`, assert the viewer list is empty.
- **A second viewer of the same conversation is untouched.** Two processes track
  the same conversation, one leaves, the other's entry survives. Guards against a
  release that is aimed at the topic rather than the key.
- **A missing `tracked_viewers` key does not crash.** Call
  `remove_tracked_viewer/2` on a state map built without the key. This is the
  deploy-with-mounted-LiveViews case from step 1.
- **`sync_tracked_viewers/2` is idempotent.** Declare the same set twice; assert
  the second call issues no track and no untrack. Assert against the coordinator
  with Mimic, since the resulting `held` map is identical either way and cannot
  tell you which happened.

The first three drive the `AgentLiveHelpers` functions, so they need a socket.
A hand-built one needs two things that are easy to miss:

```elixir
%Phoenix.LiveView.Socket{
  # Every path under test is guarded on `connected?/1`, which reads this. An
  # unconnected socket tracks nothing, which makes each assertion below
  # vacuously true rather than failing.
  transport_pid: self(),
  # `reset_conversation/1` resets a stream, which attaches a lifecycle hook.
  # Without these keys it raises `KeyError key :lifecycle not found` before
  # reaching anything this migration changed.
  private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
  assigns: Map.put(AgentSubscriberSession.init_session_state(), :__changed__, %{})
}
```

Presence is a singleton in the supervision tree, so give each test its own
conversation and viewer ids if these run async. For the two-viewer test, keep
the second process alive until after the assertion — Presence reaps on process
exit, which would pass the test for the wrong reason.

> #### Assert against Presence, not against the record {: .warning}
>
> A test that only checks the returned `tracked_viewers` map proves the
> bookkeeping agrees with itself. The bug this release fixes is the record and
> Presence disagreeing, and `Phoenix.Tracker` answering `:ok` to a release that
> did nothing is exactly how they diverge without complaint.
>
> At least one test must read the real thing, through
> `Coordinator.list_conversation_viewers/1` or `Presence.list/1`. If deleting
> the release call leaves your suite green, the suite is describing your control
> flow rather than the leak.
>
> Run that check rather than assuming it. Put step 4's
> `maybe_leave_previous_conversation/2` back to calling
> `unsubscribe_current_agent/1` instead of `leave_current_conversation/1` — the
> one-line reversal of the fix — and confirm the switching test goes red before
> restoring it. It takes a minute and it is the only evidence that the test is
> load-bearing.

---

## Verifying the migration

The compiler cannot confirm any of this. Check it by hand.

**The leak itself**, which takes about a minute and is the whole migration in
two reads. In a browser, with IEx attached:

```elixir
# Open conversation A in the UI, then:
MyApp.Coordinator.list_conversation_viewers(a_id)
# => %{"user-1" => %{metas: [...]}}    one viewer, correct

# Now navigate to conversation B in the same tab, without reloading, then:
MyApp.Coordinator.list_conversation_viewers(a_id)
# => %{}          ← the fix. Before this migration, still one entry.

MyApp.Coordinator.list_conversation_viewers(b_id)
# => %{"user-1" => %{metas: [...]}}
```

Do the navigation with `push_patch` or a `live_redirect`, not a full page load.
A full reload kills the LiveView process and Presence reaps everything, which
passes whether or not you have done any of this.

**The create path**, which step 8b exists for. Create a new conversation from
inside an open one, then run both reads again. If the previous conversation still
holds an entry, you have a `:conversation_id` assign that bypasses the funnel.

**The shutdown that the entries govern.** Temporarily drop
`inactivity_timeout` in your Coordinator's `@config` to about 20 seconds:

1. Open a conversation, send a message, wait for idle.
2. Navigate away to another conversation.
3. The first agent should stop within about a second, on the no-viewers path,
   logging `idle with no viewers`. Without this migration it waits out the full
   inactivity timeout instead.

**Do not try to hand-verify the shutdown-cancel fix.** `Sagents.Session` builds
its `presence_tracking` options without a `:check_delay`, so a host going through
the generated Coordinator always gets the 1 second default, and navigating away
and back inside one second is not something you can do on purpose. The branch
also logs at `:debug`, so it is invisible at a default `:info` level. It needs no
host change and the library's own tests cover it; treat it as arriving for free.

**What a passing run does not prove.** Every check above runs against a single
process viewing one conversation at a time. If you did step 9, exercise the
multi-conversation host separately: open three panels, close the middle one, and
assert the other two entries survive.

---

## Recommended approach for generated files

Steps 1 through 7 are entirely template changes. Step 8 is host code, steps 9
and 10 are host code and host tests, and no template covers those.

**If your generated modules are close to stock**, start from a clean workspace,
re-run `mix sagents.setup` with the same options used originally, accept the
overwrites, and diff your customizations back in. The v0.14.0 templates contain
every change in steps 1 through 7.

**If they have drifted**, apply the steps by hand in order. Steps 1 and 2 must
land before 3 through 6, which call into them.

**Either way, the templates are the authority.** They ship inside the package,
so the exact upstream delta is two commands away and needs no other repository:

```
mix hex.package fetch sagents 0.13.2 --unpack --output /tmp/sagents-old
diff -u /tmp/sagents-old/priv/templates/agent_live_helpers.ex.eex \
        deps/sagents/priv/templates/agent_live_helpers.ex.eex
```

Repeat for `agent_subscriber_session.ex.eex` and `coordinator.ex.eex` — those
three are the whole of steps 1 through 7. Substitute the v0.13.x version you are
actually coming from.

That diff is worth running even when you are working the steps by hand. The
snippets above are written to be read, so they carry a trimmed docstring here
and there; the templates are what `mix sagents.setup` would have produced. When
the two disagree, the template wins. Reading the delta straight also tells you
which lines in your copy are upstream's and which are yours, which is the
question that makes a drifted file hard to merge in the first place.

**Either way, do step 8.** It is the only step that touches code no generator has
ever written, and a single hand-rolled `track_conversation_viewer/3` in a
`mount/3` puts the leak back with every other step correctly applied.

For details on the reasoning, see
[#180](https://github.com/sagents-ai/sagents/pull/180) and
[docs/subscriptions_and_presence.md](docs/subscriptions_and_presence.md).
