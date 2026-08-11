defmodule Sagents.Supervisor do
  @moduledoc """
  Top-level supervisor for Sagents infrastructure.

  Starts the process registry, agent dynamic supervisor, and filesystem dynamic
  supervisor as children under a single supervisor.

  ## Why use this in your application?

  OTP shuts down supervision tree children in reverse start order. By adding
  `Sagents.Supervisor` to your application's supervision tree **after** your
  Repo and PubSub, you ensure that agent processes terminate **before** Repo and
  PubSub shut down. This allows agents to persist state and broadcast shutdown
  events during `terminate/2`.

  ## Usage

  Add `Sagents.Supervisor` to your application's supervision tree after your
  Repo, PubSub, and Presence, and **before** your Endpoint:

      # lib/my_app/application.ex
      def start(_type, _args) do
        children = [
          MyApp.Repo,
          {Phoenix.PubSub, name: MyApp.PubSub},
          MyAppWeb.Presence,
          Sagents.Supervisor,
          MyAppWeb.Endpoint
        ]

        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts)
      end

  > #### The Endpoint must come after `Sagents.Supervisor` {: .warning}
  >
  > Reverse shutdown order is the whole point of that placement. Listed after,
  > the Endpoint stops accepting requests *first*, and the registry is still
  > alive to serve whatever is in flight.
  >
  > Listed **before** `Sagents.Supervisor`, the Endpoint keeps serving requests
  > after the registry is gone, and every one of them fails until the BEAM
  > exits. Correct ordering narrows that window but does not remove it, because
  > the node stays reachable for the platform's whole drain period. Wire
  > `Sagents.ready?/0` into your readiness check as well. See
  > `docs/deployment.md`.

  ## What it starts

  - `Sagents.ProcessRegistry` — Process registry (local `Registry` or
    `Horde.Registry`)
  - Agents dynamic supervisor — For managing `AgentSupervisor` instances
  - Filesystem dynamic supervisor — For managing `FileSystemServer` instances

  The backend (local vs Horde) is determined by application config:

      # Single-node (default — no config needed)
      config :sagents, :distribution, :local

      # Distributed cluster
      config :sagents, :distribution, :horde

  ## Restart strategy

  Children are supervised `:rest_for_one`, with the registry first. Everything
  listed after it depends on it: an `AgentSupervisor` and an `AgentServer`
  register their `:via` names in the registry once, at start, and nothing
  re-registers them afterwards. A registry that loses its contents would
  otherwise leave them running but invisible to every lookup, which lets a
  conversation acquire a second AgentServer.

  `:rest_for_one` expresses that dependency. A registry failure takes the
  dynamic supervisors down with it, agents stop, and the next request re-creates
  them from persisted state. That is a real cost, and it is the right one: agent
  state is durable, so a restart is recoverable, while a silent duplicate is
  not.

  `Sagents.RegistryWatcher` sits between the registry and its dependents to
  connect a registry failure to that chain. On both backends the process that
  owns the registry's ETS tables runs under a supervisor of the backend's own,
  which can replace it with a fresh, empty one without ever failing a child of
  *this* supervisor. The watcher monitors that table-owning process and fails in
  its place. See `Sagents.ProcessRegistry.watched_name/0` for why it is not
  always the process registered as `Sagents.Registry`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    # Validate Horde configuration early (raises on invalid config)
    Sagents.Horde.ClusterConfig.validate!()

    children =
      [
        Sagents.ProcessRegistry.child_spec([]),
        # Sits between the registry and its dependents on purpose. Both Horde
        # and Elixir's Registry own their ETS tables in a process one level
        # below the child listed above, and both restart that process
        # internally with empty tables, so Sagents.Supervisor never sees a
        # child fail. The watcher observes the table-owning process and fails
        # in its place, which is what puts the restart below into the
        # :rest_for_one chain.
        Sagents.RegistryWatcher,
        Sagents.ProcessSupervisor.agents_supervisor_child_spec([]),
        Sagents.ProcessSupervisor.filesystem_supervisor_child_spec([])
      ] ++ membership_children()

    # :rest_for_one because everything after the registry holds `:via`
    # registrations in it that are established once at start. A registry
    # failure has to take them down so they re-register on the way back up.
    # See the moduledoc.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  # With `members: :participation`, start the `:pg` scope and the membership
  # manager *after* the Horde clusters (so set_members/2 has live targets). The
  # manager keeps Horde membership scoped to nodes running this supervisor.
  defp membership_children do
    if Sagents.Horde.ClusterConfig.participation_membership?() do
      [
        Sagents.Horde.MembershipManager.pg_scope_spec(),
        Sagents.Horde.MembershipManager
      ]
    else
      []
    end
  end
end
