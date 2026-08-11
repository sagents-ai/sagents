defmodule Sagents.RegistryWatcher do
  @moduledoc """
  Propagates a registry restart into `Sagents.Supervisor`'s `:rest_for_one`
  restart chain.

  ## What it protects

  Every `AgentSupervisor` and `AgentServer` registers its `:via` name in
  `Sagents.Registry` exactly once, when it starts, and nothing re-registers it
  afterwards. A registry that loses its contents therefore leaves those
  processes running but invisible to every lookup. Lookups answer "nothing is
  running", the next request responds by starting an agent, and the conversation
  ends up with two AgentServers holding and persisting state for it, with
  nothing reporting the conflict.

  `Sagents.Supervisor` uses `:rest_for_one` so a registry failure restarts
  everything listed after it, which re-establishes those registrations. The
  watcher is what connects a registry failure to that chain, because on both
  backends the process that holds the registrations sits one level below where
  the strategy can see it.

  ## What each backend actually looks like

  Under `:horde`, `Horde.Registry.start_link/3` starts a supervisor, and the
  process registered under the name is its child:

      Sagents.Supervisor
      └── Sagents.Horde.RegistryImpl   <- the child Sagents.Supervisor supervises (a supervisor)
          ├── Horde.RegistryImpl       <- registered as Sagents.Registry, owns the ETS tables
          └── Sagents.Registry.Crdt

  Under `:local`, `Registry.start_link/1` registers its `Registry.Supervisor`
  under the given name, and the ETS tables belong to a `Registry.Partition`
  child:

      Sagents.Supervisor
      └── Sagents.Registry                    <- the child Sagents.Supervisor supervises
          └── Sagents.Registry.PIDPartition0  <- owns the ETS tables

  The shapes differ, and so does which process `Sagents.Supervisor` can see fail
  on its own. What does not differ is that in both cases a backend supervisor
  can replace the table-owning process with a fresh, empty one without ever
  failing a child of `Sagents.Supervisor`:

  - `:horde` restarts `Horde.RegistryImpl` under `Sagents.Horde.RegistryImpl`.
  - `:local` restarts `Registry.Partition` under `Sagents.Registry`.

  A `:local` registry has a second failure mode, `Registry.Supervisor` itself
  dying, which *is* a failed child and does reach `:rest_for_one` unaided. That
  one is already handled, and `Sagents.LocalRegistry` is what makes its restart
  survivable. It is the partition case that needs watching.

  ## What is watched

  This watcher monitors `Sagents.ProcessRegistry.watched_name/0`, the process
  that owns the tables rather than the process that holds the registry's name.
  On `:horde` those are the same process; on `:local` they are not.

  It stops when that process dies. Listed immediately after the registry in
  `Sagents.Supervisor`, its stop is a child failure the `:rest_for_one` strategy
  does act on, taking the agent and filesystem supervisors down with it. Agents
  stop, and the next request re-creates them from persisted state with fresh
  registrations.

  Watching the partition covers the `Registry.Supervisor` case too, since the
  partition dies whenever its supervisor does.

  ## When it fires, and when it does not

  Only the death of the table-owning process fires it. In particular it does
  **not** fire on an orderly shutdown. The watcher is listed after the registry
  so that it can monitor it, and OTP terminates children in reverse order, so
  that same placement means the watcher is already gone by the time the registry
  stops. A draining node therefore never looks like a registry failure. Draining
  is handled by `Sagents.ready?/0` and the guarded lookups instead, not here.

  ## The trade being made

  A registry crash costs running agents rather than leaving duplicates behind.
  Agent state is durable, so a restart is recoverable and mostly invisible to a
  user. A silent duplicate is neither: two AgentServers hold and persist state
  for one conversation, and nothing reports the conflict.

  On a healthy multi-node cluster this is more disruptive than doing nothing
  would have been. Horde replicates registrations through the same CRDT as
  membership, so a peer repairs a restarted registry within a few hundred
  milliseconds, pointing at the very processes this watcher just took down.

  It fires anyway, because nothing on this node can tell in time whether a
  repair is coming. A single-node deployment has no peer at all. A partitioned
  or lagging cluster is indistinguishable from a healthy one from here, right up
  until the window where guessing wrong leaves agents alive and unregistered.
  The cost of over-reacting is a restart from durable state; the cost of
  under-reacting is silent corruption. The asymmetry is the whole argument.

  Both halves are pinned in `test/sagents/horde/rolling_deploy_test.exs`: a peer
  repairing a crashed node's registry, and an agent on the crashed node coming
  down regardless.

  Started automatically by `Sagents.Supervisor`. You do not start it yourself.
  """

  use GenServer

  require Logger

  # How often to look for the registry when it is not registered yet, which
  # happens briefly while a backend supervisor restarts its own child.
  @poll_interval 100

  @doc """
  Start the watcher.

  ## Options

  - `:name` - registered name, defaults to this module. `nil` starts it
    unnamed, which tests use to run more than one at a time.
  - `:registry_name` - the process name to watch, defaults to
    `Sagents.ProcessRegistry.watched_name/0`. Overridden only in tests.
  """
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    registry_name =
      Keyword.get(opts, :registry_name, Sagents.ProcessRegistry.watched_name())

    {:ok, %{ref: nil, pid: nil, registry_name: registry_name}, {:continue, :monitor}}
  end

  @impl true
  def handle_continue(:monitor, state) do
    {:noreply, monitor_registry(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, monitor_registry(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{ref: ref, pid: pid} = state) do
    Logger.warning(
      "#{inspect(state.registry_name)}, which holds this node's registry contents, " <>
        "went down (#{inspect(reason)}). Restarting agent and filesystem supervisors " <>
        "so their registrations are re-established. Running agents will restart from " <>
        "persisted state."
    )

    # A `{:shutdown, _}` reason still restarts a :permanent child, and unlike a
    # bare error it is not reported as a crash. This is a deliberate, handled
    # condition, not a bug in this process.
    {:stop, {:shutdown, {:registry_down, reason}}, %{state | ref: nil, pid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Watch whatever process currently holds the registry name. If the name is
  # unclaimed, poll rather than failing: a backend supervisor may be mid-restart
  # of its own child, and this process must not turn that into a restart storm.
  defp monitor_registry(state) do
    case Process.whereis(state.registry_name) do
      nil ->
        Process.send_after(self(), :poll, @poll_interval)
        state

      pid ->
        %{state | ref: Process.monitor(pid), pid: pid}
    end
  end
end
