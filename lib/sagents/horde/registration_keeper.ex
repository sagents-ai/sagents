if Code.ensure_loaded?(Horde.Registry) do
  defmodule Sagents.Horde.RegistrationKeeper do
    @moduledoc """
    Restores a `:via` name that `Sagents.Registry` drops while the process
    holding it is still running.

    Started by `Sagents.Supervisor` under `config :sagents, :distribution,
    :horde`. You do not start it yourself.

    ## The race it covers

    When a node leaves, `Horde.Registry` prunes that node's names: it reads the
    keys its local table attributes to the node and deletes each one from the
    CRDT by key. At the same moment, `Horde.DynamicSupervisor` is restarting the
    node's agents on the survivors, and each restarted process registers the
    same names again. A registration written to the CRDT before the registry
    has applied it to its table is still listed under the departed node, so the
    prune deletes it. The process keeps running, but every lookup reports
    nothing there, and the next request starts a second agent for the same
    conversation.

    ## What it does

    The registry sends this process `{:unregister, registry, key, pid}` for
    every name it removes. When the name is one a Sagents process holds for its
    whole life, its owner is a live process on this node, and no other process
    holds the name, the name is registered again for that owner.

    The names kept are `{:agent_server, _}`, `{:agent_supervisor, _}`,
    `{:sub_agents_supervisor, _}`, `{:sub_agent, _}`, and
    `{:filesystem_server, _}`. Each is a `:via` name registered when its process
    starts and never unregistered while it runs, so a live owner without its name
    has lost it. Other keys are left alone, so an explicit unregister is never
    undone.

    A restored name is logged and emits `[:sagents, :registry, :restored]`
    telemetry with `%{count: 1}` and `%{key: key, pid: pid}`.

    ## Placement

    The registry delivers to its listeners with `send/2` to a registered name,
    which raises when nothing holds that name. This process is therefore listed
    before the registry in `Sagents.Supervisor`, so it is running whenever the
    registry is, and stops after it. The registry lists it as a listener only
    when it is running at the registry's start (see `listener_names/0`).
    """

    use GenServer
    require Logger

    @registry Sagents.Registry

    @kept_kinds [
      :agent_server,
      :agent_supervisor,
      :sub_agents_supervisor,
      :sub_agent,
      :filesystem_server
    ]

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end

    @doc """
    The listener names a `Horde.Registry` should be started with: this process
    when it is running, otherwise none.
    """
    @spec listener_names() :: [atom()]
    def listener_names do
      if Process.whereis(__MODULE__), do: [__MODULE__], else: []
    end

    @impl true
    def init(opts) do
      {:ok, %{registry: Keyword.get(opts, :registry, @registry)}}
    end

    @impl true
    def handle_info(
          {:unregister, registry, {kind, _id} = key, pid},
          %{registry: registry} = state
        )
        when kind in @kept_kinds and is_pid(pid) and node(pid) == node() do
      maybe_restore(registry, key, pid)
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp maybe_restore(registry, key, pid) do
      # The registry notifies listeners before it deletes the name from its
      # table. A call to it returns only after that message is fully handled,
      # so the lookup below sees the table as the removal left it.
      _members = Horde.Cluster.members(registry)

      if Process.alive?(pid) and Horde.Registry.lookup(registry, key) == [] do
        restore(registry, key, pid)
      end
    catch
      # A registry that is restarting or stopping cannot be asked. Its restart
      # goes through Sagents.Supervisor's :rest_for_one chain, which restarts
      # the name holders too.
      kind, reason ->
        Logger.debug(
          "Could not check registration #{inspect(key)} for #{inspect(pid)}: " <>
            "#{inspect(kind)} #{inspect(reason)}"
        )
    end

    defp restore(registry, key, pid) do
      case Horde.Registry.register_name({registry, key}, pid) do
        :yes ->
          Logger.warning(
            "Restored registration #{inspect(key)} for #{inspect(pid)}, " <>
              "which the registry dropped while the process was running"
          )

          :telemetry.execute([:sagents, :registry, :restored], %{count: 1}, %{
            key: key,
            pid: pid
          })

        :no ->
          :ok
      end
    end
  end
end
