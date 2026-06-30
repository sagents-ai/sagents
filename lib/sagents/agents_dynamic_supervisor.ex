defmodule Sagents.AgentsDynamicSupervisor do
  @moduledoc """
  Dynamic supervisor for managing AgentSupervisor instances.

  Each AgentSupervisor manages a single agent (conversation) and its supporting infrastructure.
  This supervisor allows agents to be started and stopped dynamically as conversations are created
  and terminated.

  ## Scope

  Unlike FileSystemSupervisor which scopes by user/project, this supervisor manages individual
  agent instances identified by `agent_id` (typically "conversation-{id}").

  ## Usage

      # Start the supervisor (typically in your Application)
      {:ok, pid} = AgentsDynamicSupervisor.start_link(name: MyApp.AgentsDynamicSupervisor)

      # Start an agent supervisor
      {:ok, agent_sup_pid} = AgentsDynamicSupervisor.start_agent(
        agent_id: "conversation-123",
        agent: agent,
        initial_state: state,
        pubsub: {Phoenix.PubSub, :my_app_pubsub}
      )

      # Stop an agent supervisor
      :ok = AgentsDynamicSupervisor.stop_agent("conversation-123")

      # List all running agents
      agent_ids = AgentsDynamicSupervisor.list_agents()
  """

  use DynamicSupervisor
  require Logger

  alias Sagents.AgentSupervisor

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the AgentsDynamicSupervisor.

  ## Options

  - `:name` - Registered name for the supervisor (optional, defaults to `__MODULE__`)

  ## Examples

      {:ok, pid} = start_link(name: MyApp.AgentsDynamicSupervisor)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a new agent supervisor as a child of this dynamic supervisor.

  ## Parameters

  - `opts` - Keyword list of options passed to AgentSupervisor.start_link/1
    - `:agent_id` - Agent identifier (required, will be extracted to set supervisor name)
    - `:agent` - The Agent struct (required)
    - `:initial_state` - Initial State for AgentServer (optional)
    - `:pubsub` - PubSub configuration as `{module(), atom()}` tuple (optional, used only for `Phoenix.Presence` wiring)
    - `:inactivity_timeout` - Timeout in milliseconds (optional)
    - `:shutdown_delay` - Shutdown delay in milliseconds (optional)
    - `:presence_tracking` - Presence tracking configuration (optional)
    - `:conversation_id` - Conversation identifier (optional)
    - `:agent_persistence` - Module implementing `Sagents.AgentPersistence` (optional)
    - `:display_message_persistence` - Module implementing `Sagents.DisplayMessagePersistence` (optional)
    - `:supervisor` - Supervisor reference (optional, defaults to `__MODULE__`)

  ## Returns

  - `{:ok, pid}` - Agent supervisor started successfully
  - `{:ok, pid, info}` - Agent supervisor already running (idempotent)
  - `{:error, reason}` - Failed to start

  ## Examples

      {:ok, agent_sup_pid} = AgentsDynamicSupervisor.start_agent(
        agent_id: "conversation-123",
        agent: agent,
        initial_state: state,
        pubsub: {Phoenix.PubSub, :my_app_pubsub}
      )
  """
  @spec start_agent(keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(opts) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)

    # Extract agent_id and set supervisor name
    agent_id = Keyword.fetch!(opts, :agent_id)
    supervisor_name = AgentSupervisor.get_name(agent_id)

    # Add name to opts for AgentSupervisor
    supervisor_opts = Keyword.put(opts, :name, supervisor_name)

    # Remove :supervisor key as it's not needed by AgentSupervisor
    supervisor_opts = Keyword.delete(supervisor_opts, :supervisor)

    # Start as child of dynamic supervisor
    # Note: DynamicSupervisor always shows :undefined for child IDs in which_children/1
    # This is expected behavior - children are tracked by PID, not ID
    child_spec = %{
      id: AgentSupervisor,
      start: {AgentSupervisor, :start_link, [supervisor_opts]},
      restart: :transient,
      type: :supervisor
    }

    case Sagents.ProcessSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} ->
        Logger.debug("Started AgentSupervisor for agent_id=#{agent_id}, pid=#{inspect(pid)}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug(
          "AgentSupervisor already running for agent_id=#{agent_id}, pid=#{inspect(pid)}"
        )

        {:ok, pid, :already_started}

      {:error, reason} = error ->
        if registration_timeout?(reason) do
          # Retryable: the :via registration call exceeded Horde's hardcoded 5s
          # default. Logged at warning since `start_agent_sync/1` retries it; a
          # genuinely-live prior registration surfaces as {:already_started, _}
          # above, so we deliberately do NOT trust a possibly-dead remote pid
          # here (Process.alive?/1 can't check a remote node).
          Logger.warning(
            "AgentSupervisor registration for agent_id=#{agent_id} timed out: #{inspect(reason)}"
          )
        else
          Logger.error(
            "Failed to start AgentSupervisor for agent_id=#{agent_id}: #{inspect(reason)}"
          )
        end

        error
    end
  end

  @doc """
  Start a new agent supervisor and wait for it to be ready.

  This is a synchronous version that waits for the AgentServer child to be
  fully registered before returning. See `AgentSupervisor.start_link_sync/1`
  for details on why this is needed.

  ## Parameters

  Same as `start_agent/1`, plus:
  - `:startup_timeout` - Maximum time to wait for AgentServer to be ready (default: 5000ms)
  - `:registration_retries` - How many extra times to retry the start if the
    AgentSupervisor's `:via` registration times out (Horde/distributed only).
    Defaults to `1`. See "Registration timeouts" below.
  - `:registration_retry_backoff` - Milliseconds to wait between registration
    retries (default: 250ms).

  ## Registration timeouts

  Under the `:horde` distribution backend, a newly-spawned `AgentSupervisor`
  registers its `:via` name in `Horde.Registry` before `init/1` runs, via a
  `GenServer.call` that uses Horde's hardcoded 5000ms default. On a busy or
  churning cluster that call can time out, surfacing as
  `{:timeout, {GenServer, :call, [Sagents.Registry, {:register, ...}, 5000]}}`.

  The `GenServer.call` timeout runs *inside the spawning supervisor* during
  `:gen.init_it`, so the timeout exit kills that process — after this error the
  supervisor is gone, not lingering. This function therefore simply **retries**
  the start with a short backoff (up to `:registration_retries` times).

  It deliberately does not try to "recover" by looking the pid back up: the
  process is dead, and the placed pid is typically on a remote node where
  `Process.alive?/1` cannot verify liveness anyway. A genuinely-live prior
  registration (e.g. a concurrent start that won) still surfaces correctly as
  `{:ok, pid, :already_started}` from `start_agent/1`.

  ## Examples

      {:ok, agent_sup_pid} = AgentsDynamicSupervisor.start_agent_sync(
        agent_id: "conversation-123",
        agent: agent,
        initial_state: state,
        pubsub: {Phoenix.PubSub, :my_app_pubsub},
        startup_timeout: 10_000
      )
  """
  @spec start_agent_sync(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent_sync(opts) do
    startup_timeout = Keyword.get(opts, :startup_timeout, 5_000)
    retries = Keyword.get(opts, :registration_retries, 1)
    agent_id = Keyword.fetch!(opts, :agent_id)

    do_start_agent_sync(opts, agent_id, startup_timeout, retries)
  end

  defp do_start_agent_sync(opts, agent_id, startup_timeout, retries_left) do
    case start_agent(opts) do
      {:ok, _pid} ->
        # Wait for AgentServer to be registered
        wait_for_agent_ready(agent_id, startup_timeout)

      {:ok, _pid, :already_started} ->
        # Already running, verify it's ready
        wait_for_agent_ready(agent_id, startup_timeout)

      {:error, reason} = error ->
        if retries_left > 0 and registration_timeout?(reason) do
          backoff = Keyword.get(opts, :registration_retry_backoff, 250)

          Logger.warning(
            "Retrying AgentSupervisor start for agent_id=#{agent_id} after registration " <>
              "timeout (#{retries_left} attempt(s) left, backoff=#{backoff}ms)"
          )

          Process.sleep(backoff)
          do_start_agent_sync(opts, agent_id, startup_timeout, retries_left - 1)
        else
          error
        end
    end
  end

  @doc """
  Stop an agent supervisor.

  ## Parameters

  - `agent_id` - Agent identifier
  - `opts` - Options (optional)
    - `:supervisor` - Supervisor reference (defaults to `__MODULE__`)
    - `:reason` - Shutdown reason (defaults to `:normal`)
    - `:timeout` - Shutdown timeout in milliseconds (defaults to `:infinity`)

  ## Examples

      :ok = AgentsDynamicSupervisor.stop_agent("conversation-123")
      :ok = AgentsDynamicSupervisor.stop_agent("conversation-123", reason: :shutdown, timeout: 5000)
  """
  @spec stop_agent(String.t(), keyword()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)

    case AgentSupervisor.get_pid(agent_id) do
      {:ok, pid} ->
        Sagents.ProcessSupervisor.terminate_child(supervisor, pid)
        Logger.debug("Stopped AgentSupervisor for agent_id=#{agent_id}")
        :ok

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  List all running agent IDs.

  ## Parameters

  - `supervisor` - Supervisor reference (optional, defaults to `__MODULE__`)

  ## Returns

  List of agent_id strings

  ## Examples

      agent_ids = AgentsDynamicSupervisor.list_agents()
      # => ["conversation-1", "conversation-2"]
  """
  @spec list_agents(atom() | pid()) :: [String.t()]
  def list_agents(supervisor \\ __MODULE__) do
    Sagents.ProcessSupervisor.which_children(supervisor)
    |> Enum.map(fn {_id, pid, _type, _modules} ->
      # Get agent_id from the AgentSupervisor's registered name via Registry
      case Sagents.ProcessRegistry.keys(pid) do
        [{:agent_supervisor, agent_id}] -> agent_id
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Count running agents.

  ## Parameters

  - `supervisor` - Supervisor reference (optional, defaults to `__MODULE__`)

  ## Examples

      count = AgentsDynamicSupervisor.count_agents()
      # => 5
  """
  @spec count_agents(atom() | pid()) :: non_neg_integer()
  def count_agents(supervisor \\ __MODULE__) do
    Sagents.ProcessSupervisor.count_children(supervisor).active
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Matches the exact shape of a Horde `:via` registration timeout, e.g.
  # `{:timeout, {GenServer, :call, [Sagents.Registry, {:register, _, _, _}, 5000]}}`.
  # Anything else (a real crash, :already_present, etc.) is a genuine failure.
  defp registration_timeout?(
         {:timeout, {GenServer, :call, [registry, {:register, _key, _value, _pid} | _rest]}}
       ) do
    registry == Sagents.ProcessRegistry.registry_name()
  end

  defp registration_timeout?(_reason), do: false

  defp wait_for_agent_ready(agent_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_agent_ready(agent_id, deadline, 10)
  end

  defp do_wait_for_agent_ready(agent_id, deadline, delay) do
    case AgentSupervisor.get_pid(agent_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(delay)
          # Exponential backoff with max 100ms
          next_delay = min(delay * 2, 100)
          do_wait_for_agent_ready(agent_id, deadline, next_delay)
        else
          {:error, :timeout_waiting_for_agent}
        end
    end
  end
end
