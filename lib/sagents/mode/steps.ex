defmodule Sagents.Mode.Steps do
  @moduledoc """
  Sagents-specific pipeline steps for custom execution modes.

  These steps handle concerns that belong at the agent layer, not the
  LLMChain layer: HITL interrupts and state propagation from tool results.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias Sagents.State
  alias Sagents.InterruptSignal
  alias Sagents.MiddlewareEntry
  alias Sagents.Middleware.HumanInTheLoop

  @doc """
  Check if the LLM response contains tool calls that need human approval.

  Reads middleware list from opts `:middleware`. Inspects `chain.exchanged_messages`
  for tool calls that match the HITL policy.

  Returns `{:interrupt, chain, interrupt_data}` if approval is needed.
  """
  def check_pre_tool_hitl({:continue, chain}, opts) do
    middleware = Keyword.get(opts, :middleware, [])

    hitl_middleware =
      Enum.find(middleware, fn %MiddlewareEntry{module: module} ->
        module == HumanInTheLoop
      end)

    case hitl_middleware do
      nil ->
        {:continue, chain}

      %MiddlewareEntry{module: module, config: config} ->
        agent_id =
          case chain.custom_context do
            %{state: %{agent_id: agent_id}} -> agent_id
            _ -> nil
          end

        state = %State{
          agent_id: agent_id,
          messages: chain.exchanged_messages,
          metadata: %{}
        }

        case module.check_for_interrupt(state, config) do
          {:interrupt, interrupt_data} ->
            {:interrupt, chain, interrupt_data}

          :continue ->
            {:continue, chain}
        end
    end
  end

  def check_pre_tool_hitl(terminal, _opts), do: terminal

  @doc """
  Propagate state updates from tool results into the chain's custom_context.

  After tool execution, tools may have returned State structs as
  `processed_content`. This step extracts those deltas and merges them
  into `custom_context.state`.
  """
  def propagate_state({:continue, chain}, _opts) do
    {:continue, update_chain_state_from_tools(chain)}
  end

  def propagate_state(terminal, _opts), do: terminal

  @doc """
  Check if the last tool-role message contains an InterruptSignal in its
  processed_content, indicating a SubAgent HITL interrupt.

  This step runs **after** tool execution and state propagation. It scans
  the chain's `last_message` for an `InterruptSignal` struct and, if found,
  converts the pipeline to `{:interrupt, chain, interrupt_data}`.
  """
  def check_post_tool_interrupt({:continue, chain}, _opts) do
    case find_all_interrupt_signals(chain) do
      [] ->
        {:continue, chain}

      [single] ->
        interrupt_data = %{
          type: single.type,
          sub_agent_id: single.sub_agent_id,
          subagent_type: single.subagent_type,
          interrupt_data: single.interrupt_data,
          tool_call_id: single.tool_call_id,
          pending_interrupts: []
        }

        {:interrupt, chain, interrupt_data}

      [current | rest] ->
        interrupt_data = %{
          type: current.type,
          sub_agent_id: current.sub_agent_id,
          subagent_type: current.subagent_type,
          interrupt_data: current.interrupt_data,
          tool_call_id: current.tool_call_id,
          pending_interrupts:
            Enum.map(rest, fn signal ->
              %{
                type: signal.type,
                sub_agent_id: signal.sub_agent_id,
                subagent_type: signal.subagent_type,
                interrupt_data: signal.interrupt_data,
                tool_call_id: signal.tool_call_id
              }
            end)
        }

        {:interrupt, chain, interrupt_data}
    end
  end

  def check_post_tool_interrupt(terminal, _opts), do: terminal

  # Scan the chain's last_message for all InterruptSignals in processed_content
  defp find_all_interrupt_signals(chain) do
    case chain.last_message do
      %Message{role: :tool, tool_results: tool_results} when is_list(tool_results) ->
        Enum.flat_map(tool_results, fn result ->
          case result.processed_content do
            %InterruptSignal{} = signal ->
              [%{signal | tool_call_id: result.tool_call_id}]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # ── Helpers (extracted from Agent) ──────────────────────

  @doc false
  def update_chain_state_from_tools(chain) do
    current_state =
      case chain.custom_context do
        %{state: %State{} = state} -> state
        _ -> State.new!()
      end

    state_deltas = extract_state_deltas_from_chain(chain)

    if Enum.empty?(state_deltas) do
      chain
    else
      updated_state =
        Enum.reduce(state_deltas, current_state, fn delta, acc ->
          State.merge_states(acc, delta)
        end)

      LLMChain.update_custom_context(chain, %{state: updated_state})
    end
  end

  @doc false
  def extract_state_deltas_from_chain(chain) do
    chain.messages
    |> Enum.reverse()
    |> Enum.take_while(fn msg ->
      not (msg.role == :assistant and Message.is_tool_call?(msg))
    end)
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(fn message ->
      case message.tool_results do
        nil ->
          []

        tool_results when is_list(tool_results) ->
          tool_results
          |> Enum.filter(fn result -> is_struct(result.processed_content, State) end)
          |> Enum.map(& &1.processed_content)
      end
    end)
    |> Enum.reverse()
  end
end
