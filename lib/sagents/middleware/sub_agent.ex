defmodule Sagents.Middleware.SubAgent do
  @moduledoc """
  Middleware for delegating tasks to specialized SubAgents.

  Provides a `task` tool that allows the main agent to delegate complex,
  multi-step work to specialized SubAgents. SubAgents run in isolated
  contexts with their own conversation history, providing token efficiency
  and clean separation of concerns.

  ## Features

  - **Dynamic SubAgents**: Create SubAgents from configuration at runtime
  - **Pre-compiled SubAgents**: Use pre-built Agent instances
  - **HITL Propagation**: SubAgent interrupts automatically propagate to parent
  - **Token Efficiency**: Parent only sees final result, not SubAgent's internal work
  - **Process Isolation**: SubAgents run as supervised processes

  ## Configuration Options

  The middleware accepts these options:

    * `:subagents` - List of `SubAgent.Config` or `SubAgent.Compiled` configurations
      for pre-defined subagents. Defaults to `[]`.

    * `:model` - The chat model for dynamic subagents. Required.

    * `:middleware` - Additional middleware to add to subagents. Defaults to `[]`.

    * `:block_middleware` - List of middleware modules to exclude from general-purpose
      subagent inheritance. Defaults to `[]`. See "Middleware Filtering" below.

    * `:include_task_list` - Whether to render the `## Available Tasks` section
      (one bullet per configured sub-agent plus `general-purpose`) into the
      middleware's system prompt. Defaults to `true`.

      Set to `false` when the integrating application supplies the task menu
      another way. For example, a `/commands` flow that injects only the
      relevant task entry on demand to keep the base context lean and reduce
      the chance of the model picking the wrong task. The `task` tool's
      `task_name` enum still constrains valid values regardless.

  ## Configuration Example

      middleware = [
        {SubAgent, [
          model: model,
          subagents: [
            SubAgent.Config.new!(%{
              name: "researcher",
              description: "Research topics using internet search",
              system_prompt: "You are an expert researcher...",
              tools: [internet_search_tool]
            }),
            SubAgent.Compiled.new!(%{
              name: "coder",
              description: "Write code for specific tasks",
              agent: pre_built_coder_agent
            })
          ],
          block_middleware: [ConversationTitle, Summarization]
        ]}
      ]

  ## Middleware Filtering

  When a general-purpose subagent is created, it inherits the parent agent's middleware
  stack with certain exclusions:

  1. **SubAgent middleware is ALWAYS excluded** - This prevents recursive subagent
     nesting which could lead to resource exhaustion. You cannot override this.

  2. **Blocked middleware is excluded** - Any modules listed in `:block_middleware`
     are filtered out before passing to the subagent.

  ### Example: Blocking Unnecessary Middleware

  Some middleware is inappropriate for short-lived subagents:

      {SubAgent, [
        model: model,
        subagents: [],

        # These middleware modules won't be inherited by general-purpose subagents
        block_middleware: [
          Sagents.Middleware.ConversationTitle,  # Subagents don't need titles
          Sagents.Middleware.Summarization       # Short tasks don't need summarization
        ]
      ]}

  ### Pre-configured Subagents

  The `:block_middleware` option only affects **general-purpose** subagents created
  dynamically via the `task` tool. Pre-configured subagents (defined in `:subagents`)
  use their own explicitly defined middleware and are NOT affected by this option.

      {SubAgent, [
        subagents: [
          # This subagent defines its own middleware - block_middleware doesn't apply
          SubAgent.Config.new!(%{
            name: "researcher",
            middleware: [ConversationTitle]  # Explicitly included
          })
        ],
        block_middleware: [ConversationTitle]  # Only affects general-purpose
      ]}

  ## Usage Example

      # Main agent decides to delegate work
      "I need to research renewable energy. I'll use the researcher SubAgent."
      → Calls: task("Research renewable energy impacts", "researcher")

      # SubAgent executes independently
      # If SubAgent hits HITL interrupt (e.g., internet_search needs approval):
      #   1. SubAgent pauses
      #   2. Interrupt propagates to parent
      #   3. User sees: "SubAgent 'researcher' needs approval for 'internet_search'"
      #   4. User approves
      #   5. Parent resumes, which resumes SubAgent
      #   6. SubAgent completes and returns result

  ## Architecture

      Main Agent
        │
        ├─ task("research task", "researcher")
        │   │
        │   └─ SubAgent (as SubAgentServer process)
        │       ├─ Fresh conversation
        │       ├─ Specialized tools
        │       ├─ LLM executes
        │       └─ Returns final message only
        │
        └─ Receives result, continues

  ## HITL Interrupt Flow

      1. SubAgent hits HITL interrupt
      2. SubAgentServer.execute() returns {:interrupt, interrupt_data}
      3. Task tool receives interrupt
      4. Task tool returns {:interrupt, enhanced_data} to parent
      5. Parent agent propagates to AgentServer
      6. User approves
      7. Parent agent resumes
      8. Task tool calls SubAgentServer.resume(decisions)
      9. SubAgent continues and completes
  """

  @behaviour Sagents.Middleware

  require Logger

  # Static descriptions for the `task` tool. The list of available task types
  # is rendered in the system prompt under "## Available Tasks", so the
  # description here only needs to point at it. When the list is suppressed
  # via `:include_task_list`, the description switches to a "wait to be
  # directed" instruction so the model doesn't try to guess at task types
  # whose descriptions it cannot see.
  @task_tool_description_with_list "Delegate a task to a specialized handler. " <>
                                     "See the `Available Tasks` section for the list of " <>
                                     "task types and what each one does. Choose the matching `task_name` and " <>
                                     "provide clear `instructions` describing what the handler should accomplish."

  @task_tool_description_without_list "Delegate a task to a specialized handler. " <>
                                        "Only invoke this tool when the user or another part of the conversation " <>
                                        "has explicitly directed you to a specific task type. Pass that task type " <>
                                        "as `task_name` and provide clear `instructions` describing what the " <>
                                        "handler should accomplish. Do not guess at task types on your own."

  alias Sagents.State
  alias Sagents.SubAgent
  alias Sagents.SubAgentServer
  alias Sagents.SubAgentsDynamicSupervisor
  alias LangChain.Callbacks
  alias LangChain.Function
  alias LangChain.Message.ToolResult

  ## Middleware Callbacks

  @impl true
  def init(opts) do
    # Extract configuration
    subagents = Keyword.get(opts, :subagents, [])
    agent_id = Keyword.fetch!(opts, :agent_id)
    model = Keyword.fetch!(opts, :model)
    middleware = Keyword.get(opts, :middleware, [])
    block_middleware = Keyword.get(opts, :block_middleware, [])
    include_task_list = Keyword.get(opts, :include_task_list, true)

    # Validate block_middleware entries (warn about potential issues)
    validate_block_middleware(block_middleware, middleware)

    # Build agent lookup map from subagent configs
    # Returns {:ok, %{"researcher" => agent_struct, "coder" => agent_struct}}
    # This is just a MAP for looking up which Agent to use, NOT a process Registry
    case SubAgent.build_agent_map(subagents, model, middleware) do
      {:ok, agent_map} ->
        # Build descriptions map for tool schema
        descriptions = SubAgent.build_descriptions(subagents)

        # Build until_tool map from subagent configs that have until_tool set
        until_tool_map =
          subagents
          |> Enum.filter(fn config ->
            is_struct(config, SubAgent.Config) and config.until_tool != nil
          end)
          |> Map.new(fn config -> {config.name, config.until_tool} end)

        # Build display_texts map: %{task_name => display_text}.
        # Used by the :on_tool_call_identified callback to re-label the
        # `task` tool call in the UI based on which subagent was picked.
        display_texts_map =
          for cfg <- subagents,
              text = Map.get(cfg, :display_text),
              is_binary(text) and text != "",
              into: %{},
              do: {cfg.name, text}

        # Build use_instructions map: %{task_name => use_instructions}.
        # Presence of any entry enables the `get_task_instructions` tool.
        use_instructions_map =
          for cfg <- subagents,
              text = Map.get(cfg, :use_instructions),
              is_binary(text) and text != "",
              into: %{},
              do: {cfg.name, text}

        # Add "general-purpose" entry for dynamic subagent creation
        # This special marker enables runtime tool inheritance
        agent_map_with_general = Map.put(agent_map, "general-purpose", :dynamic)

        descriptions_with_general =
          Map.put(
            descriptions,
            "general-purpose",
            "General-purpose subagent for complex, multi-step tasks. " <>
              "Inherits all tools and middleware from parent agent. " <>
              "Use when you need to delegate independent work that can run in isolation."
          )

        config = %{
          agent_map: agent_map_with_general,
          descriptions: descriptions_with_general,
          agent_id: agent_id,
          model: model,
          block_middleware: block_middleware,
          until_tool_map: until_tool_map,
          display_texts_map: display_texts_map,
          use_instructions_map: use_instructions_map,
          include_task_list: include_task_list
        }

        {:ok, config}

      {:error, reason} ->
        {:error, "Failed to build subagent lookup map: #{reason}"}
    end
  end

  @impl true
  def system_prompt(config) do
    base = """
    ## SubAgent Delegation

    You have access to a `task` tool for delegating work to specialized SubAgents.

    **Use SubAgents when:**
    - Task is complex and multi-step
    - Task can be fully delegated in isolation
    - You only care about the final result
    - Heavy context/token usage would benefit from isolation
    - Instructed to use a specific task

    **Do NOT use SubAgents when:**
    - Task is trivial (single tool call)
    - You need to see intermediate reasoning
    - Task requires iterative back-and-forth

    SubAgents have their own conversation context and will work independently
    to complete the task. You will receive only their final result.
    """

    base
    |> maybe_append_available_tasks(config)
    |> maybe_append_use_instructions_guidance(config)
  end

  defp maybe_append_available_tasks(prompt, config) do
    if include_task_list?(config) do
      descriptions = Map.get(config, :descriptions, %{})
      use_instructions_map = Map.get(config, :use_instructions_map, %{})

      case build_available_tasks_section(descriptions, use_instructions_map) do
        nil -> prompt
        section -> prompt <> "\n" <> section
      end
    else
      prompt
    end
  end

  # The flag defaults to `false` here (rather than `true` as in `init/1`) so
  # legacy callers passing a bare map or `nil` to `system_prompt/1` (e.g. the
  # `system_prompt(nil)` test) get the safe "render nothing" behaviour.
  defp include_task_list?(config) when is_map(config),
    do: Map.get(config, :include_task_list, false) == true

  defp include_task_list?(_), do: false

  defp task_tool_description(config) do
    if include_task_list?(config) do
      @task_tool_description_with_list
    else
      @task_tool_description_without_list
    end
  end

  defp maybe_append_use_instructions_guidance(prompt, config) do
    # The guidance text references the `Available Tasks` list. When that list
    # is suppressed via `include_task_list: false`, skip the guidance too —
    # the integrating app (e.g. a `/commands` flow) is then responsible for
    # telling the model when to use `get_task_instructions`.
    if include_task_list?(config) and has_use_instructions?(config) do
      prompt <>
        """

        When a task in the `Available Tasks` list has a terse description, call
        `get_task_instructions(task_name: "...")` first to fetch its full
        usage guide, then invoke `task` with informed `instructions`. For
        trivial cases where the description is clear, skip the fetch and call
        `task` directly.
        """
    else
      prompt
    end
  end

  defp build_available_tasks_section(descriptions, _use_instructions_map)
       when map_size(descriptions) == 0,
       do: nil

  defp build_available_tasks_section(descriptions, use_instructions_map) do
    bullets =
      descriptions
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, desc} ->
        if Map.has_key?(use_instructions_map, name) do
          "- #{name}: #{desc} Call `get_task_instructions(\"#{name}\")` for the full usage guide before invoking."
        else
          "- #{name}: #{desc}"
        end
      end)
      |> Enum.join("\n")

    "## Available Tasks\n\n" <> bullets <> "\n"
  end

  @impl true
  def tools(config) do
    if has_use_instructions?(config) do
      [build_task_tool(config), build_get_task_instructions_tool(config)]
    else
      [build_task_tool(config)]
    end
  end

  @impl true
  def callbacks(config) do
    display_texts_map = Map.get(config, :display_texts_map, %{})

    if map_size(display_texts_map) == 0 do
      %{}
    else
      %{
        on_tool_call_identified: fn chain, tool_call, _function ->
          maybe_refire_with_subagent_display_text(chain, tool_call, display_texts_map)
        end
      }
    end
  end

  @impl true
  def debug_summary(config) do
    subagents =
      Enum.map(config.agent_map, fn
        {name, :dynamic} -> "#{name} (general-purpose, dynamic tool inheritance)"
        {name, _agent_struct} -> name
      end)

    %{
      subagents: subagents,
      descriptions: config.descriptions,
      block_middleware: config.block_middleware,
      until_tool_map: config.until_tool_map,
      has_use_instructions: not Enum.empty?(Map.get(config, :use_instructions_map, %{}))
    }
  end

  defp has_use_instructions?(config) when is_map(config) do
    config
    |> Map.get(:use_instructions_map, %{})
    |> map_size()
    |> Kernel.>(0)
  end

  defp has_use_instructions?(_), do: false

  # When the `task` tool call is identified, the chain augments it with the
  # tool's static display_text ("Running task"). If the parent picked a
  # task_name with its own `display_text`, re-fire the callback with the
  # overridden ToolCall so downstream observers (UI) can re-label the running
  # tool call.
  defp maybe_refire_with_subagent_display_text(chain, %{name: "task"} = tool_call, display_texts) do
    case Map.get(tool_call, :arguments) do
      args when is_map(args) ->
        task_name = Map.get(args, "task_name")

        case Map.get(display_texts, task_name) do
          nil ->
            :ok

          override when is_binary(override) ->
            if tool_call.display_text != override do
              updated_call = %{tool_call | display_text: override}
              func = chain._tool_map[tool_call.name]

              Callbacks.fire(chain.callbacks, :on_tool_call_identified, [
                chain,
                updated_call,
                func
              ])
            end

            :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_refire_with_subagent_display_text(_chain, _tool_call, _display_texts), do: :ok

  ## Private Functions - Tool Building

  defp build_task_tool(config) do
    # Get list of available subagent names from the lookup map
    task_names = config.agent_map |> Map.keys()

    Function.new!(%{
      name: "task",
      description: task_tool_description(config),
      display_text: "Running task",
      parameters_schema: %{
        type: "object",
        required: ["instructions", "task_name"],
        properties: %{
          "instructions" => %{
            type: "string",
            description:
              "Detailed instructions for what the SubAgent should accomplish. Be specific about the task, expected output, and any context needed."
          },
          "task_name" => %{
            type: "string",
            enum: task_names,
            description: "Which specialized task to perform"
          },
          "system_prompt" => %{
            type: "string",
            description:
              "Optional custom system prompt to define how the SubAgent should behave. " <>
                "Only applicable for 'general-purpose' type. Defines role, capabilities, and constraints. " <>
                "If omitted, a default general-purpose prompt will be used."
          }
        }
      },
      function: fn args, context ->
        execute_task(args, context, config)
      end,
      # Allow multiple SubAgents to run in parallel
      async: true
    })
  end

  defp build_get_task_instructions_tool(config) do
    use_instructions_map = Map.get(config, :use_instructions_map, %{})
    eligible = Map.keys(use_instructions_map)

    Function.new!(%{
      name: "get_task_instructions",
      description:
        "Fetch the full usage guide for a specific sub-agent before calling `task`. " <>
          "Use this to learn how to frame the `instructions` argument or what prerequisites the sub-agent expects.",
      display_text: "Reading task instructions",
      async: false,
      parameters_schema: %{
        type: "object",
        required: ["task_name"],
        properties: %{
          "task_name" => %{
            type: "string",
            enum: eligible,
            description: "Which tasks's usage guide to retrieve."
          }
        }
      },
      function: fn %{"task_name" => name}, _ctx ->
        case Map.fetch(use_instructions_map, name) do
          {:ok, txt} -> {:ok, txt}
          :error -> {:error, "no usage guide for tasks #{inspect(name)}"}
        end
      end
    })
  end

  ## Private Functions - Task Execution

  defp execute_task(args, context, config) do
    instructions = Map.fetch!(args, "instructions")
    task_name = Map.fetch!(args, "task_name")

    # Check if we're resuming an existing SubAgent
    case get_resume_context(context) do
      {:resume, sub_agent_id} ->
        # Resume existing SubAgent with decisions
        resume_subagent(sub_agent_id, context)

      :new ->
        # Start new SubAgent task (pass full args for system_prompt support)
        start_subagent(instructions, task_name, args, context, config)
    end
  end

  defp get_resume_context(context) do
    # Check if this is a resume operation
    # The context will contain resume info from Agent.resume
    case Map.get(context, :resume_info) do
      %{sub_agent_id: sub_agent_id} ->
        {:resume, sub_agent_id}

      _ ->
        :new
    end
  end

  @doc """
  Starts and executes a new SubAgent to delegate work.

  This function allows custom tools and middleware to spawn SubAgents for
  delegating complex, multi-step tasks, similar to how the built-in `task` tool
  works. The SubAgent runs as an isolated, supervised process with its own
  conversation context.

  ## Parameters

  - `instructions` - Detailed instructions for what the SubAgent should
    accomplish. Be specific about the task, expected output, and any context
    needed.

  - `task_name` - The name of the task to use. Must match a configured
    SubAgent name (from middleware init) or "general-purpose" for dynamic
    SubAgents.

  - `args` - Full arguments map containing:
    - `"instructions"` (required) - Same as instructions parameter
    - `"task_name"` (required) - Same as task_name parameter
    - `"system_prompt"` (optional) - Custom system prompt for general-purpose
      SubAgents

  - `context` - Tool execution context map containing:
    - `:agent_id` - Parent agent ID
    - `:state` - Parent agent state
    - `:parent_middleware` - Parent middleware list (for general-purpose
      SubAgents)
    - `:resume_info` - Resume information if continuing interrupted SubAgent

  - `config` - Middleware configuration map containing:
    - `:agent_map` - Map of task_name -> Agent struct
    - `:descriptions` - Map of task_name -> description string
    - `:agent_id` - Parent agent ID
    - `:model` - Model configuration

  ## Returns

  - `{:ok, result}` - SubAgent completed successfully, returns final message
    content
  - `{:interrupt, interrupt_data}` - SubAgent hit HITL interrupt, needs approval
  - `{:error, reason}` - Failed to start or execute SubAgent

  ## Example

  Using from a custom tool function:

      def my_research_tool_function(args, context) do
        # Build config from middleware state
        subagent_config = %{
          agent_map: context.subagent_map,
          descriptions: context.subagent_descriptions,
          agent_id: context.agent_id,
          model: context.model
        }

        # Prepare arguments
        task_args = %{
          "instructions" => "Research quantum computing developments",
          "task_name" => "research"
        }

        # Start SubAgent
        case SubAgent.start_subagent(
          "Research quantum computing developments",
          "researcher",
          task_args,
          context,
          subagent_config
        ) do
          {:ok, result} ->
            {:ok, "Research complete: " <> result}

          {:interrupt, interrupt_data} ->
            # Propagate interrupt to parent
            {:interrupt, interrupt_data}

          {:error, reason} ->
            {:error, "Failed to research: " <> reason}
        end
      end

  ## Notes

  - SubAgents run in isolated process contexts with their own conversation
    history
  - Parent only sees final result, not intermediate reasoning (token efficient)
  - HITL interrupts from SubAgents automatically propagate to parent
  - For "general-purpose" type, tools and middleware are inherited from parent
  - SubAgents are supervised and cleaned up automatically
  """
  @spec start_subagent(String.t(), String.t(), map(), map(), map()) ::
          {:ok, String.t()}
          | {:ok, String.t(), term()}
          | {:interrupt, map()}
          | {:error, String.t()}
  def start_subagent(instructions, task_name, args, context, config) do
    Logger.debug("Starting SubAgent: #{task_name}")

    # Get agent from lookup map
    case Map.fetch(config.agent_map, task_name) do
      {:ok, :dynamic} ->
        # Handle "general-purpose" dynamic subagent with tool inheritance
        start_dynamic_subagent(instructions, args, context, config)

      {:ok, agent_config} ->
        # Look up until_tool configuration for this subagent type
        until_tool_map = Map.get(config, :until_tool_map, %{})
        until_tool = Map.get(until_tool_map, task_name)

        # Extract parent's tool_context, metadata, runtime, and scope so
        # SubAgent tools see the same context as parent tools. Agent.build_chain
        # stores the original tool_context map as an explicit :tool_context key
        # in custom_context, and scope under the canonical :scope key. Metadata
        # and runtime are nested in state and copied into the SubAgent's fresh
        # State.
        {parent_tool_context, parent_metadata, parent_runtime, parent_scope} =
          extract_parent_context(context)

        # Create SubAgent struct from pre-configured agent
        # Check if it's a Compiled struct (with initial_messages) or just an Agent
        subagent =
          case agent_config do
            %SubAgent.Compiled{} = compiled ->
              # Use new_from_compiled to include initial_messages
              SubAgent.new_from_compiled(
                parent_agent_id: config.agent_id,
                instructions: instructions,
                compiled_agent: compiled.agent,
                initial_messages: compiled.initial_messages || [],
                until_tool: until_tool,
                parent_tool_context: parent_tool_context,
                parent_metadata: parent_metadata,
                parent_runtime: parent_runtime,
                scope: parent_scope
              )

            agent ->
              # Regular Agent struct from Config
              SubAgent.new_from_config(
                parent_agent_id: config.agent_id,
                instructions: instructions,
                agent_config: agent,
                until_tool: until_tool,
                parent_tool_context: parent_tool_context,
                parent_metadata: parent_metadata,
                parent_runtime: parent_runtime,
                scope: parent_scope
              )
          end

        # Get supervisor for this parent agent
        # Uses existing Sagents.Registry for process lookup
        supervisor_name = SubAgentsDynamicSupervisor.get_name(config.agent_id)

        # Spawn SubAgentServer under supervision
        # SubAgentServer will register itself in Sagents.Registry
        tool_call_id = Map.get(context, :tool_call_id)

        child_spec = %{
          id: subagent.id,
          start:
            {SubAgentServer, :start_link, [[subagent: subagent, tool_call_id: tool_call_id]]},
          # Don't restart on crash
          restart: :temporary
        }

        try do
          case DynamicSupervisor.start_child(supervisor_name, child_spec) do
            {:ok, _pid} ->
              # Execute SubAgent synchronously (blocks until complete or interrupt)
              execute_subagent(subagent.id, task_name)

            {:error, reason} ->
              {:error, "Failed to start task: #{inspect(reason)}"}
          end
        catch
          :exit, reason ->
            {:error, "Failed to start task: #{inspect(reason)}"}
        end

      :error ->
        {:error, "Unknown task name: #{task_name}"}
    end
  end

  ## Starting Dynamic SubAgent (general-purpose with tool inheritance)

  defp start_dynamic_subagent(instructions, args, context, config) do
    Logger.debug("Starting dynamic general-purpose SubAgent")

    # Extract parent capabilities from context (set by Agent.build_chain)
    parent_middleware = Map.get(context, :parent_middleware, [])

    # Get optional custom system prompt, or use default
    system_prompt = Map.get(args, "system_prompt", default_general_purpose_prompt())

    # Validate system prompt
    case validate_system_prompt(system_prompt) do
      :ok ->
        # Filter middleware using block list from config
        filtered_middleware =
          SubAgent.subagent_middleware_stack(
            parent_middleware,
            [],
            block_middleware: Map.get(config, :block_middleware, [])
          )

        # Convert MiddlewareEntry structs back to raw middleware specs
        # parent_middleware contains initialized MiddlewareEntry structs, but Agent.new!
        # expects raw middleware specs (module or {module, opts} tuples)
        raw_middleware_specs = Sagents.MiddlewareEntry.to_raw_specs(filtered_middleware)

        # Build Agent struct with inherited middleware capabilities
        # Do NOT pass parent_tools - let filtered_middleware provide tools naturally
        # This ensures SubAgent "task" tool is not inherited after filtering out SubAgent middleware
        agent_config =
          Sagents.Agent.new!(
            %{
              model: config.model,
              base_system_prompt: system_prompt,
              middleware: raw_middleware_specs
            },
            replace_default_middleware: true,
            interrupt_on: nil
          )

        # Extract parent's tool_context, metadata, runtime, and scope for SubAgent
        # inheritance.
        {parent_tool_context, parent_metadata, parent_runtime, parent_scope} =
          extract_parent_context(context)

        # Create SubAgent struct with parent context
        subagent =
          SubAgent.new_from_config(
            parent_agent_id: config.agent_id,
            instructions: instructions,
            agent_config: agent_config,
            parent_tool_context: parent_tool_context,
            parent_metadata: parent_metadata,
            parent_runtime: parent_runtime,
            scope: parent_scope
          )

        # Get supervisor and start SubAgent (same as pre-configured)
        supervisor_name = SubAgentsDynamicSupervisor.get_name(config.agent_id)
        tool_call_id = Map.get(context, :tool_call_id)

        child_spec = %{
          id: subagent.id,
          start:
            {SubAgentServer, :start_link, [[subagent: subagent, tool_call_id: tool_call_id]]},
          restart: :temporary
        }

        try do
          case DynamicSupervisor.start_child(supervisor_name, child_spec) do
            {:ok, _pid} ->
              execute_subagent(subagent.id, "general-purpose")

            {:error, reason} ->
              {:error, "Failed to start task: #{inspect(reason)}"}
          end
        catch
          :exit, reason ->
            {:error, "Failed to start task: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Invalid system_prompt: #{reason}"}
    end
  end

  # Extract parent's tool_context, state.metadata, state.runtime, and scope
  # from the runtime context.
  #
  # Agent.build_chain stores the original tool_context map as an explicit
  # :tool_context key in custom_context, and the parent's scope under the
  # canonical :scope key. We read both directly.
  # Metadata and runtime live nested inside context.state.
  #
  # Returns {tool_context_map, metadata_map, runtime_map, scope}.
  defp extract_parent_context(context) do
    parent_tool_context = Map.get(context, :tool_context, %{})
    parent_metadata = get_in(context, [:state, Access.key(:metadata)]) || %{}
    parent_runtime = get_in(context, [:state, Access.key(:runtime)]) || %{}
    parent_scope = Map.get(context, :scope)
    {parent_tool_context, parent_metadata, parent_runtime, parent_scope}
  end

  defp default_general_purpose_prompt() do
    """
    You are a general-purpose assistant SubAgent. You have access to tools. Focus on completing the specific task you've been given.
    Return a clear, concise result suitable for the parent agent to use.
    """
  end

  defp validate_system_prompt(system_prompt) when is_binary(system_prompt) do
    cond do
      String.length(system_prompt) == 0 ->
        {:error, "system_prompt cannot be empty"}

      String.length(system_prompt) > 10_000 ->
        {:error, "system_prompt too long (max 10,000 characters)"}

      contains_potential_injection?(system_prompt) ->
        {:error, "system_prompt contains potentially unsafe content"}

      true ->
        :ok
    end
  end

  defp validate_system_prompt(_), do: {:error, "system_prompt must be a string"}

  # Validate block_middleware entries and log warnings for potential issues
  # Note: We only validate that entries are atoms and loaded modules.
  # We don't check if they're in the parent middleware stack because that
  # information isn't available at init time - the actual parent middleware
  # is passed via context when creating subagents at runtime.
  defp validate_block_middleware(block_list, _middleware) when is_list(block_list) do
    for module <- block_list do
      cond do
        not is_atom(module) ->
          Logger.warning(
            "[SubAgent] block_middleware entry #{inspect(module)} is not a module atom"
          )

        not Code.ensure_loaded?(module) ->
          Logger.warning("[SubAgent] block_middleware module #{inspect(module)} is not loaded")

        true ->
          :ok
      end
    end

    :ok
  end

  defp validate_block_middleware(block_list, _parent_middleware) do
    Logger.warning("[SubAgent] block_middleware must be a list, got: #{inspect(block_list)}")
    :ok
  end

  # Basic safety check for prompt injection patterns
  defp contains_potential_injection?(text) do
    # Check for common prompt injection patterns
    dangerous_patterns = [
      ~r/ignore\s+(all\s+)?previous\s+instructions/i,
      ~r/disregard\s+(all\s+)?previous\s+instructions/i,
      ~r/forget\s+(all\s+)?previous\s+instructions/i,
      ~r/new\s+instructions:/i,
      ~r/system\s*:\s*you\s+are\s+now/i
    ]

    Enum.any?(dangerous_patterns, fn pattern ->
      Regex.match?(pattern, text)
    end)
  end

  defp execute_subagent(sub_agent_id, task_name) do
    Logger.debug("Executing SubAgent: #{sub_agent_id}")

    case SubAgentServer.execute(sub_agent_id) do
      {:ok, final_result} ->
        Logger.debug("Task #{sub_agent_id} completed")
        SubAgentServer.stop(sub_agent_id)
        {:ok, final_result}

      {:ok, final_result, extra} ->
        # SubAgent completed with extra data (e.g., until_tool result)
        Logger.debug("Task #{sub_agent_id} completed with extra data")
        {:ok, final_result, extra}

      {:interrupt, interrupt_data} ->
        Logger.info("Task '#{task_name}' interrupted for HITL")

        # Return 3-tuple that LangChain.execute_tool_call recognizes
        # Keep alive — needs resume later
        {:interrupt, "'#{task_name}' requires human approval.",
         %{
           type: :subagent_hitl,
           sub_agent_id: sub_agent_id,
           task_name: task_name,
           interrupt_data: interrupt_data
         }}

      {:error, reason} ->
        Logger.error("Task #{sub_agent_id} failed: #{inspect(reason)}")
        # The rich error (final_messages, turn_count, original term) is
        # broadcast to the debugger via SubAgentServer's :subagent_failed_with_context
        # event -- see sub_agent_server.ex. This tool-result string is just the
        # summary returned to the parent LLM.
        SubAgentServer.stop(sub_agent_id)
        {:error, format_subagent_error(reason, task_name)}
    end
  end

  # Preserve structure for LangChainError (e.g., length-stopped) so the caller
  # can tell an LLM length truncation apart from an infrastructure failure.
  defp format_subagent_error(%LangChain.LangChainError{type: type, message: msg}, task_name)
       when is_binary(msg) do
    "Task '#{task_name}' failed (#{type || "error"}): #{msg}"
  end

  defp format_subagent_error(reason, task_name) do
    "Task '#{task_name}' failed: #{inspect(reason)}"
  end

  @doc """
  Handle resume for SubAgent interrupts.

  Claims interrupts where `state.interrupt_data` has `type: :subagent_hitl`.
  Delegates to SubAgentServer.resume and handles completion, re-interrupt,
  and error cases. Also handles `type: :multiple_interrupts` by processing
  the first interrupt and queuing the rest.
  """
  @impl true
  def handle_resume(
        _agent,
        %State{interrupt_data: %{type: :subagent_hitl} = data} = state,
        resume_data,
        _config,
        _opts
      ) do
    %{sub_agent_id: sub_agent_id, task_name: task_name, tool_call_id: tool_call_id} =
      data

    case SubAgentServer.resume(sub_agent_id, resume_data) do
      {:ok, result} ->
        SubAgentServer.stop(sub_agent_id)

        new_tool_result =
          ToolResult.new!(%{
            tool_call_id: tool_call_id,
            content: result,
            name: "task",
            is_interrupt: false
          })

        patched_state = State.replace_tool_result(state, tool_call_id, new_tool_result)
        {:ok, patched_state}

      {:interrupt, new_inner_interrupt_data} ->
        updated_interrupt = %{
          type: :subagent_hitl,
          sub_agent_id: sub_agent_id,
          task_name: task_name,
          tool_call_id: tool_call_id,
          interrupt_data: new_inner_interrupt_data
        }

        {:interrupt, %{state | interrupt_data: updated_interrupt}, updated_interrupt}

      {:error, reason} ->
        SubAgentServer.stop(sub_agent_id)

        error_result =
          ToolResult.new!(%{
            tool_call_id: tool_call_id,
            content: format_subagent_error(reason, task_name),
            name: "task",
            is_error: true,
            is_interrupt: false
          })

        patched_state = State.replace_tool_result(state, tool_call_id, error_result)
        {:ok, patched_state}
    end
  end

  def handle_resume(_agent, state, _resume_data, _config, _opts), do: {:cont, state}

  ## Resuming Existing SubAgent

  defp resume_subagent(sub_agent_id, context) do
    Logger.debug("Resuming SubAgent: #{sub_agent_id}")

    decisions = Map.get(context.resume_info, :decisions, [])
    task_name = Map.get(context.resume_info, :task_name, "unknown")

    case SubAgentServer.resume(sub_agent_id, decisions) do
      {:ok, final_result} ->
        Logger.debug("SubAgent #{sub_agent_id} completed after resume")
        SubAgentServer.stop(sub_agent_id)
        {:ok, final_result}

      {:ok, final_result, extra} ->
        # SubAgent completed with extra data after approval
        Logger.debug("SubAgent #{sub_agent_id} completed after resume with extra data")
        {:ok, final_result, extra}

      {:interrupt, interrupt_data} ->
        Logger.info("SubAgent '#{task_name}' interrupted again")

        # Return 3-tuple that LangChain.execute_tool_call recognizes
        # Keep alive — needs resume later
        {:interrupt, "'#{task_name}' requires human approval.",
         %{
           type: :subagent_hitl,
           sub_agent_id: sub_agent_id,
           task_name: task_name,
           interrupt_data: interrupt_data
         }}

      {:error, reason} ->
        Logger.error("SubAgent #{sub_agent_id} resume failed: #{inspect(reason)}")
        SubAgentServer.stop(sub_agent_id)
        {:error, format_subagent_error(reason, task_name)}
    end
  end
end
