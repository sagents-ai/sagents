defmodule Sagents.ProcessRegistry do
  @moduledoc """
  Abstraction over process registry implementations.

  Supports three backends:

  - `:local` — Elixir's built-in `Registry` (single-node, zero extra deps)
  - `:horde` — `Horde.Registry` (distributed, requires the `:horde` dependency)
  - `:global` — Erlang's `:global` (cluster-wide naming via OTP; no extra deps)

  ## Configuration

      # config/config.exs (or runtime.exs)

      # Single-node (default — no config needed)
      config :sagents, :distribution, :local

      # Distributed cluster (Horde)
      config :sagents, :distribution, :horde

      # Cluster-wide names via :global (no Horde; processes still run locally)
      config :sagents, :distribution, :global

  When `:horde` is selected, Horde.Registry is started with membership from
  `config :sagents, :horde` (see `Sagents.Horde.ClusterConfig`).

  When `:global` is selected, there is no registry process; names use
  `{:via, :global, {Sagents.Registry, key}}`. `select/1` and `keys/1` are
  emulated by scanning `:global` (see function docs for complexity).
  """

  @compile {:no_warn_undefined, [Horde.Registry, Sagents.Horde.RegistryImpl]}

  @registry_name Sagents.Registry

  # ---------------------------------------------------------------------------
  # Startup
  # ---------------------------------------------------------------------------

  @doc """
  Returns the child spec for the configured registry backend.

  Used in `Sagents.Application` supervision tree.

  For `:global`, returns a no-op supervised `Task` so the supervisor child list
  stays aligned; `:global` itself needs no extra process.
  """
  def child_spec(_opts) do
    case distribution_type() do
      :local ->
        {Registry, keys: :unique, name: @registry_name}

      :horde ->
        assert_horde_available!()
        # Use module-based implementation for dynamic config
        Supervisor.child_spec(Sagents.Horde.RegistryImpl, shutdown: 15_000)

      :global ->
        # Do not start anything
        nil
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
      #    or
      # => {:via, :global, {Sagents.Registry, {:agent_server, "agent-123"}}}
  """
  def via_tuple(key) do
    case distribution_type() do
      :global ->
        {:via, :global, {@registry_name, key}}

      :local ->
        {:via, Registry, {@registry_name, key}}

      :horde ->
        {:via, Horde.Registry, {@registry_name, key}}
    end
  end

  @doc """
  Look up a process by key.

  Returns `[{pid, value}]` if found, `[]` otherwise.

  ## Examples

      [{pid, _}] = Sagents.ProcessRegistry.lookup({:agent_server, "agent-123"})
  """
  def lookup(key) do
    case distribution_type() do
      :global ->
        case :global.whereis_name({@registry_name, key}) do
          :undefined -> []
          pid -> [{pid, nil}]
        end

      :local ->
        Registry.lookup(@registry_name, key)

      :horde ->
        Horde.Registry.lookup(@registry_name, key)
    end
  end

  @doc """
  Select processes matching a match specification.

  The match spec format is the same as `Registry.select/2` when using `:local`
  or `:horde`. With `:global`, only the match specs used in Sagents are
  supported (see `global_select/1`); this is O(n) over all global names.

  ## Examples

      Sagents.ProcessRegistry.select([
        {{{:agent_server, :"\$1"}, :_, :_}, [], [:"\$1"]}
      ])
  """
  def select(match_spec) do
    case distribution_type() do
      :global ->
        global_select(match_spec)

      :local ->
        Registry.select(@registry_name, match_spec)

      :horde ->
        Horde.Registry.select(@registry_name, match_spec)
    end
  end

  @doc """
  Returns the count of all registered entries scoped to this registry.

  With `:global`, counts names under the `Sagents.Registry` namespace only.
  """
  def count do
    case distribution_type() do
      :global ->
        :global.registered_names()
        |> Enum.count(fn
          {@registry_name, _} -> true
          _ -> false
        end)

      :local ->
        Registry.count(@registry_name)

      :horde ->
        Horde.Registry.count(@registry_name)
    end
  end

  @doc """
  Returns the keys for the given process `pid`.

  With `:global`, this scans all global names (O(n)).

  ## Examples

      Sagents.ProcessRegistry.keys(pid)
      # => [{:agent_supervisor, "agent-123"}]
  """
  def keys(pid) do
    case distribution_type() do
      :global ->
        :global.registered_names()
        |> Enum.filter(fn name ->
          match?({@registry_name, _}, name) and :global.whereis_name(name) == pid
        end)
        |> Enum.map(fn {@registry_name, key} -> key end)

      :local ->
        Registry.keys(@registry_name, pid)

      :horde ->
        Horde.Registry.keys(@registry_name, pid)
    end
  end

  @doc """
  Returns the registry module (`Registry`, `Horde.Registry`, or `:global`).

  For `:global`, this is the atom `:global` — it does not share the `Registry`
  API; use `Sagents.ProcessRegistry` helpers instead.
  """
  def registry_module do
    case distribution_type() do
      :local -> Registry
      :horde -> Horde.Registry
      :global -> :global
    end
  end

  @doc """
  Returns the registry name atom (`Sagents.Registry`).
  """
  def registry_name, do: @registry_name

  # ---------------------------------------------------------------------------
  # :global — select emulation
  # ---------------------------------------------------------------------------

  defp global_select([
         {
           {{:filesystem_server, :"$1"}, :"$2", :_},
           [],
           [{{:"$1", :"$2"}}]
         }
       ]) do
    :global.registered_names()
    |> Enum.flat_map(fn
      {@registry_name, {:filesystem_server, scope}} ->
        name = {@registry_name, {:filesystem_server, scope}}

        case :global.whereis_name(name) do
          :undefined -> []
          pid -> [{scope, pid}]
        end

      _ ->
        []
    end)
  end

  defp global_select([{{{tag, :"$1"}, :_, :_}, [], [:"$1"]}]) when is_atom(tag) do
    :global.registered_names()
    |> Enum.flat_map(fn
      {@registry_name, {^tag, id}} ->
        name = {@registry_name, {tag, id}}

        case :global.whereis_name(name) do
          :undefined -> []
          _pid -> [id]
        end

      _ ->
        []
    end)
  end

  defp global_select(other) do
    raise ArgumentError,
          "Sagents.ProcessRegistry.select/1 for :global does not support this match_spec: #{inspect(other)}"
  end

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
