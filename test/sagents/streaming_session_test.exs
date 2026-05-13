defmodule Sagents.StreamingSessionTest do
  use ExUnit.Case, async: true

  alias LangChain.Message.ToolCall
  alias LangChain.MessageDelta
  alias Sagents.StreamingSession

  describe "handle_tool_call_identified/2" do
    test "creates a new MessageDelta when state has no streaming_delta yet" do
      state = %{streaming_delta: nil}
      tool_info = %{call_id: "abc", name: "read_file", display_text: "Reading"}

      assert %{streaming_delta: %MessageDelta{} = delta} =
               StreamingSession.handle_tool_call_identified(state, tool_info)

      assert delta.role == :assistant
      assert delta.status == :incomplete

      assert [%ToolCall{call_id: "abc", name: "read_file", display_text: "Reading"} = tc] =
               delta.tool_calls

      assert tc.metadata == %{"execution_status" => "identified"}
    end

    test "upserts a new tool call into an existing streaming_delta (sibling tools share the delta)" do
      existing_call = %ToolCall{
        call_id: "first",
        name: "search",
        metadata: %{"execution_status" => "executing"}
      }

      state = %{streaming_delta: %MessageDelta{role: :assistant, tool_calls: [existing_call]}}
      tool_info = %{call_id: "second", name: "read_file", display_text: "Reading"}

      assert %{streaming_delta: %MessageDelta{tool_calls: [first, second]}} =
               StreamingSession.handle_tool_call_identified(state, tool_info)

      assert first.call_id == "first"
      assert first.metadata["execution_status"] == "executing"
      assert second.call_id == "second"
      assert second.metadata["execution_status"] == "identified"
      assert second.display_text == "Reading"
    end

    test "returns empty changes when call_id is nil" do
      assert %{} ==
               StreamingSession.handle_tool_call_identified(%{streaming_delta: nil}, %{
                 call_id: nil,
                 name: "read_file"
               })
    end

    test "returns empty changes when tool_info has no call_id key" do
      assert %{} ==
               StreamingSession.handle_tool_call_identified(%{streaming_delta: nil}, %{
                 name: "read_file"
               })
    end
  end

  describe "handle_tool_execution_update/3" do
    test "returns empty changes when state has no streaming_delta" do
      tool_info = %{call_id: "abc", name: "read_file"}

      assert %{} ==
               StreamingSession.handle_tool_execution_update(
                 %{streaming_delta: nil},
                 :executing,
                 tool_info
               )
    end

    test "writes execution_status executing and forwards display_text on :executing" do
      delta = %MessageDelta{
        role: :assistant,
        tool_calls: [%ToolCall{call_id: "abc", name: "read_file"}]
      }

      tool_info = %{call_id: "abc", name: "read_file", display_text: "Reading outline.md"}

      assert %{streaming_delta: %MessageDelta{tool_calls: [tc]}} =
               StreamingSession.handle_tool_execution_update(
                 %{streaming_delta: delta},
                 :executing,
                 tool_info
               )

      assert tc.metadata["execution_status"] == "executing"
      assert tc.display_text == "Reading outline.md"
    end

    test "refines display_text on :executing without clobbering an existing value when new is nil" do
      delta = %MessageDelta{
        role: :assistant,
        tool_calls: [%ToolCall{call_id: "abc", display_text: "Reading"}]
      }

      assert %{streaming_delta: %MessageDelta{tool_calls: [tc]}} =
               StreamingSession.handle_tool_execution_update(
                 %{streaming_delta: delta},
                 :executing,
                 %{call_id: "abc", display_text: nil}
               )

      assert tc.display_text == "Reading"
    end

    test "does not clear delta when only one of multiple sibling tool calls finishes" do
      delta = %MessageDelta{
        role: :assistant,
        tool_calls: [
          %ToolCall{call_id: "a", metadata: %{"execution_status" => "executing"}},
          %ToolCall{call_id: "b", metadata: %{"execution_status" => "executing"}}
        ]
      }

      assert %{streaming_delta: %MessageDelta{tool_calls: [a, b]}} =
               StreamingSession.handle_tool_execution_update(
                 %{streaming_delta: delta},
                 :completed,
                 %{call_id: "a", name: "search"}
               )

      assert a.metadata["execution_status"] == "completed"
      assert b.metadata["execution_status"] == "executing"
    end

    test "clears delta when the final sibling tool call reaches a terminal status" do
      delta = %MessageDelta{
        role: :assistant,
        tool_calls: [
          %ToolCall{call_id: "a", metadata: %{"execution_status" => "completed"}},
          %ToolCall{call_id: "b", metadata: %{"execution_status" => "executing"}}
        ]
      }

      assert %{streaming_delta: nil} ==
               StreamingSession.handle_tool_execution_update(
                 %{streaming_delta: delta},
                 :failed,
                 %{call_id: "b", name: "search"}
               )
    end

    test "returns empty changes when call_id is nil" do
      assert %{} ==
               StreamingSession.handle_tool_execution_update(
                 %{streaming_delta: %MessageDelta{}},
                 :executing,
                 %{call_id: nil}
               )
    end

    test "returns empty changes when tool_info has no call_id key" do
      assert %{} ==
               StreamingSession.handle_tool_execution_update(
                 %{streaming_delta: %MessageDelta{}},
                 :executing,
                 %{name: "read_file"}
               )
    end
  end
end
