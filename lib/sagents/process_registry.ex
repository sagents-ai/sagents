defmodule Sagents.ProcessRegistry do
  @moduledoc """
  Abstraction over process registry implementations.

  Supports two backends:

  - `:local` — Elixir's built-in `Registry` (single-node, zero extra deps)
  - `:horde` — `Horde.Registry` (distributed, requires the `:horde` dependency)

  ## Configuration

      # config/config.exs (or runtime.exs)

      # Single-node (default — no config needed)
      config :sagents, :distribution, :local

      # Distributed cluster
      config :sagents, :distribution, :horde

  When `:horde` is selected, Horde.Registry is started with `members: :auto`
  so it automatically discovers other nodes in the Erlang cluster.
  """

  @registry_name Sagents.Registry

  # ---------------------------------------------------------------------------
  # Startup
  # ---------------------------------------------------------------------------

  @doc """
  Returns the child spec for the configured registry backend.

  Used in `Sagents.Application` supervision tree.
  """
  def child_spec(_opts) do
    case distribution_type() do
      :local ->
        {Registry, keys: :unique, name: @registry_name}

      :horde ->
        assert_horde_available!()
        # Use module-based implementation for dynamic config
        Supervisor.child_spec(Sagents.Horde.RegistryImpl, shutdown: 15_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns a `:via` tuple for registering or looking up a process by key.

  ## Examples

      Sagents.ProcessRegistry.via_tuple({:agent_server, "agent-123"})
      # => {:via, Registry, {Sagents.Registry, {:agent_server, "agent-123"}}}
      #    or
      # => {:via, Horde.Registry, {Sagents.Registry, {:agent_server, "agent-123"}}}
  """
  def via_tuple(key) do
    {:via, registry_module(), {@registry_name, key}}
  end

  @doc """
  Look up a process by key.

  Returns `[{pid, value}]` if found, `[]` otherwise.

  ## Examples

      [{pid, _}] = Sagents.ProcessRegistry.lookup({:agent_server, "agent-123"})
  """
  def lookup(key) do
    registry_module().lookup(@registry_name, key)
  end

  @doc """
  Select processes matching a match specification.

  The match spec format is the same as `Registry.select/2`.

  ## Examples

      Sagents.ProcessRegistry.select([
        {{{:agent_server, :"\$1"}, :_, :_}, [], [:"\$1"]}
      ])
  """
  def select(match_spec) do
    registry_module().select(@registry_name, match_spec)
  end

  @doc """
  Returns the count of all registered entries.
  """
  def count do
    registry_module().count(@registry_name)
  end

  @doc """
  Returns the keys for the given process `pid`.

  ## Examples

      Sagents.ProcessRegistry.keys(pid)
      # => [{:agent_supervisor, "agent-123"}]
  """
  def keys(pid) do
    registry_module().keys(@registry_name, pid)
  end

  @doc """
  Returns the registry module (`Registry` or `Horde.Registry`).
  """
  def registry_module do
    case distribution_type() do
      :local -> Registry
      :horde -> Horde.Registry
    end
  end

  @doc """
  Returns the registry name atom (`Sagents.Registry`).
  """
  def registry_name, do: @registry_name

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp distribution_type do
    Application.get_env(:sagents, :distribution, :local)
  end

  defp assert_horde_available! do
    unless Code.ensure_loaded?(Horde.Registry) do
      raise """
      Sagents is configured to use Horde (config :sagents, :distribution, :horde)
      but the :horde dependency is not available.

      Add it to your mix.exs:

          {:horde, "~> 0.10"}
      """
    end
  end
end
