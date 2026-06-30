defmodule Sagents.Horde.ClusterConfig do
  @moduledoc """
  Configuration helpers for Horde clustering.

  Two membership modes are supported, both dynamic:

  ### Auto-discovery (all visible nodes) — default

      config :sagents, :horde,
        members: :auto

  This is also the behaviour when no `:members` key is set. The literal atom
  `:auto` is passed straight through to Horde, which starts a
  `Horde.NodeListener` and keeps the member set in sync with *all visible* BEAM
  nodes as they come and go — dead nodes are pruned on `:nodedown`.

  > #### `:auto` includes every visible node {: .warning}
  >
  > Horde's `:auto` means *all* connected nodes, regardless of role. If your
  > Erlang cluster meshes multiple unrelated service roles together (e.g. a
  > shared libcluster selector), do not use `:auto` — agents will be scattered
  > across unrelated nodes and the DeltaCrdt fan-out will span all of them. Use
  > `:participation` instead.

  ### Participation-based (scoped to nodes running Sagents) — recommended for mixed clusters

      config :sagents, :horde,
        members: :participation

  Membership is the set of nodes that actually run `Sagents.Supervisor`,
  discovered via an OTP `:pg` group and kept current on `:nodeup`/`:nodedown` by
  `Sagents.Horde.MembershipManager`. Use this when your Erlang cluster contains
  nodes that should *not* host agents (other service roles): gate
  `Sagents.Supervisor` to the agent-hosting role(s) and membership follows
  automatically — no node-name predicate, dead nodes pruned for free. Unlike
  `:auto`, it never pulls non-participating nodes into the Horde cluster.

  #### Partitioning participation

      config :sagents, :horde,
        members: :participation,
        partition: System.get_env("FLY_REGION")

  An optional `:partition` further isolates participation into independent
  groups: a node only clusters with other nodes sharing the same partition
  value. It is any opaque grouping key, set per node (commonly from an env var).
  The motivating case is geography — set it to a Fly.io `FLY_REGION` so an agent
  for an Illinois user is never placed on, or routed through, a node in France —
  but it can be anything (datacenter, tenant tier, …).
  `nil`/unset means a single global participation group (the default).

  Only meaningful with `members: :participation`. See `docs/clustering.md`.
  """

  @doc """
  Resolve cluster members for a given module name.

  Reads the `:members` config from `:sagents, :horde` and returns a value
  suitable for Horde's `:members` init option:

  - `:auto` (and the default when unset) returns the literal atom `:auto`, so
    Horde starts a `Horde.NodeListener` and manages membership dynamically.
  - `:participation` returns a self-only seed `[{module, Node.self()}]`; Horde
    starts with no `NodeListener`, and `Sagents.Horde.MembershipManager`
    maintains the real member set from the `:pg` participation group.
  """
  def resolve_members(module_name) do
    case Application.get_env(:sagents, :horde, [])[:members] do
      :participation -> [{module_name, Node.self()}]
      nil -> :auto
      :auto -> :auto
      other -> raise ArgumentError, invalid_members_message(other)
    end
  end

  @doc """
  Whether participation-based membership is enabled.

  True when running under the `:horde` backend with `members: :participation`.
  `Sagents.Supervisor` uses this to decide whether to start the `:pg` scope and
  `Sagents.Horde.MembershipManager`.
  """
  def participation_membership? do
    Application.get_env(:sagents, :distribution, :local) == :horde and
      Application.get_env(:sagents, :horde, [])[:members] == :participation
  end

  @doc """
  The configured participation partition, or `nil` when unset.

  When set (any non-nil term), `Sagents.Horde.MembershipManager` isolates
  membership so this node only clusters with nodes sharing the same partition.
  Only meaningful with `members: :participation`.
  """
  def partition do
    Application.get_env(:sagents, :horde, [])[:partition]
  end

  @doc """
  Validates Horde configuration at startup.

  Raises if configuration is invalid.
  """
  def validate! do
    distribution = Application.get_env(:sagents, :distribution, :local)

    unless distribution in [:local, :horde] do
      raise """
      Invalid Sagents configuration: unrecognized distribution type #{inspect(distribution)}.

      Must be one of:

          config :sagents, :distribution, :local   # Single-node (default)
          config :sagents, :distribution, :horde   # Distributed cluster
      """
    end

    # Validate members config if Horde is enabled
    if distribution == :horde do
      validate_members_config!()
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_members_config! do
    members = Application.get_env(:sagents, :horde, [])[:members]

    unless members in [:auto, :participation, nil] do
      raise ArgumentError, invalid_members_message(members)
    end

    if partition() != nil and members != :participation do
      raise ArgumentError, """
      Invalid Sagents Horde configuration: :partition is set (#{inspect(partition())}) \
      but :members is #{inspect(members)}.

      :partition only applies to participation-based membership. Set:

          config :sagents, :horde, members: :participation, partition: ...
      """
    end

    :ok
  end

  defp invalid_members_message(value) do
    """
    Invalid :members configuration for Horde: #{inspect(value)}

    Must be one of:
      - :auto          # all visible nodes (default)
      - :participation # nodes running Sagents.Supervisor
    """
  end
end
