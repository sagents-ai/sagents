# Clustering & distribution (Horde)

Sagents runs single-node by default. To distribute agents (and their
filesystems) across a cluster, switch the backend to [Horde](https://hexdocs.pm/horde):

```elixir
config :sagents, :distribution, :horde   # default is :local
```

This swaps three pieces of infrastructure from their local equivalents to Horde:

| Sagents process | `:local` | `:horde` |
| --- | --- | --- |
| `Sagents.Registry` | `Registry` | `Horde.Registry` |
| `Sagents.AgentsDynamicSupervisor` | `DynamicSupervisor` | `Horde.DynamicSupervisor` |
| `Sagents.FileSystem.FileSystemSupervisor` | `DynamicSupervisor` | `Horde.DynamicSupervisor` |

You also need the `:horde` dependency:

```elixir
{:horde, "~> 0.10"}
```

## The one idea that explains everything: membership

Horde places a process on a **member** node. So "which nodes can host an agent"
is entirely a question of each Horde instance's **member set**. There is no
separate "placement policy" — membership *is* the policy.

Two sub-points are worth internalising, because they explain every surprising
behaviour:

1. **Member set vs. placement eligibility are different gates.** A node can be a
   *member* without being a valid *placement target*. `Horde.UniformDistribution`
   only places on members whose status is `:alive`, and a node reports `:alive`
   only by actually running the Horde supervisor. A member that never starts
   Horde stays `:uninitialized` and is skipped for placement.

2. **The member set also drives the DeltaCrdt sync fan-out** — and that path does
   *not* filter by `:alive`. Every member, alive or not, is a CRDT sync
   neighbour. An over-broad member set therefore bloats sync traffic (and is the
   root cause of intermittent `:via` registration timeouts on busy clusters),
   even if placement itself looks correct.

The practical upshot: **scoping the member set is what matters**, not just where
processes happen to land.

## Choosing a `members` mode

Configure under `:sagents, :horde`:

```elixir
config :sagents, :horde, members: <mode>
```

| Mode | Dynamic? | Scope | Use when |
| --- | --- | --- | --- |
| `:auto` (default) | yes (`Horde.NodeListener`) | **all** visible BEAM nodes | every node in the Erlang cluster should host agents |
| `:participation` | yes (`:pg`) | nodes running `Sagents.Supervisor` | the cluster mixes roles; only some nodes should host agents |

These are the only two modes. (Static `:members` forms — a list, `function/0`,
or `{m, f, a}` — are intentionally not supported; both modes above are dynamic
and cover the real cases.)

### `:auto` — all visible nodes

`:auto` is passed straight to Horde, which runs a `Horde.NodeListener` and keeps
membership equal to `Node.list([:visible, :this])`. Correct **only if every
connected Elixir node should host agents.** If your cluster meshes unrelated
roles (web, jobs, scans, …) into one Erlang cluster — e.g. a shared libcluster
selector — `:auto` pulls all of them in. Placement stays correct (non-Horde
nodes never go `:alive`), but the CRDT fan-out spans every node. Prefer
`:participation` there.

### `:participation` — scoped to nodes running Sagents (recommended for mixed clusters)

```elixir
config :sagents, :distribution, :horde
config :sagents, :horde, members: :participation
```

Membership becomes exactly the nodes that run `Sagents.Supervisor`. Each such
node joins an OTP `:pg` group; `Sagents.Horde.MembershipManager` (started
automatically, with its `:pg` scope) adds a node to Horde's members when it
joins that group and removes it when it leaves. Dead nodes are pruned for free
(`:pg` drops them on `:nodedown`). A node that is still discovering the group
only ever adds members, so it never removes peers it has not seen yet, or the
agents registered on them.

The key move is that **you control membership simply by controlling where
`Sagents.Supervisor` starts.** Gate it to your agent-hosting role:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children =
    [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      MyAppWeb.Presence
    ] ++
      # Only :web nodes host agents; only they join the Horde cluster.
      if(:web in MyApp.Cluster.roles(), do: [Sagents.Supervisor], else: []) ++
      [MyAppWeb.Endpoint]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

That is the entire configuration: gate the supervisor, set
`members: :participation`. No node-name predicate, no manual
`Horde.Cluster.set_members/2` wiring.

### Partitioning membership (e.g. by region)

Participation answers *"which nodes host agents"*. An optional `:partition`
answers *"which of those nodes belong together"* — it isolates participation
into independent groups, so a node only clusters with other nodes sharing the
same partition value.

```elixir
# runtime.exs (runs per node)
config :sagents, :horde,
  members: :participation,
  partition: System.get_env("FLY_REGION")   # e.g. "ord"; nil => single global group
```

`:partition` is any opaque grouping key you set per node. The motivating case is
**geographic**: set it to a Fly.io `FLY_REGION` so an agent for an Illinois user
is placed on — and only visible from — a Chicago node, never one in France. But
it can be anything that should partition the cluster, such as a dedicated node
pool for a large tenant:

```elixir
config :sagents, :horde,
  members: :participation,
  partition: System.get_env("TENANT_POOL")   # nodes dedicated to a tenant
                                             # cluster only among themselves
```

A good partition value is a **stable identity, fixed for the node's lifetime.**
It is read once when the node boots and never re-read, so a node cannot move
between partitions without restarting. Geography (`FLY_REGION`) and dedicated
pools fit naturally. Avoid values that rotate or get reassigned in place — e.g. a
blue/green deploy color: "promoting" green to blue doesn't restart the node, so
its boot-time partition would be stale.

With a partition set, all three Horde instances are scoped to same-partition
nodes only. Concretely, in one connected BEAM cluster spanning `ord` and `cdg`:

- `ord` nodes see members `= ord nodes`; `cdg` nodes see members `= cdg nodes`.
- The two partitions' CRDTs never sync (disjoint member sets), so an agent
  started in `ord` is invisible to `cdg` and vice-versa.

> #### Cross-partition request routing is your responsibility {: .warning}
>
> The library guarantees agents stay *within* their partition. It does **not**
> route a user's request to the right partition. If a request for an `ord` user
> lands on a `cdg` node, that node won't find the existing `ord` agent and will
> start a *second* one in `cdg`. Ensure requests reach the right partition at the
> infra/app layer — on Fly.io, `fly-replay` to the target region (or sticky
> region routing) is the usual tool.

### Under the hood: three Horde instances

Sagents runs **three** independent Horde instances — each a separately-named
Horde process over the *same* set of nodes:

- `Sagents.Registry` (a `Horde.Registry`)
- `Sagents.AgentsDynamicSupervisor` (a `Horde.DynamicSupervisor`)
- `Sagents.FileSystem.FileSystemSupervisor` (a `Horde.DynamicSupervisor`)

The registry-vs-supervisor split is inherent to Horde (distributed name
registration and distributed placement are different components); agents and
filesystems are kept as separate supervisors because they scope differently.
Each instance has its own member set, keyed by *that instance's* name, so all
three must be kept membership-consistent — which both `:auto` and
`:participation` do for you automatically.

## Quick diagnostics

```elixir
# Nodes Horde currently considers members of each instance (keep these consistent):
Horde.Cluster.members(Sagents.Registry)
Horde.Cluster.members(Sagents.AgentsDynamicSupervisor)
Horde.Cluster.members(Sagents.FileSystem.FileSystemSupervisor)

# Compare member count to live nodes — members > live ⇒ stale/un-pruned members:
{length([node() | Node.list()]), length(Horde.Cluster.members(Sagents.Registry))}

# Total registered entries cluster-wide:
Sagents.ProcessRegistry.count()

# Can THIS node answer lookups at all? False while starting, and after
# Sagents.Supervisor has shut down while the BEAM drains.
Sagents.ready?()
```

## Taking a node out of the cluster

Membership prunes a departed node automatically. Two things it does **not** do
are worth being explicit about, because both are easy to assume.

### It does not stop traffic reaching a draining node

Membership says nothing about the window where a node has stopped its Sagents
supervision tree but is still receiving HTTP traffic, which is every rolling
deploy. Requests arriving in that window cannot be served on that node no matter
how healthy the rest of the cluster is.

See [Deployments, draining, and readiness](deployment.md) for the readiness
signal (`Sagents.ready?/0`), the required shutdown sequence, and platform
examples.

### It does not guarantee the departed node's agents are handed over

Pruning membership and handing over processes are separate mechanisms. Horde
takes over a departed node's processes only after the surviving node has
converged on the departure and marked that member dead. A node that leaves
before that convergence completes takes its agents with it.

In practice this affects agents placed shortly before the departure. An agent
that has been running for a couple of seconds or more is redistributed
reliably; one placed immediately before the node leaves is dropped in roughly
one departure in four. Whether the node leaves gracefully (`:init.stop`) or
abruptly makes no difference.

A dropped agent is dropped **cleanly**. Both the registry and the supervisor's
process CRDT are left with no entry for it, so there is no orphan and no
duplicate, and the next `Sagents.Session.ensure_running/3` starts it again from
persisted state. This is the same recovery path an inactivity shutdown uses,
which is why it is a bounded cost rather than data loss.

The rule to design to: **treat redistribution as an optimization and the next
request as the guarantee.** Work that must happen should be driven by a request,
a job, or a supervisor you control — never by assuming Horde kept an agent alive
somewhere on your behalf.

### A moved agent is built by the node that runs it

A handed-over agent is restarted from the options of its original start. Those
options include the `%Sagents.Agent{}` built by the node that requested the
start, and during a rolling deploy the survivor is often running the next build.
Horde can also place a direct start on another member, so the same mismatch
applies to a start requested during a deploy.

An agent built by another build is wrong in two ways:

- **Its configuration is that build's.** The system prompt, the tool list, the
  model, and middleware config are whatever the old code produced, and they
  stay that way for as long as the agent keeps running.
- **Its anonymous functions may not be callable.** A tool function, callback,
  or function closed over in middleware config is a reference to one compiled
  version of the module that created it. On a node with a different version
  loaded, every call raises `BadFunctionError`, which the model receives as the
  tool result.

`Sagents.Session` avoids both. It starts every agent with a `:builder` that
re-runs your `Sagents.FactoryRouter` and `Sagents.Factory`, and
`Sagents.AgentSupervisor.start_link/1` uses it whenever the agent is about to
run somewhere other than the node run that built it. The moved agent is then
built by the code that runs it, with its persisted state restored, and
`[:sagents, :agent, :built]` is emitted with `%{count: 1}` and
`%{agent_id: _, reason: _, node: _}`. A start that stays on the node that
requested it uses the agent that node already built, so the factory runs once
per start in the common case.

This makes the router and factory part of the restart path. They may run inside
a supervisor on another node rather than in the process that called
`Sagents.Session`, so they must not depend on that process: its process
dictionary, `self()`, or Logger and tracing context set by the caller. Inputs
belong in the scope and `:request_opts`, which travel with the start.

If you start agents with `Sagents.AgentsDynamicSupervisor.start_agent/1`
directly, pass your own `:builder`. See `Sagents.AgentSupervisor.start_link/1`
for its contract.

#### Without a builder

`Sagents.AgentSupervisor.start_link/1` still checks the options on the node
that is about to host the agent, and when they hold a function that node cannot
call, it starts nothing:

- On a handover, the agent is dropped cleanly, exactly as described above, and
  the next start builds it from current code.
- On a direct start placed on a member running a different build,
  `Sagents.AgentsDynamicSupervisor.start_agent/1` and `start_agent_sync/1`
  return `{:error, :stale_closures}`.

The refusing node logs a warning naming the modules involved and emits
`[:sagents, :agent, :stale_closures]` with `%{count: 1}` and
`%{agent_id: _, modules: _, node: _}`. Without a builder, an agent whose
functions are all still callable is handed over with its original build's
configuration.

If you want to observe this directly, the coverage is in
`test/sagents/horde/node_transfer_test.exs`:

```bash
mix test test/sagents/horde/node_transfer_test.exs --include cluster
```
