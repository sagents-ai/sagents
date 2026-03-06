defmodule Sagents.Middleware do
  @moduledoc """
  Behavior for DeepAgent middleware components.

  Middleware provides a composable pattern for adding capabilities to agents. Each
  middleware component can contribute:

  - System prompt additions
  - Tools (Functions)
  - State schema modifications
  - Pre/post processing hooks
  - LLM callback handlers (token usage, tool execution, message processing)

  ## Middleware Lifecycle

  1. **Initialization** - `init/1` is called when middleware is configured
  2. **Tool Collection** - `tools/1` provides tools to add to the agent
  3. **Prompt Assembly** - `system_prompt/1` contributes to the system prompt
  4. **Callback Collection** - `callbacks/1` provides LLM event handlers
  5. **Before Model** - `before_model/2` preprocesses state before LLM call
  6. **After Model** - `after_model/2` postprocesses state after LLM response
  7. **Fork Context** - `on_fork_context/2` injects process-local state into the
     context map before a sub-agent is spawned (e.g., OpenTelemetry span context,
     Logger metadata)

  ## Example

      defmodule MyMiddleware do
        @behaviour Sagents.Middleware

        @impl true
        def init(opts) do
          config = %{enabled: Keyword.get(opts, :enabled, true)}
          {:ok, config}
        end

        @impl true
        def system_prompt(_config) do
          "You have access to custom capabilities."
        end

        @impl true
        def tools(_config) do
          [my_custom_tool()]
        end

        @impl true
        def callbacks(_config) do
          %{
            on_llm_token_usage: fn _chain, usage ->
              Logger.info("Token usage: \#{inspect(usage)}")
            end
          }
        end

        @impl true
        def before_model(state, _config) do
          # Preprocess state
          {:ok, state}
        end
      end

  ## Middleware Configuration

  Middleware can be specified as:

  - Module name: `MyMiddleware`
  - Tuple with options: `{MyMiddleware, [enabled: true]}`

  ## Choosing Between AgentContext and State.metadata

  When writing middleware, you will often need to store and retrieve data.
  Choose the right store based on the persistence test:

  - **Use `AgentContext`** for process-local state that middleware needs to
    propagate to child processes. Implement `on_fork_context/2` to inject
    values and register restore functions.

    Example: An OpenTelemetry middleware storing span context.

  - **Use `State.metadata`** for data that must survive serialization and
    be available after conversation restoration.

    Example: ConversationTitle storing the generated title.

  Never store non-serializable values (PIDs, references, functions) in
  `State.metadata` — they will be lost on serialization. Use `AgentContext`
  with restore functions for such values.
  """
  alias Sagents.State
  alias Sagents.MiddlewareEntry

  @type config :: keyword()
  @type middleware_config :: any()
  @type middleware_result ::
          {:ok, State.t()} | {:interrupt, State.t(), any()} | {:error, term()}

  @doc """
  Initialize middleware with configuration options.

  Called once when the middleware is added to an agent. Returns configuration
  that will be passed to other callbacks.

  ## Convention

  - Input: `opts` as keyword list
  - Output: `config` as map for efficient runtime access

  Defaults to converting opts to a map if not implemented.

  ## Example

      def init(opts) do
        config = %{
          enabled: Keyword.get(opts, :enabled, true),
          max_retries: Keyword.get(opts, :max_retries, 3)
        }
        {:ok, config}
      end
  """
  @callback init(config) :: {:ok, middleware_config} | {:error, term()}

  @doc """
  Provide system prompt text for this middleware.

  Can return a single string or list of strings that will be joined.

  Defaults to empty string if not implemented.
  """
  @callback system_prompt(middleware_config) :: String.t() | [String.t()]

  @doc """
  Provide tools (Functions) that this middleware adds to the agent.

  Defaults to empty list if not implemented.
  """
  @callback tools(middleware_config) :: [LangChain.Function.t()]

  @doc """
  Process state before it's sent to the LLM.

  Receives the current agent state and can modify messages, add context, or
  perform validation before the LLM is invoked.

  Defaults to `{:ok, state}` if not implemented.

  ## Parameters

  - `state` - The current `Sagents.State` struct
  - `config` - The middleware configuration from `init/1`

  ## Returns

  - `{:ok, updated_state}` - Success with potentially modified state
  - `{:error, reason}` - Failure, halts execution
  """
  @callback before_model(State.t(), middleware_config) :: middleware_result()

  @doc """
  Process state after receiving LLM response.

  Receives the state after the LLM has responded and can modify the response,
  extract information, or update state.

  Defaults to `{:ok, state}` if not implemented.

  ## Parameters

  - `state` - The current `Sagents.State` struct (with LLM response)
  - `config` - The middleware configuration from `init/1`

  ## Returns

  - `{:ok, updated_state}` - Success with potentially modified state
  - `{:interrupt, state, interrupt_data}` - Pause execution for human intervention
  - `{:error, reason}` - Failure, halts execution
  """
  @callback after_model(State.t(), middleware_config) :: middleware_result()

  @doc """
  Handle asynchronous messages sent to this middleware.

  Middleware can spawn async tasks that send messages back to the AgentServer using
  `send(server_pid, {:middleware_message, middleware_id, message})`. When such messages
  are received, they are routed to this callback.

  This enables patterns like:
  - Spawning background processing tasks
  - Receiving results from async operations
  - Updating state based on external events

  Defaults to `{:ok, state}` if not implemented.

  ## Parameters

  - `message` - The message payload sent from the async task
  - `state` - The current `Sagents.State` struct
  - `config` - The middleware configuration from `init/1`

  ## Returns

  - `{:ok, updated_state}` - Success with potentially modified state
  - `{:error, reason}` - Failure (logged but does not halt agent execution)

  ## Example

      def handle_message({:title_generated, title}, state, _config) do
        updated_state = State.put_metadata(state, "conversation_title", title)
        {:ok, updated_state}
      end

      def handle_message({:title_generation_failed, reason}, state, _config) do
        Logger.warning("Title generation failed: \#{inspect(reason)}")
        {:ok, state}
      end
  """
  @callback handle_message(message :: term(), State.t(), middleware_config) ::
              {:ok, State.t()}
              | {:error, term()}

  @doc """
  Provide the state schema module for this middleware.

  If the middleware needs to add fields to the agent state, it should
  return a module that defines those fields.

  Defaults to `nil` if not implemented.
  """
  @callback state_schema() :: module() | nil

  @doc """
  Called when the AgentServer starts or restarts.

  This allows middleware to perform initialization actions that require
  the AgentServer to be running, such as broadcasting initial state to
  subscribers (e.g., TODOs for UI display).

  Receives the current state and middleware config.
  Returns `{:ok, state}` (state is not typically modified here but could be).

  Defaults to `{:ok, state}` if not implemented.

  ## Parameters

  - `state` - The current `Sagents.State` struct
  - `config` - The middleware configuration from `init/1`

  ## Returns

  - `{:ok, state}` - Success (state typically unchanged)
  - `{:error, reason}` - Failure (logged but does not halt agent)

  ## Example

      def on_server_start(state, _config) do
        # Broadcast initial todos when AgentServer starts
        broadcast_todos(state.agent_id, state.todos)
        {:ok, state}
      end
  """
  @callback on_server_start(State.t(), middleware_config) :: {:ok, State.t()} | {:error, term()}

  @doc """
  Provide LangChain callback handlers for this middleware.

  Receives the middleware configuration from `init/1` and returns a callback
  handler map compatible with `LangChain.Chains.LLMChain.add_callback/2`.
  This allows middleware to observe LLM events such as token usage, tool
  execution, and message processing.

  When multiple middleware declare callbacks, all handlers are collected and
  fire in fan-out fashion (every matching handler from every middleware fires).

  Defaults to empty map (`%{}`) if not implemented. Return `%{}` for no callbacks.

  ## Parameters

  - `config` - The middleware configuration from `init/1`

  ## Returns

  - A map of callback keys to handler functions

  ## Available Callback Keys

  These are the LangChain-native keys supported by `LLMChain`. Use only these
  keys in your callback map (see `LangChain.Chains.ChainCallbacks` for full
  type signatures):

  **Model-level callbacks:**
  - `:on_llm_new_delta` - Streaming token/delta received
  - `:on_llm_new_message` - Complete message from LLM
  - `:on_llm_ratelimit_info` - Rate limit headers from provider
  - `:on_llm_token_usage` - Token usage information
  - `:on_llm_response_headers` - Raw response headers

  **Chain-level callbacks:**
  - `:on_message_processed` - Message fully processed by chain
  - `:on_message_processing_error` - Error processing a message
  - `:on_error_message_created` - Error message created
  - `:on_tool_call_identified` - Tool call detected during streaming
  - `:on_tool_execution_started` - Tool begins executing
  - `:on_tool_execution_completed` - Tool finished successfully
  - `:on_tool_execution_failed` - Tool execution errored
  - `:on_tool_response_created` - Tool response message created
  - `:on_retries_exceeded` - Max retries exhausted

  ## Example

      def callbacks(_config) do
        %{
          on_llm_token_usage: fn _chain, usage ->
            Logger.info("Token usage: \#{inspect(usage)}")
          end,
          on_message_processed: fn _chain, message ->
            Logger.info("Message: \#{inspect(message)}")
          end
        }
      end
  """
  @callback callbacks(middleware_config) :: map()

  @doc """
  Inject process-local state into the context map before forking to a child process.

  Called during `AgentContext.fork_with_middleware/1` before a sub-agent is spawned.
  This gives each middleware the opportunity to capture process-local state
  (e.g., OpenTelemetry span context, Logger metadata, correlation IDs) into the
  context map so it can be propagated to child processes.

  The callback receives the current context map and the middleware configuration,
  and must return a (potentially modified) context map.

  Use `AgentContext.add_restore_fn/2` inside this callback to register a function
  that the child process will call during `AgentContext.init/1` to rebuild
  process-local state from the context.

  Defaults to returning the context unchanged if not implemented.

  ## Parameters

  - `context` - The current context map being prepared for the child process
  - `config` - The middleware configuration from `init/1`

  ## Returns

  - A (potentially modified) context map

  ## Example

      def on_fork_context(context, _config) do
        # Capture OpenTelemetry span context
        otel_ctx = OpenTelemetry.Ctx.get_current()
        context = Map.put(context, :otel_ctx, otel_ctx)

        # Register a restore function for the child process
        AgentContext.add_restore_fn(context, fn ctx ->
          OpenTelemetry.Ctx.attach(ctx[:otel_ctx])
        end)
      end
  """
  @callback on_fork_context(context :: map(), middleware_config) :: map()

  @optional_callbacks [
    init: 1,
    system_prompt: 1,
    tools: 1,
    before_model: 2,
    after_model: 2,
    handle_message: 3,
    state_schema: 0,
    on_server_start: 2,
    callbacks: 1,
    on_fork_context: 2
  ]

  @doc """
  Normalize middleware specification to {module, config} tuple.

  Accepts:
  - Module atom: `MyMiddleware` -> `{MyMiddleware, []}`
  - Tuple with keyword list: `{MyMiddleware, [key: value]}` -> `{MyMiddleware, [key: value]}`
  """
  def normalize(middleware) when is_atom(middleware) do
    {middleware, []}
  end

  def normalize({module, opts}) when is_atom(module) and is_list(opts) do
    {module, opts}
  end

  def normalize({module, opts}) when is_atom(module) and is_map(opts) do
    # Convert map to keyword list for consistency
    {module, Map.to_list(opts)}
  end

  def normalize(middleware) do
    raise ArgumentError,
          "Invalid middleware specification: #{inspect(middleware)}. " <>
            "Expected module or {module, opts} tuple with keyword list options."
  end

  @doc """
  Initialize a middleware module with its configuration.
  Returns a MiddlewareEntry struct.

  ## Configuration Convention

  - Input `opts` should be a keyword list
  - Returned `config` should be a map for efficient runtime access
  """
  def init_middleware(middleware) do
    {module, opts} = normalize(middleware)

    config =
      try do
        case module.init(opts) do
          {:ok, config} when is_map(config) ->
            config

          {:ok, config} when is_list(config) ->
            # Convert keyword list to map for consistency
            Map.new(config)

          {:error, reason} ->
            raise "Failed to initialize #{module}: #{inspect(reason)}"
        end
      rescue
        UndefinedFunctionError ->
          # If no init/1, convert opts to map
          Map.new(opts)
      end

    # Determine middleware ID (use custom :id from config, or default to module name)
    middleware_id = Map.get(config, :id, module)

    %MiddlewareEntry{
      id: middleware_id,
      module: module,
      config: config
    }
  end

  @doc """
  Get system prompt from middleware.
  """
  def get_system_prompt(%MiddlewareEntry{module: module, config: config}) do
    try do
      case module.system_prompt(config) do
        prompts when is_list(prompts) -> Enum.join(prompts, "\n\n")
        prompt when is_binary(prompt) -> prompt
      end
    rescue
      UndefinedFunctionError -> ""
    end
  end

  @doc """
  Get tools from middleware.
  """
  def get_tools(%MiddlewareEntry{module: module, config: config}) do
    # Don't use function_exported? as it can return false positives
    # in test environments due to code reloading issues
    try do
      module.tools(config)
    rescue
      UndefinedFunctionError -> []
    end
  end

  @doc """
  Get LLM callback handlers from middleware.

  Returns the callback handler map from the middleware's `callbacks/1` callback,
  or `nil` if the callback is not implemented.
  """
  def get_callbacks(%MiddlewareEntry{module: module, config: config}) do
    try do
      module.callbacks(config)
    rescue
      UndefinedFunctionError -> nil
    end
  end

  @doc """
  Collect callback handler maps from all middleware.

  Calls `get_callbacks/1` on each middleware entry and filters out nils.
  Returns a list of callback handler maps suitable for passing
  to `LLMChain.add_callback/2`.
  """
  @spec collect_callbacks([MiddlewareEntry.t()]) :: [map()]
  def collect_callbacks(middleware) when is_list(middleware) do
    middleware
    |> Enum.map(&get_callbacks/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Apply before_model hook from middleware.

  ## Parameters

  - `state` - The current agent state
  - `entry` - MiddlewareEntry struct with module and config

  ## Returns

  - `{:ok, updated_state}` - Success with potentially modified state
  - `{:error, reason}` - Error from middleware
  """
  @spec apply_before_model(State.t(), Sagents.MiddlewareEntry.t()) ::
          middleware_result()
  def apply_before_model(state, %MiddlewareEntry{module: module, config: config}) do
    try do
      module.before_model(state, config)
    rescue
      UndefinedFunctionError -> {:ok, state}
    end
  end

  @doc """
  Apply after_model hook from middleware.

  ## Parameters

  - `state` - The current agent state (with LLM response)
  - `entry` - MiddlewareEntry struct with module and config

  ## Returns

  - `{:ok, updated_state}` - Success with potentially modified state
  - `{:error, reason}` - Error from middleware
  """
  @spec apply_after_model(State.t(), Sagents.MiddlewareEntry.t()) ::
          middleware_result()
  def apply_after_model(state, %MiddlewareEntry{module: module, config: config}) do
    try do
      module.after_model(state, config)
    rescue
      UndefinedFunctionError -> {:ok, state}
    end
  end

  @doc """
  Apply handle_message callback from middleware.

  ## Parameters

  - `message` - The message payload to handle
  - `state` - The current agent state
  - `entry` - MiddlewareEntry struct with module and config

  ## Returns

  - `{:ok, updated_state}` - Success with potentially modified state
  - `{:error, reason}` - Error from middleware
  """
  @spec apply_handle_message(term(), State.t(), Sagents.MiddlewareEntry.t()) ::
          {:ok, State.t()} | {:error, term()}
  def apply_handle_message(message, state, %MiddlewareEntry{module: module, config: config}) do
    try do
      module.handle_message(message, state, config)
    rescue
      UndefinedFunctionError -> {:ok, state}
    end
  end

  @doc """
  Apply on_server_start callback from middleware.

  Called when the AgentServer starts to allow middleware to perform
  initialization actions like broadcasting initial state.

  ## Parameters

  - `state` - The current agent state
  - `entry` - MiddlewareEntry struct with module and config

  ## Returns

  - `{:ok, state}` - Success (state typically unchanged)
  - `{:error, reason}` - Error from middleware
  """
  @spec apply_on_server_start(State.t(), Sagents.MiddlewareEntry.t()) ::
          {:ok, State.t()} | {:error, term()}
  def apply_on_server_start(state, %MiddlewareEntry{module: module, config: config}) do
    try do
      module.on_server_start(state, config)
    rescue
      UndefinedFunctionError -> {:ok, state}
    end
  end

  @doc """
  Apply on_fork_context callback from middleware.

  Called during context forking to allow middleware to inject process-local state
  into the context map before it is passed to a child process.

  ## Parameters

  - `context` - The current context map
  - `entry` - MiddlewareEntry struct with module and config

  ## Returns

  - The (potentially modified) context map
  """
  @spec apply_on_fork_context(map(), Sagents.MiddlewareEntry.t()) :: map()
  def apply_on_fork_context(context, %MiddlewareEntry{module: module, config: config}) do
    try do
      module.on_fork_context(context, config)
    rescue
      UndefinedFunctionError -> context
    end
  end
end
