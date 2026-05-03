defmodule Sagents.SubAgent do
  @moduledoc """
  A runnable, pausable, and resumable agent execution context.

  ## Core Philosophy

  **"The SubAgent struct HOLDS the LLMChain."**

  This is the key insight that makes pause/resume trivial:
  - **The chain persists** in the SubAgent struct between pause and resume
  - The chain remembers all messages, tool calls, and state
  - Pause = stop executing, save the SubAgent struct
  - Resume = continue the SAME chain with decisions
  - No reconstruction needed

  ## The SubAgent Struct

  The SubAgent holds:
  - **The LLMChain** - THE KEY FIELD - manages the entire conversation
  - **Status tracking** (idle, running, interrupted, completed, error)
  - **Interrupt data** when paused (which tools need approval)
  - **Error** when failed
  - **Metadata** (id, parent_agent_id, created_at)

  ## How It Works

  1. **Initialization**: Create LLMChain with initial messages, tools, and model
  2. **Execution**: Run LLMChain in a loop until completion or interrupt
  3. **Conversation**: All messages live in the chain - it's all there
  4. **Results**: Extract from the final message in the chain

  ## Key Design Principles

  1. **Chain Persistence = Simple Resume**
     - Chain is already paused at the right spot
     - Resume just continues the chain with decisions
     - The chain remembers everything

  2. **Direct Chain Management**
     - SubAgent.execute runs LLMChain.run directly
     - No delegation to Agent
     - Full control over the execution loop

  3. **HITL = Pause/Resume**
     - Interrupt → Chain pauses after LLM returns tool calls
     - Save interrupt data (which tools, what arguments)
     - Resume → Apply decisions, execute tools, continue chain
     - Can have multiple pause/resume cycles naturally

  ## SubAgent Execution Flow

  ### Creating a SubAgent

      # From configuration
      subagent = SubAgent.new_from_config(
        parent_agent_id: "main-agent",
        instructions: "Research renewable energy",
        agent_config: agent_from_registry,
        parent_state: parent_state
      )

  ### Executing

      case SubAgent.execute(subagent) do
        {:ok, completed_subagent} ->
          # Extract result
          result = SubAgent.extract_result(completed_subagent)

        {:interrupt, interrupted_subagent} ->
          # Needs human approval
          # interrupted_subagent.interrupt_data contains action requests

        {:error, error_subagent} ->
          # Execution failed
          # error_subagent.error contains the error
      end

  ### Resuming After Interrupt

      case SubAgent.resume(interrupted_subagent, decisions) do
        {:ok, completed_subagent} -> # Completed
        {:interrupt, interrupted_subagent} -> # Another interrupt
        {:error, error_subagent} -> # Failed
      end

  ## Multiple Interrupts

  The beauty of this design: multiple interrupts just repeat the pause/resume:

      # First execution
      {:interrupt, subagent1} = SubAgent.execute(subagent0)
      # chain paused at: [user, assistant_with_tool_call_1]

      # First resume
      {:interrupt, subagent2} = SubAgent.resume(subagent1, [decision1])
      # chain paused at: [user, assistant_1, tool_result_1, assistant_with_tool_call_2]

      # Second resume
      {:ok, subagent3} = SubAgent.resume(subagent2, [decision2])
      # chain completed
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  alias __MODULE__
  alias Sagents.AgentUtils
  alias Sagents.State
  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias LangChain.Utils

  @primary_key false
  embedded_schema do
    # Core execution context - THE KEY FIELD
    # LLMChain struct
    field :chain, :any, virtual: true

    # Status tracking
    field :status, Ecto.Enum,
      values: [:idle, :running, :interrupted, :completed, :error],
      default: :idle

    # HITL configuration - which tools require approval
    field :interrupt_on, :map, virtual: true

    # Interrupt data (when status = :interrupted)
    field :interrupt_data, :map, virtual: true

    # Error information (when status = :error)
    field :error, :any, virtual: true

    # Until-tool termination: tool name (string) or list of tool names
    field :until_tool, :any, virtual: true

    # Maximum number of LLM calls per execution. Overrides the mode's default
    # (50 for AgentExecution). See Agent :max_runs for details.
    field :max_runs, :integer, virtual: true

    # Metadata
    field :id, :string
    field :parent_agent_id, :string
    field :created_at, :utc_datetime
  end

  @type t :: %__MODULE__{
          chain: LLMChain.t() | nil,
          status: :idle | :running | :interrupted | :completed | :error,
          interrupt_on: map() | nil,
          interrupt_data: map() | nil,
          error: term() | nil,
          until_tool: String.t() | [String.t()] | nil,
          id: String.t() | nil,
          parent_agent_id: String.t() | nil,
          created_at: DateTime.t() | nil
        }

  ## Construction Functions

  @doc """
  Create a SubAgent from configuration (dynamic subagent).

  The main agent configures a subagent through the task tool by providing:
  - Instructions (becomes user message)
  - Agent configuration (Agent struct)

  ## Options

  - `:parent_agent_id` - Parent's agent ID (required)
  - `:instructions` - Task description (required)
  - `:agent_config` - Agent struct with tools, model, middleware (required)
  - `:parent_tool_context` - Parent's tool_context map to inherit (optional).
    Static, caller-supplied data (e.g., `user_id`, feature flags) that tools
    access as flat top-level keys on context. Defaults to `%{}`.
  - `:parent_metadata` - Parent's state metadata map to inherit (optional).
    Dynamic, middleware-managed data (e.g., `conversation_title`) that tools
    access via `context.state.metadata`. Defaults to `%{}`.
  - `:parent_runtime` - Parent's `state.runtime` map to inherit (optional).
    Process-local middleware state such as captured `ProcessContext` snapshots.
    Inherited so sub-agents continue to see the parent's propagated tenant /
    OTel / Sentry context. Defaults to `%{}`.
  - `:scope` - Scope struct to inherit from the parent (optional). Propagated to
    the SubAgent's `custom_context.scope` so sub-agent tools and persistence callbacks
    see the same tenant context as the parent. Defaults to `agent_config.scope`.

  ## Examples

      subagent = SubAgent.new_from_config(
        parent_agent_id: "main-agent",
        instructions: "Research renewable energy impacts",
        agent_config: agent_struct,
        parent_tool_context: %{user_id: 42, tenant: "acme"},
        parent_metadata: %{"conversation_title" => "Research"},
        scope: %MyApp.Accounts.Scope{user: user}
      )
  """
  def new_from_config(opts) do
    agent_config = Keyword.fetch!(opts, :agent_config)
    instructions = Keyword.fetch!(opts, :instructions)

    messages = build_initial_messages(agent_config.assembled_system_prompt, instructions)

    build_subagent(agent_config, messages, opts)
  end

  @doc """
  Create a SubAgent from compiled agent (pre-built).

  A compiled subagent is pre-defined by the application with complete control
  over configuration.

  ## Options

  - `:parent_agent_id` - Parent's agent ID (required)
  - `:instructions` - Task description (required)
  - `:compiled_agent` - Pre-built Agent struct (required)
  - `:initial_messages` - Optional initial message sequence (default: [])
  - `:parent_tool_context` - Parent's tool_context map to inherit (optional).
    Static, caller-supplied data (e.g., `user_id`, feature flags) that tools
    access as flat top-level keys on context. Defaults to `%{}`.
  - `:parent_metadata` - Parent's state metadata map to inherit (optional).
    Dynamic, middleware-managed data (e.g., `conversation_title`) that tools
    access via `context.state.metadata`. Defaults to `%{}`.
  - `:parent_runtime` - Parent's `state.runtime` map to inherit (optional).
    Process-local middleware state such as captured `ProcessContext` snapshots.
    Inherited so sub-agents continue to see the parent's propagated tenant /
    OTel / Sentry context. Defaults to `%{}`.
  - `:scope` - Scope struct to inherit from the parent (optional). Propagated to
    the SubAgent's `custom_context.scope` so sub-agent tools and persistence callbacks
    see the same tenant context as the parent. Defaults to `compiled_agent.scope`.

  ## Examples

      subagent = SubAgent.new_from_compiled(
        parent_agent_id: "main-agent",
        instructions: "Extract structured data",
        compiled_agent: data_extractor_agent,
        initial_messages: [prep_message],
        parent_tool_context: %{user_id: 42},
        parent_metadata: %{"conversation_title" => "Extraction"}
      )
  """
  def new_from_compiled(opts) do
    compiled_agent = Keyword.fetch!(opts, :compiled_agent)
    instructions = Keyword.fetch!(opts, :instructions)
    initial_messages = Keyword.get(opts, :initial_messages, [])

    system_messages = build_initial_messages(compiled_agent.assembled_system_prompt, nil)
    user_message = Message.new_user!(instructions)
    messages = system_messages ++ initial_messages ++ [user_message]

    build_subagent(compiled_agent, messages, opts)
  end

  # Shared construction logic for all SubAgent creation paths.
  #
  # Given an Agent struct (from either Config or Compiled), the initial messages,
  # and the caller's opts, builds the complete SubAgent with:
  # - Fresh state inheriting parent's metadata snapshot
  # - tool_context merged into custom_context (flat for tool access, preserved
  #   as :tool_context key for nested SubAgent extraction)
  # - Chain wired up with model, tools, and messages
  #
  # ## Context propagation
  #
  # Two context channels flow from parent to SubAgent:
  # - `parent_tool_context`: static, caller-supplied data merged flat into
  #   custom_context (e.g., user_id, current_scope). This is the sole source
  #   of tool_context for SubAgents -- the Agent struct's own tool_context is
  #   not used because pre-configured SubAgent Agents are built at init time
  #   without access to the parent's runtime tool_context.
  # - `parent_metadata`: dynamic, middleware-managed data copied into the
  #   SubAgent's State.metadata (e.g., conversation_title)
  #
  # See docs/tool_context_and_state.md for full details.
  defp build_subagent(agent, messages, opts) do
    parent_agent_id = Keyword.fetch!(opts, :parent_agent_id)
    parent_tool_context = Keyword.get(opts, :parent_tool_context, %{})
    parent_metadata = Keyword.get(opts, :parent_metadata, %{})
    parent_runtime = Keyword.get(opts, :parent_runtime, %{})
    # Scope propagates from parent to SubAgent so sub-agent tools and callbacks
    # see the same tenant context. Fall back to the compiled/config agent's own
    # `:scope` field if the caller didn't pass one (e.g., direct new_from_compiled).
    scope = Keyword.get(opts, :scope, agent.scope)
    until_tool = Keyword.get(opts, :until_tool)
    max_runs = Keyword.get(opts, :max_runs)

    sub_agent_id = "#{parent_agent_id}-sub-#{:erlang.unique_integer([:positive])}"

    # SubAgent gets its own state but inherits the parent's metadata snapshot
    # and runtime context. The runtime carries process-local middleware state
    # like ProcessContext snapshots.
    subagent_state =
      State.new!(%{
        agent_id: sub_agent_id,
        metadata: parent_metadata,
        runtime: parent_runtime
      })

    # Merge parent_tool_context into custom_context (same pattern as
    # Agent.build_chain). Internal keys always take precedence on collision.
    custom_context =
      parent_tool_context
      |> Map.merge(%{
        state: subagent_state,
        parent_middleware: agent.middleware,
        # Preserve the tool_context as an explicit key so nested SubAgents
        # can extract it cleanly (same as Agent.build_chain).
        tool_context: parent_tool_context,
        # First-class scope channel, same canonical key as Agent.build_chain.
        scope: scope,
        # Direct to the parent agent id.
        agent_id: parent_agent_id
      })

    chain =
      LLMChain.new!(%{
        llm: agent.model,
        custom_context: custom_context
      })
      |> LLMChain.add_tools(agent.tools)
      |> LLMChain.add_messages(messages)

    interrupt_on = extract_interrupt_on_from_middleware(agent.middleware)

    %SubAgent{
      id: sub_agent_id,
      parent_agent_id: parent_agent_id,
      chain: chain,
      interrupt_on: interrupt_on,
      until_tool: until_tool,
      max_runs: max_runs,
      status: :idle,
      created_at: DateTime.utc_now()
    }
  end

  ## Execution Functions

  @doc """
  Execute the SubAgent.

  Runs the LLMChain until:
  - Natural completion (no more tool calls)
  - HITL interrupt (tool needs approval)
  - Error

  Returns updated SubAgent struct with new status.

  ## Options

  - `:callbacks` - Map of LLMChain callbacks (e.g., `%{on_message_processed: fn...}`)

  ## Examples

      case SubAgent.execute(subagent) do
        {:ok, completed_subagent} ->
          result = SubAgent.extract_result(completed_subagent)

        {:interrupt, interrupted_subagent} ->
          # interrupted_subagent.interrupt_data contains action_requests

        {:error, error_subagent} ->
          # error_subagent.error contains the error
      end

      # With callbacks for real-time message broadcasting
      callbacks = %{
        on_message_processed: fn _chain, message ->
          broadcast_message(message)
        end
      }
      SubAgent.execute(subagent, callbacks: callbacks)
  """
  def execute(subagent, opts \\ [])

  def execute(%SubAgent{status: :idle, chain: chain} = subagent, opts) do
    callbacks = Keyword.get(opts, :callbacks, %{})
    Logger.debug("SubAgent #{subagent.id} executing")

    # Update status to running
    running_subagent = %{subagent | status: :running}

    # Add callbacks to chain once at entry point (not in the loop)
    chain_with_callbacks = maybe_add_callbacks(chain, callbacks)

    # Execute using the mode system
    case run_with_mode(chain_with_callbacks, subagent) do
      {:ok, final_chain} ->
        # Chain completed successfully
        Logger.debug("SubAgent #{subagent.id} completed successfully")

        {:ok,
         %SubAgent{
           running_subagent
           | status: :completed,
             chain: final_chain
         }}

      {:ok, final_chain, extra} ->
        # Chain completed with extra data (e.g., until_tool result)
        Logger.debug("SubAgent #{subagent.id} completed successfully with extra data")

        {:ok,
         %SubAgent{
           running_subagent
           | status: :completed,
             chain: final_chain
         }, extra}

      {:interrupt, interrupted_chain, interrupt_data} ->
        # Chain hit HITL interrupt
        Logger.debug("SubAgent #{subagent.id} interrupted for HITL")

        {:interrupt,
         %SubAgent{
           running_subagent
           | status: :interrupted,
             chain: interrupted_chain,
             interrupt_data: interrupt_data
         }}

      {:error, reason} ->
        Logger.error("SubAgent #{subagent.id} execution error: #{inspect(reason)}")

        {:error,
         %SubAgent{
           running_subagent
           | status: :error,
             error: reason
         }}
    end
  end

  def execute(%SubAgent{status: status}, _opts) do
    {:error, {:invalid_status, status, :expected_idle}}
  end

  @doc """
  Resume the SubAgent after HITL interrupt.

  Takes human decisions and continues execution from where it left off.
  This is the magic - the agent state is already paused at the right spot.

  ## Parameters

  - `subagent` - SubAgent with status :interrupted
  - `decisions` - List of decision maps from human reviewer
  - `opts` - Optional keyword list with:
    - `:callbacks` - Map of LLMChain callbacks (e.g., `%{on_message_processed: fn...}`)

  ## Returns

  - `{:ok, completed_subagent}` - Execution completed
  - `{:interrupt, interrupted_subagent}` - Another interrupt (multiple HITL tools)
  - `{:error, error_subagent}` - Resume failed

  ## Examples

      decisions = [
        %{type: :approve},
        %{type: :edit, arguments: %{"path" => "safe.txt"}}
      ]

      case SubAgent.resume(interrupted_subagent, decisions) do
        {:ok, completed_subagent} ->
          result = SubAgent.extract_result(completed_subagent)

        {:interrupt, interrupted_again} ->
          # Another interrupt - repeat the process

        {:error, error_subagent} ->
          # Handle error
      end
  """
  def resume(subagent, decisions, opts \\ [])

  def resume(
        %SubAgent{
          status: :interrupted,
          chain: chain,
          interrupt_data: interrupt_data
        } = subagent,
        decisions,
        opts
      ) do
    callbacks = Keyword.get(opts, :callbacks, %{})
    Logger.debug("SubAgent #{subagent.id} resuming with #{length(decisions)} decisions")

    # Update status to running
    running_subagent = %{
      subagent
      | status: :running,
        interrupt_data: nil
    }

    # Extract interrupt context
    action_requests = interrupt_data.action_requests
    hitl_tool_call_ids = interrupt_data.hitl_tool_call_ids

    # Get ALL tool calls from the last assistant message (HITL + non-HITL)
    all_tool_calls = AgentUtils.get_tool_calls_from_last_message(chain)

    # Build full decisions list (mix human decisions with auto-approvals)
    # This is needed because LLMChain.execute_tool_calls_with_decisions expects
    # a decision for EVERY tool call, not just the HITL ones
    full_decisions =
      AgentUtils.build_full_decisions(
        all_tool_calls,
        hitl_tool_call_ids,
        decisions,
        action_requests
      )

    # Reset callbacks before re-adding — the chain from the initial execute()
    # already has callbacks attached. Without clearing, they'd stack and fire twice.
    chain_clean = %{chain | callbacks: []}
    chain_with_callbacks = maybe_add_callbacks(chain_clean, callbacks)

    # Use LLMChain to execute tool calls with decisions
    # This handles approve/edit/reject logic and creates tool result messages
    chain_with_results =
      LLMChain.execute_tool_calls_with_decisions(
        chain_with_callbacks,
        all_tool_calls,
        full_decisions
      )

    # Continue execution using the mode system after applying decisions
    case run_with_mode(chain_with_results, subagent) do
      {:ok, final_chain} ->
        # SubAgent completed after resume
        Logger.debug("SubAgent #{subagent.id} completed after resume")

        {:ok,
         %SubAgent{
           running_subagent
           | status: :completed,
             chain: final_chain
         }}

      {:ok, final_chain, extra} ->
        # SubAgent completed with extra data after resume
        Logger.debug("SubAgent #{subagent.id} completed after resume with extra data")

        {:ok,
         %SubAgent{
           running_subagent
           | status: :completed,
             chain: final_chain
         }, extra}

      {:interrupt, interrupted_chain, new_interrupt_data} ->
        # Another interrupt (multiple HITL tools in sequence)
        Logger.debug("SubAgent #{subagent.id} interrupted again")

        {:interrupt,
         %SubAgent{
           running_subagent
           | status: :interrupted,
             chain: interrupted_chain,
             interrupt_data: new_interrupt_data
         }}

      {:error, reason} ->
        Logger.error("SubAgent #{subagent.id} resume failed: #{inspect(reason)}")

        {:error,
         %SubAgent{
           running_subagent
           | status: :error,
             error: reason
         }}
    end
  end

  def resume(%SubAgent{status: status}, _decisions, _opts) do
    {:error, {:invalid_status, status, :expected_interrupted}}
  end

  ## State Query Functions

  @doc """
  Check if SubAgent can be executed.

  Only SubAgents with status :idle can be executed.
  """
  def can_execute?(%SubAgent{status: :idle}), do: true
  def can_execute?(%SubAgent{}), do: false

  @doc """
  Check if SubAgent can be resumed.

  Only SubAgents with status :interrupted can be resumed.
  """
  def can_resume?(%SubAgent{status: :interrupted}), do: true
  def can_resume?(%SubAgent{}), do: false

  @doc """
  Check if SubAgent is in a terminal state.

  Terminal states are :completed and :error.
  """
  def is_terminal?(%SubAgent{status: :completed}), do: true
  def is_terminal?(%SubAgent{status: :error}), do: true
  def is_terminal?(%SubAgent{}), do: false

  ## Result Extraction

  @doc """
  Extract result from completed SubAgent.

  For completed SubAgents, extracts the final message content as a string.
  This is the default extraction - middleware or custom logic can provide
  different extraction.

  Returns `{:ok, string}` on success or `{:error, reason}` on failure.

  ## Examples

      {:ok, completed_subagent} = SubAgent.execute(subagent)
      {:ok, result} = SubAgent.extract_result(completed_subagent)
      # => {:ok, "Research complete: Solar energy has shown..."}
  """
  def extract_result(%SubAgent{status: :completed, chain: chain}) do
    case Utils.ChainResult.to_string(chain) do
      {:ok, result} -> {:ok, result}
      {:error, _chain, reason} -> {:error, reason}
    end
  end

  def extract_result(%SubAgent{status: status}) do
    {:error, {:invalid_status, status, :expected_completed}}
  end

  ## Private Helper Functions

  defp build_initial_messages(system_prompt, instructions)
       when is_binary(system_prompt) and system_prompt != "" do
    case instructions do
      nil -> [Message.new_system!(system_prompt)]
      _ -> [Message.new_system!(system_prompt), Message.new_user!(instructions)]
    end
  end

  defp build_initial_messages(_system_prompt, instructions) when is_binary(instructions) do
    [Message.new_user!(instructions)]
  end

  defp build_initial_messages(_system_prompt, nil), do: []

  # Extract interrupt_on configuration from middleware list
  defp extract_interrupt_on_from_middleware(middleware) when is_list(middleware) do
    Enum.find_value(middleware, %{}, fn
      %Sagents.MiddlewareEntry{
        module: Sagents.Middleware.HumanInTheLoop,
        config: config
      } ->
        cond do
          is_map(config) -> Map.get(config, :interrupt_on)
          is_list(config) -> Keyword.get(config, :interrupt_on)
          true -> nil
        end

      _ ->
        nil
    end)
  end

  defp extract_interrupt_on_from_middleware(_), do: %{}

  # Execute chain using the mode system (replaces execute_chain_with_hitl/2)
  #
  # Delegates to LLMChain.run/2 with mode: Sagents.Modes.AgentExecution,
  # giving SubAgents the same pipeline as Agents (check_max_runs, check_pause,
  # HITL, propagate_state, until_tool).
  #
  # Note: Callbacks should be added to the chain BEFORE calling this function.
  defp run_with_mode(chain, subagent) do
    mode_opts = build_mode_opts(subagent)

    case LLMChain.run(chain, mode_opts) do
      {:ok, final_chain} -> {:ok, final_chain}
      {:ok, final_chain, extra} -> {:ok, final_chain, extra}
      {:interrupt, chain, interrupt_data} -> {:interrupt, chain, interrupt_data}
      # Infrastructure pause is treated as completion for SubAgents.
      # SubAgents are short-lived and don't support the external pause signal
      # that LangChain modes can return. If the mode pauses, we consider the
      # SubAgent's work done with whatever progress was made.
      {:pause, chain} -> {:ok, chain}
      {:error, _chain, reason} -> {:error, reason}
    end
  end

  @doc false
  def build_mode_opts(%SubAgent{
        interrupt_on: interrupt_on,
        until_tool: until_tool,
        max_runs: max_runs
      }) do
    opts = [mode: Sagents.Modes.AgentExecution]

    opts =
      if interrupt_on != nil and is_map(interrupt_on) and map_size(interrupt_on) > 0 do
        # Build a MiddlewareEntry for the HITL middleware so that
        # check_pre_tool_hitl in the mode pipeline can find it.
        # We call HumanInTheLoop.init/1 to get a properly normalized config.
        {:ok, hitl_config} =
          Sagents.Middleware.HumanInTheLoop.init(interrupt_on: interrupt_on)

        hitl_entry = %Sagents.MiddlewareEntry{
          id: Sagents.Middleware.HumanInTheLoop,
          module: Sagents.Middleware.HumanInTheLoop,
          config: hitl_config
        }

        Keyword.put(opts, :middleware, [hitl_entry])
      else
        opts
      end

    opts =
      case until_tool do
        nil -> opts
        ut -> Keyword.put(opts, :until_tool, ut)
      end

    opts =
      case max_runs do
        nil -> opts
        mr -> Keyword.put(opts, :max_runs, mr)
      end

    opts
  end

  # Helper to conditionally add callbacks to chain
  defp maybe_add_callbacks(chain, callbacks) when callbacks in [nil, %{}, []], do: chain

  defp maybe_add_callbacks(chain, callbacks) when is_list(callbacks) do
    Enum.reduce(callbacks, chain, fn cb_map, acc ->
      LLMChain.add_callback(acc, cb_map)
    end)
  end

  defp maybe_add_callbacks(chain, callbacks) when is_map(callbacks) do
    LLMChain.add_callback(chain, callbacks)
  end

  ## Nested Modules (Config and Compiled)

  defmodule Config do
    @moduledoc """
    Configuration for dynamically-created SubAgents.

    Defines all parameters needed to instantiate a SubAgent at runtime.
    """

    use Ecto.Schema
    import Ecto.Changeset
    alias __MODULE__

    @primary_key false
    embedded_schema do
      field :name, :string
      field :description, :string
      field :system_prompt, :string
      field :instructions, :string
      field :system_prompt_override, :string
      field :use_instructions, :string
      field :display_text, :string
      field :tools, {:array, :any}, default: [], virtual: true
      field :model, :any, virtual: true
      field :middleware, {:array, :any}, default: [], virtual: true
      field :interrupt_on, :map
      field :until_tool, :any, virtual: true
      field :max_runs, :integer, virtual: true
    end

    @type t :: %Config{
            name: String.t(),
            description: String.t(),
            system_prompt: String.t() | nil,
            instructions: String.t() | nil,
            system_prompt_override: String.t() | nil,
            use_instructions: String.t() | nil,
            display_text: String.t() | nil,
            tools: [LangChain.Function.t()],
            model: term() | nil,
            middleware: list(),
            interrupt_on: map() | nil,
            until_tool: String.t() | [String.t()] | nil,
            max_runs: integer() | nil
          }

    def new(attrs) do
      %Config{}
      |> cast(attrs, [
        :name,
        :description,
        :system_prompt,
        :instructions,
        :system_prompt_override,
        :use_instructions,
        :display_text,
        :tools,
        :model,
        :middleware,
        :interrupt_on,
        :until_tool,
        :max_runs
      ])
      |> validate_required([:name, :description, :tools])
      |> validate_length(:name, min: 1, max: 100)
      |> validate_length(:description, min: 1, max: 500)
      |> validate_length(:system_prompt, min: 1, max: 10_000)
      |> validate_length(:instructions, min: 1, max: 10_000)
      |> validate_length(:system_prompt_override, min: 1, max: 10_000)
      |> validate_length(:use_instructions, min: 1, max: 10_000)
      |> validate_length(:display_text, min: 1, max: 200)
      |> validate_tools()
      |> validate_until_tool()
      |> validate_prompt_source()
      |> apply_action(:insert)
    end

    def new!(attrs) do
      case new(attrs) do
        {:ok, config} -> config
        {:error, changeset} -> raise LangChain.LangChainError, changeset
      end
    end

    defp validate_tools(changeset) do
      case get_field(changeset, :tools) do
        tools when is_list(tools) and length(tools) > 0 ->
          if Enum.all?(tools, &is_struct(&1, LangChain.Function)) do
            changeset
          else
            add_error(changeset, :tools, "must be a list of LangChain.Function structs")
          end

        [] ->
          add_error(changeset, :tools, "must contain at least one tool")

        _ ->
          add_error(changeset, :tools, "must be a list")
      end
    end

    defp validate_until_tool(changeset) do
      until_tool = get_field(changeset, :until_tool)
      tools = get_field(changeset, :tools)

      case until_tool do
        nil ->
          changeset

        name when is_binary(name) ->
          validate_tool_names_exist(changeset, [name], tools)

        names when is_list(names) ->
          validate_tool_names_exist(changeset, names, tools)

        _ ->
          add_error(changeset, :until_tool, "must be a string or list of strings")
      end
    end

    defp validate_tool_names_exist(changeset, names, tools) when is_list(tools) do
      tool_names =
        tools
        |> Enum.filter(&is_struct(&1, LangChain.Function))
        |> Enum.map(& &1.name)
        |> MapSet.new()

      missing = Enum.reject(names, &MapSet.member?(tool_names, &1))

      if missing == [] do
        changeset
      else
        add_error(
          changeset,
          :until_tool,
          "references tools that are not in the tools list: #{Enum.join(missing, ", ")}"
        )
      end
    end

    defp validate_tool_names_exist(changeset, _names, _tools), do: changeset

    # At least one of system_prompt, instructions, or system_prompt_override
    # must be present so the sub-agent has *some* task framing beyond the
    # boilerplate.
    defp validate_prompt_source(changeset) do
      sources = [:system_prompt, :instructions, :system_prompt_override]
      any_present? = Enum.any?(sources, &present?(get_field(changeset, &1)))

      if any_present? do
        changeset
      else
        add_error(
          changeset,
          :system_prompt,
          "at least one of :system_prompt, :instructions, or :system_prompt_override must be set"
        )
      end
    end

    defp present?(nil), do: false
    defp present?(""), do: false
    defp present?(str) when is_binary(str), do: true
    defp present?(_), do: false
  end

  defmodule Compiled do
    @moduledoc """
    Pre-compiled SubAgent with an existing Agent instance.
    """

    use Ecto.Schema
    import Ecto.Changeset
    alias __MODULE__

    @primary_key false
    embedded_schema do
      field :name, :string
      field :description, :string
      field :use_instructions, :string
      field :display_text, :string
      field :agent, :any, virtual: true
      field :extract_result, :any, virtual: true
      field :initial_messages, {:array, :any}, default: [], virtual: true
    end

    @type t :: %Compiled{
            name: String.t(),
            description: String.t(),
            use_instructions: String.t() | nil,
            display_text: String.t() | nil,
            agent: Sagents.Agent.t(),
            extract_result: (State.t() -> any()) | nil,
            initial_messages: [LangChain.Message.t()]
          }

    def new(attrs) do
      %Compiled{}
      |> cast(attrs, [
        :name,
        :description,
        :use_instructions,
        :display_text,
        :agent,
        :extract_result,
        :initial_messages
      ])
      |> validate_required([:name, :description, :agent])
      |> validate_length(:name, min: 1, max: 100)
      |> validate_length(:description, min: 1, max: 500)
      |> validate_length(:use_instructions, min: 1, max: 10_000)
      |> validate_length(:display_text, min: 1, max: 200)
      |> validate_agent()
      |> validate_extract_result()
      |> validate_initial_messages()
      |> apply_action(:insert)
    end

    def new!(attrs) do
      case new(attrs) do
        {:ok, compiled} -> compiled
        {:error, changeset} -> raise LangChain.LangChainError, changeset
      end
    end

    defp validate_agent(changeset) do
      case get_field(changeset, :agent) do
        %Sagents.Agent{} ->
          changeset

        _ ->
          add_error(changeset, :agent, "must be a Sagents.Agent struct")
      end
    end

    defp validate_extract_result(changeset) do
      case get_field(changeset, :extract_result) do
        nil ->
          changeset

        fun when is_function(fun, 1) ->
          changeset

        _ ->
          add_error(
            changeset,
            :extract_result,
            "must be a function that takes one argument (State)"
          )
      end
    end

    defp validate_initial_messages(changeset) do
      case get_field(changeset, :initial_messages) do
        nil ->
          # Treat nil as empty list
          put_change(changeset, :initial_messages, [])

        [] ->
          changeset

        messages when is_list(messages) ->
          # Validate all items are Message structs
          if Enum.all?(messages, &is_struct(&1, LangChain.Message)) do
            changeset
          else
            add_error(changeset, :initial_messages, "must be a list of Message structs")
          end

        _ ->
          add_error(changeset, :initial_messages, "must be a list of Message structs")
      end
    end
  end

  ## AgentMap Building Functions

  @doc """
  Build an agent map of subagents from configurations.
  """
  def build_agent_map(configs, default_model, default_middleware \\ []) do
    try do
      registry =
        Enum.reduce(configs, %{}, fn config, acc ->
          agent = configure_new_subagent(config, default_model, default_middleware)
          Map.put(acc, config.name, agent)
        end)

      {:ok, registry}
    rescue
      e -> {:error, "Failed to build subagent registry: #{Exception.message(e)}"}
    end
  end

  @doc """
  Build a registry of subagents, raising on error.
  """
  def build_agent_map!(configs, default_model, default_middleware \\ []) do
    case build_agent_map(configs, default_model, default_middleware) do
      {:ok, registry} -> registry
      {:error, reason} -> raise LangChain.LangChainError, reason
    end
  end

  @doc """
  Build descriptions map for subagents.
  """
  def build_descriptions(configs) do
    Enum.reduce(configs, %{}, fn config, acc ->
      Map.put(acc, config.name, config.description)
    end)
  end

  @doc """
  Build a middleware stack for subagents, filtering out blocked middleware.

  The SubAgent middleware itself is ALWAYS filtered out to prevent recursive
  subagent nesting, regardless of whether it appears in the block list.

  This function handles middleware in all formats:
  - Raw module atoms (e.g., `Sagents.Middleware.SubAgent`)
  - Raw tuples (e.g., `{Sagents.Middleware.SubAgent, opts}`)
  - Initialized MiddlewareEntry structs (from `agent.middleware`)

  ## Options

    * `:block_middleware` - List of middleware modules to exclude from inheritance.
      These modules will not be passed to general-purpose subagents. Defaults to `[]`.

  ## Examples

      # Default behavior: only SubAgent middleware is filtered
      subagent_middleware_stack(parent_middleware)

      # Block additional middleware from being inherited
      subagent_middleware_stack(parent_middleware, [],
        block_middleware: [ConversationTitle, Summarization]
      )

      # Add additional middleware while blocking others
      subagent_middleware_stack(parent_middleware, [CustomMiddleware],
        block_middleware: [ConversationTitle]
      )

  """
  @spec subagent_middleware_stack(list(), list(), keyword()) :: list()
  def subagent_middleware_stack(default_middleware, additional_middleware \\ [], opts \\ []) do
    block_list = Keyword.get(opts, :block_middleware, [])

    # Always block SubAgent middleware + user-specified modules
    # Use MapSet for O(1) lookup performance
    blocked_modules = MapSet.new([Sagents.Middleware.SubAgent | block_list])

    filtered =
      Enum.reject(default_middleware, fn mw ->
        extract_middleware_module(mw) in blocked_modules
      end)

    filtered ++ additional_middleware
  end

  @doc """
  Check if a middleware spec refers to the SubAgent middleware.

  Handles all middleware formats: raw modules, tuples, and MiddlewareEntry structs.
  """
  @spec is_subagent_middleware?(any()) :: boolean()
  def is_subagent_middleware?(middleware) do
    extract_middleware_module(middleware) == Sagents.Middleware.SubAgent
  end

  @doc """
  Extract the module from any middleware format.

  Returns the middleware module regardless of whether the input is:
  - A raw module atom
  - A {module, opts} tuple
  - A MiddlewareEntry struct

  Returns nil for unrecognized formats.
  """
  @spec extract_middleware_module(any()) :: module() | nil
  def extract_middleware_module(%Sagents.MiddlewareEntry{module: module}), do: module
  def extract_middleware_module({module, _opts}) when is_atom(module), do: module
  def extract_middleware_module(module) when is_atom(module), do: module
  def extract_middleware_module(_), do: nil

  ## Private Functions

  # Universal framing for task-style sub-agents. Prepended to every Config-path
  # sub-agent's system prompt so authors can focus on task specifics in
  # `instructions`. Overridable via `system_prompt_override`.
  @task_subagent_boilerplate """
  You are a sub-agent invoked by to perform a specific, bounded task. You have access to tools. Focus on completing the task you've been given.

  - You must complete the task and return a result, or fail and return a clear error. Do not stall.
  - You cannot ask the user questions. There is no user in this conversation — only the instructions you've been given.
  - Do not request clarification. Make the best decision with the information you have and report what you did.
  - When finished, return a clear, concise result suitable for the parent agent to use.
  """

  @doc """
  Returns the universal framing prompt prepended to every task-style sub-agent's
  system prompt.

  Encodes the "no user, complete-or-fail, no clarifying questions" contract so
  that `Sagents.SubAgent.Task` authors can focus their `instructions/0` on the
  substantive procedure. Host compilers combine this with the task's
  `instructions/0` to form the child agent's system prompt; it can be replaced
  per-sub-agent via `Sagents.SubAgent.Config`'s `system_prompt_override`.
  """
  def task_subagent_boilerplate, do: @task_subagent_boilerplate

  @doc """
  Compose the child agent's `base_system_prompt` from a Config.

  Composition rule:
  - Header = `system_prompt_override` (if set) else the built-in boilerplate.
  - Body = `instructions` (if set) else `system_prompt` (legacy) else "".

  The header and body are joined with a blank line. Middleware-contributed
  prompt fragments are appended later by the normal `Sagents.Agent` compile
  path — this function does not handle those.
  """
  def compose_child_system_prompt(%Config{} = cfg) do
    header = cfg.system_prompt_override || @task_subagent_boilerplate
    body = cfg.instructions || cfg.system_prompt || ""

    [header, body]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp configure_new_subagent(%Config{} = config, default_model, default_middleware) do
    # Use config's model or fall back to default
    model = config.model || default_model

    # Build middleware stack (filters out SubAgent middleware)
    middleware = subagent_middleware_stack(default_middleware, config.middleware)

    # Append HITL middleware if interrupt_on is configured on this sub-agent.
    # This must be done explicitly because replace_default_middleware: true
    # skips build_default_middleware where HITL would normally be added.
    middleware =
      Sagents.Middleware.HumanInTheLoop.maybe_append(middleware, config.interrupt_on)

    base_system_prompt = compose_child_system_prompt(config)

    # Create the agent with explicit middleware (replace defaults to avoid duplication)
    Sagents.Agent.new!(
      %{
        model: model,
        base_system_prompt: base_system_prompt,
        tools: config.tools,
        middleware: middleware
      },
      replace_default_middleware: true
    )
  end

  defp configure_new_subagent(%Compiled{} = compiled, _default_model, _default_middleware) do
    # Return the entire Compiled struct to preserve initial_messages and other metadata
    compiled
  end
end
