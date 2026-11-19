defmodule Sagents.AgentServerSubagentApprovalLabelTest do
  @moduledoc """
  When a sub-agent started by a `task` call pauses for approval, the parent's
  `:interrupted` update keeps the call's label (the model's title, else the
  sub-agent's display_text), including for a second approval inside the same
  sub-agent. A call with no label gets "Task awaiting approval".
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, AgentSupervisor, State, SubAgent}
  alias Sagents.SubAgentsDynamicSupervisor
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.{Function, Message}
  alias LangChain.Message.ToolCall

  setup :set_mimic_global

  defp writer(opts \\ []) do
    SubAgent.Config.new!(
      Map.merge(
        %{
          name: "writer",
          description: "Writes files",
          system_prompt: "You write files.",
          tools: [
            Function.new!(%{
              name: "file_write",
              description: "Write a file",
              function: fn _args, _context -> {:ok, "written"} end
            })
          ],
          interrupt_on: %{"file_write" => true}
        },
        Map.new(opts)
      )
    )
  end

  defp parent_agent(subagent) do
    Agent.new!(
      %{
        agent_id: "approval-label-#{System.unique_integer([:positive])}",
        model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"}),
        base_system_prompt: "You delegate tasks to sub-agents."
      },
      subagent_opts: [subagents: [subagent]]
    )
  end

  defp task_call(arguments) do
    Message.new_assistant!(%{
      tool_calls: [
        ToolCall.new!(%{
          call_id: "parent_tc",
          name: "task",
          arguments:
            Map.merge(%{"task_name" => "writer", "instructions" => "Write it."}, arguments)
        })
      ]
    })
  end

  defp file_write_call(call_id) do
    Message.new_assistant!(%{
      tool_calls: [ToolCall.new!(%{call_id: call_id, name: "file_write", arguments: %{}})]
    })
  end

  # Model responses in order; the last one repeats.
  defp stub_model(responses) do
    calls = :counters.new(1, [:atomics])

    stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
      :counters.add(calls, 1, 1)
      index = min(:counters.get(calls, 1), length(responses)) - 1
      {:ok, Enum.at(responses, index)}
    end)
  end

  defp start_parent(agent) do
    start_supervised!(
      {AgentSupervisor, name: AgentSupervisor.get_name(agent.agent_id), agent: agent}
    )

    {:ok, _server, _ref} = AgentServer.subscribe(agent.agent_id)
    agent.agent_id
  end

  defp interrupted_label do
    assert_receive {:agent,
                    {:tool_execution_update, :interrupted, %{call_id: "parent_tc"} = info}},
                   5_000

    assert_receive {:agent, {:status_changed, :interrupted, _}}, 5_000
    info.display_text
  end

  describe "the :interrupted update" do
    test "carries the model's title, through a second approval in the same sub-agent" do
      agent_id = start_parent(parent_agent(writer()))

      stub_model([
        task_call(%{"title" => "Write the test file"}),
        file_write_call("sub_tc_1"),
        file_write_call("sub_tc_2"),
        Message.new_assistant!(%{content: "Done."})
      ])

      :ok = AgentServer.add_message(agent_id, Message.new_user!("Write a file"))
      assert interrupted_label() == "Write the test file"

      :ok = AgentServer.resume(agent_id, [%{type: :approve}])
      assert interrupted_label() == "Write the test file"
    end

    test "carries the sub-agent's display_text when there is no title" do
      agent_id = start_parent(parent_agent(writer(display_text: "Writing files")))

      stub_model([
        task_call(%{}),
        file_write_call("sub_tc_1"),
        Message.new_assistant!(%{content: "Done."})
      ])

      :ok = AgentServer.add_message(agent_id, Message.new_user!("Write a file"))
      assert interrupted_label() == "Writing files"
    end

    test "says \"Task awaiting approval\" when the call has no label" do
      agent_id = start_parent(parent_agent(writer()))

      stub_model([
        task_call(%{}),
        file_write_call("sub_tc_1"),
        Message.new_assistant!(%{content: "Done."})
      ])

      :ok = AgentServer.add_message(agent_id, Message.new_user!("Write a file"))
      assert interrupted_label() == "Task awaiting approval"
    end
  end

  describe "the :subagent_hitl interrupt data" do
    defp execute_until_interrupt(agent, responses) do
      {:ok, _pid} = SubAgentsDynamicSupervisor.start_link(agent_id: agent.agent_id)
      stub_model(responses)

      Agent.execute(agent, State.new!(%{messages: [Message.new_user!("Write a file")]}))
    end

    test "has the label as :display_text, on the first and a repeated approval" do
      agent = parent_agent(writer())

      assert {:interrupt, state, %{type: :subagent_hitl} = data} =
               execute_until_interrupt(agent, [
                 task_call(%{"title" => "Write the test file"}),
                 file_write_call("sub_tc_1"),
                 file_write_call("sub_tc_2"),
                 Message.new_assistant!(%{content: "Done."})
               ])

      assert data.display_text == "Write the test file"

      assert {:interrupt, _state, %{type: :subagent_hitl} = again} =
               Agent.resume(agent, state, [%{type: :approve}])

      assert again.display_text == "Write the test file"
    end

    test "has no :display_text when the call has no label" do
      assert {:interrupt, _state, %{type: :subagent_hitl} = data} =
               execute_until_interrupt(parent_agent(writer()), [
                 task_call(%{}),
                 file_write_call("sub_tc_1"),
                 Message.new_assistant!(%{content: "Done."})
               ])

      refute Map.has_key?(data, :display_text)
    end
  end
end
