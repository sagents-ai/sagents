defmodule Sagents.Middleware.HumanInTheLoopConcurrencyTest do
  @moduledoc """
  Approved calls to `async: true` tools run concurrently when an interrupted
  agent resumes, so a batch of slow approved calls takes about as long as the
  slowest one.
  """
  use Sagents.BaseCase, async: true
  use Mimic

  alias Sagents.Agent
  alias Sagents.Middleware.HumanInTheLoop
  alias Sagents.State
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  setup :verify_on_exit!

  # Tells the test it has started, then waits to be released.
  defp blocking_command_tool(test_pid) do
    Function.new!(%{
      name: "run_command",
      description: "Runs a command on a device",
      async: true,
      parameters_schema: %{
        type: "object",
        properties: %{device: %{type: "string"}},
        required: ["device"]
      },
      function: fn %{"device" => device}, _context ->
        send(test_pid, {:entered, device, self()})

        receive do
          :release -> {:ok, "Ran on #{device}"}
        end
      end
    })
  end

  test "approved async calls run at the same time on resume" do
    test_pid = self()
    devices = ["web-1", "web-2", "web-3"]

    tool_calls =
      for device <- devices do
        ToolCall.new!(%{
          call_id: "call_#{device}",
          name: "run_command",
          arguments: %{"device" => device}
        })
      end

    stub(ChatAnthropic, :call, fn _model, messages, _callbacks ->
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, [Message.new_assistant!("All commands finished.")]}
      else
        {:ok, [Message.new_assistant!(%{content: "Running them.", tool_calls: tool_calls})]}
      end
    end)

    {:ok, agent} =
      Agent.new(
        %{
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6", stream: false}),
          tools: [blocking_command_tool(test_pid)],
          middleware: [{HumanInTheLoop, [interrupt_on: %{"run_command" => true}]}]
        },
        replace_default_middleware: true
      )

    initial_state = State.new!(%{messages: [Message.new_user!("Run it everywhere")]})

    assert {:interrupt, interrupted_state, %{action_requests: [_web1, _web2, _web3]}} =
             Agent.execute(agent, initial_state)

    resume =
      Task.async(fn ->
        Agent.resume(
          agent,
          interrupted_state,
          Enum.map(devices, fn _device -> %{type: :approve} end)
        )
      end)

    # Every approved command is running before any is released.
    tool_pids =
      for device <- devices do
        assert_receive {:entered, ^device, pid}, 1_000
        pid
      end

    Enum.each(tool_pids, &send(&1, :release))

    assert {:ok, final_state} = Task.await(resume)

    assert %Message{role: :tool, tool_results: results} =
             Enum.find(final_state.messages, &(&1.role == :tool))

    assert Enum.map(results, & &1.tool_call_id) == Enum.map(devices, &"call_#{&1}")
  end
end
