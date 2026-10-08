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
  starts `Sagents.Supervisor` joins an OTP `:pg` group, and this process adds
  each node to Horde's members as it joins that group and removes it once it
  leaves. Because a node runs
  `Sagents.Supervisor` only where the host application chose to (e.g. gated to a
  `:web` role), "nodes running Sagents" *is* "agent-hosting nodes" — no
  node-name predicate required. `:pg` removes a node's entry automatically on
  `:nodedown`, so dead nodes are pruned without any extra wiring.

  ## What it manages

  On startup and on every `:pg` join/leave it updates the members of all three
  Sagents Horde instances through `Horde.Cluster.set_members/2` so they stay
  consistent:

  - `Sagents.Registry`
  - `Sagents.AgentsDynamicSupervisor`
  - `Sagents.FileSystem.FileSystemSupervisor`

  Every update starts from what the instance holds at that moment and only
  adds the nodes a `:pg` view shows or removes the nodes `:pg` reported as
  gone. A view is never handed to Horde as the whole member set. `:pg`
  discovers the other nodes' scopes asynchronously, so for a moment after this
  process joins, the group it reads is a partial view of the cluster, while
  Horde, which also learns members through CRDT replication from its peers,
  may already hold the rest. Horde treats a member missing from `set_members/2`
  as removed and drops that member's registrations cluster-wide, so applying a
  partial view would unregister every agent on the nodes it has not seen yet.

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

    # Discovery of the other nodes' scopes is still in flight, so this is a
    # partial view. It can only add; the rest arrives as :join events.
    add_members(current_member_nodes(group))

    {:ok, %{ref: ref, group: group}}
  end

  @impl true
  def handle_info({ref, :join, _group, pids}, %{ref: ref} = state) do
    add_members(member_nodes(pids))
    {:noreply, state}
  end

  def handle_info({ref, :leave, _group, pids}, %{ref: ref} = state) do
    # A node has left only once none of its marker pids remain in the group.
    left = member_nodes(pids) -- current_member_nodes(state.group)
    remove_members(left)
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

  # Horde's only membership API is `set_members/2`, which takes what it is
  # given as the whole truth and removes everything else. So each instance is
  # updated from what it holds right now: nodes are added to that, or removed
  # from it, and Horde is only called when the result differs. Horde learns
  # members through CRDT replication as well, which is why "what it holds" is
  # read fresh each time rather than tracked here.
  defp add_members(nodes), do: update_members(:add, nodes, &Enum.uniq(&1 ++ nodes))

  defp remove_members([]), do: :ok
  defp remove_members(nodes), do: update_members(:remove, nodes, &(&1 -- nodes))

  defp update_members(action, nodes, update) do
    for horde <- @hordes do
      try do
        current = horde_member_nodes(horde)
        wanted = Enum.sort(update.(current))

        if wanted != Enum.sort(current) do
          Logger.debug(
            "Sagents Horde membership #{action} #{inspect(nodes)} on #{inspect(horde)}: #{inspect(wanted)}"
          )

          :ok = Horde.Cluster.set_members(horde, Enum.map(wanted, &{horde, &1}))
        end
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

  defp horde_member_nodes(horde) do
    horde
    |> Horde.Cluster.members()
    |> Enum.map(fn {_name, member_node} -> member_node end)
    |> Enum.uniq()
  end
end
