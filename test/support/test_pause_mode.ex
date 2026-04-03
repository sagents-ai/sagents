defmodule Sagents.Test.PauseMode do
  @moduledoc false
  @behaviour LangChain.Chains.LLMChain.Mode

  @doc """
  A test mode that always returns `{:pause, chain}`.

  Used to simulate infrastructure pause signals (e.g., node draining)
  without needing a real LLM call.
  """
  @impl true
  def run(chain, _opts) do
    {:pause, chain}
  end
end
