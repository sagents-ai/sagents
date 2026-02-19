defmodule Sagents.Horde.RegistryImpl do
  @moduledoc """
  Module-based Horde.Registry for dynamic configuration.

  Enables runtime configuration of cluster membership and other
  Horde.Registry options via application config.
  """
  use Horde.Registry

  @registry_name Sagents.Registry

  def start_link(init_arg) do
    Horde.Registry.start_link(__MODULE__, init_arg, name: @registry_name)
  end

  @impl true
  def init(init_arg) do
    [
      keys: :unique,
      members: members()
    ]
    |> Keyword.merge(Keyword.drop(init_arg, [:name]))
    |> Horde.Registry.init()
  end

  defp members do
    Sagents.Horde.ClusterConfig.resolve_members(@registry_name)
  end
end
