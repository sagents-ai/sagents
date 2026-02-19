defmodule Sagents.Horde.FileSystemSupervisorImpl do
  @moduledoc """
  Module-based Horde.DynamicSupervisor for filesystem processes.

  This enables dynamic configuration of Horde cluster membership
  and distribution strategy via application config.
  """
  use Horde.DynamicSupervisor

  @supervisor_name Sagents.FileSystem.FileSystemSupervisor

  def start_link(init_arg) do
    Horde.DynamicSupervisor.start_link(__MODULE__, init_arg, name: @supervisor_name)
  end

  @impl true
  def init(init_arg) do
    base_config = [
      strategy: :one_for_one,
      members: members(),
      distribution_strategy: distribution_strategy()
    ]

    base_config
    |> Keyword.merge(Keyword.drop(init_arg, [:name]))
    |> Horde.DynamicSupervisor.init()
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: 15_000
    }
  end

  defp members do
    Sagents.Horde.ClusterConfig.resolve_members(__MODULE__)
  end

  defp distribution_strategy do
    Application.get_env(:sagents, :horde, [])
    |> Keyword.get(:distribution_strategy, Horde.UniformDistribution)
  end
end
