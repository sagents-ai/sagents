# Migration Guide: v0.11.x → v0.12.0

## What changed and why

A node stops being able to serve agent requests **the moment
`Sagents.Supervisor` shuts down**, and it keeps accepting TCP connections for
the rest of the platform's grace period, commonly 30 to 60 seconds. That is
every rolling deploy, every scale-down, every machine migration.

`Sagents.Registry` lives in ETS tables owned by a process on the local node.
When that process stops, the tables go with it. So during the drain window:

- the node still holds open connections and still accepts new ones,
- no agent lookup on it can succeed,
- and no retry helps, because the registry is not coming back on this node.

It is not a race with a small window. It is a stable condition for the whole
drain, and it is **local**: every other node in the cluster serves the same
request perfectly well. That makes it a routing problem, not an outage.

Before v0.12.0 that condition had no name. Neither backend reports it:
`Horde.Registry.lookup/2` derives its ETS table name arithmetically and reads it
unguarded, and Elixir's `Registry` does the same through `Registry.key_info!/1`,
so both raise `ArgumentError` from inside `:ets`. Where Sagents caught that or
never triggered it, the answer came back as `nil`, `[]`, `false`, or `0`, which
a caller reads as **"nothing is running"** and responds to by starting an agent.
On a draining node that silently produces a second AgentServer for a
conversation that already has one elsewhere, with both holding and persisting
its state.

v0.12.0 makes the condition a first-class answer:

- `Sagents.ready?/0`: a boolean for your **readiness** check.
- `{:error, :registry_unavailable}`: from every API whose return shape can
  carry it. Deliberately distinct from `{:error, :not_running}`.
- `Sagents.RegistryUnavailableError`: raised by the APIs whose shape cannot,
  rather than answering with a plausible-looking default.

The release also hardens the case where the registry process itself fails.
`Sagents.Supervisor` now supervises `:rest_for_one` with the registry first, so
a registry failure restarts the dynamic supervisors under it. Agents register
their `:via` names once, at start, and nothing re-registers them, so a registry
that comes back empty would otherwise leave them running but invisible to every
lookup. That is the same silent-duplicate outcome by a different route.

And separately: `Sagents.Middleware.Summarization` no longer picks a cutoff that
orphans a tool result.

## Read this before you start

**This release changes library code, not the modules `mix sagents.setup`
generated into your app.** That is the opposite of the v0.11.0 migration. The
behaviour changes underneath you on `mix deps.get`, whether or not you edit a
line. Two consequences:

1. **Functions you use today can now raise.** They raise only on a node whose
   Sagents tree is down, so your tests pass and local development never sees it.
   Production sees it on every deploy.
2. **A registry crash now restarts your agents** instead of leaving them
   running-but-unfindable. Costed and deliberate; see step 6.

**The compiler will not help you, and dialyzer only barely will.** Every changed
return type is *additive*: a new `{:error, :registry_unavailable}` member in a
union. A `case` that already handles `{:error, :not_found}` still compiles; it
raises `CaseClauseError` at runtime on a draining node. If you run dialyzer, do
it now and read anything it says about the call sites in step 4; it is the only
automatic signal in this migration, and it is partial.

So this is **search-driven**. Work the steps in order and run the greps.

Nothing here is required to keep working: upgrade, change nothing, and your app
behaves as v0.11.1 did except that the failures during a drain are now named
instead of anonymous. Everything below is what turns that naming into a fix.

---

## Prerequisites

1. Start from a clean, committed workspace.
2. Update the dependency to `~> 0.12.0` and run `mix deps.get`.
3. Run `mix compile`. **It will be clean.** That is expected.
4. Note which distribution backend you run, because the drain window exists on
   both and this guide applies to both:

   ```
   grep -rn "config :sagents, :distribution" config/
   ```

---

## Migration Steps

### 1. Add a readiness endpoint, and keep liveness separate

This is the step that actually fixes anything. Everything else narrows windows
or reports failures well.

```elixir
# lib/my_app_web/controllers/health_controller.ex
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller

  # Liveness: is the BEAM up at all? Never consults Sagents.
  def alive(conn, _params), do: send_resp(conn, 200, "ok")

  # Readiness: should this node receive traffic?
  def ready(conn, _params) do
    if Sagents.ready?() do
      send_resp(conn, 200, "ok")
    else
      send_resp(conn, 503, "draining")
    end
  end
end
```

```elixir
# lib/my_app_web/router.ex
scope "/health", MyAppWeb do
  get "/alive", HealthController, :alive
  get "/ready", HealthController, :ready
end
```

Three things about that snippet are load-bearing:

- **`ready` and `alive` must not share a source.** A draining node is not
  unhealthy, and the platform's response to a failed *liveness* probe is a
  restart, which is exactly the wrong move. If you have one `/health` route
  today doing both jobs, split it.
- **The scope has no `pipe_through`.** Not the browser pipeline (a probe has no
  session and no CSRF token), and not an `:api` pipeline either: `plug :accepts,
  ["json"]` makes the route content-negotiate, and probes frequently send no
  `Accept` header at all. The probe then gets a 406 and reads the node as
  unhealthy for a reason that has nothing to do with Sagents. A bare `send_resp`
  cannot fail that way.
- **Keep it out of any authentication pipeline**, and out of any plug that
  itself touches Sagents.

If you already have a readiness endpoint, add `Sagents.ready?/0` to it rather
than adding a second one. The platform polls one URL.

---

### 2. Put `Sagents.Supervisor` before your Endpoint

```
grep -n "Sagents.Supervisor" lib/*/application.ex
```

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyAppWeb.Presence,
  Sagents.Supervisor,
  MyAppWeb.Endpoint      # after, so OTP stops it FIRST
]
```

OTP stops children in reverse order. Listed this way the Endpoint stops
accepting requests first and the registry is still alive to serve what is in
flight. Listed the other way round, the Endpoint outlives the registry and
serves the entire drain with a dead one underneath it.

This is a one-line change and most apps already have it right, because
`Sagents.Supervisor` also has to come *after* Repo and PubSub so agents can
persist state and broadcast on the way down. Both constraints point at the same
slot. Confirm it rather than assuming it.

Correct ordering narrows the window; it does not remove it. The node stays
reachable until the platform stops routing to it, which is what steps 1 and 3
are for. Do all three.

---

### 3. Give the platform time to notice

A readiness check that flips to `false` at the same instant the tree comes down
buys you nothing. The platform has to poll it, observe the change, and update
its routing table *before* shutdown proceeds.

The sequence you are building:

```
1. platform signals shutdown
2. node reports NOT ready          <-- Sagents.ready?() goes false
3. load balancer stops routing to it
4. in-flight requests finish
5. supervision tree stops           <-- registry goes away here
6. BEAM exits
```

Out of the box only 5 and 6 happen. Steps 2 through 4 are yours.

The general principle, whatever the platform: intercept the shutdown signal,
make readiness report false, wait longer than
`(readiness poll interval × unhealthy threshold)` plus your longest ordinary
request, and only then let the tree stop.

**Fly.io.** Fly sends `SIGINT` first, then `SIGTERM` after `kill_timeout`.

```toml
# fly.toml
kill_signal = "SIGINT"
kill_timeout = "45s"

[[services.http_checks]]
  path = "/health/ready"
  interval = "5s"
  timeout = "2s"
  grace_period = "10s"
```

**Kubernetes.**

```yaml
readinessProbe:
  httpGet: { path: /health/ready, port: 4000 }
  periodSeconds: 5
  failureThreshold: 2

lifecycle:
  preStop:
    exec:
      command: ["sleep", "20"]

terminationGracePeriodSeconds: 60
```

`preStop` runs before `SIGTERM` is delivered and endpoint removal happens
concurrently with it, so the sleep is what gives the mesh time to stop routing.

**On the BEAM side**, if you want the delay inside the release rather than in a
`preStop` hook, trap the signal in a small process listed **before**
`Sagents.Supervisor` in your tree. Listed there, OTP stops it last, so its
`terminate/2` runs after the Endpoint has stopped accepting and before anything
else comes down.

```elixir
defmodule MyApp.Drain do
  @moduledoc """
  Holds the shutdown open long enough for the load balancer to observe
  readiness going false and stop routing here.

  Listed before Sagents.Supervisor in the application tree, so OTP stops it
  last and this wait happens while the registry is still alive.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, Keyword.get(opts, :delay, 0)}
  end

  @impl true
  def terminate(_reason, delay) do
    Process.sleep(delay)
    :ok
  end
end
```

Configure `delay` to `0` in dev and test. A drain delay that fires on every
`Ctrl-C` is a delay you will disable in week two, and then it is not there in
production either. Also give the child a `shutdown:` timeout longer than the
delay, or the supervisor will kill it before `terminate/2` returns.

Whichever mechanism you pick, the readiness signal has to be **live** during the
wait. That is why the delay goes on this side of `Sagents.Supervisor` and not
after it.

---

### 4. Audit every call site that reads the registry

```
grep -rn "AgentServer\.\|Session\.\|AgentSupervisor\.\|ProcessRegistry\." lib/ --include="*.ex" --include="*.heex"
```

Sort what you find into the two tables below.

#### 4a. These now **raise** `Sagents.RegistryUnavailableError`

Their return shapes have no room for "cannot answer", and answering with a
plausible default is what produces the duplicate agent.

| function | used to answer on a dead registry |
| --- | --- |
| `Sagents.AgentServer.get_pid/1` | `nil` |
| `Sagents.AgentServer.get_status/1` | `:not_running` |
| `Sagents.AgentServer.get_info/1` | an `:ets` `ArgumentError` |
| `Sagents.AgentServer.get_state/1` | an `:ets` `ArgumentError` |
| `Sagents.AgentServer.get_metadata/1` | `{:error, :not_found}` |
| `Sagents.AgentServer.get_agent/1` | `{:error, :not_found}` |
| `Sagents.AgentServer.get_inactivity_status/1` | an `:ets` `ArgumentError` |
| `Sagents.AgentServer.export_state/1` | an `:ets` `ArgumentError` |
| `Sagents.AgentServer.restore_state/2` | an `:ets` `ArgumentError` |
| `Sagents.AgentServer.update_agent_and_state/3` | an `:ets` `ArgumentError` |
| `Sagents.AgentServer.running?/1` | `false` |
| `Sagents.AgentServer.agent_info/1` | `nil` |
| `Sagents.AgentServer.stop/1` | an `:ets` `ArgumentError` |
| `Sagents.Session.running?/2` | `false` |
| `Sagents.ProcessRegistry.lookup/1` | `[]` |
| `Sagents.ProcessRegistry.select/1` | `[]` |
| `Sagents.ProcessRegistry.count/0` | `0` |
| `Sagents.ProcessRegistry.keys/1` | `[]` |

> #### The `get_status/1` trap {: .warning}
>
> `AgentServer.get_status/1` reads as total. It wraps its call in
> `try/catch :exit -> :not_running`, so every call site treats it as a function
> that cannot fail. It now raises **before** reaching the call it guards, and a
> `catch :exit` clause does not catch a `raise`.
>
> This matters because `get_status/1` is the natural thing to call on a mount
> path, to seed `agent_status` and `agent_alive?`. If yours is inside a
> `try/rescue` for something else, `Ecto.NoResultsError` say, that will not
> catch it either. The symptom is a crashed mount for the whole drain window,
> from a line that looks defensive.
>
> ```
> grep -rn "get_status\|get_info(" lib/ --include="*.ex"
> ```

#### 4b. These gained `{:error, :registry_unavailable}`

| function | note |
| --- | --- |
| `Sagents.AgentServer.fetch_pid/1` | **new**; the non-raising `get_pid/1` |
| `Sagents.ProcessRegistry.fetch/1` | **new**; the non-raising `lookup/1` |
| `Sagents.AgentServer.execute/1`, `cancel/1`, `resume/2`, `add_message/3`, `reset/1`, `dismiss_interrupt/1` | |
| `Sagents.Session.start/3`, `ensure_running/3`, `resume/4`, `dismiss/3`, `stop/2` | |
| `Sagents.AgentSupervisor.get_pid/1` | alongside `{:error, :not_found}` |
| `Sagents.AgentsDynamicSupervisor.stop_agent/2` | alongside `{:error, :not_found}` |

One deliberate exception: `AgentServer.queue_message_from_tool/3` folds the
condition into its existing `{:error, :no_server}`. It runs inside tool code, which has no
better move than its fallback path, and raising out of a tool body is what that
guard exists to prevent.

#### What to change

**Anything a web request or a LiveView mount can reach** should move from the
first table to the second:

```elixir
# Before. Raises on a draining node
case AgentServer.get_pid(agent_id) do
  nil -> start_it()
  pid -> use_it(pid)
end

# After
case AgentServer.fetch_pid(agent_id) do
  {:ok, pid} -> use_it(pid)
  {:error, :not_running} -> start_it()
  {:error, :registry_unavailable} -> draining()
end
```

**Where the read is incidental to a bigger operation**, such as a mount that
loads a conversation and happens to want the agent's status, guard the whole
thing on `Sagents.ready?/0` instead of rewriting each call:

```elixir
def load_conversation(socket, conversation_id, opts) do
  if Sagents.ready?() do
    do_load_conversation(socket, conversation_id, opts)
  else
    {:error, put_flash(socket, :error, @draining_message)}
  end
end
```

That is the better shape when everything downstream needs the registry anyway.
There is nothing worth half-rendering on a node that is going away.

**Leave the raising forms in place** in tests, mix tasks, IEx helpers, and
anywhere else that runs with the supervision tree definitively up. The raise is
a diagnostic, and converting a test to `fetch_pid/1` demonstrates nothing.

---

### 5. Answer `:registry_unavailable` as its own thing

Two rules, and the first one is the whole point of the release.

**Never collapse it into "not running".**

| answer | meaning | correct response |
| --- | --- | --- |
| `{:error, :not_running}` | the registry answered; nothing is running | start an agent |
| `{:error, :registry_unavailable}` | the registry could not answer | retry elsewhere |

A catch-all that starts an agent is the failure this release exists to prevent:

```elixir
# WRONG. The catch-all swallows :registry_unavailable and starts a duplicate
case Session.ensure_running(config, assigns, request_opts: opts) do
  {:ok, changes} -> assign(socket, changes)
  {:error, _reason} -> start_a_fresh_one(socket)
end
```

**Answer 503, not 500.** A 500 says the request cannot be served. A 503 says it
cannot be served *here*, which is true, and it is the status clients and load
balancers already know how to retry.

```elixir
case Sagents.Session.ensure_running(config, assigns, request_opts: opts) do
  {:ok, changes} -> assign(socket, changes)
  {:error, :registry_unavailable} -> {:error, message: "Service is restarting, please retry", code: 503}
  {:error, reason} -> {:error, message: "Could not start session: #{inspect(reason)}"}
end
```

In a LiveView there is no status code to send, so the equivalent is separate
product copy and a separate log level. Route every session failure through one
funnel rather than adding a clause per call site:

```elixir
@draining_message "This server is restarting. Please try that again in a moment."

def flash_session_error(socket, reason, copy) do
  label = Keyword.fetch!(copy, :log_label)

  case reason do
    :registry_unavailable ->
      Logger.warning("#{label}: this node is draining, its Sagents registry is unavailable")
      put_flash(socket, :error, @draining_message)

    other ->
      Logger.error("#{label}: #{inspect(other)}")
      put_flash(socket, :error, Keyword.fetch!(copy, :user_message))
  end
end
```

Two details worth keeping:

- **`:warning`, not `:error`.** A routine deploy should not fill the log with
  alarms. An error level here trains people to ignore the one time it means
  something.
- **"Please try again" is literally accurate**, not a euphemism. Every other
  node serves the request fine, and the client's reconnect after a deploy lands
  on one of them. Telling the user something failed would be the inaccurate
  version.

Keep the log term and the user copy **separate**, for the same reason the
v0.11.0 guide gave: interpolating the reason puts internal vocabulary in front
of a person.

---

### 6. Know what a registry crash now costs

You do not wire anything up for this, but you should know it happened, because
the behaviour changed and it is visible.

`Sagents.Supervisor` supervises `:rest_for_one` with the registry first, and a
new `Sagents.RegistryWatcher` sits between the registry and its dependents. A
registry failure now restarts the agent and filesystem dynamic supervisors:
running agents on that node stop and are re-created from persisted state on the
next request.

That is heavy-handed on purpose. An `AgentSupervisor` and an `AgentServer`
register their `:via` names once, at start, and nothing re-registers them. A
registry that comes back empty underneath them leaves them running but invisible
to every lookup, so the next request reads "nothing is running" and starts a
*second* AgentServer, with both persisting the same conversation. Restarting is
recoverable; a silent duplicate is not.

On a healthy multi-node `:horde` cluster a peer would have repaired the
registry within a few hundred milliseconds, so this over-reacts. It does so
knowingly: nothing on the affected node can tell in time whether repair is
coming. A single-node deployment has no peer, and a partitioned or lagging
cluster looks identical from the inside until the window has passed.

**What to check in your app:** anything that assumed an agent stays alive
because nothing asked it to stop. A registry crash now costs the in-flight LLM
turns on that node, the same as a deploy does.

None of this touches draining. The watcher is listed after the registry, so OTP
stops it first on a normal shutdown; a draining node never looks like a registry
failure.

---

### 7. Stop treating Horde redistribution as a guarantee

**Skip this step if you run `:local`.**

Not a code change in this release, but a documented limit that is easy to have
designed against without noticing.

Horde hands a departed node's processes to a survivor only once that survivor
has converged on the departure and marked the member dead. A node that leaves
*before* convergence completes takes its agents with it. An agent running for a
couple of seconds or more is redistributed reliably; one placed immediately
before the node departs is dropped in roughly one departure in four. Graceful
(`:init.stop`) and abrupt departures behave identically.

A dropped agent is dropped **cleanly**. The registry and Horde's process CRDT
are both left empty for it, so there is no orphan and no duplicate, and the next
`Sagents.Session.ensure_running/3` starts it from persisted state.

So:

```
grep -rn "node_transferring\|node_transferred" lib/ --include="*.ex" --include="*.heex"
```

Anything that must happen has to be driven by a request, a job, or a supervisor
you control, never by an agent you assume Horde kept alive somewhere. A
background loop inside an agent, a timer that fires "later", a piece of work
handed to an agent and then forgotten: all of those need a driver that survives
the node.

Steps 1 through 3 are also what protect you here, since they stop new agents
being placed on a node that is about to leave, which is exactly the case that
loses them.

---

### 8. Summarization: nothing to change, something to re-check

`Sagents.Middleware.Summarization` picked cutoffs that could orphan a tool
result: keeping a `:tool` message whose originating assistant tool call was
summarized away. Providers reject that outright, OpenAI with "No tool call
found for function call output", so a long conversation could start failing
every turn after its first compaction. Cuts landing between consecutive results
from parallel tool calls hit the same way.

The cutoff search now rejects a point where the first kept message is a tool
result, as well as the previously-handled case of summarizing away an assistant
whose results remain on the kept side.

**Skip this if `Summarization` is not in your middleware stack.** If it is,
there is no code change, but the effect is worth knowing: the middleware is now
slightly *more* willing to summarize nothing rather than produce an invalid
transcript. If you tuned `messages_to_keep` against the old behaviour, check
that compaction still triggers where you expect.

---

### 9. Fix the tests that now fail, and add the ones that catch this

Existing tests are unlikely to fail: the registry is up in the test
environment, which is exactly why this migration has no automatic signal. Two
things that can break:

- A test asserting `Session.stop/2` returns only `{:ok, :stopped | :not_running}`,
  or `AgentSupervisor.get_pid/1` only `{:ok, pid} | {:error, :not_found}`, if
  you assert on the spec rather than the value.
- A Mimic stub of `Sagents.AgentServer` or `Sagents.ProcessRegistry` that no
  longer covers the functions the code now calls: `fetch_pid/1` in place of
  `get_pid/1`, `fetch/1` in place of `lookup/1`.

Worth adding, because they are cheap and nothing else covers the drain path:

- **The readiness endpoint answers 503 when the node cannot host agents.** Stub
  `Sagents.ready?/0` rather than stopping the real supervision tree, which would
  take every other test's agents with it.
- **The liveness endpoint answers 200 anyway.** This is the assertion that stops
  someone helpfully "fixing" the duplication by pointing both at the same
  source.
- **The readiness route needs no session and no `Accept` header.** Guards the
  pipeline decision in step 1, which is otherwise invisible until a real probe
  gets a 406.
- **Your guarded load path returns without touching the registry while
  draining.** Write it with *no* stubs for the registry-reading modules: if the
  guard regresses, the test fails on an unstubbed call rather than passing
  quietly.
- **Your error funnel shows retry copy for `:registry_unavailable`** and never
  interpolates a raw reason term into user-facing text.

---

## Verifying the migration

The compiler cannot confirm any of this. Check it by hand.

**The registry-gone path**, without deploying anything:

```elixir
# in IEx, on a running app
Sagents.ready?()
# => true

Supervisor.terminate_child(MyApp.Supervisor, Sagents.Supervisor)

Sagents.ready?()
# => false
```

With the tree down, hit the app:

1. `GET /health/ready` answers **503**; `GET /health/alive` answers **200**.
2. Open a conversation. You get your draining copy, not a crashed mount and not
   a 500.
3. Send a message. Same: retryable copy, and the log shows a **warning**, not an
   error.

Then put it back:

```elixir
Supervisor.restart_child(MyApp.Supervisor, Sagents.Supervisor)
Sagents.ready?()
# => true
```

and confirm the app works normally again.

**The drain sequence**, on your real platform: deploy, and poll `/health/ready`
throughout. If it is still answering 200 at the moment agent requests start
failing, steps 1 through 3 are not wired correctly. That gap is the entire bug.

**The registry-crash path**, if you want to see step 6:

```elixir
Process.exit(Process.whereis(Sagents.Registry), :kill)
```

The dynamic supervisors restart with it, running agents on that node stop, and
the next request re-creates them from persisted state. `Sagents.ready?/0` should
be back to `true` within milliseconds.

---

## Recommended approach for generated files

Unlike v0.11.0, there is nothing to re-generate: `mix sagents.setup` templates
did not change in this release. Every step above is host code: your
application module, your router, your controllers, your LiveViews, your
deployment config.

If you skip everything else, do step 1. A readiness endpoint on its own converts
the failure from "every request during every deploy fails on this node" to
"traffic goes somewhere that works". Steps 4 and 5 make the requests that still
slip through report themselves honestly.
