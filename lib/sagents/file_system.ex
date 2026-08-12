defmodule Sagents.FileSystem do
  @moduledoc """
  Public API for filesystem lifecycle management.

  Provides convenience functions for starting, stopping, and accessing
  filesystem instances independent of agent lifecycles.

  ## Filesystem Scopes

  Filesystems are identified by scope keys (tuples) that determine their lifecycle:
  - `{:user, user_id}` - User-scoped filesystem
  - `{:project, project_id}` - Project-scoped filesystem
  - `{:organization, org_id}` - Organization-scoped filesystem
  - `{:agent, agent_id}` - Agent-scoped filesystem (backward compatible)

  ## Usage

      # Start a filesystem with a specific directory (idempotent)
      {:ok, config} = FileSystemConfig.new(%{
        base_directory: "Documents",
        persistence_module: Disk,
        storage_opts: [path: "/data/users/123"]
      })

      {:ok, pid} = FileSystem.ensure_filesystem({:user, 123}, [config])

      # Or use a default config that catches all paths (no base_directory needed)
      {:ok, config} = FileSystemConfig.new(%{
        default: true,
        persistence_module: MyApp.DBPersistence,
        storage_opts: [user_id: 123]
      })

      {:ok, pid} = FileSystem.ensure_filesystem({:user, 123}, [config])

      # Check if running
      true = FileSystem.filesystem_running?({:user, 123})

      # Get PID
      {:ok, pid} = FileSystem.get_filesystem_pid({:user, 123})

      # Get scope from PID
      {:user, 123} = FileSystem.get_scope(pid)

      # Stop filesystem
      :ok = FileSystem.stop_filesystem({:user, 123})
  """

  alias Sagents.FileSystem.FileSystemSupervisor
  alias Sagents.FileSystemServer

  @doc """
  Ensure a filesystem is running for the given scope (idempotent).

  If the filesystem is already running, returns the existing PID.
  If not running, starts a new filesystem with the given configs.

  ## Parameters

  - `scope_key` - Tuple identifying the filesystem scope (e.g., `{:user, 123}`)
  - `configs` - List of FileSystemConfig structs
  - `opts` - Additional options:
    - `:supervisor` - Supervisor reference (PID or registered name). Defaults to `FileSystemSupervisor`.

  Subscribers receive events via direct `send/2` (see
  `Sagents.FileSystemServer.subscribe/1`)

  ## Returns

  - `{:ok, pid}` - Filesystem PID (existing or newly started)
  - `{:error, :registry_unavailable}` - this node's registry could not answer,
    so it cannot tell whether one is already running and deliberately does not
    start one
  - `{:error, reason}` - Error starting filesystem

  ## Examples

      {:ok, config} = FileSystemConfig.new(%{
        scope_key: {:user, 123},
        base_directory: "Documents",
        persistence_module: Disk,
        storage_opts: [path: "/data/users/123"]
      })

      # First call starts the filesystem
      {:ok, pid} = ensure_filesystem({:user, 123}, [config])

      # Subsequent calls return the same PID
      {:ok, ^pid} = ensure_filesystem({:user, 123}, [config])
  """
  @spec ensure_filesystem(tuple(), list(), keyword()) :: {:ok, pid()} | {:error, term()}

  def ensure_filesystem(scope_key, configs, opts \\ [])

  def ensure_filesystem(scope_key, _configs, _opts) when not is_tuple(scope_key) do
    {:error, :invalid_arguments}
  end

  def ensure_filesystem(_scope_key, configs, _opts) when not is_list(configs) do
    {:error, :invalid_arguments}
  end

  def ensure_filesystem(scope_key, configs, opts)
      when is_tuple(scope_key) and is_list(configs) do
    case FileSystemSupervisor.get_filesystem(scope_key) do
      {:ok, pid} ->
        # Already running
        {:ok, pid}

      {:error, :not_found} ->
        # Not running, start it
        case FileSystemSupervisor.start_filesystem(scope_key, configs, opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      {:error, :registry_unavailable} = error ->
        # This node cannot see whether a filesystem already exists for the
        # scope, so it must not start one. Starting anyway is how a scope ends
        # up with two servers holding the same files.
        error
    end
  end

  @doc """
  Start a new filesystem for the given scope.

  Returns an error if a filesystem is already running for this scope.
  For idempotent behavior, use `ensure_filesystem/3` instead.

  ## Parameters

  - `scope_key` - Tuple identifying the filesystem scope
  - `configs` - List of FileSystemConfig structs
  - `opts` - Additional options:
    - `:supervisor` - Supervisor reference (PID or registered name). Defaults to `FileSystemSupervisor`.

  ## Returns

  - `{:ok, pid}` - Successfully started filesystem
  - `{:error, {:already_started, pid}}` - Filesystem already running
  - `{:error, reason}` - Other error

  ## Examples

      {:ok, pid} = start_filesystem({:user, 123}, [config])
  """
  @spec start_filesystem(tuple(), list(), keyword()) :: {:ok, pid()} | {:error, term()}

  def start_filesystem(scope_key, configs, opts \\ []) do
    FileSystemSupervisor.start_filesystem(scope_key, configs, opts)
  end

  @doc """
  Stop a running filesystem.

  The filesystem will be gracefully terminated, allowing it to flush any pending writes.

  ## Parameters

  - `scope_key` - Tuple identifying the filesystem scope
  - `opts` - Additional options:
    - `:supervisor` - Supervisor reference (PID or registered name). Defaults to `FileSystemSupervisor`.

  ## Returns

  - `:ok` - Successfully stopped
  - `{:error, :not_found}` - Filesystem not running
  - `{:error, :registry_unavailable}` - this node's registry could not answer

  The last one matters more than it looks. This is often a best-effort cleanup
  called before real work, so it reports rather than raises: a raise here takes
  the caller's whole operation down with it, turning "the scratch filesystem
  survived" into "the record was never deleted".

  ## Examples

      :ok = stop_filesystem({:user, 123})
  """
  @spec stop_filesystem(tuple(), keyword()) ::
          :ok | {:error, :not_found | :registry_unavailable}

  def stop_filesystem(scope_key, opts \\ []) do
    FileSystemSupervisor.stop_filesystem(scope_key, opts)
  end

  @doc """
  Check if a filesystem is running for the given scope.
  **Raises on a node whose registry is unavailable.**

  `Sagents.RegistryUnavailableError` comes out of this whenever this node's
  registry cannot answer, which covers the drain window of every rolling
  deploy. A boolean has no room for "cannot tell", and `false` reads as
  "nothing is running", which a caller responds to by starting a second
  filesystem for a scope that already has one elsewhere. Use
  `fetch_filesystem_running/1` anywhere a web request can reach.

  ## Parameters

  - `scope_key` - Tuple identifying the filesystem scope

  ## Returns

  Boolean indicating whether the filesystem is running.

  ## Examples

      true = filesystem_running?({:user, 123})
      false = filesystem_running?({:user, 999})
  """
  @spec filesystem_running?(tuple()) :: boolean()
  def filesystem_running?(scope_key) when is_tuple(scope_key) do
    case fetch_filesystem_running(scope_key) do
      {:ok, running?} ->
        running?

      {:error, :registry_unavailable} ->
        raise Sagents.RegistryUnavailableError,
          operation: :"FileSystem.filesystem_running?/1"
    end
  end

  @doc """
  Whether a filesystem is running for `scope_key`, without raising.

  The non-raising sibling of `filesystem_running?/1`, in the same relationship
  as `Sagents.Session.fetch_running/2` to `running?/2`:

  - `{:ok, true}` / `{:ok, false}` - the registry answered
  - `{:error, :registry_unavailable}` - this node's registry could not answer

  Prefer this anywhere a web request can reach. `{:ok, false}` means "start
  one"; the error means this node cannot know, so it must not guess.

  ## Examples

      {:ok, true} = fetch_filesystem_running({:user, 123})
      {:ok, false} = fetch_filesystem_running({:user, 999})
  """
  @spec fetch_filesystem_running(tuple()) :: {:ok, boolean()} | {:error, :registry_unavailable}
  def fetch_filesystem_running(scope_key) when is_tuple(scope_key) do
    case FileSystemSupervisor.get_filesystem(scope_key) do
      {:ok, _pid} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, :registry_unavailable} = error -> error
    end
  end

  @doc """
  Get the PID of a running filesystem by scope key.

  ## Parameters

  - `scope_key` - Tuple identifying the filesystem scope

  ## Returns

  - `{:ok, pid}` - Filesystem found
  - `{:error, :not_found}` - Filesystem not running
  - `{:error, :registry_unavailable}` - this node's registry could not answer

  ## Examples

      {:ok, pid} = get_filesystem_pid({:user, 123})
  """
  @spec get_filesystem_pid(tuple()) ::
          {:ok, pid()} | {:error, :not_found | :registry_unavailable}
  def get_filesystem_pid(scope_key) do
    FileSystemSupervisor.get_filesystem(scope_key)
  end

  @doc """
  Get the scope key for a filesystem PID.

  ## Parameters

  - `pid` - Filesystem process PID

  ## Returns

  The scope key tuple, or `{:error, reason}` if the scope cannot be determined.

  ## Examples

      {:ok, {:user, 123}} = get_scope(pid)
  """
  @spec get_scope(pid()) :: {:ok, tuple()} | {:error, term()}
  def get_scope(pid) when is_pid(pid) do
    FileSystemServer.get_scope(pid)
  end

  @doc """
  List all running filesystems.

  ## Returns

  List of `{scope_key, pid}` tuples.

  Raises `Sagents.RegistryUnavailableError` when this node's registry cannot
  answer, rather than reporting an empty list as though it were a real result.

  ## Examples

      filesystems = list_filesystems()
      # => [{:user, 123, #PID<0.123.0>}, {:project, 456, #PID<0.124.0>}]
  """
  @spec list_filesystems() :: [{tuple(), pid()}]
  def list_filesystems do
    FileSystemSupervisor.list_filesystems()
  end
end
