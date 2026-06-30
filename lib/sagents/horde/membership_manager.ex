defmodule Sagents.Horde.MembershipManager do
  @moduledoc """
  Keeps Horde cluster membership scoped to the nodes that actually run
  `Sagents.Supervisor`, and keeps it current as nodes come and go.

  This is the membership mechanism behind:

      config :sagents, :distribution, :horde
      config :sagents, :horde, members: :participation

  ## Why this exists

  Horde's built-in `members: :auto` derives membership from
  `Node.list([:visible, :this])` — *every* connected BEAM node, regardless of
  whether it runs Horde. In a cluster that meshes multiple service roles into
  one Erlang cluster, that pulls unrelated nodes into the Sagents Horde cluster:
  it bloats the DeltaCrdt sync fan-out (a cause of registration timeouts) and,
  for membership added but never reporting `:alive`, leaves dead entries that
  are never pruned.

  Membership here is instead derived from **participation**: every node that
  starts `Sagents.Supervisor` joins an OTP `:pg` group, and this process sets
  Horde's members to exactly the nodes in that group. Because a node runs
  `Sagents.Supervisor` only where the host application chose to (e.g. gated to a
  `:web` role), "nodes running Sagents" *is* "agent-hosting nodes" — no
  node-name predicate required. `:pg` removes a node's entry automatically on
  `:nodedown`, so dead nodes are pruned without any extra wiring.

  ## What it manages

  On startup and on every `:pg` join/leave it calls `Horde.Cluster.set_members/2`
  on all three Sagents Horde instances so they stay consistent:

  - `Sagents.Registry`
  - `Sagents.AgentsDynamicSupervisor`
  - `Sagents.FileSystem.FileSystemSupervisor`

  It is started automatically by `Sagents.Supervisor` (together with its `:pg`
  scope) when `members: :participation` is configured; you do not start it
  yourself.

  ## Partitioning

  When `config :sagents, :horde, partition: <value>` is set, the `:pg` group is
  keyed by that partition (`{:sagents_members, value}`). A node only joins and
  monitors its own partition's group, so membership is isolated per partition —
  e.g. nodes in one Fly.io region never become members of another region's Horde
  cluster, even when all nodes share one connected BEAM cluster.
  """

  use GenServer
  require Logger

  @compile {:no_warn_undefined, Horde.Cluster}

  @scope Sagents.Horde.MembershipScope
  @base_group :sagents_members

  # The Horde clusters whose membership we keep in sync. Each is a registered
  # name resolvable on the local node.
  @hordes [
    Sagents.Registry,
    Sagents.AgentsDynamicSupervisor,
    Sagents.FileSystem.FileSystemSupervisor
  ]

  @doc "The `:pg` scope used for participation tracking."
  def scope, do: @scope

  @doc """
  The `:pg` group joined by each participating node.

  Keyed by the configured partition (`Sagents.Horde.ClusterConfig.partition/0`)
  so nodes only cluster with same-partition peers. Unpartitioned membership uses
  the base group atom.
  """
  def group, do: group_for(Sagents.Horde.ClusterConfig.partition())

  @doc "The `:pg` group for a given partition (`nil` => unpartitioned base group)."
  def group_for(nil), do: @base_group
  def group_for(partition), do: {@base_group, partition}

  @doc "The Horde clusters this manager keeps membership-consistent."
  def hordes, do: @hordes

  @doc """
  Child spec for the `:pg` scope this manager relies on.

  `Sagents.Supervisor` starts this *before* the manager so the scope is
  available when the manager joins and monitors it.
  """
  def pg_scope_spec do
    %{
      id: @scope,
      start: {:pg, :start_link, [@scope]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    group = group()

    # Mark this node as a participant in its partition group, then monitor that
    # group so we react to same-partition nodes joining/leaving on :nodeup/down.
    :ok = :pg.join(@scope, group, self())
    {ref, _pids} = :pg.monitor(@scope, group)

    nodes = current_member_nodes(group)
    apply_members(nodes)

    {:ok, %{ref: ref, group: group, members: nodes}}
  end

  @impl true
  def handle_info({ref, action, _group, _pids}, %{ref: ref} = state)
      when action in [:join, :leave] do
    nodes = current_member_nodes(state.group)

    state =
      if nodes == state.members do
        state
      else
        Logger.debug("Sagents Horde membership changed (#{action}): #{inspect(nodes)}")

        apply_members(nodes)
        %{state | members: nodes}
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp current_member_nodes(group) do
    :pg.get_members(@scope, group)
    |> member_nodes()
  end

  @doc false
  # Unique sorted list of nodes hosting a participation marker pid. Public for
  # testing; not part of the supported API.
  def member_nodes(pids) do
    pids
    |> Enum.map(&node/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp apply_members(nodes) do
    for horde <- @hordes do
      members = Enum.map(nodes, &{horde, &1})

      try do
        :ok = Horde.Cluster.set_members(horde, members)
      catch
        kind, reason ->
          # A horde process may be momentarily unavailable (e.g. restarting).
          # The next :pg event re-applies, so log and move on rather than crash.
          Logger.warning(
            "Failed to set Horde members for #{inspect(horde)} " <>
              "(#{inspect(kind)}: #{inspect(reason)}); will retry on next change"
          )
      end
    end

    :ok
  end
end
