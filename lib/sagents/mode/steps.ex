defmodule Sagents.Mode.Steps do
  @moduledoc """
  Sagents-specific pipeline steps for custom execution modes.

  These steps handle concerns that belong at the agent layer, not the
  LLMChain layer: HITL interrupts and state propagation from tool results.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.LangChainError
  alias LangChain.Message
  alias Sagents.State
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

  # ── Loop Boundary (with until_tool enforcement) ────────────────

  @doc """
  Decide whether to loop or return, with until_tool contract enforcement.

  This is a safer variant of LangChain's `continue_or_done/3` that adds
  enforcement of the "until_tool" contract: if the LLM stops (needs_response
  becomes false) without ever calling the target tool, it returns an error
  instead of `{:ok, chain}`.

  If the target tool WAS called, `check_until_tool/2` would have already
  converted the pipeline to `{:ok, chain, tool_result}`, which passes
  through here as a terminal.

  ## When `until_tool_active` is false or absent in opts

  - `{:continue, chain}` with `needs_response: true` -> calls `run_fn.(chain, opts)` (loop)
  - `{:continue, chain}` with `needs_response: false` -> `{:ok, chain}` (normal completion)
  - Any terminal tuple -> pass through unchanged

  ## When `until_tool_active` is true in opts

  - `{:continue, chain}` with `needs_response: true` -> calls `run_fn.(chain, opts)` (loop)
  - `{:continue, chain}` with `needs_response: false` -> `{:error, chain, %LangChainError{...}}`
  - Any terminal tuple -> pass through unchanged
  """
  def continue_or_done_safe(
        {:continue, %LLMChain{needs_response: true} = chain},
        run_fn,
        opts
      ) do
    run_fn.(chain, opts)
  end

  def continue_or_done_safe({:continue, chain}, _run_fn, opts) do
    if Keyword.get(opts, :until_tool_active, false) do
      tool_names = Keyword.get(opts, :tool_names, [])

      {:error, chain,
       LangChainError.exception(
         type: "until_tool_not_called",
         message:
           "Agent completed without calling target tool(s): #{inspect(tool_names)}. " <>
             "The LLM stopped responding before invoking the required tool."
       )}
    else
      {:ok, chain}
    end
  end

  def continue_or_done_safe(terminal, _run_fn, _opts) do
    terminal
  end

  # ── Private Helpers (extracted from Agent) ──────────────────────

  defp update_chain_state_from_tools(chain) do
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

  defp extract_state_deltas_from_chain(chain) do
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

        _ ->
          []
      end
    end)
  end
end
