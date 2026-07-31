# Migration Guide: v0.10.x → v0.11.0

## What changed and why

An open `ask_user` question used to disappear when the agent's inactivity timer
fired, taking whatever the user had typed with it.

The interrupt itself was always durable: it is persisted with the agent state,
and a fresh boot rebuilds it and comes up `:interrupted`. The loss was entirely
in the host UI, which treated "the process went away" as a status change and
cleared the prompt. v0.11.0 separates the two facts a host was conflating:

- `agent_status` — **what the conversation is waiting on**. Stays `:interrupted`
  while the user owes an answer, process or no process.
- `agent_alive?` — **whether a process is backing this session right now**.

Answering an interrupt now goes through `Sagents.Session.resume/4`, which tries
the live agent first and, if none is running, starts one with the answer already
in hand. The woken agent applies it before its first broadcast, so subscribers
see a single `{:status_changed, :running, nil}` rather than an `:interrupted`
snapshot for a question that is already answered.

## Read this before you start

**The compiler will not help you.** Nothing in this release changed arity or
return type. Your app compiles clean against v0.11.0 and every existing test
passes — and the bug silently persists. There is no deprecation-warning
checklist like the v0.7.0 migration had.

That is because the affected modules were **generated into your app** by
`mix sagents.setup`. They are your copies; a dependency bump does not touch them.

So this migration is **search-driven, not warning-driven**. Work the steps in
order and run the searches given; do not assume a clean compile means you are
done.

Nothing here is required. Upgrading and changing no host code is safe and
behaves exactly as v0.10.1 did. Everything below is opt-in to get the fix.

---

## Prerequisites

1. Start from a clean, committed workspace.
2. Update the dependency to `~> 0.11.0` and run `mix deps.get`.
3. Run `mix compile`. **It will be clean.** That is expected, not evidence that
   there is nothing to do.
4. Locate your generated modules. They are wherever `mix sagents.setup` put
   them; the default names are `AgentSubscriberSession`, `Coordinator`, and
   `AgentLiveHelpers`:

   ```
   grep -rln "Sagents.Session\|Sagents.AgentUtils\|Sagents.Subscriber" lib/ --include="*.ex"
   ```

---

## Migration Steps

### 1. Teach the subscriber session that liveness is not status

In your `AgentSubscriberSession` (or whatever module holds your host-agnostic
state transitions).

**1a. Add the new state key.**

```elixir
# init_session_state/0
def init_session_state do
  %{
    agent_status: :not_running,
    agent_alive?: false,          # ← add
    # ...
  }
end
```

**1b. Every `handle_status_*` reports the agent as alive.** An inbound agent
event is proof a process exists, whatever the event says.

```elixir
# Before
def handle_status_running,
  do: Map.merge(AgentUtils.cleared_interrupt_changes(), %{agent_status: :running})

# After
def handle_status_running,
  do:
    Map.merge(
      AgentUtils.cleared_interrupt_changes(),
      %{agent_status: :running, agent_alive?: true}
    )
```

Do this for **all** of them: running, idle, cancelled, error, and interrupted.

**1c. `handle_publisher_down/3` reports the agent as gone.**

```elixir
case Subscriber.handle_publisher_down(subs, ref, reason) do
  {:matched, new_subs} -> %{sagents_subs: new_subs, agent_alive?: false}   # ← add key
  :no_match -> %{}
end
```

Deliberately do not touch interrupt state here. A crashed agent with a restorable
interrupt boots straight back into `:interrupted`; one without boots `:idle` and
your ordinary status handler clears the prompt.

---

### 2. Replace `handle_agent_shutdown/2` entirely

This is the core of the migration. **Deleting the old body matters as much as
adding the new one.**

```elixir
# Before — every line of this is harmful
def handle_agent_shutdown(state, _shutdown_data) do
  base =
    Map.merge(AgentUtils.cleared_interrupt_changes(), %{
      agent_id: nil,
      agent_status: :not_running,
      loading: false,
      streaming_delta: nil
    })

  case Map.get(state, :agent_id) do
    nil ->
      base

    agent_id ->
      subs = Map.get(state, :sagents_subs, %{})
      new_subs = Subscriber.unsubscribe_from_agent(subs, agent_id)
      Map.put(base, :sagents_subs, new_subs)
  end
end

# After
def handle_agent_shutdown(state, shutdown_data) do
  AgentUtils.shutdown_session_changes(state, shutdown_data)
end
```

Three separate bugs go away with that body:

1. **It cleared the interrupt UI unconditionally.** That is the reported bug.
   `shutdown_session_changes/2` keeps a *restorable* prompt on screen (returning
   only `%{agent_alive?: false, loading: false, streaming_delta: nil}`) and
   collapses everything else to `:not_running`, exactly as before.

2. **It nil'd `agent_id`.** That value is a pure function of the conversation id
   and is what you need in order to wake the agent again. Nil-ing it also
   silently broke `handle_conversation_title_generated/3`, which compares an
   inbound event's agent id against it.

3. **It unsubscribed, which destroyed recovery.**
   `Subscriber.unsubscribe_from_agent/2` *deletes* the subs entry, and
   `Subscriber.handle_presence_diff/3` only revives entries in the `:pending`
   state. The shutdown event is broadcast *before* the process dies, so this
   delete always beat the `:DOWN` that would have marked the entry `:pending`.
   The subscription was unrecoverable without a remount. Do nothing instead:
   `handle_publisher_down/3` plus the next presence arrival is the designed
   recovery path.

`shutdown_session_changes/2` is idempotent — a single shutdown delivers the event
more than once — and it never touches `:agent_id` or `:sagents_subs`.

---

### 3. Add a resume entry point to the Coordinator

```elixir
def resume_agent_session(state, resume_data, request_opts \\ []),
  do: Sagents.Session.resume(@config, state, resume_data, request_opts: request_opts)
```

---

### 4. Route every interrupt response through it

Find the direct resume calls:

```
grep -rn "AgentServer.resume" lib/ --include="*.ex"
```

Each one becomes a call to `resume_agent_session/3`. The return has three shapes:

```elixir
case Coordinator.resume_agent_session(socket.assigns, resume_data, request_opts) do
  :ok ->
    # A live agent took it.
    socket |> assign(changes) |> assign(running_changes)

  {:ok, session_changes} ->
    # The agent was asleep and was woken with the answer in hand.
    # session_changes carries subscription bookkeeping — merge it.
    socket |> assign(session_changes) |> assign(changes) |> assign(running_changes)

  {:error, reason} ->
    put_flash(socket, :error, "Could not submit response: #{inspect(reason)}")
end
```

Pass the **same `request_opts`** you pass to `ensure_agent_session_running/2`
(timezone, tool context, whatever your FactoryConfig consumes). An agent woken to
accept an answer must be configured exactly like one woken any other way.

**Delete any "agent is no longer running" guard.** It looked like this:

```elixir
# Delete this entire branch
if is_nil(agent_id) do
  put_flash(socket, :error, "Agent is no longer running. Please send a new message to restart.")
else
  # ...
end
```

It existed only because the shutdown handler nil'd `agent_id`. `Session.resume/4`
asks the agent directly, which also covers a crash that never broadcast a
shutdown at all.

**Do not route intermediate steps through it.** In a multi-question batch or a
multi-tool HITL approval, only the *final* answer resumes; the intermediate ones
return `{:more, changes}` and need no agent. Waking one for those is wrong.

---

### 5. Guard duplicate submissions

Not caused by this release, but newly reachable and worth fixing while you are
here. A click-to-select answer renders no submit button to disable, and
`Session.resume/4` is synchronous, so a fast double click delivers a second event
*after* the first cleared `pending_question`.

```elixir
def handle_question_response(socket, response) do
  if is_nil(socket.assigns[:pending_question]) do
    socket
  else
    # ... existing body
  end
end

def handle_hitl_decision(socket, index, decision_type) do
  if (socket.assigns[:pending_tools] || []) == [] do
    socket
  else
    # ... existing body
  end
end
```

Without the first guard the LiveView crashes on the missing question. Without the
second, `AgentUtils.advance_hitl_decisions/3` receives an empty list, reports the
batch settled, and **resumes with a fabricated decision** — silent and worse than
a crash.

---

### 6. Update the UI

**6a. Gate any "wake the agent" affordance on liveness.**

```
grep -rn "agent_status == :not_running" lib/ --include="*.ex" --include="*.heex"
```

```elixir
# Before — hides the button exactly when a dormant conversation owes an answer,
# because that conversation now correctly stays :interrupted
:if={@agent_status == :not_running}

# After
:if={!@agent_alive?}
```

Thread `agent_alive?` through to any component that needs it, and seed it at
mount from the agent's status:

```elixir
|> assign(:agent_alive?, agent_status != :not_running)
```

Also set it optimistically wherever you start an agent, so the affordance updates
on the click that caused the wake rather than a round trip later:

```elixir
{:ok, changes} -> socket |> assign(changes) |> assign(:agent_alive?, true)
```

**6b. Protect typed text, if your question form has free-text input.**

Wrap the answer controls in an ignored region keyed on the question's
`tool_call_id`:

```heex
<div id={"question-body-#{@question.tool_call_id}"} phx-update="ignore">
  <%!-- radios / checkboxes / textareas / submit --%>
</div>
```

Any diff at all makes LiveView patch the container, and morphdom resyncs a
`TEXTAREA`'s value from the server's HTML for every element that is not
`document.activeElement`. The server never renders what the user typed, so an
unrelated assign change wipes it — and this release guarantees one, because the
shutdown flips `agent_alive?`.

Keying the id on `tool_call_id` is what still lets the *next* question in a batch
render: morphdom replaces an ignored subtree only when its id changes. Ids are
distinct per question on both the live and restored paths.

Keep anything without typed state (a Cancel button) **outside** the region so it
can still re-render.

---

### 7. Check for re-subscribe-as-resync

The one behavioural change in this release that is not opt-in:
`on_subscribed/3` no longer fires for a pid already subscribed to that channel.
It is documented as a *newly registered* subscriber snapshot, and a pid that has
been receiving broadcasts all along has nothing to resync.

```
grep -rn "subscribe_to_agent\|AgentServer.subscribe" lib/ --include="*.ex"
```

If any call site subscribes an already-subscribed pid specifically to force a
state refresh, replace it with `Sagents.AgentServer.get_info/1`. Ordinary
subscribe calls, remounts, second tabs, and presence-driven re-subscription after
a crash are all unaffected — each is a genuinely new registration.

---

### 8. Collapse duplicated shutdown-event handling

All three `{:agent_shutdown, _}` emit sites now send the same map:

```elixir
%{
  agent_id: String.t(),
  reason: :inactivity | :no_viewers | term(),
  status: Sagents.AgentServer.status(),
  interrupt_restorable: boolean(),
  last_activity_at: DateTime.t() | nil,
  shutdown_at: DateTime.t()
}
```

Previously `terminate/2` sent only `%{reason:, status:}`, so hosts needed a clause
per site and could not correlate the event by agent id. If you wrote two clauses
to absorb that, they can collapse to one. Subset map patterns keep working
unchanged.

---

### 9. Fix the tests that now fail

This is the **only** place you get an automatic signal, and it is a good one.

Any host test asserting the old shutdown behaviour will fail, for example:

```elixir
assert changes.agent_id == nil            # no longer true, and that is the fix
assert changes.agent_status == :not_running   # no longer true for a restorable interrupt
```

Rewrite them against the new contract. Worth adding, since these are pure
state-map-in / changes-map-out functions needing no agent, DB, or LiveView:

- a restorable question survives shutdown (`agent_status` stays `:interrupted`,
  `agent_alive?` becomes `false`)
- a non-restorable interrupt (a sub-agent approval) still clears
- a missing `:interrupt_restorable` key is treated as not restorable
- the result is idempotent across two consecutive deliveries
- `agent_id` and `sagents_subs` are untouched
- a half-answered question batch keeps its accumulated responses

---

## Verifying the migration

The compiler cannot confirm this worked. Test it by hand:

1. Temporarily drop `inactivity_timeout` in your Coordinator's `@config` to
   ~20 seconds.
2. Prompt the agent so it asks a question.
3. Wait for the nap. Watch for `shutting down due to inactivity` in the log.
4. **The question should still be on screen.** That is the fix.
5. Answer it. The log should show:

   ```
   Starting agent session for conversation N
   Agent conversation-N applying a resume submitted while it was not running
   ```

   with **no** `{:status_changed, :interrupted, _}` between them.

To kill the agent instantly instead of waiting, use the same path the inactivity
timer uses:

```elixir
Sagents.AgentSupervisor.stop(YourApp.Coordinator.conversation_agent_id(conversation_id))
```

Do not use `Sagents.AgentServer.stop/1` — that kills only the server, and the
supervisor restarts it as a permanent child.

---

## Recommended approach for generated files

If your generated modules are close to stock, the fastest route is to start from
a clean workspace, re-run `mix sagents.setup` with the same options used
originally, accept the overwrites, and diff your customizations back in. The
v0.11.0 templates contain every change in steps 1 through 5.

If they have drifted, apply the steps by hand. Step 2 is the one that must not be
skipped or half-applied.
