defmodule Sagents.Agent do
  @moduledoc """
  Main entry point for creating Agents.

  A Agent is an AI agent with composable middleware that provides
  capabilities like TODO management, filesystem operations, and task delegation.

  ## Basic Usage

      # Create agent with default middleware
      {:ok, agent} = Agent.new(%{
        agent_id: "my-agent-1",
        model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6"}),
        base_system_prompt: "You are a helpful assistant."
      })

      # Execute with messages
      state = State.new!(%{messages: [%{role: "user", content: "Hello!"}]})
      {:ok, result_state} = Agent.execute(agent, state)

  ## Middleware Composition

      # Append custom middleware to defaults
      {:ok, agent} = Agent.new(%{
        middleware: [MyCustomMiddleware]
      })

      # Customize default middleware
      {:ok, agent} = Agent.new(%{
        filesystem_opts: [long_term_memory: true]
      })

      # Provide complete middleware stack
      {:ok, agent} = Agent.new(%{
        replace_default_middleware: true,
        middleware: [{MyMiddleware, []}]
      })
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  alias __MODULE__
  alias Sagents.Middleware
  alias Sagents.State
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Chains.LLMChain
  alias Sagents.Middleware.HumanInTheLoop

  @primary_key false
  embedded_schema do
    field :agent_id, :string
    field :model, :any, virtual: true
    field :base_system_prompt, :string
    field :assembled_system_prompt, :string
    field :tools, {:array, :any}, default: [], virtual: true
    field :middleware, {:array, :any}, default: [], virtual: true
    field :name, :string
    field :filesystem_scope, :any, virtual: true
    # Caller-supplied context merged into LLMChain.custom_context for tool functions.
    field :tool_context, :map, default: %{}, virtual: true
    # Timeout for async tool execution. Integer (ms) or :infinity.
    # Overrides application config when set. See LLMChain docs for details.
    field :async_tool_timeout, :any, virtual: true
    # Fallback models to use when primary model fails
    field :fallback_models, {:array, :any}, default: [], virtual: true
    # Optional function to modify chain before each LLM attempt (including first)
    # Signature: (LLMChain.t() -> LLMChain.t())
    field :before_fallback, :any, virtual: true
    # Custom LLMChain execution mode module. Must implement the
    # LangChain.Chains.LLMChain.Mode behaviour. Defaults to
    # Sagents.Modes.AgentExecution when nil.
    field :mode, :any, virtual: true
  end

  @type t :: %Agent{}

  @create_fields [
    :agent_id,
    :model,
    :base_system_prompt,
    :assembled_system_prompt,
    :tools,
    :middleware,
    :name,
    :filesystem_scope,
    :tool_context,
    :async_tool_timeout,
    :fallback_models,
    :before_fallback,
    :mode
  ]
  @required_fields [:agent_id, :model]

  @doc """
  Create a new Agent.

  ## Attributes

  - `:agent_id` - Unique identifier for the agent (optional, auto-generated if not provided)
  - `:model` - LangChain ChatModel struct (required)
  - `:base_system_prompt` - Base system instructions
  - `:tools` - Additional tools beyond middleware (default: [])
  - `:middleware` - List of middleware modules/configs (default: [])
  - `:name` - Agent name for identification (default: nil)
  - `:filesystem_scope` - Optional scope key for referencing an independently-running filesystem (e.g., `{:user, 123}`, `{:project, 456}`)
  - `:tool_context` - Map of caller-supplied data merged into `LLMChain.custom_context`
    so every tool function receives it as part of its second argument. Internal keys
    (`:state`, `:parent_middleware`, `:parent_tools`) always take precedence on collision.
    (default: `%{}`)
  - `:async_tool_timeout` - Timeout for parallel tool execution. Integer (milliseconds) or
    `:infinity`. Overrides application-level config. See LLMChain module docs for details.
    (default: uses application config or `:infinity`)
  - `:fallback_models` - List of ChatModel structs to try if primary model fails (default: [])
  - `:before_fallback` - Optional function to modify chain before each attempt (default: nil).
    Signature: `fn chain -> modified_chain end`.
    Useful for provider-specific system prompts or modifications

  ## Options

  - `:replace_default_middleware` - If true, use only provided middleware (default: false)
  - `:todo_opts` - Options for TodoList middleware
  - `:filesystem_opts` - Options for Filesystem middleware
  - `:summarization_opts` - Options for Summarization middleware (e.g., `[max_tokens_before_summary: 150_000, messages_to_keep: 8]`)
  - `:subagent_opts` - Options for SubAgent middleware
  - `:interrupt_on` - Map of tool names to interrupt configuration (default: nil)

  ### Human-in-the-loop configuration

  The `:interrupt_on` option enables human oversight for specific tools:

      # Simple boolean configuration
      interrupt_on: %{
        "write_file" => true,    # Require approval
        "delete_file" => true,
        "read_file" => false     # No approval needed
      }

      # Advanced configuration
      interrupt_on: %{
        "write_file" => %{
          allowed_decisions: [:approve, :edit, :reject]
        }
      }

  ## Examples

      # Basic agent
      {:ok, agent} = Agent.new(%{
        agent_id: "basic-agent",
        model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6"}),
        base_system_prompt: "You are helpful."
      })

      # With custom tools
      {:ok, agent} = Agent.new(%{
        agent_id: "tool-agent",
        model: model,
        tools: [write_file_tool, search_tool]
      })

      # With human-in-the-loop for file operations
      {:ok, agent} = Agent.new(
        %{
          agent_id: "hitl-agent",
          model: model,
          tools: [write_file_tool, delete_file_tool]
        },
        interrupt_on: %{
          "write_file" => true,  # Require approval for writes
          "delete_file" => %{allowed_decisions: [:approve, :reject]}  # No edit for deletes
        }
      )

      # Execute and handle interrupts
      case Agent.execute(agent, state) do
        {:ok, final_state} ->
          IO.puts("Agent completed successfully")

        {:interrupt, interrupted_state, interrupt_data} ->
          # Present interrupt_data.action_requests to user
          # Get their decisions
          decisions = UI.get_decisions(interrupt_data)
          {:ok, final_state} = Agent.resume(agent, interrupted_state, decisions)

        {:error, reason} ->
          Logger.error("Agent failed: \#{inspect(reason)}")
      end

      # With custom middleware configuration
      {:ok, agent} = Agent.new(
        %{
          agent_id: "custom-middleware-agent",
          model: model
        },
        filesystem_opts: [long_term_memory: true]
      )

      # With caller-supplied context for tool functions
      {:ok, agent} = Agent.new(%{
        agent_id: "context-agent",
        model: model,
        tool_context: %{user_id: 42, tenant: "acme"}
      })

      # Tool functions receive the context as their second argument:
      # fn args, context ->
      #   context.user_id  #=> 42
      #   context.tenant   #=> "acme"
      #   context.state    #=> %State{} (always present)
      # end
  """
  def new(attrs \\ %{}, opts \\ []) do
    %Agent{}
    |> cast(attrs, @create_fields)
    |> put_agent_id_if_missing()
    |> validate_required(@required_fields)
    |> build_and_initialize_middleware(opts)
    |> assemble_full_system_prompt()
    |> collect_all_tools()
    |> apply_action(:insert)
  end

  @doc """
  Create a new Agent, raising on error.
  """
  def new!(attrs \\ %{}, opts \\ []) do
    case new(attrs, opts) do
      {:ok, agent} -> agent
      {:error, changeset} -> raise LangChainError, changeset
    end
  end

  @doc false
  def changeset(agent \\ %Agent{}, attrs) do
    agent
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
  end

  defp put_agent_id_if_missing(changeset) do
    case get_field(changeset, :agent_id) do
      nil -> put_change(changeset, :agent_id, generate_agent_id())
      _ -> changeset
    end
  end

  defp build_and_initialize_middleware(changeset, opts) do
    # Build middleware list
    replace_defaults = Keyword.get(opts, :replace_default_middleware, false)
    user_middleware = get_field(changeset, :middleware) || []
    model = get_field(changeset, :model)
    agent_id = get_field(changeset, :agent_id)
    filesystem_scope = get_field(changeset, :filesystem_scope)

    middleware_list =
      case replace_defaults do
        false ->
          # Append user middleware to defaults (inject agent_id, model, and filesystem_scope)
          build_default_middleware(model, agent_id, opts) ++
            inject_agent_context(user_middleware, agent_id, model, filesystem_scope)

        true ->
          # Use only user-provided middleware (inject agent_id, model, and filesystem_scope)
          inject_agent_context(user_middleware, agent_id, model, filesystem_scope)
      end

    # Initialize middleware
    case initialize_middleware_list(middleware_list) do
      {:ok, initialized} ->
        put_change(changeset, :middleware, initialized)

      {:error, reason} ->
        add_error(changeset, :middleware, "initialization failed: #{inspect(reason)}")
    end
  end

  # Inject agent_id, model, and filesystem_scope into user middleware configurations
  defp inject_agent_context(middleware_list, agent_id, model, filesystem_scope) do
    base_context =
      if filesystem_scope do
        [agent_id: agent_id, model: model, filesystem_scope: filesystem_scope]
      else
        [agent_id: agent_id, model: model]
      end

    Enum.map(middleware_list, fn
      # Module without options - inject context
      module when is_atom(module) ->
        {module, base_context}

      # Module with options - merge context
      {module, opts} when is_list(opts) ->
        {module, Keyword.merge(base_context, opts)}

      # Module with map options - merge context
      {module, opts} when is_map(opts) ->
        merged = Map.merge(Map.new(base_context), opts)
        {module, Map.to_list(merged)}

      # Pass through anything else as-is
      other ->
        other
    end)
  end

  @doc """
  Build the default middleware stack.

  This is a utility function that can be used to build the default middleware
  stack with custom options. Useful when you want to customize middleware
  configuration or when building subagents.

  ## Parameters

  - `model` - The LangChain ChatModel struct
  - `agent_id` - The agent's unique identifier
  - `opts` - Keyword list of middleware options

  ## Options

  - `:todo_opts` - Options for TodoList middleware
  - `:filesystem_opts` - Options for Filesystem middleware
  - `:summarization_opts` - Options for Summarization middleware
  - `:subagent_opts` - Options for SubAgent middleware
  - `:interrupt_on` - Map of tool names to interrupt configuration

  ## Examples

      middleware = Agent.build_default_middleware(
        model,
        "agent-123",
        filesystem_opts: [long_term_memory: true],
        interrupt_on: %{"write_file" => true}
      )
  """
  def build_default_middleware(model, agent_id, opts \\ []) do
    # Build middleware stack Note: SubAgent middleware accesses parent
    # middleware/tools via runtime context, not via init configuration. See
    # execute_loop/3 where custom_context is set.
    [
      # TodoList middleware for task management
      {Sagents.Middleware.TodoList, Keyword.get(opts, :todo_opts, [])},
      # Filesystem middleware for mock file operations
      {Sagents.Middleware.FileSystem,
       Keyword.merge([agent_id: agent_id], Keyword.get(opts, :filesystem_opts, []))},
      # SubAgent middleware for delegating to specialized sub-agents
      {Sagents.Middleware.SubAgent,
       Keyword.merge(
         [agent_id: agent_id, model: model],
         Keyword.get(opts, :subagent_opts, [])
       )},
      # Summarization middleware for managing conversation length
      {Sagents.Middleware.Summarization,
       Keyword.merge([model: model], Keyword.get(opts, :summarization_opts, []))},
      # PatchToolCalls middleware to fix dangling tool calls
      {Sagents.Middleware.PatchToolCalls, []}
    ]
    # Conditionally add HumanInTheLoop middleware if interrupt_on is configured
    |> HumanInTheLoop.maybe_append(Keyword.get(opts, :interrupt_on))
  end

  defp initialize_middleware_list(middleware_list) do
    try do
      initialized =
        middleware_list
        |> Enum.map(&Middleware.init_middleware/1)

      {:ok, initialized}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp assemble_full_system_prompt(changeset) do
    base_prompt = get_field(changeset, :base_system_prompt) || ""
    initialized_middleware = get_field(changeset, :middleware) || []

    middleware_prompts =
      initialized_middleware
      |> Enum.map(&Middleware.get_system_prompt/1)
      |> Enum.reject(&(&1 == ""))

    full_prompt =
      [base_prompt | middleware_prompts]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    put_change(changeset, :assembled_system_prompt, full_prompt)
  end

  defp collect_all_tools(changeset) do
    base_tools = get_field(changeset, :tools) || []
    initialized_middleware = get_field(changeset, :middleware) || []

    middleware_tools =
      initialized_middleware
      |> Enum.flat_map(&Middleware.get_tools/1)

    all_tools = base_tools ++ middleware_tools

    put_change(changeset, :tools, all_tools)
  end

  @doc """
  Execute the agent with the given state.

  Applies middleware hooks in order:
  1. before_model hooks (in order)
  2. LLM execution
  3. after_model hooks (in reverse order)

  ## Options

  - `:callbacks` - A list of callback handler maps. Each map may contain
    LangChain callback keys (see `LangChain.Chains.ChainCallbacks`) and/or
    the Sagents-specific `:on_after_middleware` key. All maps are added to
    the LLMChain, and matching handlers fire in fan-out (all maps checked).

    LangChain callback keys (e.g., `:on_llm_token_usage`, `:on_message_processed`)
    are fired by `LLMChain.run/2` during execution. The `:on_after_middleware`
    key is fired by the agent directly after `before_model` hooks complete,
    before the LLM call — it receives the prepared state as its single argument.

    When running via `AgentServer`, callbacks are built automatically:
    PubSub callbacks (for broadcasting events) are combined with middleware
    callbacks (from `Middleware.collect_callbacks/1`) into this list.

  ## Returns

  - `{:ok, state}` - Normal completion
  - `{:interrupt, state, interrupt_data}` - Execution paused for human approval
  - `{:error, reason}` - Execution failed

  ## Examples

      state = State.new!(%{messages: [%{role: "user", content: "Hello"}]})

      case Agent.execute(agent, state) do
        {:ok, final_state} ->
          # Normal completion
          handle_response(final_state)

        {:interrupt, interrupted_state, interrupt_data} ->
          # Human approval needed
          decisions = get_human_decisions(interrupt_data)
          {:ok, final_state} = Agent.resume(agent, interrupted_state, decisions)
          handle_response(final_state)

        {:error, err} ->
          # Handle error
          Logger.error("Agent execution failed: \#{inspect(err)}")
      end

      # With custom callbacks
      callbacks = [
        %{
          on_llm_token_usage: fn _chain, usage ->
            IO.inspect(usage, label: "tokens")
          end
        }
      ]

      Agent.execute(agent, state, callbacks: callbacks)
  """
  def execute(%Agent{} = agent, %State{} = state, opts \\ []) do
    # Ensure agent_id is set in state (library handles this automatically)
    state = %{state | agent_id: agent.agent_id}

    callbacks = Keyword.get(opts, :callbacks)

    with {:ok, validated_opts} <- validate_until_tool(agent, opts),
         {:ok, prepared_state} <- apply_before_model_hooks(state, agent.middleware) do
      # Fire callback with post-middleware state (before LLM call)
      fire_callback(callbacks, :on_after_middleware, [prepared_state])

      case execute_model(agent, prepared_state, callbacks, validated_opts) do
        {:ok, response_state} ->
          # Normal completion - run after_model hooks
          apply_after_model_hooks(response_state, agent.middleware)

        {:ok, response_state, extra} ->
          # 3-tuple completion (e.g., until_tool result) - run after_model hooks
          # and re-attach extra data
          case apply_after_model_hooks(response_state, agent.middleware) do
            {:ok, final_state} ->
              {:ok, final_state, extra}

            {:interrupt, interrupted_state, interrupt_data} ->
              {:interrupt, interrupted_state, interrupt_data}

            {:error, reason} ->
              {:error, reason}
          end

        {:interrupt, interrupted_state, interrupt_data} ->
          # Interrupt from execute_model - return immediately without after_model hooks
          {:interrupt, interrupted_state, interrupt_data}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Resume agent execution after an interrupt.

  Cycles through the middleware stack, giving each middleware a chance to claim
  and handle the interrupt via `handle_resume/4`. The first middleware that returns
  `{:ok, state}` or `{:interrupt, ...}` or `{:error, ...}` wins. If no middleware
  claims the interrupt, returns an error.

  ## Parameters

  - `agent` - The agent instance
  - `state` - The state at the point of interruption (with `interrupt_data` set)
  - `resume_data` - Data provided by the caller to resume (polymorphic per middleware)
  - `opts` - Options (same as `execute/3`, including `:callbacks`)

  ## Examples

      # HITL resume with decisions
      {:interrupt, state, interrupt_data} = Agent.execute(agent, initial_state)
      decisions = [%{type: :approve}, %{type: :reject}]
      {:ok, final_state} = Agent.resume(agent, state, decisions)

      # AskUserQuestion resume with response
      {:interrupt, state, %{type: :ask_user_question}} = Agent.execute(agent, initial_state)
      response = %{type: :answer, selected: ["PostgreSQL"]}
      {:ok, final_state} = Agent.resume(agent, state, response)
  """
  def resume(%Agent{} = agent, %State{} = state, resume_data, opts \\ []) do
    # Ensure agent_id is set in state (library handles this automatically)
    state = %{state | agent_id: agent.agent_id}

    case apply_handle_resume_hooks(agent, state, resume_data, agent.middleware, opts) do
      {:ok, updated_state} ->
        execute(agent, %{updated_state | interrupt_data: nil}, opts)

      {:interrupt, interrupted_state, new_interrupt_data} ->
        {:interrupt, %{interrupted_state | interrupt_data: new_interrupt_data},
         new_interrupt_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_handle_resume_hooks(agent, state, resume_data, middleware, opts) do
    original_interrupt_data = state.interrupt_data

    result =
      Enum.reduce_while(middleware, {:cont, state}, fn mw, {:cont, current_state} ->
        case Middleware.apply_handle_resume(agent, current_state, resume_data, mw, opts) do
          {:cont, updated_state} -> {:cont, {:cont, updated_state}}
          {:ok, updated_state} -> {:halt, {:ok, updated_state}}
          {:interrupt, s, d} -> {:halt, {:interrupt, s, d}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:cont, new_state} ->
        if new_state.interrupt_data != nil and
             new_state.interrupt_data != original_interrupt_data do
          # A middleware (e.g., HITL) discovered a secondary interrupt during
          # its work and set it on state via {:cont}. Re-scan the middleware
          # stack so the owning middleware can claim it. Pass nil for
          # resume_data since this is a claim cycle, not a user-initiated
          # resume.
          apply_handle_resume_hooks(agent, new_state, nil, middleware, opts)
        else
          {:error, "No middleware handled the resume for this interrupt"}
        end

      other ->
        other
    end
  end

  @doc false
  def build_chain(agent, messages, state, callbacks) do
    build_chain_impl(agent, messages, state, callbacks)
  end

  # Private functions

  defp generate_agent_id do
    # Generate a unique ID using Elixir's Uniq library or a simple UUID
    ("agent_" <> :crypto.strong_rand_bytes(16)) |> Base.url_encode64(padding: false)
  end

  defp apply_before_model_hooks(state, middleware) do
    Enum.reduce_while(middleware, {:ok, state}, fn mw, {:ok, current_state} ->
      case Middleware.apply_before_model(current_state, mw) do
        {:ok, updated_state} -> {:cont, {:ok, updated_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_after_model_hooks(state, middleware) do
    # Apply in reverse order
    middleware
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, state}, fn mw, {:ok, current_state} ->
      case Middleware.apply_after_model(current_state, mw) do
        {:ok, updated_state} ->
          {:cont, {:ok, updated_state}}

        {:interrupt, interrupted_state, interrupt_data} ->
          # Middleware requested an interrupt, halt and return interrupt
          {:halt, {:interrupt, interrupted_state, interrupt_data}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Fire a Sagents-specific callback key (e.g., :on_after_middleware) from the
  # callbacks list. This handles keys that are NOT LangChain-native — they won't
  # be fired by LLMChain.run, so we iterate the list and fire matching handlers
  # ourselves. LangChain-native keys are handled separately via maybe_add_callbacks
  # which adds each map to the chain for LLMChain to fire during execution.
  defp fire_callback(nil, _key, _args), do: :ok
  defp fire_callback([], _key, _args), do: :ok

  defp fire_callback(callbacks, key, args) when is_list(callbacks) do
    Enum.each(callbacks, fn cb_map ->
      case cb_map do
        %{^key => callback} when is_function(callback) ->
          apply(callback, args)

        _ ->
          :ok
      end
    end)
  end

  defp execute_model(%Agent{} = agent, %State{} = state, callbacks, opts) do
    with {:ok, langchain_messages} <- validate_messages(state.messages),
         {:ok, chain} <- build_chain_impl(agent, langchain_messages, state, callbacks),
         result <- execute_chain(chain, agent.middleware, agent, opts) do
      case result do
        {:ok, executed_chain} ->
          case extract_state_from_chain(executed_chain, state) do
            {:ok, final_state} ->
              # Check if the last message was cancelled due to a streaming error
              # (e.g. content filtering). The error is stored in message metadata
              # by LLMChain.cancel_delta/3.
              case check_for_streaming_error(final_state) do
                nil -> {:ok, final_state}
                error -> {:error, error}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, executed_chain, extra} ->
          case extract_state_from_chain(executed_chain, state) do
            {:ok, final_state} -> {:ok, final_state, extra}
            {:error, reason} -> {:error, reason}
          end

        {:interrupt, interrupted_chain, interrupt_data} ->
          # Tool calls need human approval - return interrupt with current state
          case extract_state_from_chain(interrupted_chain, state) do
            {:ok, interrupted_state} ->
              # Add interrupt_data to state so it's available during resume
              state_with_interrupt_data = %{interrupted_state | interrupt_data: interrupt_data}
              {:interrupt, state_with_interrupt_data, interrupt_data}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_for_streaming_error(%State{messages: messages}) do
    case List.last(messages) do
      %Message{status: :cancelled, metadata: %{streaming_error: error}} -> error
      _ -> nil
    end
  end

  defp validate_messages(messages) do
    # Messages are already LangChain.Message structs, just validate them
    if Enum.all?(messages, &is_struct(&1, Message)) do
      {:ok, messages}
    else
      {:error, "All messages must be LangChain.Message structs"}
    end
  end

  defp build_chain_impl(agent, messages, state, callbacks) do
    # Add system message if we have a system prompt
    messages_with_system =
      case agent.assembled_system_prompt do
        prompt when is_binary(prompt) and prompt != "" ->
          [Message.new_system!(prompt) | messages]

        _ ->
          messages
      end

    chain_config = %{
      llm: agent.model,
      verbose: false,
      # verbose: true,
      custom_context:
        Map.merge(
          agent.tool_context || %{},
          %{
            state: state,
            # Make parent agent's middleware and tools available to tools (e.g., SubAgent middleware)
            parent_middleware: agent.middleware,
            parent_tools: agent.tools
          }
        )
    }

    # Add async_tool_timeout if explicitly set on agent
    chain_config =
      if agent.async_tool_timeout do
        Map.put(chain_config, :async_tool_timeout, agent.async_tool_timeout)
      else
        chain_config
      end

    chain =
      chain_config
      |> LLMChain.new!()
      |> LLMChain.add_tools(agent.tools)
      |> LLMChain.add_messages(messages_with_system)
      |> maybe_add_callbacks(callbacks)

    {:ok, chain}
  rescue
    error -> {:error, "Failed to build chain: #{inspect(error)}"}
  end

  # Add each callback map to the LLMChain for LangChain-native key dispatch.
  # Each map is added individually so LLMChain can fan-out: if multiple maps
  # contain the same key (e.g., :on_llm_token_usage), all handlers fire.
  # Any non-LangChain keys in the maps (e.g., :on_after_middleware) are
  # silently ignored by LLMChain — those are handled by fire_callback/3.
  defp maybe_add_callbacks(chain, nil), do: chain
  defp maybe_add_callbacks(chain, []), do: chain

  defp maybe_add_callbacks(chain, callbacks) when is_list(callbacks) do
    Enum.reduce(callbacks, chain, fn cb_map, acc ->
      LLMChain.add_callback(acc, cb_map)
    end)
  end

  # Build options for LLMChain.run/2, including fallback configuration
  defp build_run_options(agent, base_opts \\ []) do
    opts = base_opts

    # Add fallback models if configured
    opts =
      if agent.fallback_models != [] do
        Keyword.put(opts, :with_fallbacks, agent.fallback_models)
      else
        opts
      end

    # Add before_fallback function if configured
    # NOTE: This fires for EVERY attempt, including the first
    opts =
      if agent.before_fallback do
        Keyword.put(opts, :before_fallback, agent.before_fallback)
      else
        opts
      end

    opts
  end

  defp validate_until_tool(%Agent{} = agent, opts) do
    case Keyword.get(opts, :until_tool) do
      nil ->
        {:ok, opts}

      tool when is_binary(tool) ->
        do_validate_tool_names(agent, [tool], opts)

      tools when is_list(tools) ->
        do_validate_tool_names(agent, tools, opts)

      other ->
        {:error, "Invalid :until_tool option: expected string or list, got: #{inspect(other)}"}
    end
  end

  defp do_validate_tool_names(%Agent{tools: tools}, target_names, opts) do
    available = MapSet.new(tools, & &1.name)
    missing = Enum.reject(target_names, &MapSet.member?(available, &1))

    case missing do
      [] ->
        {:ok, opts}

      names ->
        {:error,
         "until_tool: tool(s) #{inspect(names)} not found. Available: #{inspect(MapSet.to_list(available))}"}
    end
  end

  defp execute_chain(chain, middleware, agent, opts) do
    run_opts = build_run_options(agent)

    mode_opts =
      run_opts
      |> Keyword.put(:mode, agent.mode || Sagents.Modes.AgentExecution)
      |> Keyword.put(:middleware, middleware)
      |> maybe_put_until_tool(opts)

    if is_raw_langchain_mode?(agent.mode) do
      Logger.warning(
        "Agent #{agent.agent_id} is using raw LangChain mode #{inspect(agent.mode)}. " <>
          "HITL interrupts and state propagation will NOT be applied. " <>
          "Consider using Sagents.Modes.AgentExecution with opts instead."
      )
    end

    case LLMChain.run(chain, mode_opts) do
      {:ok, chain} ->
        {:ok, chain}

      {:ok, chain, extra} ->
        {:ok, chain, extra}

      {:interrupt, chain, interrupt_data} ->
        {:interrupt, chain, interrupt_data}

      {:pause, chain} ->
        {:pause, chain}

      {:error, _chain, %LangChainError{} = reason} ->
        {:error, reason}

      {:error, _chain, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_until_tool(mode_opts, opts) do
    case Keyword.get(opts, :until_tool) do
      nil -> mode_opts
      until_tool -> Keyword.put(mode_opts, :until_tool, until_tool)
    end
  end

  defp is_raw_langchain_mode?(nil), do: false

  defp is_raw_langchain_mode?(module) when is_atom(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.LangChain.Chains.LLMChain.Modes.")
  end

  defp extract_state_from_chain(chain, %State{} = original_state) do
    # Use the chain's current set of messages as the agent's messages state.
    {_system, chain_messages} = LangChain.Utils.split_system_message(chain.messages)

    # Extract any state updates from tool results (used by middleware like
    # TodoList) Some tools return State objects as processed_content to update
    # agent state
    state_updates =
      chain_messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.flat_map(fn message ->
        case message.tool_results do
          nil ->
            []

          tool_results when is_list(tool_results) ->
            Enum.filter(tool_results, fn result ->
              is_struct(result.processed_content, State)
            end)
            |> Enum.map(& &1.processed_content)

          _ ->
            []
        end
      end)

    # Use the full set of chain messages (excluding the system message)
    # for the state's set of messages.
    updated_state = %State{original_state | messages: chain_messages}

    # Merge in any state updates from tools (e.g., todo list updates)
    final_state =
      Enum.reduce(state_updates, updated_state, fn state_update, acc ->
        State.merge_states(acc, state_update)
      end)

    {:ok, final_state}
  rescue
    error -> {:error, "Failed to extract state: #{inspect(error)}"}
  end
end
