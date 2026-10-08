defmodule Sagents.UserRequestTest do
  use Sagents.BaseCase, async: true

  alias Sagents.{UserRequest, State}
  alias LangChain.Message
  alias LangChain.Message.{ContentPart, ToolCall, ToolResult}
  alias LangChain.TokenUsage

  defp stamped(%Message{} = message, seq), do: UserRequest.put_seq(message, seq)

  defp with_metadata(%Message{} = message, metadata),
    do: %Message{message | metadata: Map.merge(message.metadata || %{}, metadata)}

  defp with_usage(%Message{} = message, input, output) do
    usage = TokenUsage.new!(%{input: input, output: output})
    %Message{message | metadata: Map.put(message.metadata || %{}, :usage, usage)}
  end

  defp tool_call_message(name, call_id) do
    Message.new_assistant!(%{
      tool_calls: [ToolCall.new!(%{call_id: call_id, name: name, arguments: %{}})]
    })
  end

  defp tool_result_message(call_id) do
    Message.new_tool_result!(%{
      tool_results: [ToolResult.new!(%{tool_call_id: call_id, name: "lookup", content: "ok"})]
    })
  end

  defp narration_message(text) do
    Message.new_assistant!(%{content: [ContentPart.narration!(text)]})
  end

  describe "stamp/2" do
    test "fills a blank" do
      assert UserRequest.seq(UserRequest.stamp(Message.new_user!("hi"), 3)) == 3
    end

    test "keeps an existing number" do
      message = stamped(Message.new_user!("hi"), 2)
      assert UserRequest.seq(UserRequest.stamp(message, 5)) == 2
    end

    test "ignores 0" do
      message = Message.new_user!("hi")
      assert UserRequest.stamp(message, 0) == message
    end

    test "keeps other metadata" do
      message = with_metadata(Message.new_assistant!("hi"), %{end_turn: true})

      assert %Message{metadata: %{end_turn: true, user_request_seq: 1}} =
               UserRequest.stamp(message, 1)
    end
  end

  describe "stamp_result/2" do
    test "stamps the state of each result shape" do
      state = State.new!(%{messages: [Message.new_user!("hi")]})

      assert {:ok, %State{messages: [%Message{metadata: %{user_request_seq: 4}}]}} =
               UserRequest.stamp_result({:ok, state}, 4)

      assert {:ok, %State{messages: [%Message{metadata: %{user_request_seq: 4}}]}, :extra} =
               UserRequest.stamp_result({:ok, state, :extra}, 4)

      assert {:interrupt, %State{messages: [%Message{metadata: %{user_request_seq: 4}}]}, :data} =
               UserRequest.stamp_result({:interrupt, state, :data}, 4)

      assert {:pause, %State{messages: [%Message{metadata: %{user_request_seq: 4}}]}} =
               UserRequest.stamp_result({:pause, state}, 4)
    end

    test "passes other results through" do
      assert UserRequest.stamp_result({:error, :boom}, 4) == {:error, :boom}
    end
  end

  describe "final_answer?/1" do
    test "is true for a plain answer" do
      assert UserRequest.final_answer?(Message.new_assistant!("Here you go"))
    end

    test "is false for a tool-call message" do
      refute UserRequest.final_answer?(tool_call_message("lookup", "call_1"))
    end

    test "is false for narration only" do
      refute UserRequest.final_answer?(narration_message("Checking the logs first."))
    end

    test "is false when the provider reports the turn is still open" do
      message = with_metadata(Message.new_assistant!("Working"), %{end_turn: false})
      refute UserRequest.final_answer?(message)
    end

    test "is false for a summary" do
      message = with_metadata(Message.new_assistant!("Earlier we..."), %{summary: true})
      refute UserRequest.final_answer?(message)
    end

    test "is false for non-assistant messages" do
      refute UserRequest.final_answer?(Message.new_user!("hi"))
      refute UserRequest.final_answer?(tool_result_message("call_1"))
    end
  end

  describe "list/1" do
    test "groups out-of-order stamps by number and skips unstamped messages" do
      user_1 = stamped(Message.new_user!("first"), 1)
      user_2 = stamped(Message.new_user!("second"), 2)
      answer_1 = stamped(Message.new_assistant!("answer one"), 1)
      answer_2 = stamped(Message.new_assistant!("answer two"), 2)
      legacy = Message.new_user!("legacy")

      state = State.new!(%{messages: [legacy, user_1, user_2, answer_1, answer_2]})

      assert [
               %{seq: 1, messages: [^user_1, ^answer_1], final_message: ^answer_1},
               %{seq: 2, messages: [^user_2, ^answer_2], final_message: ^answer_2}
             ] = UserRequest.list(state)
    end
  end

  describe "get/2" do
    test "returns nil when no message carries the number" do
      state = State.new!(%{messages: [stamped(Message.new_user!("hi"), 1)]})

      assert UserRequest.get(state, 2) == nil
      assert %{seq: 1} = UserRequest.get(state, 1)
    end
  end

  describe "summarize/2" do
    test "sums usage across messages, including sub-agent usage" do
      subagent_usage = TokenUsage.new!(%{input: 1000, output: 200})

      tool_result =
        with_metadata(tool_result_message("call_1"), %{subagent_usage: subagent_usage})

      messages = [
        Message.new_user!("go"),
        with_usage(tool_call_message("task", "call_1"), 100, 10),
        tool_result,
        with_usage(Message.new_assistant!("done"), 150, 20)
      ]

      assert %{token_usage: %TokenUsage{input: 1250, output: 230}} =
               UserRequest.summarize(1, messages)
    end

    test "token_usage is nil when nothing reported usage" do
      assert %{token_usage: nil} = UserRequest.summarize(1, [Message.new_user!("hi")])
    end

    test "counts tool calls by name and assistant messages excluding summaries" do
      summary = with_metadata(Message.new_assistant!("Earlier..."), %{summary: true})

      messages = [
        summary,
        Message.new_user!("go"),
        tool_call_message("lookup", "call_1"),
        tool_result_message("call_1"),
        tool_call_message("lookup", "call_2"),
        tool_result_message("call_2"),
        tool_call_message("write_file", "call_3"),
        tool_result_message("call_3"),
        Message.new_assistant!("done")
      ]

      assert %{
               assistant_message_count: 4,
               tool_calls: %{"lookup" => 2, "write_file" => 1}
             } = UserRequest.summarize(1, messages)
    end

    test "the final message is the last answer, not a trailing narration" do
      answer = Message.new_assistant!("The answer")

      messages = [
        Message.new_user!("go"),
        narration_message("Looking"),
        answer,
        narration_message("Wrapping up")
      ]

      assert %{final_message: ^answer} = UserRequest.summarize(1, messages)
    end

    test "the final message is nil without an answer" do
      messages = [Message.new_user!("go"), tool_call_message("lookup", "call_1")]
      assert %{final_message: nil} = UserRequest.summarize(1, messages)
    end
  end
end
