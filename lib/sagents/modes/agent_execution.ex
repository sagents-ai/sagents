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
    mode returns `{:ok, chain, tool_result}` once the target tool is *called*,
    or `{:error, chain, %LangChainError{}}` if the LLM stops without calling it.
  - `:require_tool_success` — Boolean (default `false`). When `true`, the mode
    terminates only when the target tool returns a *successful* (non-error)
    result; an error result keeps the loop running so the LLM can correct the
    call, bounded by `:max_runs`.

  These two are the mode's internal representation. Callers using
  `Sagents.Agent.execute/3` pass the friendlier mutually-exclusive
  `:until_tool` / `:until_tool_success` (each naming the target tool), which are
  collapsed into the pair above via `collapse_until_tool/2`.
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
    |> check_tool_interrupts(opts)
    |> maybe_check_until_tool(opts)
    |> continue_or_done_safe(&do_run/2, opts)
  end

  # ── Private Helpers ──────────────────────────────────────────────

  # `:until_tool` names the target tool (string or list); `:require_tool_success`
  # (boolean) says whether it must return a non-error result. Populates the
  # internal `:tool_names` and `:until_tool_active` keys read downstream;
  # `:require_tool_success` is already a boolean in opts (default false).
  defp normalize_until_tool_opts(opts) do
    case normalize_tool_names(Keyword.get(opts, :until_tool)) do
      nil ->
        opts

      names ->
        opts
        |> Keyword.put(:tool_names, names)
        |> Keyword.put(:until_tool_active, true)
    end
  end

  defp normalize_tool_names(nil), do: nil
  defp normalize_tool_names([]), do: nil
  defp normalize_tool_names(name) when is_binary(name), do: [name]
  defp normalize_tool_names(names) when is_list(names), do: names

  defp maybe_check_until_tool(pipeline_result, opts) do
    cond do
      not Keyword.get(opts, :until_tool_active, false) ->
        pipeline_result

      # require success — terminate only on a successful matching result.
      Keyword.get(opts, :require_tool_success, false) ->
        check_until_tool_success(pipeline_result, opts)

      # any call to the target tool ends the run.
      true ->
        check_until_tool(pipeline_result, opts)
    end
  end

  @doc """
  Collapse the public `:until_tool` / `:until_tool_success` either-or spelling
  into the internal `{tool_name | nil, require_success_boolean}` representation.

  The friendly either-or options are mutually exclusive (validated at the public
  boundary in `Sagents.Agent` / `Sagents.SubAgent.Config`). If both are non-nil
  when this is called, the success variant wins.

  Used at the two collapse points — `Sagents.Agent.execute/3` (opts → mode opts)
  and `Sagents.Middleware.SubAgent` (config → sub-agent construction) — so the
  rest of the system carries only `:until_tool` + `:require_tool_success`.
  """
  @spec collapse_until_tool(term(), term()) :: {term() | nil, boolean()}
  def collapse_until_tool(_until_tool, until_tool_success) when not is_nil(until_tool_success),
    do: {until_tool_success, true}

  def collapse_until_tool(until_tool, nil) when not is_nil(until_tool), do: {until_tool, false}

  def collapse_until_tool(_until_tool, _until_tool_success), do: {nil, false}
end
