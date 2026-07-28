defmodule Sagents.Test.PauseContextMode do
  @moduledoc false
  @behaviour LangChain.Chains.LLMChain.Mode

  alias LangChain.Chains.LLMChain

  @doc """
  A test mode that pauses via the normalized shape: the reason folded into
  `custom_context.pause_reason` with a `{:pause, chain}` 2-tuple — what
  `Sagents.Mode.Steps.normalize_pause/1` produces, and what a mode composed
  from pipeline steps hands to `LLMChain.run/2`.
  """
  @impl true
  def run(chain, _opts) do
    {:pause, LLMChain.update_custom_context(chain, %{pause_reason: %{cause: :store_unreachable}})}
  end
end
