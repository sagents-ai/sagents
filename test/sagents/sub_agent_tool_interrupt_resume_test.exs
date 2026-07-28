defmodule Sagents.SubAgentToolInterruptResumeTest do
  use ExUnit.Case, async: true

  alias Sagents.SubAgent
  alias Sagents.Agent
  alias LangChain.Function
  alias LangChain.ChatModels.ChatAnthropic

  defp test_tool(name \\ "test_tool") do
    Function.new!(%{
      name: name,
      description: "A test tool",
      function: fn _args, _context -> {:ok, "result"} end
    })
  end

  defp test_model do
    ChatAnthropic.new!(%{
      model: "claude-sonnet-4-6",
      api_key: "test_key"
    })
  end

  defp test_agent do
    Agent.new!(%{
      model: test_model(),
      base_system_prompt: "Test agent",
      replace_default_middleware: true,
      middleware: [],
      tools: [test_tool()]
    })
  end

  defp interrupted_subagent(interrupt_data) do
    subagent =
      SubAgent.new_from_config(
        parent_agent_id: "test",
        instructions: "Task",
        agent_config: test_agent(),
        parent_state: %{messages: []}
      )

    %{subagent | status: :interrupted, interrupt_data: interrupt_data}
  end

  describe "resume/3 with a tool-raised interrupt" do
    test "returns a structured error instead of raising KeyError" do
      # Shape produced by `check_tool_interrupts` when a tool body raises an
      # interrupt: arbitrary tool-supplied data plus the tool_call_id. It has
      # neither :action_requests nor :hitl_tool_call_ids.
      interrupt_data = %{
        type: :escalation,
        request_id: "esc-1666",
        capability: "finance_export",
        tool_call_id: "call_finance_export_0_1602"
      }

      assert {:error, {:unsupported_interrupt, :tool_raised}} =
               SubAgent.resume(interrupted_subagent(interrupt_data), [%{type: :approve}])
    end

    test "returns a structured error for the multiple-interrupts shape" do
      interrupt_data = %{
        type: :multiple_interrupts,
        interrupts: [
          %{type: :escalation, tool_call_id: "call_a"},
          %{type: :escalation, tool_call_id: "call_b"}
        ]
      }

      assert {:error, {:unsupported_interrupt, :tool_raised}} =
               SubAgent.resume(interrupted_subagent(interrupt_data), [%{type: :approve}])
    end

    test "leaves the subagent resumable so the caller can inspect it" do
      interrupt_data = %{type: :escalation, tool_call_id: "call_a"}
      subagent = interrupted_subagent(interrupt_data)

      assert {:error, {:unsupported_interrupt, :tool_raised}} =
               SubAgent.resume(subagent, [%{type: :approve}])

      assert subagent.status == :interrupted
      assert subagent.interrupt_data == interrupt_data
    end
  end
end
