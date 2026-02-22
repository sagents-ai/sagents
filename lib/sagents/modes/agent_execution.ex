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
  5. Loop if `needs_response` is true

  ## Options

  - `:middleware` — Agent's middleware list (for HITL checking)
  - `:should_pause?` — Zero-arity function for infrastructure pause
  - `:max_runs` — Maximum LLM calls (default: 50)
  """

  @behaviour LangChain.Chains.LLMChain.Mode

  import LangChain.Chains.LLMChain.Mode.Steps
  import Sagents.Mode.Steps

  alias LangChain.Chains.LLMChain

  @impl true
  def run(%LLMChain{} = chain, opts) do
    chain = ensure_mode_state(chain)
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
    |> continue_or_done(&do_run/2, opts)
  end
end
