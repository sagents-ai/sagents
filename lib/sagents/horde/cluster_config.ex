defmodule Sagents.Horde.ClusterConfig do
  @moduledoc """
  Configuration helpers for Horde clustering.

  ## Configuration Examples

  ### Auto-discovery (all nodes in cluster)

      config :sagents, :horde,
        members: :auto

  ### Static member list

      config :sagents, :horde,
        members: [
          {Sagents.Horde.AgentsSupervisorImpl, :node1@host},
          {Sagents.Horde.AgentsSupervisorImpl, :node2@host}
        ]

  ### Dynamic via MFA tuple

      config :sagents, :horde,
        members: {MyApp.HordeConfig, :get_members, []}

  ### Regional clustering (Fly.io example)

      # In config/runtime.exs
      region = System.get_env("FLY_REGION") || "default"

      config :sagents, :horde,
        members: {Sagents.Horde.ClusterConfig, :regional_members, [region]}
  """

  require Logger

  @doc """
  Resolve cluster members for a given module name.

  Reads the `:members` config from `:sagents, :horde` and resolves it
  to a list of `{module, node}` tuples suitable for Horde.
  """
  def resolve_members(module_name) do
    case Application.get_env(:sagents, :horde, [])[:members] do
      :auto -> auto_members(module_name)
      list when is_list(list) -> list
      fun when is_function(fun, 0) -> fun.()
      {mod, fun, args} -> apply(mod, fun, [module_name | args])
      nil -> auto_members(module_name)
    end
  end

  @doc """
  Returns members for auto-discovery mode.

  Includes all connected nodes plus the current node.
  """
  def auto_members(module_name) do
    [Node.self() | Node.list()]
    |> Enum.map(&{module_name, &1})
  end

  @doc """
  Returns members for regional clustering.

  Only includes nodes with matching region metadata.
  Useful for Fly.io deployments where you want agents to stay
  within a geographic region.

  ## Examples

      # In config/runtime.exs
      region = System.get_env("FLY_REGION") || "default"

      config :sagents, :horde,
        members: {Sagents.Horde.ClusterConfig, :regional_members, [region]}
  """
  def regional_members(module_name, region) when is_binary(region) do
    # Store region in persistent_term on startup
    region_key = {:sagents_region, Node.self()}
    :persistent_term.put(region_key, region)

    # Get all nodes in same region
    [Node.self() | Node.list()]
    |> Enum.filter(&in_region?(&1, region))
    |> Enum.map(&{module_name, &1})
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

  defp in_region?(node, expected_region) do
    case :rpc.call(node, :persistent_term, :get, [{:sagents_region, node}, nil]) do
      ^expected_region -> true
      _ -> false
    end
  end

  defp validate_members_config! do
    members = Application.get_env(:sagents, :horde, [])[:members]

    cond do
      members == :auto ->
        :ok

      is_list(members) ->
        unless Enum.all?(members, &valid_member_tuple?/1) do
          raise """
          Invalid :members configuration for Horde.
          Expected list of {module, node} tuples, got: #{inspect(members)}
          """
        end

      is_function(members, 0) ->
        :ok

      is_tuple(members) and tuple_size(members) == 3 ->
        {mod, fun, args} = members

        unless is_atom(mod) and is_atom(fun) and is_list(args) do
          raise "Invalid MFA tuple for :members: #{inspect(members)}"
        end

      members == nil ->
        :ok

      true ->
        raise """
        Invalid :members configuration for Horde.
        Must be one of:
          - :auto
          - [{module, node}, ...]
          - function/0
          - {Module, :function, args}

        Got: #{inspect(members)}
        """
    end
  end

  defp valid_member_tuple?({mod, node}) when is_atom(mod) and is_atom(node), do: true
  defp valid_member_tuple?(_), do: false
end
