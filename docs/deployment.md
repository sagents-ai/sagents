# Deployments, draining, and readiness

This guide covers what has to happen when a node goes away: a rolling deploy, a
scale-down, a machine migration, a restart. It applies to `:local` and `:horde`
alike, and it matters more the more nodes you run.

The short version:

> A node stops being able to serve agent requests **the moment
> `Sagents.Supervisor` shuts down**, but it keeps accepting TCP connections for
> the rest of the platform's grace period. If your load balancer is still
> routing there, every one of those requests fails. Tell the platform the node
> is not ready *before* you let the supervision tree stop.

## The problem, concretely

`Sagents.Registry` is the map from `agent_id` to a process. Every agent lookup
reads it. It lives in ETS tables owned by the registry process on the local
node, so when that process stops, the tables go with it.

On SIGTERM, OTP shuts your application's supervision tree down in reverse child
order. `Sagents.Supervisor` and its registry terminate. **The BEAM keeps running
after that** for however long the platform allows, commonly 30 to 60 seconds.
During that window:

- the node still holds open connections and still accepts new ones,
- but no agent lookup on it can succeed,
- and no retry helps, because the registry is not coming back on this node.

This is not a race with a small window. It is a stable condition for the whole
drain period. It is also **local**: other nodes in the cluster are healthy and
can serve the request perfectly well. That is what makes it a routing problem
rather than an outage.

## The sequence you need

```
1. platform signals shutdown
2. node reports NOT ready          <-- your drain flag flips here
3. load balancer stops routing to it
4. in-flight requests finish
5. supervision tree stops           <-- Sagents.ready?() goes false here
6. BEAM exits
```

Out of the box, only steps 5 and 6 happen. Steps 2 through 4 are yours to wire
up, and they are the whole fix. The library gives you the signal for step 5 and
a clean error if a request slips through anyway.

**Note where the two signals sit.** `Sagents.ready?/0` first answers false at
step 5, which is after the load balancer needed it at step 2. So a readiness
endpoint wired to `Sagents.ready?/0` **alone** answers 200 for the entire drain
and then starts failing requests at the same instant it starts reporting
unhealthy. That is worse than nothing, because it looks finished.

Readiness needs two sources: a flag you set at step 2 (step 3 below), and
`Sagents.ready?/0` for every other way the tree can be down (still booting,
crashed, restarting).

## Step 1: readiness, not liveness

`Sagents.ready?/0` answers whether this node can host and route agent sessions.
Wire it into your **readiness** check, together with the drain flag from step 3.

Keep it out of your liveness check. A draining node is not an unhealthy one, and
what that costs depends on the platform: Kubernetes restarts a pod that fails
liveness, which is exactly the wrong move, while Fly never acts on a check
result at all. The reason to have `alive/2` on either platform is that it is the
signal that **stays green while readiness goes red**, the only way to read your
platform's check list and tell a node draining normally (alive 200, ready 503)
from one that is wedged (both failing). Readiness alone cannot express that
difference, and during a rolling deploy it is the difference an operator is
looking at.

```elixir
# lib/my_app_web/controllers/health_controller.ex
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller

  # Liveness: is the BEAM up at all? Never consults Sagents or the drain flag.
  def alive(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  # Readiness: should this node receive traffic? The drain flag flips first,
  # at step 2; Sagents.ready?/0 covers every other way the tree can be down.
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

```elixir
# lib/my_app_web/router.ex
scope "/health", MyAppWeb do
  get "/alive", HealthController, :alive
  get "/ready", HealthController, :ready
end
```

**The scope has no `pipe_through`** on purpose. Not the browser pipeline, since
a probe has no session and no CSRF token, and not an `:api` pipeline either:
`plug :accepts, ["json"]` makes the route content-negotiate, and probes
frequently send no `Accept` header at all. The probe then takes a 406 and reads
the node as unhealthy for a reason that has nothing to do with Sagents.

Check `endpoint.ex` for anything above the router that can halt or redirect,
too. `force_ssl` is the common one: probes reach the machine over plain HTTP on
the internal network with no `x-forwarded-proto` to rewrite on, so `Plug.SSL`
answers 301 and the readiness endpoint never runs. Exclude both full paths, and
repeat the host defaults, because passing any `:exclude` value replaces
`Plug.SSL`'s defaults entirely:

```elixir
force_ssl: [
  rewrite_on: [:x_forwarded_proto],
  exclude: [
    hosts: ["localhost", "127.0.0.1"],
    # Exact full-path matches, not prefixes. `paths: ["/health"]` does NOT
    # cover "/health/ready": Plug.SSL compares conn.path_info for equality.
    paths: ["/health/alive", "/health/ready"]
  ]
]
```

## Step 2: supervision tree order

`Sagents.Supervisor` must come **before** your Endpoint:

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

OTP shuts children down in reverse order, and that single rule is what makes all
three positions correct at once. Trace it: `Drain` → `Endpoint` →
`Sagents.Supervisor` → `PubSub` → `Repo`. The drain sleeps while the listener is
still up and can still answer the probe, then the listener stops, then the
registry, then the things agents needed in order to persist themselves.

The Endpoint's position matters on its own: listed the other way around, it
outlives the registry and serves the entire drain period with a dead registry
underneath it.

The drain process must be **last**, which is the placement that is easy to get
backwards. Listed anywhere earlier, its wait happens behind an already-stopped
listener, where no probe can observe the readiness change it exists to publish.

Correct ordering narrows the window. It does not remove it: the node is still
reachable by the load balancer until the platform stops sending traffic, which
is what step 1 is for. Do both.

## Step 3: give the platform time to notice

A readiness check that flips to `false` at the same instant the tree comes down
buys you nothing. The platform needs to poll it, observe the change, and update
its routing table before shutdown proceeds. That is what the drain delay is for.

The general principle, whatever the platform:

1. Intercept the shutdown signal.
2. Make readiness report false.
3. Wait longer than `(readiness poll interval × unhealthy threshold)`, plus the
   time your longest ordinary request takes.
4. Only then let the supervision tree stop.

A small process at the end of your tree does all four:

```elixir
defmodule MyApp.Drain do
  @moduledoc """
  Holds shutdown open long enough for the load balancer to observe readiness
  going false and stop routing here.

  Listed LAST in the application tree. OTP stops children in reverse order, so
  last means `terminate/2` runs first, while the Endpoint is still serving and
  can still answer the readiness probe.
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
  is read directly by the caller.
- **Configure `delay: 0` in dev and test.** A drain delay that fires on every
  `Ctrl-C` is a delay you will disable in week two, and then it is not there in
  production either. Take the value from config, so `drain_delay/0` in your
  application module reads `Application.get_env(:my_app, :drain_delay_ms, 0)`
  and only `config/runtime.exs` sets it to something like `20_000`.

> #### The signal that reaches the BEAM must be SIGTERM {: .warning}
>
> Everything above, and every `terminate/2` in your tree including the one in
> `Sagents.AgentServer` that persists agent state, hangs off OTP calling
> `init:stop()`. Only **SIGTERM** produces that. OTP's default
> `erl_signal_handler` maps `sigterm` to `init:stop()`; `sigquit` and `sigusr1`
> map to `erlang:halt/0,1`, which is immediate and graceless; and **`sigint`
> matches none of its clauses**, falling through to a no-op. What SIGINT
> actually reaches is the BEAM's break handler.
>
> | signal | `terminate/2` runs? | result |
> | --- | --- | --- |
> | `SIGTERM` | yes, with `reason: :shutdown` | drain waits, state persists, agents broadcast shutdown |
> | `SIGINT` | **no** | break handler; the node either sits until SIGKILL or halts outright |
>
> So under SIGINT there is no drain, no readiness flip, and **no agent state
> persisted**: every deploy silently loses the in-flight turn on every
> conversation. Where this goes wrong in practice is a hand-written platform
> config, a `CMD` that puts a shell at PID 1, and process managers that send
> something other than SIGTERM.
>
> A shell-form `CMD /app/bin/server` makes `/bin/sh` PID 1, and it does not
> forward SIGTERM to its child, so the BEAM never sees the signal and is
> SIGKILLed at the deadline with nothing having run. Use the exec form, which is
> what the generated Phoenix Dockerfile ships: `CMD ["/app/bin/server"]`.

### Fly.io

Fly sends the configured `kill_signal`, waits `kill_timeout`, then sends
**`SIGKILL`**. Nothing happens in between, so `kill_timeout` is not a stage in a
graceful sequence: it is the hard deadline before the machine dies mid-drain,
and it must exceed your drain delay.

`fly launch` detects an Elixir project and generates `kill_signal = "SIGTERM"`,
so this is normally already right. Confirm the line rather than assuming it,
since everything above depends on it.

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

With a 5 second interval the proxy notices within a few seconds of readiness
flipping, so a 45 second `kill_timeout` leaves room for a 20 second drain.

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
> A wrong sub-key does not give you a degraded check, it gives you **no check at
> all**, and readiness is the entire mechanism by which the drain does anything.
> Fly Proxy is never told to stop routing, so the node keeps taking new requests
> for the whole delay and the endpoint still closes underneath whatever is in
> flight: the exact failure this guide exists to prevent, now with the drain
> delay added to every machine stop. Confirm it with `fly checks list`.

**Wire the liveness endpoint too.** On Fly this is not the readiness block with
a different path: a liveness check belongs in the **top-level `[checks]`
section**, a different shape that needs a unique name, an explicit `port`, and
an explicit `type`.

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

If you run agents in more than one region, read the partition section of
[Clustering](clustering.md) as well: `fly-replay` routing a request to the wrong
region has a different and worse failure mode than draining does.

### Kubernetes

Kubernetes sends `SIGTERM` already, so there is no signal to change.

```yaml
readinessProbe:
  httpGet: { path: /health/ready, port: 4000 }
  periodSeconds: 5
  failureThreshold: 2

# Both endpoints, or the liveness half of step 1 is wired to nothing. Unlike
# Fly, Kubernetes does act on this one: keep the drain flag out of it, or the
# kubelet restarts the pod you are trying to drain.
livenessProbe:
  httpGet: { path: /health/alive, port: 4000 }
  periodSeconds: 15
  failureThreshold: 3

terminationGracePeriodSeconds: 60
```

With `MyApp.Drain` in the tree you do not also need a `preStop` sleep;
`terminationGracePeriodSeconds` must exceed the drain delay plus your longest
request.

If you would rather keep the wait outside the BEAM, drop `MyApp.Drain` and use
`lifecycle.preStop.exec.command: ["sleep", "20"]` instead. `preStop` runs before
`SIGTERM` is delivered and endpoint removal happens concurrently with it, so the
sleep does give the service mesh time to stop routing. The cost is that
readiness then has only `Sagents.ready?/0` to report, which goes false at step 5
rather than step 2, which is too late to be the signal the mesh acted on. Prefer the
in-BEAM flag.

## Step 4: handle the error if one slips through

Even with all of the above, a request can arrive mid-transition. Sagents reports
that as a value rather than raising, so you can answer it correctly:

```elixir
case Sagents.Session.ensure_running(config, socket.assigns, request_opts: opts) do
  {:ok, changes} ->
    assign(socket, changes)

  {:error, :registry_unavailable} ->
    # This node is draining. Another node can serve this fine.
    {:error, message: "Service is restarting, please retry", code: 503}

  {:error, reason} ->
    {:error, message: "Could not start session: #{inspect(reason)}"}
end
```

**Answer 503, not 500.** A 500 says the request cannot be served. A 503 says it
cannot be served *here*, which is true, and it is the answer clients and load
balancers know how to retry.

### Which functions report it, and which raise

Classify by **how a call reaches the registry**, not by which module it lives in.
That rule is short, checkable against the source, and it covers functions this
page does not name:

| how it reaches the registry | behaviour when the registry is gone |
| --- | --- |
| `GenServer.cast` on a `:via` tuple | **safe.** Elixir wraps `cast` in `try … catch _, _ -> :ok`, so it silently no-ops |
| `GenServer.call` on a `:via` tuple | **raises.** A `catch :exit` clause does not catch a raise |
| `get_pid/1`, `whereis/1`, `lookup/1`, `select/1`, `count/0`, `keys/1` | **raises** `Sagents.RegistryUnavailableError` |
| `fetch_pid/1`, `fetch/1`, `fetch_running/2`, `fetch_filesystem_running/1` | `{:error, :registry_unavailable}` |

The `cast` and `call` asymmetry is why a function's signature tells you nothing
on its own. Same via tuple, same dead registry, opposite outcome.

The tuple-returning forms, by layer:

- `Sagents.Session`: `start/3`, `ensure_running/3`, `resume/4`, `dismiss/3`,
  `stop/2`, `fetch_running/2`
- `Sagents.AgentServer`: `fetch_pid/1`, `execute/1`, `cancel/1`, `resume/2`,
  `add_message/3`, `reset/1`, `dismiss_interrupt/1`, `subscribe/3`
- `Sagents.FileSystem`: `ensure_filesystem/3`, `stop_filesystem/2`,
  `get_filesystem_pid/1`, `fetch_filesystem_running/1`
- `Sagents.AgentSupervisor`: `get_pid/1`, `stop/2`
- `Sagents.ProcessRegistry`: `fetch/1`, and `Sagents.FileSystemServer.fetch_pid/1`

The raising ones you are most likely to meet by accident are the two
`?`-predicates, `Sagents.Session.running?/2` and
`Sagents.FileSystem.filesystem_running?/1`, because a name ending in `?` is the
last thing a reader suspects of raising. Both have non-raising siblings in the
list above. `Sagents.FileSystem.list_filesystems/0` and
`Sagents.AgentServer.get_status/1` are the next two: `get_status/1` wraps its
call in `try/catch :exit`, so every call site reads as though it cannot fail,
while the raise happens *before* reaching the call that `catch` guards.

**Do not skip the filesystem layer because it looks incidental.**
`Sagents.FileSystem` gets read as one function when it is a module of them, and
its calls sit in the least suspicious place: best-effort cleanup, where the
return is usually discarded. Discarding it there is fine and stays fine. Two
other shapes are worth checking:

- **A catch-all that logs.** `{:error, :registry_unavailable}` reaching an
  `{:error, reason} -> Logger.error(...)` clause turns every deploy into an
  alarm for a condition that is not a fault.
- **`ensure_filesystem/3` returning the error.** It deliberately does not start
  a filesystem it could not first check for, because this node cannot see
  whether one already exists elsewhere. A caller that reads any error as "start
  failed, carry on degraded" is making a different decision than the one that
  was reported.

> #### The not-found atom differs by layer {: .warning}
>
> Only `:registry_unavailable` is spelled the same everywhere.
> `Sagents.AgentServer.fetch_pid/1` and `Sagents.FileSystemServer.fetch_pid/1`
> answer `{:error, :not_running}`; `Sagents.ProcessRegistry.fetch/1` answers
> `{:error, :not_registered}`; the supervisor layer
> (`Sagents.AgentSupervisor.get_pid/1`,
> `Sagents.FileSystem.get_filesystem_pid/1`) answers `{:error, :not_found}`.
>
> Copying a `case` shape from one layer to another gives you a `CaseClauseError`
> on the drain path, which is the one path with no test coverage.

### Why it is not just `nil`

`:registry_unavailable` is deliberately **not** folded into "no agent is
running". They mean different things and require different responses:

| answer | meaning | correct response |
| --- | --- | --- |
| `{:error, :not_running}` | the registry answered; nothing is running | start an agent |
| `{:error, :registry_unavailable}` | the registry could not answer | retry elsewhere |

If the second were reported as the first, every request during every drain would
start a *new* agent for a conversation that already has one somewhere else. Two
processes would then hold and persist state for the same conversation, silently.
That is why the distinction is load-bearing rather than cosmetic.

It is also why the raising functions raise rather than answering. A shape like
`pid() | nil`, a boolean, or a list has no room for a third answer, and every
plausible default is the dangerous one: `nil`, `false` and `[]` all read as
"nothing is running". A loud, named error is the safer answer, even at the cost
of a `?`-predicate that can raise. On request paths, prefer the tuple-returning
forms listed above.

## What happens to running agents

Agent state is durable, which is what makes all of this recoverable.

- **Graceful shutdown.** Agents terminate, persist their state, and broadcast a
  shutdown event.
- **A node vanishing abruptly.** Under `:horde`, surviving members usually
  restart the departed node's agents on their own. Treat this as an
  optimization, not a guarantee — see the warning below.
- **The next request either way.** `Sagents.Session.ensure_running/3` starts the
  agent from persisted state on whichever node handles it. A conversation that
  was mid-run resumes as a fresh run rather than continuing the interrupted one.

So a deploy costs you in-flight LLM turns, not conversations. Sizing your drain
window is a question of how long you are willing to wait for those turns, not of
whether state survives.

> #### Redistribution is best-effort; the next request is the guarantee {: .warning}
>
> Horde only hands a departed node's processes to a survivor once that survivor
> has converged on the departure — its member entry for the node has to be
> marked dead before the takeover clause fires. A node that leaves *before* that
> convergence completes takes its agents with it instead of handing them over.
>
> An agent that has been running for a couple of seconds or more is
> redistributed reliably. One placed immediately before the node departs is
> dropped in roughly one departure in four. Both `:init.stop` and an abrupt node
> loss behave identically here — being graceful does not help.
>
> When an agent is dropped it is **dropped cleanly, not corrupted**: the
> registry and Horde's process CRDT are both left empty for that agent, so
> nothing is left behind and no duplicate is possible. The next
> `Sagents.Session.ensure_running/3` starts it again from persisted state,
> exactly as it would after an inactivity shutdown.
>
> The practical consequences:
>
> - **Do not treat redistribution as a correctness property.** Anything that
>   must happen must be driven by a request, a job, or a supervisor you control,
>   not by an agent that you assume Horde kept alive somewhere.
> - **The drain sequence above is what protects you.** Steps 1 to 4 stop new
>   agents being placed on a node that is about to leave, which is exactly the
>   case that loses them.

### If the registry itself fails

A node's registry process crashing is rare, but it has a defined outcome on both
backends, and it is deliberately a noisy one.

`Sagents.Supervisor` supervises its children `:rest_for_one` with the registry
first, so a registry failure restarts the agent and filesystem supervisors too.
Running agents on that node stop and are re-created from persisted state on the
next request.

That looks heavy-handed and is the point. An `AgentSupervisor` and an
`AgentServer` register their `:via` names once, at start, and nothing
re-registers them. A registry that comes back empty underneath them leaves them
running but invisible to every lookup — so the next request reads "nothing is
running" and starts a *second* AgentServer for a conversation that already has
one, with both persisting state and nothing reporting the conflict. Restarting
them is recoverable; a silent duplicate is not.

Two internal pieces make that restart reach the right processes, and you do not
interact with either:

- `Sagents.RegistryWatcher`. On both backends the process owning the registry's
  ETS tables runs under a supervisor of the backend's own, which restarts it
  with empty tables without failing a child of `Sagents.Supervisor`. Under
  `:horde` that process is the one registered as `Sagents.Registry`; under
  `:local` it is a `Registry.Partition` one level below the name. The watcher
  monitors it and fails in its place.
- `Sagents.LocalRegistry`. Under `:local` the restart races the outgoing
  registry's partition process, which traps exits and holds its registered name
  for a few milliseconds after the registry is gone. A start landing inside that
  window fails with `{:already_started, pid}`, and a supervisor does not recover
  from a failed restart. `Sagents.LocalRegistry` waits for the straggler to exit
  and retries.

None of this is part of draining. The watcher is listed after the registry, and
OTP stops children in reverse order, so it is already gone by the time the
registry stops on a normal shutdown. A draining node never looks like a registry
failure.

> #### On a cluster this deliberately over-reacts {: .info}
>
> Under `:horde`, registrations replicate through the same CRDT as membership,
> so a surviving peer repairs a restarted registry within a few hundred
> milliseconds, pointing at the very processes that were still running. Left
> alone, a registry crash on a healthy multi-node cluster would cost nothing.
>
> Sagents restarts the node's agents anyway. Nothing on the affected node can
> tell in time whether a repair is coming: a single-node deployment has no peer,
> and a partitioned or lagging cluster looks identical from the inside until the
> window has passed. Guessing wrong leaves agents running but unregistered,
> which is what produces two AgentServers persisting one conversation with
> nothing reporting it.
>
> So the failure is bounded to a restart from durable state rather than left to
> become silent corruption. What it means for you: a registry crash costs the
> in-flight LLM turns on that node, the same as a deploy does, and conversations
> resume on the next request.

## Verifying it

The failure mode this guide exists to prevent has direct test coverage in
`test/sagents/horde/rolling_deploy_test.exs`, which drives real Erlang nodes
through a shutdown while probing them:

```bash
mix test test/sagents/horde/rolling_deploy_test.exs --include cluster --include slow
```

To check your own application, hit `/health/ready` while a deploy is in flight
and confirm it reports 503 before the node stops answering agent requests. If
readiness is still reporting 200 at the moment lookups start failing, steps 1
through 3 are not wired correctly.

Check the probe is not being redirected on the way in, which `force_ssl` will do
silently:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://<internal-address>/health/ready
```

A `301` means the exclusion in step 1 is missing, and no amount of correct
readiness logic will help.

**Then confirm the platform is actually asking.** Both checks above talk to your
app, and the app can be perfectly healthy while the platform has been told to
poll nothing, which is what a misspelled check sub-key produces:

```bash
fly checks list -a <app>     # must list your checks. An empty table means the
                             # key decoded into nothing
kubectl describe pod <pod>   # the Liveness:/Readiness: lines, same question
```

Do not substitute `fly config validate` for this. It reports
`Configuration is valid` for a file containing sections and keys `flyctl` does
not recognize: it confirms well-formed TOML, not that Fly understood any
particular line. The curl proves your app answers; `fly checks list` proves the
platform is asking. They are independent failures and you need both.

## Related

- [Clustering & distribution (Horde)](clustering.md) for membership, placement,
  and partitioning.
- [Lifecycle](lifecycle.md) for what an individual agent does on shutdown.
- [Persistence](persistence.md) for what survives and how it is restored.
