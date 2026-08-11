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
  shutdown event. Under `:horde`, surviving members pick up the work when a
  request next asks for it.
- **A node vanishing abruptly.** Horde detects the departure and redistributes.
  The new process starts from persisted state.
- **The next request either way.** `Sagents.Session.ensure_running/3` starts the
  agent from persisted state on whichever node handles it. A conversation that
  was mid-run resumes as a fresh run rather than continuing the interrupted one.

So a deploy costs you in-flight LLM turns, not conversations. Sizing your drain
window is a question of how long you are willing to wait for those turns, not of
whether state survives.

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
