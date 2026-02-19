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
  Repo, PubSub, and Presence:

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

    children = [
      Sagents.ProcessRegistry.child_spec([]),
      Sagents.ProcessSupervisor.agents_supervisor_child_spec([]),
      Sagents.ProcessSupervisor.filesystem_supervisor_child_spec([])
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
