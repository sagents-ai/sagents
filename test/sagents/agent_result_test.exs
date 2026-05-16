defmodule Sagents.AgentResultTest do
  use ExUnit.Case, async: true

  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias Sagents.AgentResult
  alias Sagents.State

  defp tool_call(call_id, name, args) do
    ToolCall.new!(%{call_id: call_id, name: name, arguments: args})
  end

  defp tool_result(call_id, name, processed \\ nil) do
    %ToolResult{
      tool_call_id: call_id,
      name: name,
      content: "ok",
      processed_content: processed
    }
  end

  defp state_with_extraction_call(args, processed \\ nil) do
    call = tool_call("call_1", "submit", args)
    assistant = Message.new_assistant!(%{tool_calls: [call]})

    tool_msg =
      Message.new_tool_result!(%{tool_results: [tool_result("call_1", "submit", processed)]})

    State.new!(%{messages: [Message.new_user!("hi"), assistant, tool_msg]})
  end

  describe "tool_result/1" do
    test "extracts the third element from a 3-tuple" do
      state = State.new!()
      tr = tool_result("call_1", "submit")
      assert {:ok, ^tr} = AgentResult.tool_result({:ok, state, tr})
    end

    test "walks state.messages for a 2-tuple" do
      state = state_with_extraction_call(%{"x" => 1})
      assert {:ok, %ToolResult{name: "submit"}} = AgentResult.tool_result({:ok, state})
    end

    test "accepts a bare State" do
      state = state_with_extraction_call(%{"x" => 1})
      assert {:ok, %ToolResult{name: "submit"}} = AgentResult.tool_result(state)
    end

    test "returns an error when no tool result is present" do
      state = State.new!(%{messages: [Message.new_user!("hi")]})

      assert {:error, %LangChainError{type: "no_tool_result"}} =
               AgentResult.tool_result(state)
    end

    test "prefers a non-error result over an error result" do
      err = %ToolResult{tool_call_id: "1", name: "a", content: "bad", is_error: true}
      ok = %ToolResult{tool_call_id: "2", name: "b", content: "good"}

      msg = Message.new_tool_result!(%{tool_results: [err, ok]})
      state = State.new!(%{messages: [msg]})

      assert {:ok, %ToolResult{name: "b"}} = AgentResult.tool_result(state)
    end

    test "passes through error tuples unchanged" do
      err = {:error, :boom}
      assert ^err = AgentResult.tool_result(err)
    end

    test "translates :interrupt into an error" do
      assert {:error, %LangChainError{type: "interrupted"}} =
               AgentResult.tool_result({:interrupt, State.new!(), %{}})
    end

    test "translates :pause into an error" do
      assert {:error, %LangChainError{type: "paused"}} =
               AgentResult.tool_result({:pause, State.new!()})
    end
  end

  describe "tool_arguments/1" do
    test "returns the arguments map from the 3-tuple's matching tool call" do
      state = state_with_extraction_call(%{"title" => "hello"})
      tr = tool_result("call_1", "submit")

      assert {:ok, %{"title" => "hello"}} =
               AgentResult.tool_arguments({:ok, state, tr})
    end

    test "falls back to last assistant tool call for 2-tuple" do
      state = state_with_extraction_call(%{"title" => "hello"})

      assert {:ok, %{"title" => "hello"}} =
               AgentResult.tool_arguments({:ok, state})
    end

    test "returns error when no tool call is present" do
      state =
        State.new!(%{
          messages: [
            Message.new_user!("hi"),
            Message.new_assistant!("just text")
          ]
        })

      assert {:error, %LangChainError{type: "no_tool_arguments"}} =
               AgentResult.tool_arguments(state)
    end

    test "passes error tuples through" do
      err = {:error, :nope}
      assert ^err = AgentResult.tool_arguments(err)
    end
  end

  describe "processed_content/1" do
    test "returns the processed_content of the result tool" do
      state = state_with_extraction_call(%{"x" => 1}, %{x: 1, native: true})
      tr = tool_result("call_1", "submit", %{x: 1, native: true})

      assert {:ok, %{x: 1, native: true}} =
               AgentResult.processed_content({:ok, state, tr})
    end

    test "errors when processed_content is nil" do
      state = state_with_extraction_call(%{"x" => 1})
      tr = tool_result("call_1", "submit", nil)

      assert {:error, %LangChainError{type: "no_processed_content"}} =
               AgentResult.processed_content({:ok, state, tr})
    end

    test "propagates a missing-tool-result error" do
      state = State.new!(%{messages: [Message.new_user!("hi")]})

      assert {:error, %LangChainError{type: "no_tool_result"}} =
               AgentResult.processed_content(state)
    end
  end

  describe "to_string/1" do
    test "returns the last assistant text" do
      state =
        State.new!(%{
          messages: [
            Message.new_user!("hi"),
            Message.new_assistant!("hello there")
          ]
        })

      assert {:ok, "hello there"} = AgentResult.to_string({:ok, state})
    end

    test "errors when the last message is not an assistant message" do
      state = State.new!(%{messages: [Message.new_user!("hi")]})

      assert {:error, %LangChainError{type: "to_string"}} =
               AgentResult.to_string(state)
    end

    test "errors with no messages" do
      assert {:error, %LangChainError{type: "to_string"}} =
               AgentResult.to_string(State.new!())
    end

    test "works against a 3-tuple by ignoring the extra" do
      state =
        State.new!(%{
          messages: [
            Message.new_user!("hi"),
            Message.new_assistant!("hello")
          ]
        })

      tr = tool_result("c", "n")
      assert {:ok, "hello"} = AgentResult.to_string({:ok, state, tr})
    end
  end
end
