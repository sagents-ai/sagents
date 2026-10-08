defmodule Sagents.AgentUserRequestTest do
  @moduledoc """
  Every message an `Sagents.Agent.execute/3` run produces carries the run's
  user request number, including messages that pass no callback, and tools can
  read the number from their context.
  """
  use Sagents.BaseCase, async: true
  use Mimic

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.MessageExpansion
  alias Sagents.{Agent, UserRequest, State}

  setup :verify_on_exit!

  defp tool_call(name, call_id) do
    ToolCall.new!(%{status: :complete, call_id: call_id, name: name, arguments: %{}})
  end

  defp calls_tool(name) do
    {:ok, [Message.new_assistant!(%{tool_calls: [tool_call(name, "call_1")]})]}
  end

  defp tool(name, fun) do
    Function.new!(%{
      name: name,
      description: "Test tool",
      parameters_schema: %{type: "object", properties: %{}},
      function: fun
    })
  end

  defp agent_with(tools, opts \\ []) do
    {:ok, agent} =
      Agent.new(
        %{
          model: mock_model(),
          tools: tools,
          base_system_prompt: "Test agent",
          middleware: Keyword.get(opts, :middleware, [])
        },
        [replace_default_middleware: true] ++ Keyword.take(opts, [:interrupt_on])
      )

    agent
  end

  defp seqs(%State{messages: messages}), do: Enum.map(messages, &UserRequest.seq/1)

  defp answers(text) do
    fn _model, _messages, _tools -> {:ok, [Message.new_assistant!(text)]} end
  end

  test "a run stamps the messages it adds; a pre-stamped message keeps its number" do
    ChatAnthropic
    |> expect(:call, fn _model, _messages, _tools -> calls_tool("lookup") end)
    |> expect(:call, answers("Found it."))

    lookup = tool("lookup", fn _args, _ctx -> {:ok, "result"} end)
    user = UserRequest.put_seq(Message.new_user!("Find it"), 3)

    assert {:ok, final_state} =
             Agent.execute(agent_with([lookup]), State.new!(%{messages: [user]}),
               user_request_seq: 4
             )

    assert [
             %Message{role: :user},
             %Message{role: :assistant},
             %Message{role: :tool},
             %Message{role: :assistant}
           ] = final_state.messages

    assert seqs(final_state) == [3, 4, 4, 4]
    assert final_state.user_request_seq == 4
  end

  test "messages a tool's expansion inserts are stamped" do
    ChatAnthropic
    |> expect(:call, fn _model, _messages, _tools -> calls_tool("load") end)
    |> expect(:call, answers("Done."))

    load =
      tool("load", fn _args, _ctx ->
        MessageExpansion.expand("Loaded.", [Message.new_user!("Use this material.")],
          result_content: "Loaded."
        )
      end)

    assert {:ok, final_state} =
             Agent.execute(agent_with([load]), State.new!(%{messages: [Message.new_user!("go")]}),
               user_request_seq: 2
             )

    inserted =
      Enum.find(final_state.messages, fn message ->
        message.role == :user and
          LangChain.Message.ContentPart.content_to_string(message.content) ==
            "Use this material."
      end)

    assert %Message{} = inserted
    assert UserRequest.seq(inserted) == 2
    assert Enum.all?(seqs(final_state), &(&1 == 2))
  end

  test "a tool reads the run's number from its context" do
    test_pid = self()

    ChatAnthropic
    |> expect(:call, fn _model, _messages, _tools -> calls_tool("probe") end)
    |> expect(:call, answers("ok"))

    probe =
      tool("probe", fn _args, ctx ->
        send(test_pid, {:seen, ctx.user_request_seq})
        {:ok, "ok"}
      end)

    Agent.execute(agent_with([probe]), State.new!(%{messages: [Message.new_user!("go")]}),
      user_request_seq: 6
    )

    assert_received {:seen, 6}
  end

  test "a tool's todo delta does not reset the state's number" do
    ChatAnthropic
    |> expect(:call, fn _model, _messages, _tools -> calls_tool("plan") end)
    |> expect(:call, answers("Planned."))

    plan =
      tool("plan", fn _args, _ctx ->
        {:ok, "planned", %State{todos: [Sagents.Todo.new!(%{id: "1", content: "step"})]}}
      end)

    assert {:ok, final_state} =
             Agent.execute(agent_with([plan]), State.new!(%{messages: [Message.new_user!("go")]}),
               user_request_seq: 5
             )

    assert final_state.user_request_seq == 5
    assert [_todo] = final_state.todos
  end

  test "an interrupted run's state is stamped, and the resume continues the number" do
    ChatAnthropic
    |> expect(:call, fn _model, _messages, _tools -> calls_tool("guarded") end)
    |> expect(:call, answers("Approved and done."))

    guarded = tool("guarded", fn _args, _ctx -> {:ok, "done"} end)

    agent =
      agent_with([guarded],
        middleware: [{Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{"guarded" => true}]}],
        interrupt_on: %{"guarded" => true}
      )

    assert {:interrupt, interrupted_state, _data} =
             Agent.execute(agent, State.new!(%{messages: [Message.new_user!("go")]}),
               user_request_seq: 7
             )

    assert Enum.all?(seqs(interrupted_state), &(&1 == 7))

    assert {:ok, final_state} = Agent.resume(agent, interrupted_state, [%{type: :approve}])
    assert Enum.all?(seqs(final_state), &(&1 == 7))
  end

  test "without the option the state's own number is used" do
    ChatAnthropic |> expect(:call, answers("hi"))

    assert {:ok, final_state} =
             Agent.execute(
               agent_with([]),
               State.new!(%{messages: [Message.new_user!("hi")], user_request_seq: 2})
             )

    assert seqs(final_state) == [2, 2]
  end

  test "with the default 0 nothing is stamped" do
    ChatAnthropic |> expect(:call, answers("hi"))

    assert {:ok, final_state} =
             Agent.execute(agent_with([]), State.new!(%{messages: [Message.new_user!("hi")]}))

    assert seqs(final_state) == [nil, nil]
  end

  test "an invalid number raises" do
    assert_raise ArgumentError, fn ->
      Agent.execute(agent_with([]), State.new!(), user_request_seq: -1)
    end
  end
end
