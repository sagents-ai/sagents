defmodule Sagents.AgentServerTaskTitleTest do
  @moduledoc """
  A `task` call is labelled with the model's `title`, or the chosen
  sub-agent's `display_text`, in the `:executing` lifecycle update and in the
  persisted display item, for streamed and non-streamed responses.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, AgentSupervisor, SubAgent}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.{Function, Message, MessageDelta}
  alias LangChain.Message.ToolCall

  setup :set_mimic_global

  setup do
    Sagents.TestDisplayMessagePersistenceForwarding.register_test_process(self())
    :ok
  end

  defp kb_subagent do
    SubAgent.Config.new!(%{
      name: "kb",
      description: "Drafts knowledge base articles",
      system_prompt: "You draft articles.",
      display_text: "Drafting KB article",
      tools: [
        Function.new!(%{
          name: "noop",
          description: "Does nothing",
          function: fn _args, _context -> {:ok, "ok"} end
        })
      ]
    })
  end

  defp start_parent do
    agent_id = "task-title-#{System.unique_integer([:positive])}"

    agent =
      Agent.new!(
        %{
          agent_id: agent_id,
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"}),
          base_system_prompt: "You delegate tasks to sub-agents."
        },
        subagent_opts: [subagents: [kb_subagent()]]
      )

    start_supervised!(
      {AgentSupervisor,
       name: AgentSupervisor.get_name(agent_id),
       agent: agent,
       conversation_id: "conv-#{agent_id}",
       display_message_persistence: Sagents.TestDisplayMessagePersistenceForwarding}
    )

    {:ok, _server, _ref} = AgentServer.subscribe(agent_id)
    agent_id
  end

  # The parent's first model call returns `first_response`; the sub-agent's
  # call and the parent's follow-up return plain answers.
  defp stub_model(first_response) do
    calls = :counters.new(1, [:atomics])

    stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
      :counters.add(calls, 1, 1)

      case :counters.get(calls, 1) do
        1 -> {:ok, first_response}
        2 -> {:ok, Message.new_assistant!(%{content: "Sub-agent finished."})}
        _later -> {:ok, Message.new_assistant!(%{content: "All done."})}
      end
    end)
  end

  defp whole_response(arguments) do
    Message.new_assistant!(%{
      tool_calls: [ToolCall.new!(%{call_id: "call_task", name: "task", arguments: arguments})]
    })
  end

  # The same tool call as a stream: the name arrives with the first half of the
  # JSON arguments, the rest arrives with the completed status.
  defp streamed_response(arguments) do
    json = Jason.encode!(arguments)
    {head, tail} = String.split_at(json, div(String.length(json), 2))

    [
      MessageDelta.new!(%{
        role: :assistant,
        status: :incomplete,
        tool_calls: [
          ToolCall.new!(%{index: 0, call_id: "call_task", name: "task", arguments: head})
        ]
      }),
      MessageDelta.new!(%{
        role: :assistant,
        status: :complete,
        tool_calls: [ToolCall.new!(%{index: 0, arguments: tail})]
      })
    ]
  end

  defp run_turn(response) do
    agent_id = start_parent()
    stub_model(response)
    :ok = AgentServer.add_message(agent_id, Message.new_user!("Please delegate."))

    assert_receive {:agent, {:tool_execution_update, :executing, %{call_id: "call_task"} = info}},
                   5_000

    assert_receive {:saved_message, %Message{role: :assistant, tool_calls: [_]},
                    [%{type: :tool_call} = item]},
                   5_000

    assert_receive {:agent, {:status_changed, :idle, _}}, 5_000
    {info.display_text, item.content["display_text"]}
  end

  for {mode, build} <- [whole: :whole_response, streamed: :streamed_response] do
    describe "#{mode} response" do
      test "the model's title labels the call" do
        response =
          unquote(build)(%{
            "task_name" => "general-purpose",
            "instructions" => "Check the device.",
            "title" => "Investigate\n device   state"
          })

        assert {"Investigate device state", "Investigate device state"} = run_turn(response)
      end

      test "without a title, the sub-agent's display_text labels the call" do
        response =
          unquote(build)(%{"task_name" => "kb", "instructions" => "Draft the VPN article."})

        assert {"Drafting KB article", "Drafting KB article"} = run_turn(response)
      end

      test "without a title or a configured display_text, the call keeps the static label" do
        response =
          unquote(build)(%{"task_name" => "general-purpose", "instructions" => "Check it."})

        assert {"Running task", "Running task"} = run_turn(response)
      end
    end
  end
end
