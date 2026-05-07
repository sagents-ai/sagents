defmodule Sagents.Session do
  @moduledoc """
  Session lifecycle for conversation-centric agents. Owns the procedural
  work of: router consult, factory invocation, state seeding, supervisor
  config, subscriber wiring.

  ## Configuration

  Session functions take a `config` map with the following keys:

  - `:factory_router` - module implementing `Sagents.FactoryRouter`.
  - `:agent_persistence` - module implementing `Sagents.AgentPersistence`.
  - `:display_message_persistence` - module implementing
    `Sagents.DisplayMessagePersistence`.
  - `:pubsub` - `{Phoenix.PubSub, name}` tuple.
  - `:presence_module` - Phoenix Presence module.
  - `:inactivity_timeout` - milliseconds before agent stops on idle.
  - `:agent_id_fun` - 1-arity function mapping `conversation_id` →
    `agent_id` string.

  ## Factory contract

  Factories implement `c:Sagents.Factory.create_agent/2` taking
  `(agent_id, config)` and returning `{:ok, agent, session_opts}`. The
  router supplies `config` verbatim — by convention a typed struct from
  a paired `*Config` module. The library recognizes these keys in
  `session_opts`:

  - `:fresh_state_attrs` - map seeded into `Sagents.State.new!/1` on fresh
    state only (ignored when persisted state is restored). Use this to
    pre-populate todos, scratchpad data, or any other initial state. For
    seeding todos:

        {:ok, agent, fresh_state_attrs: %{todos: my_todos}}

  - `:supervisor_opts` - keyword list merged into the supervisor_config
    passed to `Sagents.AgentsDynamicSupervisor.start_agent_sync/1`. Use
    this for per-factory `AgentSupervisor` / `AgentServer` configuration
    such as `:message_preprocessor` or any other supervisor-level opt.
    The library does NOT inspect the contents — keys are forwarded
    verbatim, so factories can pass anything the supervisor accepts
    (including future additions) without requiring a library change.

  All other keys in `session_opts` are app-internal; the library plumbs
  them through but does not inspect them.
  """

  require Logger

  alias Sagents.{
    AgentServer,
    AgentSupervisor,
    AgentsDynamicSupervisor,
    State,
    Subscriber
  }

  @type config :: %{
          required(:factory_router) => module(),
          required(:agent_persistence) => module(),
          required(:display_message_persistence) => module(),
          required(:pubsub) => {module(), atom()},
          required(:presence_module) => module(),
          required(:inactivity_timeout) => pos_integer(),
          required(:agent_id_fun) => (term() -> String.t())
        }

  @type session_info :: %{
          agent_id: String.t(),
          pid: pid(),
          conversation_id: term()
        }

  @doc """
  Starts (or returns the existing) agent session for a conversation.

  Idempotent: if an agent is already running for `conversation_id`, returns
  the existing session info without consulting the router or factory again.

  ## Options

  - `:scope` — Phoenix scope (forwarded to factory + persistence).
  - `:request_opts` — keyword list passed to the router as the third
    argument. Routers commonly forward this verbatim into `factory_opts`.
  - `:initial_subscribers` — list of `{channel, pid}` tuples seeded as
    subscribers before the agent's `init/1` returns. Use to atomically
    start-and-subscribe.
  """
  @spec start(config(), conversation_id :: term(), opts :: keyword()) ::
          {:ok, session_info()} | {:error, term()}
  def start(config, conversation_id, opts \\ []) do
    agent_id = config.agent_id_fun.(conversation_id)

    case AgentServer.get_pid(agent_id) do
      nil ->
        do_start(config, conversation_id, agent_id, opts)

      pid ->
        Logger.debug("Agent session already running for conversation #{inspect(conversation_id)}")

        {:ok,
         %{
           agent_id: agent_id,
           pid: pid,
           conversation_id: conversation_id
         }}
    end
  end

  @doc """
  Ensure the agent session for `state.conversation_id` is running and
  that the calling process is subscribed to its events.

  `state` is the host's process-level map (LiveView socket assigns,
  GenServer state, etc.). Required keys:

  - `:conversation_id`
  - `:current_scope`

  Optional keys:

  - `:sagents_subs` (defaults to `%{}`) — existing `Sagents.Subscriber`
    subs map.

  Per-request data destined for the FactoryConfig flows through `opts`,
  not the state map:

  - `:request_opts` — keyword list forwarded verbatim to the router as
    its third argument. The router converts this to a map and passes it
    to your `*Config.from_inputs/1`. Use this for per-call fields like
    `:timezone`, `:tool_context`, or anything else your Config consumes.

  Returns `{:ok, %{sagents_subs: new_subs, agent_id: agent_id}}` for the
  caller to merge back into its state map.
  """
  @spec ensure_running(config(), state_map :: map(), opts :: keyword()) ::
          {:ok, %{sagents_subs: map(), agent_id: String.t()}} | {:error, term()}
  def ensure_running(config, state, opts \\ []) when is_map(state) do
    conversation_id = Map.fetch!(state, :conversation_id)
    agent_id = config.agent_id_fun.(conversation_id)
    subs = Map.get(state, :sagents_subs, %{})

    start_opts = [
      scope: Map.fetch!(state, :current_scope),
      request_opts: Keyword.get(opts, :request_opts, []),
      initial_subscribers: [{:main, self()}]
    ]

    case start(config, conversation_id, start_opts) do
      {:ok, %{pid: pid}} ->
        new_subs =
          case Map.get(subs, {:agent, agent_id}) do
            %{state: :subscribed, server_pid: ^pid} -> subs
            _other -> Subscriber.subscribe_to_agent(subs, agent_id)
          end

        {:ok, %{sagents_subs: new_subs, agent_id: agent_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stop the agent session for a conversation. No-op if nothing is running.
  """
  @spec stop(config(), conversation_id :: term()) :: {:ok, :stopped | :not_running}
  def stop(config, conversation_id) do
    agent_id = config.agent_id_fun.(conversation_id)

    case AgentServer.get_pid(agent_id) do
      nil ->
        {:ok, :not_running}

      _pid ->
        AgentServer.stop(agent_id)
        {:ok, :stopped}
    end
  end

  @doc "Whether an agent session is currently running for `conversation_id`."
  @spec running?(config(), conversation_id :: term()) :: boolean()
  def running?(config, conversation_id) do
    agent_id = config.agent_id_fun.(conversation_id)
    AgentServer.get_pid(agent_id) != nil
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp do_start(config, conversation_id, agent_id, opts) do
    scope = Keyword.get(opts, :scope)
    request_opts = Keyword.get(opts, :request_opts, [])
    initial_subscribers = Keyword.get(opts, :initial_subscribers, [])

    Logger.info("Starting agent session for conversation #{inspect(conversation_id)}")

    with {:ok, factory_module, factory_config} <-
           config.factory_router.resolve(scope, conversation_id, request_opts),
         {:ok, agent, session_opts} <-
           invoke_factory(factory_module, factory_config, agent_id) do
      fresh_state_attrs = derive_fresh_state_attrs(session_opts)

      {:ok, state} =
        State.load_or_new(
          config.agent_persistence,
          scope,
          %{agent_id: agent_id, conversation_id: conversation_id},
          fresh_state_attrs: fresh_state_attrs
        )

      supervisor_config =
        build_supervisor_config(
          config,
          agent_id,
          conversation_id,
          agent,
          state,
          initial_subscribers,
          Keyword.get(session_opts, :supervisor_opts, [])
        )

      case AgentsDynamicSupervisor.start_agent_sync(supervisor_config) do
        {:ok, _supervisor_pid} ->
          {:ok, session_info(agent_id, conversation_id)}

        {:error, reason} ->
          Logger.error("Failed to start agent session: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp invoke_factory(factory_module, config, agent_id) do
    factory_module.create_agent(agent_id, config)
    |> handle_factory_return(factory_module)
  rescue
    e in [FunctionClauseError, UndefinedFunctionError] ->
      if function_exported?(factory_module, :create_agent, 1) do
        reraise ArgumentError,
                """
                #{inspect(factory_module)} appears to use the legacy
                `create_agent/1` (keyword-opts) shape. The Sagents.Factory
                contract is now `create_agent(agent_id, config)`.

                Migration:

                    @impl Sagents.Factory
                    def create_agent(agent_id, %YourConfig{} = config) do
                      # ...
                    end

                See PLAN-RefactoringTheAgentAPI-FactoriesAndConfig.md.
                """,
                __STACKTRACE__
      else
        reraise e, __STACKTRACE__
      end
  end

  defp handle_factory_return({:ok, _agent, session_opts} = ok, _factory_module)
       when is_list(session_opts),
       do: ok

  defp handle_factory_return({:error, _reason} = err, _factory_module), do: err

  defp handle_factory_return({:ok, _agent, other}, factory_module) do
    raise ArgumentError, """
    #{inspect(factory_module)}.create_agent/2 returned a third element
    that is not a keyword list: #{inspect(other)}.

    The Sagents.Factory contract requires `{:ok, agent, session_opts}`
    where `session_opts` is a keyword list.
    """
  end

  defp handle_factory_return(other, factory_module) do
    raise ArgumentError, """
    #{inspect(factory_module)} returned an unexpected value from
    create_agent/2: #{inspect(other)}.

    Expected `{:ok, agent, session_opts}` or `{:error, reason}`.
    """
  end

  defp derive_fresh_state_attrs(session_opts) do
    case Keyword.fetch(session_opts, :fresh_state_attrs) do
      {:ok, attrs} when is_map(attrs) -> attrs
      :error -> %{}
    end
  end

  defp build_supervisor_config(
         config,
         agent_id,
         conversation_id,
         agent,
         state,
         initial_subscribers,
         supervisor_opts
       ) do
    presence_tracking = [
      enabled: true,
      presence_module: config.presence_module,
      topic: presence_topic(conversation_id)
    ]

    [
      agent_id: agent_id,
      name: AgentSupervisor.get_name(agent_id),
      agent: agent,
      initial_state: state,
      pubsub: config.pubsub,
      inactivity_timeout: config.inactivity_timeout,
      presence_tracking: presence_tracking,
      presence_module: config.presence_module,
      conversation_id: conversation_id,
      agent_persistence: config.agent_persistence,
      display_message_persistence: config.display_message_persistence,
      initial_subscribers: initial_subscribers
    ]
    # Merge factory-supplied supervisor_opts (e.g. :message_preprocessor) last
    # so factories CAN override base defaults if they have reason to. The
    # common case is additive keys the supervisor/AgentServer accept.
    |> Keyword.merge(supervisor_opts)
  end

  defp session_info(agent_id, conversation_id) do
    %{
      agent_id: agent_id,
      pid: AgentServer.get_pid(agent_id),
      conversation_id: conversation_id
    }
  end

  defp presence_topic(conversation_id), do: "conversation:#{conversation_id}"
end
