defmodule Sagents.Modes.AgentExecution do
  @moduledoc """
  Standard sagents execution mode.

  Replaces the separate `execute_chain_with_state_updates` and
  `execute_chain_with_hitl` loops with a single composable pipeline.

  ## Pipeline

  1. Call the LLM
  2. Check for HITL interrupts (if HumanInTheLoop middleware present)
  3. Execute tools
  4. Propagate state updates from tool results
  5. Check if target tool was called (if `until_tool` is set)
  6. Loop if `needs_response` is true, or error if until_tool contract violated

  ## Options

  - `:middleware` — Agent's middleware list (for HITL checking)
  - `:should_pause?` — Zero-arity function for infrastructure pause
  - `:max_runs` — Maximum LLM calls (default: 50)
  - `:until_tool` — Tool name (string) or list of tool names. When set, the
    mode will return `{:ok, chain, tool_result}` when the target tool is called,
    or `{:error, chain, %LangChainError{}}` if the LLM stops without calling it.
  """

  @behaviour LangChain.Chains.LLMChain.Mode

  import LangChain.Chains.LLMChain.Mode.Steps
  import Sagents.Mode.Steps

  alias LangChain.Chains.LLMChain

  @impl true
  def run(%LLMChain{} = chain, opts) do
    chain = ensure_mode_state(chain)
    opts = normalize_until_tool_opts(opts)
    do_run(chain, opts)
  end

  defp do_run(chain, opts) do
    {:continue, chain}
    |> call_llm()
    |> check_max_runs(Keyword.put_new(opts, :max_runs, 50))
    |> check_pause(opts)
    |> check_pre_tool_hitl(opts)
    |> execute_tools()
    |> propagate_state(opts)
    |> maybe_check_until_tool(opts)
    |> continue_or_done_safe(&do_run/2, opts)
  end

  # ── Private Helpers ──────────────────────────────────────────────

  defp normalize_until_tool_opts(opts) do
    case Keyword.get(opts, :until_tool) do
      nil ->
        opts

      # Empty list means no until_tool behavior
      [] ->
        opts

      tool_name when is_binary(tool_name) ->
        opts
        |> Keyword.put(:tool_names, [tool_name])
        |> Keyword.put(:until_tool_active, true)

      tool_names when is_list(tool_names) ->
        opts
        |> Keyword.put(:tool_names, tool_names)
        |> Keyword.put(:until_tool_active, true)
    end
  end

  defp maybe_check_until_tool(pipeline_result, opts) do
    if Keyword.get(opts, :until_tool_active, false) do
      check_until_tool(pipeline_result, opts)
    else
      pipeline_result
    end
  end
end
