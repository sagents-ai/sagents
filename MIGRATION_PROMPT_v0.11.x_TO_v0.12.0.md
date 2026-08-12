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
drain, and it is **local**: the node that replaces this one serves the same
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

**This release changes library code and the `mix sagents.setup` templates.** The
library behaviour changes underneath you on `mix deps.get`, whether or not you
edit a line. The template change does *not* reach your app, because generated
modules are your copies; step 2 is the patch you apply by hand.

Two things change under you with no action on your part:

1. **Functions you use today can now raise.** They raise only on a node whose
   Sagents tree is down, so your tests pass and local development never sees it.
   Production sees it on every deploy.
2. **A registry crash now restarts that node's agents** instead of leaving them
   running-but-unfindable. Costed and deliberate; see step 5.

**The compiler will not help you, and dialyzer only barely will.** Every changed
return type is *additive*: a new `{:error, :registry_unavailable}` member in a
union. A `case` that already handles `{:error, :not_found}` still compiles; it
raises `CaseClauseError` at runtime on a draining node. If you run dialyzer, do
it now and read anything it says about the call sites in step 3. It is the only
automatic signal in this migration, and it is partial.

So this is **search-driven**. Work the steps in order and run the greps.

Nothing here is required to keep working: upgrade, change nothing, and your app
behaves as v0.11.1 did except that the failures during a drain are now named
instead of anonymous. Everything below is what turns that naming into a fix.

### If you run a single machine

Most of this guide talks about a cluster, because that is where the failure is
easiest to describe. **It applies to a single-machine deployment too, and the
reasoning barely changes.** A rolling deploy still has a *new* machine coming up
to take traffic, so "route this request somewhere else" is still what has to
happen; it just happens across the deploy rather than across the cluster. "Try
again in a moment" is still literally accurate for a client reconnecting after
the swap.

What a single-machine deployment loses is only step 6, which is Horde-specific.

---

## Prerequisites

1. Start from a clean, committed workspace.
2. Update the dependency to `~> 0.12.0` and run `mix deps.get`.
3. Run `mix compile`. **It will be clean.** That is expected.
4. Note your distribution backend:

   ```
   grep -rn "config :sagents, :distribution" config/
   ```

   **No output means the default, `:local`.** The drain window exists on both
   backends and every step except 6 applies to both.

5. Find your generated modules. They are wherever `mix sagents.setup` put them;
   the default names are `AgentLiveHelpers`, `Coordinator`, and
   `AgentSubscriberSession`:

   ```
   grep -rln "Sagents.Session\|Sagents.Subscriber\|Sagents.AgentUtils" lib/ --include="*.ex"
   ```

---

## Migration Steps

### 1. Make the platform stop routing here before the tree comes down

This is one mechanism with five parts, and **most of them on their own do
nothing.** Read the whole step before implementing any of it.

The sequence you are building:

```
1. platform signals shutdown
2. node reports NOT ready          <-- the drain flag flips here
3. load balancer stops routing to it
4. in-flight requests finish
5. supervision tree stops           <-- Sagents.ready?/0 goes false here
6. BEAM exits
```

Out of the box only 5 and 6 happen. Note where the two signals sit: a readiness
check wired to `Sagents.ready?/0` **alone** first reports 503 at step 5, which is
after the load balancer needed it at step 2. That endpoint answers 200 for the
entire drain and then starts failing requests at the same instant it starts
reporting unhealthy. It is worse than nothing, because it looks finished.

So the readiness endpoint needs two sources: a flag you set at step 2, and
`Sagents.ready?/0` for every other way the tree can be down (still booting,
crashed, restarting).

**1a. A drain process that owns the flag.**

```elixir
defmodule MyApp.Drain do
  @moduledoc """
  Holds shutdown open long enough for the load balancer to observe readiness
  going false and stop routing here.

  Listed LAST in the application tree. OTP stops children in reverse order, so
  last means `terminate/2` runs first, while the Endpoint is still serving and
  can still answer the readiness probe. Any earlier position and the sleep
  happens behind a stopped listener, where nothing can observe it.
  """
  use GenServer

  require Logger

  @flag {__MODULE__, :draining?}

  @doc "Whether this node has begun shutting down. Safe to call from a request."
  def draining?, do: :persistent_term.get(@flag, false)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    delay = Keyword.get(opts, :delay, 0)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[delay: delay]]},
      # Must exceed the delay, or the supervisor brutal-kills this process
      # partway through terminate/2 and the drain silently does not happen.
      shutdown: delay + :timer.seconds(5)
    }
  end

  @impl true
  def init(opts) do
    # Without this, terminate/2 is not called on supervisor shutdown at all.
    Process.flag(:trap_exit, true)
    :persistent_term.put(@flag, false)
    {:ok, Keyword.get(opts, :delay, 0)}
  end

  @impl true
  def terminate(_reason, delay) do
    :persistent_term.put(@flag, true)
    Logger.info("draining: readiness is now false, waiting #{delay}ms before shutdown")
    Process.sleep(delay)
    :ok
  end
end
```

Two details that are easy to get wrong and hard to notice:

- **The flag must be readable without talking to this process.** During
  `terminate/2` the GenServer is out of its receive loop, so a
  `GenServer.call(MyApp.Drain, :draining?)` from the readiness endpoint blocks
  for the whole sleep and then exits when the process dies. `:persistent_term`
  (or ETS, or `Application.put_env`) is read directly by the caller. A single
  write at shutdown is a fine use of `:persistent_term`.
- **Configure `delay: 0` in dev and test.** A drain delay that fires on every
  `Ctrl-C` is a delay you will disable in week two, and then it is not there in
  production either.

**1b. The readiness endpoint, reading both sources.**

```elixir
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller

  # Liveness: is the BEAM up at all? Never consults Sagents or the drain flag,
  # because a draining node is not an unhealthy one. On platforms that restart
  # on liveness failure (Kubernetes) a restart is exactly the wrong move; on
  # platforms that never act on it (Fly) this is the signal that separates
  # "draining normally" (alive 200, ready 503) from "wedged" (both failing).
  def alive(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  # Readiness: should this node receive traffic?
  def ready(conn, _params) do
    {status, body} =
      if MyApp.Drain.draining?() or not Sagents.ready?() do
        {503, "draining"}
      else
        {200, "ok"}
      end

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
```

`put_resp_content_type/2` is not decoration: without it `send_resp/3` sets no
content type, and `text_response(conn, 200)` in your tests raises
`no content-type was set, expected a text response`.

```elixir
# lib/my_app_web/router.ex
scope "/health", MyAppWeb do
  get "/alive", HealthController, :alive
  get "/ready", HealthController, :ready
end
```

**The scope has no `pipe_through`** on purpose. Not the browser pipeline (a
probe has no session and no CSRF token), and not an `:api` pipeline either:
`plug :accepts, ["json"]` makes the route content-negotiate, and probes
frequently send no `Accept` header at all. The probe then gets a 406 and reads
the node as unhealthy for a reason that has nothing to do with Sagents.

**1c. Audit `endpoint.ex` for plugs that can halt or redirect.**

Anything above the router that can `halt` will eat the probe, and two of them
are standard production furniture. Both are invisible in dev and test, because
both are prod-only config: the same failure mode as the migration itself.

```
grep -n "force_ssl\|plug " config/runtime.exs config/prod.exs lib/*_web/endpoint.ex
```

- **`force_ssl`.** Probes reach the machine over plain HTTP on the internal
  network, with no `x-forwarded-proto` for `rewrite_on` to read, so `Plug.SSL`
  answers with a 301 and the readiness endpoint never runs.
- **A canonical-host or www-redirect plug.** Same shape: the probe arrives on an
  internal address, not the canonical hostname, and gets 301'd.

The exclusion for `force_ssl`, with two traps in it:

```elixir
force_ssl: [
  rewrite_on: [:x_forwarded_proto],
  exclude: [
    # Repeating the defaults is required. Passing any :exclude value replaces
    # Plug.SSL's default [hosts: ["localhost", "127.0.0.1"]] entirely.
    hosts: ["localhost", "127.0.0.1"],
    # Exact full-path matches, not prefixes. `paths: ["/health"]` does NOT
    # cover "/health/ready": Plug.SSL compares conn.path_info for equality.
    # The Phoenix production template ships `# paths: ["/health"]` commented
    # out, which is why this is worth spelling out.
    paths: ["/health/alive", "/health/ready"]
  ]
]
```

**1d. Supervision tree order.**

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyAppWeb.Presence,
  Sagents.Supervisor,     # after Repo/PubSub, so agents can persist on the way down
  MyAppWeb.Endpoint,      # after Sagents, so OTP stops the listener FIRST
  {MyApp.Drain, delay: drain_delay()}   # LAST, so it stops FIRST
]
```

with the delay coming from config, so 1a's "zero in dev and test" has somewhere
to live:

```elixir
# same module as start/2
defp drain_delay, do: Application.get_env(:my_app, :drain_delay_ms, 0)
```

```elixir
# config/runtime.exs, prod only
config :my_app, drain_delay_ms: 20_000
```

Reverse shutdown order is what makes all three positions correct at once. Trace
it: `Drain` → `Endpoint` → `Sagents.Supervisor` → `PubSub` → `Repo`. The drain
sleeps while the listener is still up, then the listener stops, then the
registry, then the things agents needed in order to persist themselves.

**1e. Tell the platform to poll it.**

Whatever the platform, size the wait as
`(readiness poll interval × unhealthy threshold)` plus your longest ordinary
request, and make the platform's hard kill deadline exceed that.

> #### The signal that reaches the BEAM must be SIGTERM {: .warning}
>
> Everything in this step, and every `terminate/2` in your tree including the
> one that persists agent state, hangs off OTP calling `init:stop()`. Only
> **SIGTERM** produces that. OTP's default `erl_signal_handler` maps `sigterm`
> to `init:stop()`; `sigquit` and `sigusr1` map to `erlang:halt/0,1`, which is
> immediate and graceless; and **`sigint` matches none of its clauses**, falling
> through to a no-op. What SIGINT actually reaches is the BEAM's break handler.
>
> The observable difference on a release started with `bin/my_app start`, which
> runs `elixir --no-halt`:
>
> | signal | `terminate/2` runs? | result |
> | --- | --- | --- |
> | `SIGTERM` | yes, with `reason: :shutdown` | drain waits, state persists, agents broadcast shutdown |
> | `SIGINT` | **no** | break handler; the node either sits until SIGKILL or halts outright |
>
> So under SIGINT there is no drain, no readiness flip, and **no agent state
> persisted**. `Sagents.AgentServer.terminate/2` is what saves it, so every deploy
> would silently lose the in-flight turn on every conversation.
>
> A stock Phoenix deployment usually has this right already, which is the reason
> to know it: it is a line nobody thinks about, so it is a line that gets
> "simplified" away. The places it actually goes wrong are a hand-written
> platform config, a `CMD` that puts a shell at PID 1 (below), and process
> managers that send something other than SIGTERM.

**Fly.io.** Fly sends the configured `kill_signal`, waits `kill_timeout`, then
sends **`SIGKILL`**. Nothing happens in between, so `kill_timeout` is not a stage
in a graceful sequence: it is the hard deadline before the machine dies
mid-drain, and it must exceed your drain delay.

`fly launch` detects an Elixir project and generates `kill_signal = "SIGTERM"`,
so this is normally already right. Confirm the line rather than assuming it,
since everything in this step depends on it:

```toml
# fly.toml. Use this form if your file has [http_service], which is what
# `fly launch` has generated for years.
kill_signal = "SIGTERM"   # confirm this is present and says SIGTERM
kill_timeout = "45s"      # hard deadline before SIGKILL; must exceed the drain

# Readiness. This is the check that changes routing, so this is the one that
# makes the drain do anything at all.
[[http_service.checks]]
  path = "/health/ready"
  interval = "5s"
  timeout = "2s"
  grace_period = "10s"
```

> #### `checks` and `http_checks` are not interchangeable {: .warning}
>
> There are **two** independent axes here and they do not vary together. The
> *format* (`[http_service]` and `[[services]]`, which are mutually exclusive)
> and the *sub-key*, which is spelled differently under each. `flyctl` decodes
> the two from separate struct fields, so only two of the four combinations
> exist:
>
> | table | result |
> | --- | --- |
> | `[[http_service.checks]]` | correct for the `[http_service]` format |
> | `[[http_service.http_checks]]` | **decoded into nothing** |
> | `[[services.http_checks]]` | correct for the older `[[services]]` format |
> | `[[services.checks]]` | **decoded into nothing** |
>
> Getting the sub-key wrong does not give you a degraded check, it gives you
> **no check at all**, and readiness is the entire mechanism by which the drain
> does anything. Fly Proxy is never told to stop routing, so the node keeps
> taking new requests for the whole delay and the endpoint still closes
> underneath whatever is in flight: exactly the failure this step exists to
> prevent, now with 20 extra seconds added to every machine stop.
>
> Nothing in the file or in `fly config validate` will tell you. Confirm it
> against the platform with `fly checks list`. See step 8.

**Wire the liveness endpoint too**, or the endpoint step 1b just had you write is
unreachable. On Fly this is not the readiness block with a different path: a
liveness check belongs in the **top-level `[checks]` section**, a different shape
that needs a unique name, an explicit `port`, and an explicit `type`.

```toml
# Top-level checks do NOT affect routing, and Fly never restarts or stops a
# machine over a failed check. This exists so `fly status` / `fly checks list`
# can separate a node draining normally from one that is wedged.
[checks]
  [checks.alive]
    type = 'http'
    port = 8080          # your internal_port; must be bound on 0.0.0.0
    path = '/health/alive'
    method = 'get'
    interval = '15s'
    timeout = '5s'
    grace_period = '30s' # must cover boot
```

Do not put `/health/alive` in `[[http_service.checks]]` instead. That section
governs routing, and an endpoint that always answers 200 tells the proxy nothing
while adding a check every deploy has to wait on.

**Kubernetes.** Sends `SIGTERM` already, so there is no signal to change.

```yaml
readinessProbe:
  httpGet: { path: /health/ready, port: 4000 }
  periodSeconds: 5
  failureThreshold: 2

# Both endpoints, or the liveness half of step 1b is wired to nothing. Unlike
# Fly, Kubernetes does act on this one: keep the drain flag out of it, or the
# kubelet restarts the pod you are trying to drain.
livenessProbe:
  httpGet: { path: /health/alive, port: 4000 }
  periodSeconds: 15
  failureThreshold: 3

terminationGracePeriodSeconds: 60
```

**Either platform: check the signal actually reaches the BEAM.** A shell-form
`CMD /app/bin/server` makes `/bin/sh` PID 1, and it does not forward SIGTERM to
its child, so the BEAM never sees the signal and is SIGKILLed at the deadline
with nothing having run. Use the exec form, which is what the generated Phoenix
Dockerfile ships:

```dockerfile
CMD ["/app/bin/server"]
```

With `MyApp.Drain` in the tree you do not also need a `preStop` sleep;
`terminationGracePeriodSeconds` must exceed the drain delay plus your longest
request. If you would rather keep the wait outside the BEAM, drop `MyApp.Drain`,
use `lifecycle.preStop.exec.command: ["sleep", "20"]`, and accept that readiness
then has only `Sagents.ready?/0` to report, which is too late. Prefer the
in-BEAM flag.

---

### 2. Patch your generated `AgentLiveHelpers`

**Do not skip this because your compile is clean.** Every application generated
by `mix sagents.setup` ships this defect, and it is the release's own headline
trap sitting in code you did not write.

`load_conversation/3` calls `AgentServer.get_status/1` and
`AgentServer.get_info/1` inside a `try ... rescue Ecto.NoResultsError`. Both now
raise `Sagents.RegistryUnavailableError`, which that `rescue` does not catch. The
symptom is a **crashed LiveView mount for the entire drain window of every
deploy**, from a function that reads as defensive.

Re-running the generator is not the fix. That file is meant to be customized, so
you have customized it. Apply this by hand:

```elixir
# Before
def load_conversation(socket, conversation_id, opts) do
  scope = Keyword.fetch!(opts, :scope)
  # ... whole body ...
end

# After. The body moves unchanged into a private function
@draining_message "This server is restarting. Please try that again in a moment."

def load_conversation(socket, conversation_id, opts) do
  if Sagents.ready?() do
    do_load_conversation(socket, conversation_id, opts)
  else
    Logger.warning(
      "Refusing to load conversation #{inspect(conversation_id)}: " <>
        "this node is draining, its Sagents registry is unavailable"
    )

    {:error, put_flash(socket, :error, @draining_message)}
  end
end

defp do_load_conversation(socket, conversation_id, opts) do
  scope = Keyword.fetch!(opts, :scope)
  # ... whole body, unchanged ...
end
```

Guard the whole function rather than converting each call. Everything in the
body needs the registry (the status read, the subscribe, the auto-wake), so
there is nothing worth half-rendering on a node that is going away.

Your caller already handles `{:error, socket}` for the not-found case, so no
call site changes. Reword `@draining_message` for your product.

> #### The `get_status/1` trap, stated once {: .warning}
>
> `AgentServer.get_status/1` reads as total. It wraps its call in
> `try/catch :exit -> :not_running`, so every call site treats it as a function
> that cannot fail. It now raises **before** reaching the call it guards, and a
> `catch :exit` clause does not catch a `raise`.
>
> The generated helper is where you will meet it, but check your own code too:
>
> ```
> grep -rn "get_status\|get_info(" lib/ --include="*.ex"
> ```

---

### 3. Audit every call site that reads the registry

```
grep -rn "\bSagents\.\|AgentServer\.\|\bSession\.\|AgentSupervisor\.\|ProcessRegistry\." lib/ --include="*.ex" --include="*.heex"
```

> #### That grep misses your Coordinator's callers {: .warning}
>
> `mix sagents.setup` generates a `Coordinator` that wraps `Sagents.Session`,
> and its own moduledoc tells you to call the wrapper rather than
> `Sagents.Session` directly. So the grep finds `coordinator.ex` and **misses
> every caller that must learn the new error**: `ensure_agent_session_running`
> contains no `Session.`.
>
> Grep for your wrapper's function names too:
>
> ```
> grep -rn "ensure_agent_session_running\|resume_agent_session\|dismiss_agent_session\|stop_conversation_session\|session_running?" lib/ --include="*.ex" --include="*.heex"
> ```

#### Classify what you find by resolution path

Rather than checking a function against a list, check **how it reaches the
registry**. This table is short, checkable against the source, and it classifies
functions this guide has not thought of:

| how it reaches the registry | behaviour on a dead registry |
| --- | --- |
| `GenServer.cast` on a `:via` tuple | **safe.** Elixir wraps `cast` in `try … catch _, _ -> :ok`, which swallows the `ArgumentError` too. `touch/1`, `publish_event_from/2`, `save_synthetic_message_from/2` silently no-op |
| `GenServer.call` on a `:via` tuple | **raises.** `catch :exit` does not catch a raise |
| explicit `get_pid/1`, `whereis/1`, `lookup/1`, `select/1`, `count/0`, `keys/1` | **raises** `Sagents.RegistryUnavailableError` |
| explicit `fetch_pid/1`, `fetch/1`, `fetch_running/2` | `{:error, :registry_unavailable}` |

The `cast` / `call` asymmetry is why a function's signature tells you nothing
here. Same via tuple, same dead registry, opposite outcome.

#### The functions that raise

`AgentServer`: `get_pid/1`, `get_status/1`, `get_info/1`, `get_state/1`,
`get_metadata/1`, `get_agent/1`, `get_inactivity_status/1`, `export_state/1`,
`restore_state/2`, `update_agent_and_state/3`, `running?/1`, `agent_info/1`,
`stop/1`.

`Session`: `running?/2`.

`FileSystem`: `filesystem_running?/1`, `list_filesystems/0`.
`FileSystemServer`: `whereis/1`.

`ProcessRegistry`: `lookup/1`, `select/1`, `count/0`, `keys/1`.

`SubAgentServer`: `whereis/1`. `SubAgentsDynamicSupervisor`: `whereis/1`.
`AgentsDynamicSupervisor`: `list_agents/1`. These three are documented as
raising for completeness; every caller runs inside an agent turn, where the
agent's own registration means the condition cannot arise.

#### The functions that gained `{:error, :registry_unavailable}`

`AgentServer`: `fetch_pid/1` **(new)**, `execute/1`, `cancel/1`, `resume/2`,
`add_message/3`, `reset/1`, `dismiss_interrupt/1`, `subscribe/3`.

`Session`: `start/3`, `ensure_running/3`, `resume/4`, `dismiss/3`, `stop/2`,
`fetch_running/2` **(new)**.

`FileSystem`: `ensure_filesystem/3`, `stop_filesystem/2`, `get_filesystem_pid/1`,
`fetch_filesystem_running/1` **(new)**.

`ProcessRegistry`: `fetch/1` **(new)**.
`FileSystemServer`: `fetch_pid/1` **(new)**.
`AgentSupervisor`: `get_pid/1`. `AgentsDynamicSupervisor`: `stop_agent/2`.

> #### Do not skip the filesystem layer because it looks incidental {: .warning}
>
> `Sagents.FileSystem` gets read as one function when it is a whole module of
> them, and its calls sit in the least suspicious place: best-effort cleanup,
> where the return is usually discarded.
>
> ```elixir
> Sagents.FileSystem.stop_filesystem({:project, project.id})
> Repo.transaction(delete_everything(project))
> ```
>
> Discarding it there is fine, and remains fine. What is worth checking on this
> layer is the other two shapes:
>
> - **A catch-all that logs.** `{:error, :registry_unavailable}` reaching an
>   `{:error, reason} -> Logger.error(...)` clause turns every deploy into an
>   alarm for a condition that is not a fault. Give it the step 4 treatment.
> - **`ensure_filesystem/3` returning the error.** It deliberately does not start
>   a filesystem it could not first check for, because this node cannot see
>   whether one already exists elsewhere. A caller that treats any error as
>   "start failed, carry on degraded" is making a different decision than the
>   one that was reported.

> **The not-found atom differs by layer.** `AgentServer.fetch_pid/1` and
> `FileSystemServer.fetch_pid/1` answer `{:error, :not_running}`;
> `ProcessRegistry.fetch/1` answers `{:error, :not_registered}`; the supervisor
> layer (`AgentSupervisor.get_pid/1`, `FileSystem.get_filesystem_pid/1`) answers
> `{:error, :not_found}`. Only `:registry_unavailable` is spelled the same
> everywhere. Copying a `case` shape across layers gives you a `CaseClauseError`
> on the drain path, which is the one path with no test coverage.

Three functions deliberately swallow the condition rather than reporting it,
because the caller has no possible response: `AgentServer.notify_middleware/3`
logs and returns `:ok`, `AgentServer.unsubscribe/3` returns `:ok`, and
`AgentServer.queue_message_from_tool/3` folds it into its existing
`{:error, :no_server}`. Raising out of a tool body or a fire-and-forget push
would be worse than dropping the message.

The subscription layer (`Sagents.Subscriber`) records an entry it cannot
subscribe as `:pending` and moves on, including when the reason is an
unavailable registry. That is safe here specifically because **nothing starts a
producer off the back of a pending entry**. The dangerous conflation is
"cannot answer" read as "nothing is running" by a caller whose response is to
start one. A pending subscription just waits for the next presence diff.

#### What to change

**Anything a web request or a LiveView mount can reach** moves to the
tuple-returning form:

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

**Where the read is incidental to a bigger operation**, guard the whole thing on
`Sagents.ready?/0` instead, as step 2 does.

**Check every discarded return.** This is new: these functions could not fail
this way before, so ignoring the result was harmless.

```
grep -rn "AgentServer.add_message\|AgentServer.execute\|AgentServer.resume" lib/ --include="*.ex"
```

An `add_message/3` whose return is discarded used to be fine. Now
`{:error, :registry_unavailable}` leaves the UI at `loading: true` with nothing
ever arriving to clear it: a spinner that never resolves, indistinguishable from
a slow model. **The newly-possible error turns a discarded return into a hang
rather than a no-op.**

**Leave the raising forms in place** in tests, mix tasks, IEx helpers, and
anywhere else that runs with the supervision tree definitively up. The raise is
a diagnostic, and converting a test to `fetch_pid/1` demonstrates nothing.

**If you wrapped a raising predicate**, carry the warning into your wrapper's
docs. `Coordinator.session_running?/1` is a public function whose name is the
least likely thing in your API to be suspected of raising, and the wrapper is
where the next reader meets it. `Session.fetch_running/2` (and the generated
`Coordinator.fetch_session_running/1`) is the non-raising form if you would
rather not have the landmine at all.

---

### 4. Answer `:registry_unavailable` as its own thing

Two rules, and the first one is the whole point of the release.

**Never collapse it into "not running".**

| answer | meaning | correct response |
| --- | --- | --- |
| `{:error, :not_running}` | the registry answered; nothing is running | start an agent |
| `{:error, :registry_unavailable}` | the registry could not answer | retry elsewhere |

A catch-all that starts an agent is the failure this release exists to prevent:

```elixir
# WRONG. The catch-all swallows :registry_unavailable and starts a duplicate
case Coordinator.ensure_agent_session_running(socket.assigns, opts) do
  {:ok, changes} -> assign(socket, changes)
  {:error, _reason} -> put_flash(socket, :error, "Failed to start. Please try again.")
end
```

**Answer 503, not 500.** A 500 says the request cannot be served. A 503 says it
cannot be served *here*, which is true, and it is the status clients and load
balancers already know how to retry.

In a LiveView there is no status code to send, so the equivalent is separate
product copy and a separate log level. Route every session failure through one
funnel rather than adding a clause per call site. The v0.12.0 `AgentLiveHelpers`
template ships this as `flash_session_error/3`; if yours predates that, add it:

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

Three details worth keeping:

- **`:warning`, not `:error`.** A routine deploy should not fill the log with
  alarms. An error level here trains people to ignore the one time it means
  something.
- **"Please try again" is literally accurate**, not a euphemism. The node that
  replaces this one serves the request fine, and the client's reconnect after a
  deploy lands there.
- **Keep the log term and the user copy separate.** Never interpolate the reason
  into the flash. A live-but-wrong-state agent returns "Cannot resume, server is
  not interrupted": an internal string, and one that says "agent", a word many
  products deliberately never put in front of a user.

Both rules existed before this release. What makes them load-bearing now is that
the drain path is **the only failure a healthy production system produces
routinely**, so a raw term in a flash is no longer a rare-path wart.

---

### 5. Know what a registry crash now costs

You wire nothing up for this, but the behaviour changed and it is visible.

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

On a healthy multi-node `:horde` cluster a peer would have repaired the registry
within a few hundred milliseconds, so this over-reacts. It does so knowingly:
nothing on the affected node can tell in time whether repair is coming. A
single-node deployment has no peer, and a partitioned or lagging cluster looks
identical from the inside until the window has passed.

**What to check in your app:** anything that assumed an agent stays alive because
nothing asked it to stop. A registry crash now costs the in-flight LLM turns on
that node, the same as a deploy does.

None of this touches draining. The watcher is listed after the registry, so OTP
stops it first on a normal shutdown; a draining node never looks like a registry
failure.

---

### 6. Stop treating Horde redistribution as a guarantee

**Skip this step if you run `:local`.**

Not a code change in this release: a documented limit that is easy to have
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

```
grep -rn "node_transferring\|node_transferred" lib/ --include="*.ex" --include="*.heex"
```

Anything that must happen has to be driven by a request, a job, or a supervisor
you control, never by an agent you assume Horde kept alive somewhere. A
background loop inside an agent, a timer that fires "later", a piece of work
handed to an agent and then forgotten: all of those need a driver that survives
the node.

Step 1 is also what protects you here, since it stops new agents being placed on
a node that is about to leave, which is exactly the case that loses them.

---

### 7. Summarization: nothing to change, something to re-check

`Sagents.Middleware.Summarization` picked cutoffs that could orphan a tool
result: keeping a `:tool` message whose originating assistant tool call was
summarized away. Providers reject that outright, OpenAI with "No tool call found
for function call output", so a long conversation could start failing every turn
after its first compaction. Cuts landing between consecutive results from
parallel tool calls hit the same way.

The cutoff search now rejects a point where the first kept message is a tool
result, as well as the previously-handled case of summarizing away an assistant
whose results remain on the kept side.

**Skip this if `Summarization` is not in your middleware stack.** If it is,
there is no code change, but the middleware is now slightly *more* willing to
summarize nothing rather than produce an invalid transcript. If you tuned
`messages_to_keep` against the old behaviour, check that compaction still
triggers where you expect.

---

### 8. Fix the tests that now fail, and add the ones that catch this

Existing tests are unlikely to fail: the registry is up in the test environment,
which is exactly why this migration has no automatic signal. Two things that can
break:

- A test asserting `Session.stop/2` returns only
  `{:ok, :stopped | :not_running}`, or `AgentSupervisor.get_pid/1` only
  `{:ok, pid} | {:error, :not_found}`, if you assert on the spec rather than the
  value.
- A Mimic stub of `Sagents.AgentServer` or `Sagents.ProcessRegistry` that no
  longer covers the functions the code now calls: `fetch_pid/1` in place of
  `get_pid/1`, `fetch/1` in place of `lookup/1`.

Worth adding, because they are cheap and nothing else covers the drain path:

- **Readiness answers 503 when the node is draining, and 200 otherwise.** Stub
  `Sagents.ready?/0` rather than stopping the real supervision tree, which would
  take every other test's agents with it. Stubbing needs the module registered
  first: add `Mimic.copy(Sagents)` to `test_helper.exs`. Cover the drain flag
  too, since that is the source that fires first in production.
- **Liveness answers 200 anyway.** This is the assertion that stops someone
  helpfully "fixing" the duplication by pointing both at the same source.
- **The readiness route needs no session and no `Accept` header.** Guards the
  pipeline decision in step 1b, which is otherwise invisible until a real probe
  gets a 406. Assert with `response/2`, or add
  `put_resp_content_type("text/plain")` so `text_response/2` works.
- **Your guarded `load_conversation/3` returns without touching the registry
  while draining.** Write it with *no* stubs for the registry-reading modules: if
  the guard regresses, the test fails on an unstubbed call rather than passing
  quietly.
- **Your error funnel shows retry copy for `:registry_unavailable`** and never
  interpolates a raw reason term into user-facing text. Assert against an
  accessor, not the literal: the v0.12.0 template exposes `draining_message/0`
  for this. A test pinned to the string keeps passing through the rewording the
  template explicitly invites, and the property worth stating is that the
  draining copy and the ordinary-failure copy **differ**, which two literal
  assertions cannot say.

> #### Stubbing `ready?/0` tests your guard, not the thing it guards {: .warning}
>
> Worth knowing before you write these, because such a test passes either way
> and looks like coverage.
>
> The registry is genuinely **up** in your test environment. So a test of step
> 2's guard that stubs only `Sagents.ready?/0`:
>
> ```elixir
> stub(Sagents, :ready?, fn -> false end)
> assert {:error, _socket} = AgentLiveHelpers.load_conversation(socket, id, scope: scope)
> ```
>
> takes the `false` branch and passes. Delete the guard and it *still* passes,
> because `AgentServer.get_status/1` answers normally against a live registry.
> The test proves a branch exists; it proves nothing about the raise the branch
> is there to avoid.
>
> Two ways to get a test with teeth:
>
> - Leave the registry-reading modules **unstubbed**, so a regressed guard fails
>   on a real call rather than passing quietly. That is the point of the
>   `load_conversation/3` suggestion above.
> - Or stub the guarded call itself to raise `Sagents.RegistryUnavailableError`,
>   and assert the surrounding operation still completes. Where the call is
>   incidental to a larger operation, that is the assertion that matters: not
>   "nothing raised" but "the delete still landed".
>
> The general form: **if deleting the code under test leaves the test green, the
> test is describing your control flow rather than the failure.**

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
4. Leave a LiveView open and start an agent from another session. Nothing
   crashes. This exercises the presence-diff path, which a host never calls
   directly and cannot find by grepping its own code.

Then put it back and confirm normal operation:

```elixir
Supervisor.restart_child(MyApp.Supervisor, Sagents.Supervisor)
Sagents.ready?()
# => true
```

**The drain flag**, which is the part that actually stops the load balancer.
With the tree fully up:

```elixir
MyApp.Drain.draining?()
# => false
```

and `/health/ready` still 200. That confirms the two sources are wired
independently rather than one shadowing the other.

**The signal path**, which everything else in step 1 depends on. Locally, against
a built release:

```
bin/my_app start &
kill -TERM <pid>
```

The log must show `SIGTERM received - shutting down` followed by your drain's own
line. If you see neither, or the process lingers, the BEAM is not getting
SIGTERM: check `kill_signal` and the `CMD` form. Repeat with `kill -INT` to see
the difference for yourself; `terminate/2` will not run at all.

**The drain sequence**, on your real platform: deploy, and poll `/health/ready`
throughout. It must report 503 **before** agent requests start failing. If it is
still answering 200 at the moment they do, step 1 is not wired correctly, and
that gap is the entire bug.

Also check your probe is not being redirected:

```
curl -sS -o /dev/null -w '%{http_code}\n' http://<internal-address>/health/ready
```

A `301` means step 1c is not done, and no amount of correct readiness logic will
help.

**Confirm the platform is actually asking.** Everything above talks to the app,
and the app can be perfectly healthy while the platform has been told to poll
nothing. Those are independent failures, and a misspelled check sub-key produces
the second while passing every test of the first:

```bash
fly checks list -a <app>     # must list your checks. An empty table means the
                             # key decoded into nothing
kubectl describe pod <pod>   # the Liveness:/Readiness: lines, same question
```

Do not substitute `fly config validate` for this. It reports
`Configuration is valid` for a file containing sections and keys `flyctl` does
not recognize: it confirms well-formed TOML, not that Fly understood any
particular line. `flyctl` does ship a stricter reflective check, but
`config validate` is not it.

**The curl proves your app answers; `fly checks list` proves the platform is
asking.** You need both.

**The registry-crash path**, if you want to see step 5:

```elixir
Process.exit(Process.whereis(Sagents.Registry), :kill)
```

The dynamic supervisors restart with it, running agents on that node stop, and
the next request re-creates them from persisted state. `Sagents.ready?/0` should
be back to `true` within milliseconds.

---

## Recommended approach for generated files

Step 2 changes the `AgentLiveHelpers` template. The v0.12.0 template also adds
`flash_session_error/3`, a `@draining_message` and a `draining_message/0`
accessor for testing it, and the `Coordinator` template adds
`fetch_session_running/1` plus a raise warning on `session_running?/1`.

**Re-running `mix sagents.setup` is not the recommended route.** These files are
meant to be customized and you have customized them. Apply step 2's diff by hand
and take `flash_session_error/3` from step 4 if you want it. If your generated
modules are genuinely stock, re-generating and diffing your changes back in
works, but check the result against step 2 either way.

Steps 1, 3 and 8 are host code and host tests, which no template covers.

If you skip everything else, do **step 1 in full**. Not step 1b alone: a
readiness endpoint reading only `Sagents.ready?/0` first reports 503 at the
moment the registry dies, which is after the load balancer needed to know. The
flag, the endpoint, the plug audit, the tree order and the platform config are
one mechanism, and most of it does nothing on its own.
