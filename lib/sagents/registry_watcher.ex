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
  watcher is what connects a registry failure to that chain, because the failure
  happens one level below where the strategy can see it:

      Sagents.Supervisor
      └── Sagents.Horde.RegistryImpl   <- the child Sagents.Supervisor supervises (a supervisor)
          ├── Horde.RegistryImpl       <- the process registered as Sagents.Registry
          └── Sagents.Registry.Crdt

  `Horde.Registry.start_link/3` starts a supervisor, and the process registered
  under the name is its child. When that child crashes, Horde's own supervisor
  restarts it with fresh, empty ETS tables, so `Sagents.Supervisor` sees no
  failed child of its own. Elixir's `Registry` is shaped the same way.

  This watcher monitors the process registered as `Sagents.Registry` directly
  and stops when it dies. Listed immediately after the registry in
  `Sagents.Supervisor`, its stop is a child failure the `:rest_for_one` strategy
  does act on, taking the agent and filesystem supervisors down with it. Agents
  stop, and the next request re-creates them from persisted state with fresh
  registrations.

  ## The trade being made

  A registry crash costs running agents rather than leaving duplicates behind.
  That is deliberate. Agent state is durable, so a restart is recoverable and
  mostly invisible to a user. A silent duplicate is neither: it corrupts the
  conversation, and nothing reports it.

  This is a rare event. It does not fire on a normal shutdown, when the whole
  tree is coming down anyway, and it does not fire when Horde repairs a
  restarted registry from a peer's CRDT without the registered process ever
  dying.

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
    `Sagents.ProcessRegistry.registry_name/0`. Overridden only in tests.
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
      Keyword.get(opts, :registry_name, Sagents.ProcessRegistry.registry_name())

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
      "#{inspect(state.registry_name)} went down (#{inspect(reason)}). " <>
        "Restarting agent and filesystem supervisors so their registrations are " <>
        "re-established. Running agents will restart from persisted state."
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
