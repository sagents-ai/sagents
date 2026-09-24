defmodule Sagents.Modes.AgentExecution do
  @moduledoc """
  Standard sagents execution mode.

  Replaces the separate `execute_chain_with_state_updates` and
  `execute_chain_with_hitl` loops with a single composable pipeline.

  ## Pipeline

  1. Check the `:max_runs` budget before starting another LLM call
  2. Expand any tool result from the previous turn that asked to arrive as
     messages
  3. Call the LLM
  4. Check for HITL interrupts (if HumanInTheLoop middleware present)
  5. Execute tools
  6. Propagate state updates from tool results
  7. Check if target tool was called (if `until_tool` is set)
  8. Loop if `needs_response` is true, or error if until_tool contract violated

  `LLMChain` sets `needs_response` when a message arrives. It is true after tool
  results, and after an assistant message that leaves the model's turn open
  (`LangChain.Message.continues_turn?/1`): the provider reported the turn is
  not over, or the message is narration only. The loop in step 8 reads that
  flag and does not inspect the message itself.

  A response the provider cut off (status `:length` or `:content_filtered`)
  ends the run in step 3 with a `"response_truncated"` or `"content_filtered"`
  error. Its tool calls may be partial, so step 5 never runs them.

  The budget is checked before a call, never after one, so the tools from the
  final permitted response still execute. A target tool returned on that
  response satisfies `until_tool` rather than ending the run with
  `exceeded_max_runs`.

  ## Resuming after human approval

  A resume executes approved tool calls outside this pipeline, then hands the
  mode a chain whose last message is that tool message.
  `Sagents.SubAgent.resume/3` does this on the chain it kept from the
  interrupted run. `Sagents.Middleware.HumanInTheLoop` does it for
  `Sagents.Agent.resume/4`, which builds a fresh chain with a fresh budget.

  A chain that arrives ending in a tool message has its results pass through
  steps 6 and 7, plus the tool-interrupt check, before the loop starts. Their
  state updates reach the chain's state, a nested interrupt surfaces, and an
  approved target tool completes the run without another LLM call, even when
  the budget is spent.

  ## Tool results that expand into messages

  A tool can return material as *messages* rather than as tool-result content,
  choosing the role it arrives at, and have the model read them on its very next
  LLM call. A tool asks for that with `LangChain.MessageExpansion.expand/3`;
  step 2 applies it.

  Step 2 comes at the top of the loop, not the bottom, and both halves of that
  matter:

  - **Before the LLM call**, which is the guarantee the tool is relying on. A
    tool that says "this arrives next" while the model keeps working in the same
    run is making a promise nothing keeps, and a model handed a description of
    material it does not have will write the material itself.
  - **After the loop boundary**, so every step that decides whether the run is
    over reads a `last_message` the model produced or the tools returned. A turn
    that interrupted or satisfied an `until_tool` contract ends without
    expanding anything into it.

  Running at the top of the loop also covers the results a resume produces.
  When those results do not end the run, step 2 is the next thing to see them,
  so a tool gated behind human approval expands on the same terms as one that
  is not.

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

  ## Pausing with a cause

  A pipeline step may pause the run with `{:pause, chain, reason}` — the
  3-tuple sibling of `{:pause, chain}`, carrying why the step paused (a
  draining node, an unreachable backing store, whatever the step knows). The
  mode folds the reason into `custom_context.pause_reason` and returns the
  `{:pause, chain}` shape `LLMChain.run/2` documents, so the result also
  passes the fallback machinery unchanged; the agent layer reads the reason
  back onto `State.pause_reason`. A step that pauses with the plain 2-tuple
  (like `check_pause/2`) keeps a nil reason.

  The 3-tuple is a *step*-level shape only. A custom mode must not return it
  from `run/2`: `LangChain.Chains.LLMChain.Mode`'s `run_result()` type does
  not admit it, and it corrupts into a generic error under `with_fallbacks:`
  (see `Sagents.Mode.Steps.normalize_pause/1`). Custom modes that want to
  report a pause cause should apply `normalize_pause/1` to their final result,
  as this mode does, or set `custom_context.pause_reason` themselves.
  """

  @behaviour LangChain.Chains.LLMChain.Mode

  import LangChain.Chains.LLMChain.Mode.Steps
  import Sagents.Mode.Steps

  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%LLMChain{} = chain, opts) do
    chain = ensure_mode_state(chain)
    opts = normalize_until_tool_opts(opts)

    {:continue, chain}
    |> maybe_process_resumed_tool_results(opts)
    |> continue_execution(opts)
    |> normalize_pause()
  end

  defp do_run(chain, opts) do
    {:continue, chain}
    |> check_max_runs(Keyword.put_new(opts, :max_runs, 50))
    |> expand_tool_results(opts)
    |> call_llm()
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

  # A chain that arrives ending in a tool message carries results no pass of
  # the loop has checked: tool calls a resume executed outside this pipeline.
  defp maybe_process_resumed_tool_results(
         {:continue, %LLMChain{last_message: %Message{role: :tool}}} = pipeline_result,
         opts
       ) do
    pipeline_result
    |> propagate_state(opts)
    |> check_tool_interrupts(opts)
    |> maybe_check_until_tool(opts)
  end

  defp maybe_process_resumed_tool_results(pipeline_result, _opts), do: pipeline_result

  defp continue_execution({:continue, chain}, opts), do: do_run(chain, opts)
  defp continue_execution(terminal, _opts), do: terminal

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
