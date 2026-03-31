defmodule Sagents.Middleware.HumanInTheLoop do
  @moduledoc """
  Middleware that enables human oversight and intervention in agent workflows.

  HumanInTheLoop (HITL) allows pausing agent execution before executing
  sensitive or critical tool operations, providing humans with the ability to
  approve, edit, or reject tool calls.

  ## Configuration

  The middleware is configured with an `interrupt_on` map that specifies which
  tools should trigger human approval:

      # Simple boolean configuration
      interrupt_on = %{
        "write_file" => true,           # Enable with default decisions
        "delete_file" => true,
        "read_file" => false            # No interruption
      }

      # Advanced configuration with custom decisions
      interrupt_on = %{
        "write_file" => %{
          allowed_decisions: [:approve, :edit, :reject]
        },
        "delete_file" => %{
          allowed_decisions: [:approve, :reject]  # No edit option
        }
      }

  ### Decision Types

  - `:approve` - Execute the tool with original arguments
  - `:edit` - Execute the tool with modified arguments
  - `:reject` - Skip tool execution entirely

  ## Usage

      # Create agent with HITL middleware
      {:ok, agent} = Agent.new(
        model: model,
        interrupt_on: %{
          "write_file" => true,
          "delete_file" => true
        }
      )

      # Execute - will return interrupt if tool needs approval
      state = State.new!(%{messages: [...]})
      result = Agent.execute(agent, state)

      case result do
        {:ok, state} ->
          # Normal completion
          handle_response(state)

        {:interrupt, state, interrupt_data} ->
          # Human approval needed
          decisions = get_human_decisions(interrupt_data)
          {:ok, final_state} = Agent.resume(agent, state, decisions)
      end

  ## Interrupt Structure

  When a tool requires approval, execution returns an interrupt tuple with
  detailed information about the tools requiring approval.

  ### Structure

      {:interrupt, state, %{
        action_requests: [action_request, ...],
        review_configs: %{tool_name => config, ...}
      }}

  ### Action Requests

  Each action request contains complete information about the tool call:

      %{
        tool_call_id: "call_123",      # Unique identifier for this tool call
        tool_name: "write_file",       # Name of the tool being called
        arguments: %{...}              # Arguments that would be passed to the tool
      }

  ### Review Configs

  A map of tool names to their approval configuration. More efficient than the
  Python library's array-based approach, providing O(1) lookup:

      %{
        "write_file" => %{
          allowed_decisions: [:approve, :edit, :reject]
        },
        "delete_file" => %{
          allowed_decisions: [:approve, :reject]  # Edit not allowed
        }
      }

  ### Complete Example

      {:interrupt, state, %{
        action_requests: [
          %{
            tool_call_id: "call_123",
            tool_name: "write_file",
            arguments: %{"path" => "file.txt", "content" => "data"}
          },
          %{
            tool_call_id: "call_456",
            tool_name: "delete_file",
            arguments: %{"path" => "old.txt"}
          }
        ],
        review_configs: %{
          "write_file" => %{allowed_decisions: [:approve, :edit, :reject]},
          "delete_file" => %{allowed_decisions: [:approve, :reject]}
        }
      }}

  ## Resume Structure

  Resume execution by providing decisions that correspond to each action request
  in order.

  ### Decision Types

  - `:approve` - Execute the tool with its original arguments
  - `:edit` - Execute the tool with modified arguments (requires `:arguments`
    field)
  - `:reject` - Skip tool execution, provide rejection message to agent

  ### Decision Format

  Each decision is a map with a required `:type` field:

      # Approve decision
      %{type: :approve}

      # Edit decision (must include :arguments with the modified parameters)
      %{type: :edit, arguments: %{"path" => "modified.txt", "content" => "new data"}}

      # Reject decision
      %{type: :reject}

  ### Complete Resume Example

  The decisions list must match the order and count of action_requests:

      # Given interrupt with 3 action requests
      {:interrupt, state, %{action_requests: [req1, req2, req3], ...}}

      # Provide corresponding decisions
      decisions = [
        %{type: :approve},                                    # Approve req1
        %{type: :edit, arguments: %{"path" => "other.txt"}}, # Edit req2's arguments
        %{type: :reject}                                      # Reject req3
      ]

      # Resume execution
      {:ok, final_state} = Agent.resume(agent, state, decisions)

  ## Position in Middleware Stack

  **HITL must be the last middleware in the stack.** This is required because
  during `handle_resume`, HITL executes ALL tool calls from the interrupted
  assistant message (auto-approving non-HITL tools). If an auto-approved tool
  produces its own interrupt (e.g., `ask_user`), HITL detects this and hands off
  via `{:cont}` so the owning middleware can claim it. Since the `handle_resume`
  middleware cycle is single-pass, only middleware that comes AFTER HITL in the
  stack will see the handoff. Placing interrupt-producing middleware before HITL
  ensures they get a chance to claim interrupts discovered during HITL's tool
  execution.

  `HumanInTheLoop.maybe_append/2` enforces this by always appending to the end
  of the middleware list.

  Default stack position:
  1. TodoList
  2. FileSystem
  3. SubAgent
  4. Summarization
  5. PatchToolCalls
  6. AskUserQuestion (or other interrupt-producing middleware)
  7. **HumanInTheLoop** ← Always last
  """

  @behaviour Sagents.Middleware

  alias Sagents.Agent
  alias Sagents.State
  alias Sagents.AgentServer
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Chains.LLMChain

  @type interrupt_config :: %{
          allowed_decisions: [atom()]
        }

  @type interrupt_on_config :: %{
          optional(String.t()) => boolean() | interrupt_config()
        }

  @type action_request :: %{
          tool_call_id: String.t(),
          tool_name: String.t(),
          arguments: map()
        }

  @type interrupt_data :: %{
          action_requests: [action_request()],
          review_configs: %{String.t() => interrupt_config()},
          hitl_tool_call_ids: [String.t()]
        }

  @type decision :: %{
          required(:type) => :approve | :edit | :reject,
          optional(:arguments) => map()
        }

  @default_decisions [:approve, :edit, :reject]

  @doc """
  Conditionally append HumanInTheLoop middleware to a middleware list.

  This is a convenience function for building middleware stacks. It only adds
  the HumanInTheLoop middleware if the `interrupt_on` configuration is provided
  and contains at least one tool configuration.

  ## Parameters

  - `middleware` - The existing middleware list
  - `interrupt_on` - Map of tool names to interrupt configuration, or `nil`

  ## Returns

  The middleware list, either unchanged or with HumanInTheLoop appended.

  ## Examples

      # With interrupt configuration - adds HumanInTheLoop
      middleware = [TodoList, FileSystem]
      |> HumanInTheLoop.maybe_append(%{"write_file" => true})
      # => [TodoList, FileSystem, {HumanInTheLoop, [interrupt_on: %{...}]}]

      # Without configuration - returns unchanged
      middleware = [TodoList, FileSystem]
      |> HumanInTheLoop.maybe_append(nil)
      # => [TodoList, FileSystem]

      # Empty map - returns unchanged
      middleware = [TodoList, FileSystem]
      |> HumanInTheLoop.maybe_append(%{})
      # => [TodoList, FileSystem]

  ## Usage in Factory

      defp build_middleware(interrupt_on) do
        [
          Sagents.Middleware.TodoList,
          Sagents.Middleware.FileSystem,
          Sagents.Middleware.SubAgent,
          Sagents.Middleware.Summarization,
          Sagents.Middleware.PatchToolCalls
        ]
        |> Sagents.Middleware.HumanInTheLoop.maybe_append(interrupt_on)
      end
  """
  @spec maybe_append(list(), interrupt_on_config() | nil) :: list()
  def maybe_append(middleware, nil), do: middleware
  def maybe_append(middleware, interrupt_on) when interrupt_on == %{}, do: middleware

  def maybe_append(middleware, interrupt_on) when is_map(interrupt_on) do
    middleware ++ [{__MODULE__, [interrupt_on: interrupt_on]}]
  end

  @impl true
  def init(opts) do
    interrupt_on = Keyword.get(opts, :interrupt_on, %{})
    config = %{interrupt_on: normalize_interrupt_config(interrupt_on)}
    {:ok, config}
  end

  @doc """
  Check if the current state requires an interrupt for human approval.

  This can be called before tool execution to determine if we need to pause
  and wait for human decisions.

  ## Parameters

  - `state` - The current agent state
  - `config` - Middleware configuration with interrupt_on map

  ## Returns

  - `{:interrupt, interrupt_data}` - If tools need approval
  - `:continue` - If no approval needed
  """
  def check_for_interrupt(%State{} = state, config) do
    # Check if the last message is an assistant message with tool calls
    case get_last_assistant_message_with_tools(state.messages) do
      nil ->
        # No tool calls to intercept
        :continue

      assistant_message ->
        # Check if any tool calls require human approval
        tool_calls = assistant_message.tool_calls || []
        interrupt_requests = collect_interrupt_requests(tool_calls, config.interrupt_on)

        if interrupt_requests == [] do
          :continue
        else
          # Generate interrupt
          interrupt_data = build_interrupt_data(interrupt_requests, config.interrupt_on)

          # Broadcast debug event for interrupt
          tool_names =
            interrupt_data.action_requests
            |> Enum.map(& &1.tool_name)
            |> Enum.join(", ")

          AgentServer.publish_debug_event_from(
            state.agent_id,
            {:middleware_action, __MODULE__,
             {:interrupt_generated,
              "#{length(interrupt_data.action_requests)} tool(s): #{tool_names}"}}
          )

          {:interrupt, interrupt_data}
        end
    end
  end

  @doc """
  Validate human decisions against tool calls.

  This is called by Agent.resume/3 to validate decisions before executing tools.
  The actual tool execution happens in LLMChain.execute_tool_calls_with_decisions/3.

  ## Parameters

  - `state` - The state at the point of interruption
  - `decisions` - List of decision maps
  - `config` - Middleware configuration

  ## Returns

  - `{:ok, state}` - Decisions are valid (state unchanged)
  - `{:error, reason}` - Invalid decisions
  """
  def process_decisions(%State{} = state, decisions, _config) when is_list(decisions) do
    # Get interrupt_data from state to determine which tools need HITL
    interrupt_data = state.interrupt_data

    if is_nil(interrupt_data) do
      {:error,
       "No interrupt data found in state. Cannot process decisions without interrupt context."}
    else
      hitl_tool_call_ids = Map.get(interrupt_data, :hitl_tool_call_ids, [])

      # Validate decision count matches HITL tool count (not all tools)
      if length(decisions) != length(hitl_tool_call_ids) do
        {:error,
         "Decision count (#{length(decisions)}) does not match HITL tool count (#{length(hitl_tool_call_ids)})"}
      else
        # Validate each decision against action_requests
        action_requests = Map.get(interrupt_data, :action_requests, [])

        case validate_decisions_against_action_requests(
               action_requests,
               decisions,
               interrupt_data
             ) do
          :ok -> {:ok, state}
          {:error, _reason} = error -> error
        end
      end
    end
  end

  @doc """
  Handle resume for HITL interrupts.

  Claims interrupts where `state.interrupt_data` has `:action_requests`.
  Validates decisions, executes approved tools via LLMChain, and returns
  the updated state with tool results added.
  """
  @impl true
  def handle_resume(
        agent,
        %State{interrupt_data: %{action_requests: _}} = state,
        decisions,
        config,
        opts
      )
      when is_list(decisions) do
    case process_decisions(state, decisions, config) do
      {:ok, ^state} ->
        execute_approved_tools(agent, state, decisions, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_resume(_agent, state, _resume_data, _config, _opts), do: {:cont, state}

  defp execute_approved_tools(agent, state, decisions, opts) do
    messages = state.messages
    callbacks = Keyword.get(opts, :callbacks)

    if Enum.all?(messages, &is_struct(&1, Message)) do
      case Agent.build_chain(agent, messages, state, callbacks) do
        {:ok, chain} ->
          # Get the assistant message with tool calls
          assistant_msg =
            Enum.reverse(messages)
            |> Enum.find(fn msg ->
              msg.role == :assistant && msg.tool_calls != nil && msg.tool_calls != []
            end)

          case assistant_msg do
            nil ->
              {:error, "No tool calls found in state"}

            %{tool_calls: all_tool_calls} ->
              interrupt_data = state.interrupt_data || %{}
              hitl_tool_call_ids = Map.get(interrupt_data, :hitl_tool_call_ids, [])
              action_requests = Map.get(interrupt_data, :action_requests, [])

              # Build decisions map indexed by tool_call_id
              decisions_by_id =
                action_requests
                |> Enum.zip(decisions)
                |> Map.new(fn {action_req, decision} ->
                  {action_req.tool_call_id, decision}
                end)

              # Build full decisions array matching ALL tool calls
              # Auto-approve non-HITL tools, use human decisions for HITL tools
              full_decisions =
                Enum.map(all_tool_calls, fn tc ->
                  if tc.call_id in hitl_tool_call_ids do
                    Map.fetch!(decisions_by_id, tc.call_id)
                  else
                    %{type: :approve}
                  end
                end)

              # Execute tool calls with decisions via LLMChain
              updated_chain =
                LLMChain.execute_tool_calls_with_decisions(
                  chain,
                  all_tool_calls,
                  full_decisions
                )

              # Extract the tool result message and add to state
              tool_result_message = List.last(updated_chain.exchanged_messages)
              state_with_results = State.add_message(state, tool_result_message)

              # Check if any auto-approved tools produced interrupts during
              # execution. If so, return {:cont} with the new interrupt_data on
              # state so the middleware cycle re-scans and the owning middleware
              # can claim it.
              interrupted = find_interrupt_results(tool_result_message)

              if interrupted == [] do
                {:ok, state_with_results}
              else
                interrupt_data = build_interrupt_data_from_results(interrupted)
                {:cont, %{state_with_results | interrupt_data: interrupt_data}}
              end
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "All messages must be LangChain.Message structs"}
    end
  end

  # Private functions

  defp normalize_interrupt_config(interrupt_on) when is_map(interrupt_on) do
    Map.new(interrupt_on, fn
      {tool_name, true} when is_binary(tool_name) ->
        {tool_name, %{allowed_decisions: @default_decisions}}

      {tool_name, false} when is_binary(tool_name) ->
        {tool_name, %{allowed_decisions: []}}

      {tool_name, %{allowed_decisions: decisions} = config}
      when is_binary(tool_name) and is_list(decisions) ->
        {tool_name, config}

      {tool_name, config} when is_binary(tool_name) and is_map(config) ->
        # If no allowed_decisions specified, use defaults
        {tool_name, Map.put_new(config, :allowed_decisions, @default_decisions)}
    end)
  end

  defp normalize_interrupt_config(_), do: %{}

  defp get_last_assistant_message_with_tools(messages) do
    # Get all tool call IDs that already have results
    executed_tool_call_ids =
      messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.flat_map(fn msg -> msg.tool_results || [] end)
      |> Enum.map(& &1.tool_call_id)
      |> MapSet.new()

    # Find the last assistant message that has tool calls without results
    messages
    |> Enum.reverse()
    |> Enum.find(fn msg ->
      if msg.role == :assistant && msg.tool_calls != nil && msg.tool_calls != [] do
        # Check if any of the tool calls haven't been executed yet
        Enum.any?(msg.tool_calls, fn tc ->
          not MapSet.member?(executed_tool_call_ids, tc.call_id)
        end)
      else
        false
      end
    end)
  end

  defp collect_interrupt_requests(tool_calls, interrupt_on) do
    Enum.filter(tool_calls, fn %ToolCall{name: tool_name} ->
      case Map.get(interrupt_on, tool_name) do
        %{allowed_decisions: decisions} when is_list(decisions) and decisions != [] ->
          true

        _ ->
          false
      end
    end)
  end

  defp build_interrupt_data(tool_calls, interrupt_on) do
    action_requests =
      Enum.map(tool_calls, fn %ToolCall{} = tc ->
        %{
          tool_call_id: tc.call_id,
          tool_name: tc.name,
          arguments: tc.arguments || %{},
          display_text: tc.display_text
        }
      end)

    review_configs =
      tool_calls
      |> Enum.map(fn %ToolCall{name: tool_name} ->
        {tool_name, Map.get(interrupt_on, tool_name, %{allowed_decisions: @default_decisions})}
      end)
      |> Enum.uniq_by(fn {tool_name, _} -> tool_name end)
      |> Map.new()

    # Track which tool call IDs require HITL decisions
    hitl_tool_call_ids = Enum.map(tool_calls, & &1.call_id)

    %{
      action_requests: action_requests,
      review_configs: review_configs,
      hitl_tool_call_ids: hitl_tool_call_ids
    }
  end

  # Find tool results that have is_interrupt: true (produced by auto-approved
  # tools that returned {:interrupt, ...} during
  # execute_tool_calls_with_decisions).
  defp find_interrupt_results(%Message{tool_results: results}) when is_list(results) do
    Enum.filter(results, & &1.is_interrupt)
  end

  defp find_interrupt_results(_), do: []

  # Build interrupt_data from interrupt ToolResults, matching the format
  # produced by LangChain.Chains.LLMChain.Mode.Steps.extract_interrupt_data.
  defp build_interrupt_data_from_results([single]) do
    Map.put(single.interrupt_data, :tool_call_id, single.tool_call_id)
  end

  defp build_interrupt_data_from_results(multiple) do
    %{
      type: :multiple_interrupts,
      interrupts:
        Enum.map(multiple, fn result ->
          Map.merge(result.interrupt_data, %{tool_call_id: result.tool_call_id})
        end)
    }
  end

  defp validate_decisions_against_action_requests(action_requests, decisions, interrupt_data) do
    # Pair action requests with decisions and add index
    paired =
      Enum.zip(action_requests, decisions)
      |> Enum.with_index()

    review_configs = Map.get(interrupt_data, :review_configs, %{})

    # Validate each decision
    Enum.reduce_while(paired, :ok, fn {{action_req, decision}, index}, _ ->
      tool_name = action_req.tool_name
      tool_config = Map.get(review_configs, tool_name, %{allowed_decisions: @default_decisions})
      allowed = tool_config.allowed_decisions || @default_decisions

      cond do
        !is_map(decision) ->
          {:halt, {:error, "Decision at index #{index} is not a map"}}

        !Map.has_key?(decision, :type) ->
          {:halt,
           {:error,
            "Decision at index #{index} missing required 'type' field: #{inspect(decision)}"}}

        decision.type not in allowed ->
          {:halt,
           {:error,
            "Decision type '#{decision.type}' not allowed for tool '#{tool_name}'. Allowed: #{inspect(allowed)}"}}

        decision.type == :edit && !Map.has_key?(decision, :arguments) ->
          {:halt,
           {:error,
            "Decision at index #{index} with type 'edit' must include 'arguments' field: #{inspect(decision)}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end
end
