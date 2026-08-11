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
2. node reports NOT ready          <-- Sagents.ready?() goes false
3. load balancer stops routing to it
4. in-flight requests finish
5. supervision tree stops           <-- registry goes away here
6. BEAM exits
```

Out of the box, only steps 5 and 6 happen. Steps 2 through 4 are yours to wire
up, and they are the whole fix. The library gives you the signal for step 2 and
a clean error if a request slips through anyway.

## Step 1: readiness, not liveness

`Sagents.ready?/0` answers whether this node can host and route agent sessions.
Wire it into your **readiness** check. Do not wire it into a liveness check: a
draining node is not unhealthy, and restarting it is the wrong response.

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

Keep these routes outside any authentication pipeline, and outside any plug that
itself touches Sagents.

## Step 2: supervision tree order

`Sagents.Supervisor` must come **before** your Endpoint:

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyAppWeb.Presence,
  Sagents.Supervisor,
  MyAppWeb.Endpoint      # after, so OTP stops it FIRST
]
```

OTP shuts children down in reverse order. Listed this way, the Endpoint stops
accepting requests first and the registry is still alive to serve whatever is
already in flight. Listed the other way around, the Endpoint outlives the
registry and serves the entire drain period with a dead registry underneath it.

Correct ordering narrows the window. It does not remove it: the node is still
reachable by the load balancer until the platform stops sending traffic, which
is what step 1 is for. Do both.

## Step 3: give the platform time to notice

A readiness check that flips to `false` at the same instant the tree comes down
buys you nothing. The platform needs to poll it, observe the change, and update
its routing table before shutdown proceeds. That is what a pre-stop hook or a
drain delay is for.

The general principle, whatever the platform:

1. Intercept the shutdown signal.
2. Make readiness report false.
3. Wait longer than `(readiness poll interval × unhealthy threshold)`, plus the
   time your longest ordinary request takes.
4. Only then let the supervision tree stop.

### Fly.io

Fly sends `SIGINT` first (then `SIGTERM` after `kill_timeout`). Set a
`kill_timeout` that covers your drain, and make sure your health check interval
is short enough that the proxy notices within it.

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

With a 5 second interval, the proxy notices within a few seconds of readiness
flipping, so a 45 second `kill_timeout` leaves plenty of room. Handle the signal
so the wait happens before the tree stops, for example by trapping it in a small
process started *before* `Sagents.Supervisor` in your tree, or by using a
release `pre_stop` hook.

If you run agents in more than one region, read the partition section of
[Clustering](clustering.md) as well: `fly-replay` routing a request to the wrong
region has a different and worse failure mode than draining does.

### Kubernetes

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

`preStop` runs before `SIGTERM` is delivered, and endpoint removal happens
concurrently with it, so the sleep is what gives the service mesh time to stop
routing. `terminationGracePeriodSeconds` must exceed the `preStop` sleep plus
your longest request.

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

The same `{:error, :registry_unavailable}` is returned by `Sagents.Session.start/3`,
`resume/4`, `dismiss/3` and `stop/2`, by `Sagents.AgentServer.fetch_pid/1`, and
by the `Sagents.AgentServer` lifecycle calls (`execute/1`, `cancel/1`,
`resume/2`, `add_message/3`, `reset/1`, `dismiss_interrupt/1`).

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

A handful of functions cannot express the condition in their return value:
`Sagents.AgentServer.get_pid/1` returns `pid() | nil`,
`Sagents.Session.running?/2` returns a boolean, and
`Sagents.ProcessRegistry.select/1` returns a list. Those **raise**
`Sagents.RegistryUnavailableError` rather than answering with a plausible
default. On request paths, prefer the tuple-returning forms
(`fetch_pid/1`, `ensure_running/3`, `Sagents.ProcessRegistry.fetch/1`).

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

## Related

- [Clustering & distribution (Horde)](clustering.md) for membership, placement,
  and partitioning.
- [Lifecycle](lifecycle.md) for what an individual agent does on shutdown.
- [Persistence](persistence.md) for what survives and how it is restored.
