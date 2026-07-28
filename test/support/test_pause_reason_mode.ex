defmodule Sagents.Test.PauseReasonMode do
  @moduledoc false
  @behaviour LangChain.Chains.LLMChain.Mode

  @doc """
  A test mode that always returns `{:pause, chain, reason}` — the positional
  pause-cause shape a custom mode may return.

  The reason is `{:node_draining, "test-node"}` so tests can assert a
  non-map term survives the trip to `State.pause_reason`.
  """
  @impl true
  def run(chain, _opts) do
    {:pause, chain, {:node_draining, "test-node"}}
  end
end
