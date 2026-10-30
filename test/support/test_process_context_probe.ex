defmodule Sagents.TestProcessContextProbe do
  @moduledoc """
  Reports a process-dictionary key from where code runs: its `probe` tool's
  body and its `:on_tool_call_review` handler send `{:probe_tool, value}` and
  `{:probe_review, value}` to `:test_pid`, reading `:key` (default `:tenant`)
  in their own process.

  The review handler reports only calls to `probe`, so a parent's own tool
  calls do not reach the test.
  """

  @behaviour Sagents.Middleware

  alias LangChain.Function

  @impl true
  def init(opts) do
    {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), key: Keyword.get(opts, :key, :tenant)}}
  end

  @impl true
  def tools(config) do
    [
      Function.new!(%{
        name: "probe",
        description: "Reports the process context.",
        parameters_schema: %{type: "object", properties: %{}},
        function: fn _args, _context ->
          send(config.test_pid, {:probe_tool, Process.get(config.key)})
          {:ok, "probed"}
        end
      })
    ]
  end

  @impl true
  def callbacks(config) do
    %{
      on_tool_call_review: fn _chain, call, _function, _review ->
        if call.name == "probe",
          do: send(config.test_pid, {:probe_review, Process.get(config.key)})

        :ok
      end
    }
  end
end
