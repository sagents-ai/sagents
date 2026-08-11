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

  ## Availability

  A lookup can only be answered while the registry process is alive on *this*
  node. Two normal situations leave it unavailable: the node has not finished
  starting `Sagents.Supervisor`, and `Sagents.Supervisor` has shut down while
  the BEAM drains during a rolling deploy. In that second window the node is
  still reachable by a load balancer but can serve no agent request at all.

  Neither backend reports this condition on its own. `Horde.Registry.lookup/2`
  derives its ETS table name arithmetically and reads it unguarded, and Elixir's
  `Registry` does the same through `Registry.key_info!/1`, so both raise
  `ArgumentError` from inside `:ets` when the table's owning process is gone.
  This module puts a guard in front of them so the condition is reported rather
  than escaping as an `:ets` error:

  - `available?/0` reports it as a boolean.
  - `fetch/1` returns `{:error, :registry_unavailable}`, distinct from
    `{:error, :not_registered}`.
  - `lookup/1`, `select/1`, `count/0` and `keys/1` cannot express it in their
    return values, so they raise `Sagents.RegistryUnavailableError`.

  **`:registry_unavailable` must never be collapsed into "not registered".**
  A caller that reads "nothing is running" responds by starting an agent, so
  collapsing the two lets a draining node start a second agent for a
  conversation that already has one elsewhere. Both would then hold and persist
  state for the same conversation, with nothing reporting it.

  See `Sagents.ready?/0` and `docs/deployment.md`.
  """

  @compile {:no_warn_undefined, [Horde.Registry, Sagents.Horde.RegistryImpl]}

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
        # Sagents.LocalRegistry wraps Registry.start_link/1 to survive a restart
        # that races the outgoing registry's partition process, which traps
        # exits and holds its registered name for a few milliseconds after the
        # registry itself is gone. See `Sagents.LocalRegistry`.
        %{
          id: @registry_name,
          start: {Sagents.LocalRegistry, :start_link, [[keys: :unique, name: @registry_name]]},
          type: :supervisor
        }

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
  Whether this node's registry can currently answer lookups.

  `false` while the node is still starting `Sagents.Supervisor`, and after that
  supervisor has shut down while the BEAM drains during a rolling deploy.

  Checks the ETS table each backend actually reads, rather than the registry
  process name, because the table is what the read touches and what its owner
  takes with it when it dies.

  ## Examples

      if Sagents.ProcessRegistry.available?() do
        # this node can host and route agent sessions
      end
  """
  @spec available?() :: boolean()
  def available? do
    :ets.whereis(keys_table_name()) != :undefined
  end

  @doc """
  Raise `Sagents.RegistryUnavailableError` unless the registry can answer.

  Used by the functions here whose return shape cannot carry the condition.
  `operation` names the caller and appears in the message.
  """
  @spec ensure_available!(atom() | nil) :: :ok
  def ensure_available!(operation \\ nil) do
    if available?() do
      :ok
    else
      raise Sagents.RegistryUnavailableError, operation: operation, registry: @registry_name
    end
  end

  @doc """
  Look up a single process by key, without raising on an unavailable registry.

  This is the form to use on request paths. The three outcomes are kept
  distinct on purpose:

  - `{:ok, pid}` - registered and alive
  - `{:error, :not_registered}` - the registry answered, nothing is registered
  - `{:error, :registry_unavailable}` - the registry could not answer at all

  The second and third must stay distinct in whatever the caller does next.
  "Nothing is registered" means start one; "cannot answer" means this node
  cannot know, so it must not guess, because guessing produces a duplicate
  agent for a conversation that already has one on another node.

  ## Examples

      case Sagents.ProcessRegistry.fetch({:agent_server, "agent-123"}) do
        {:ok, pid} -> GenServer.call(pid, :get_status)
        {:error, :not_registered} -> {:error, :agent_not_running}
        {:error, :registry_unavailable} = error -> error
      end
  """
  @spec fetch(term()) :: {:ok, pid()} | {:error, :not_registered | :registry_unavailable}
  def fetch(key) do
    if available?() do
      case registry_module().lookup(@registry_name, key) do
        [{pid, _value}] -> {:ok, pid}
        [] -> {:error, :not_registered}
      end
    else
      {:error, :registry_unavailable}
    end
  rescue
    error in ArgumentError ->
      # The registry went away between the check above and the read. Re-check
      # rather than swallowing every ArgumentError, so a genuine argument bug
      # still surfaces as itself.
      if available?() do
        reraise(error, __STACKTRACE__)
      else
        {:error, :registry_unavailable}
      end
  end

  @doc """
  Look up a process by key.

  Returns `[{pid, value}]` if found, `[]` otherwise.

  Raises `Sagents.RegistryUnavailableError` when the registry cannot answer,
  because `[]` would be indistinguishable from "not registered". Prefer
  `fetch/1` on request paths.

  ## Examples

      [{pid, _}] = Sagents.ProcessRegistry.lookup({:agent_server, "agent-123"})
  """
  def lookup(key) do
    guarded(:lookup, fn -> registry_module().lookup(@registry_name, key) end)
  end

  @doc """
  Select processes matching a match specification.

  The match spec format is the same as `Registry.select/2`.

  Raises `Sagents.RegistryUnavailableError` when the registry cannot answer, so
  a draining node never reports an empty list as though it were a real result.

  ## Examples

      Sagents.ProcessRegistry.select([
        {{{:agent_server, :"\$1"}, :_, :_}, [], [:"\$1"]}
      ])
  """
  def select(match_spec) do
    guarded(:select, fn -> registry_module().select(@registry_name, match_spec) end)
  end

  @doc """
  Returns the count of all registered entries.

  Raises `Sagents.RegistryUnavailableError` when the registry cannot answer, so
  a draining node never reports a truthful-looking `0`.
  """
  def count do
    guarded(:count, fn -> registry_module().count(@registry_name) end)
  end

  @doc """
  Returns the keys for the given process `pid`.

  Raises `Sagents.RegistryUnavailableError` when the registry cannot answer, so
  a draining node never reports an empty list as though it were a real result.

  ## Examples

      Sagents.ProcessRegistry.keys(pid)
      # => [{:agent_supervisor, "agent-123"}]
  """
  def keys(pid) do
    guarded(:keys, fn -> registry_module().keys(@registry_name, pid) end)
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

  @doc """
  The name of the process whose death empties this node's registry.

  This is not always `registry_name/0`, and the difference is what
  `Sagents.RegistryWatcher` has to monitor.

  Under `:horde` the two are the same: `Horde.RegistryImpl` is registered as
  `Sagents.Registry` and owns its own ETS tables.

  Under `:local` they differ. `Registry.start_link/1` registers a
  `Registry.Supervisor` under the given name, but the tables that hold
  registrations belong to its `Registry.Partition` child. That partition can be
  restarted with empty tables while the supervisor keeps running and keeps its
  registered name, so watching the name would miss the failure entirely.
  Watching the partition catches both: it also dies whenever its supervisor
  does.

  The single-partition name is safe because `child_spec/1` starts the registry
  without a `:partitions` option. Changing that would need this to return every
  partition.
  """
  @spec watched_name() :: atom()
  def watched_name do
    case distribution_type() do
      :local -> Module.concat(@registry_name, "PIDPartition0")
      :horde -> @registry_name
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp distribution_type do
    Application.get_env(:sagents, :distribution, :local)
  end

  # The named ETS table each backend reads on a key lookup, and which its owning
  # process destroys when it exits.
  #
  #   - Horde: `Horde.RegistryImpl` creates `:"keys_<name>"` in init/1, and
  #     `Horde.Registry.lookup/2` reads it via `:"keys_#{registry}"`.
  #   - Elixir Registry: the table is named after the registry itself, and
  #     `Registry.key_info!/1` reads it.
  defp keys_table_name do
    case distribution_type() do
      :local -> @registry_name
      :horde -> :"keys_#{@registry_name}"
    end
  end

  # Run a registry read that cannot report unavailability in its return value.
  # Checks first, and re-checks on ArgumentError to cover the small window
  # between the check and the read without swallowing unrelated argument errors.
  defp guarded(operation, fun) do
    ensure_available!(operation)
    fun.()
  rescue
    error in ArgumentError ->
      if available?() do
        reraise(error, __STACKTRACE__)
      else
        reraise(
          Sagents.RegistryUnavailableError,
          [operation: operation, registry: @registry_name],
          __STACKTRACE__
        )
      end
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
