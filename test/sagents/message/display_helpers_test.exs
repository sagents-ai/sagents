defmodule Sagents.Message.DisplayHelpersTest do
  use Sagents.BaseCase, async: true

  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias Sagents.Message.DisplayHelpers

  describe "extract_display_items/1" do
    test "extracts simple text from assistant message" do
      message = Message.new_assistant!("Hello world")

      items = DisplayHelpers.extract_display_items(message)

      assert [
               %{
                 type: :text,
                 message_type: :assistant,
                 content: %{"text" => "Hello world"}
               }
             ] = items
    end

    test "extracts thinking and text content parts" do
      message =
        Message.new_assistant!([
          ContentPart.thinking!("Let me think..."),
          ContentPart.text!("Here's my answer")
        ])

      items = DisplayHelpers.extract_display_items(message)

      assert [
               %{type: :thinking, content: %{"text" => "Let me think..."}},
               %{type: :text, content: %{"text" => "Here's my answer"}}
             ] = items
    end

    test "extracts multiple tool calls" do
      tool_call_1 = ToolCall.new!(%{call_id: "1", name: "search", arguments: %{"q" => "elixir"}})
      tool_call_2 = ToolCall.new!(%{call_id: "2", name: "weather", arguments: %{"city" => "NYC"}})

      message = Message.new_assistant!(%{tool_calls: [tool_call_1, tool_call_2]})

      items = DisplayHelpers.extract_display_items(message)

      assert [
               %{
                 type: :tool_call,
                 message_type: :assistant,
                 content: %{
                   "call_id" => "1",
                   "name" => "search",
                   "arguments" => %{"q" => "elixir"}
                 }
               },
               %{
                 type: :tool_call,
                 message_type: :assistant,
                 content: %{
                   "call_id" => "2",
                   "name" => "weather",
                   "arguments" => %{"city" => "NYC"}
                 }
               }
             ] = items
    end

    test "extracts multiple tool results" do
      result_1 =
        ToolResult.new!(%{
          tool_call_id: "1",
          name: "search",
          content: "Found...",
          is_error: false
        })

      result_2 =
        ToolResult.new!(%{tool_call_id: "2", name: "weather", content: "Sunny", is_error: false})

      message = Message.new_tool_result!(%{tool_results: [result_1, result_2]})

      items = DisplayHelpers.extract_display_items(message)

      assert [
               %{
                 type: :tool_result,
                 message_type: :tool,
                 content: %{
                   "tool_call_id" => "1",
                   "name" => "search",
                   "content" => "Found...",
                   "is_error" => false
                 }
               },
               %{
                 type: :tool_result,
                 message_type: :tool,
                 content: %{
                   "tool_call_id" => "2",
                   "name" => "weather",
                   "content" => "Sunny",
                   "is_error" => false
                 }
               }
             ] = items
    end

    test "extracts text content plus tool calls (mixed)" do
      message =
        Message.new_assistant!(%{
          content: [ContentPart.text!("Let me search for that")],
          tool_calls: [
            ToolCall.new!(%{call_id: "1", name: "search", arguments: %{"q" => "elixir"}})
          ]
        })

      items = DisplayHelpers.extract_display_items(message)

      assert [
               %{type: :text, content: %{"text" => "Let me search for that"}},
               %{
                 type: :tool_call,
                 content: %{
                   "call_id" => "1",
                   "name" => "search",
                   "arguments" => %{"q" => "elixir"}
                 }
               }
             ] = items
    end

    test "returns empty list for message with no displayable content" do
      message = Message.new_assistant!(%{content: nil, tool_calls: []})

      items = DisplayHelpers.extract_display_items(message)

      assert [] = items
    end

    test "filters out empty text content" do
      message = Message.new_assistant!(%{content: ""})

      items = DisplayHelpers.extract_display_items(message)

      assert [] = items
    end

    test "preserves display_text from ToolCall field when present" do
      # ToolCall has a direct display_text field (like ToolResult)
      tool_call =
        ToolCall.new!(%{
          call_id: "call_123",
          name: "ls",
          arguments: %{"pattern" => "*.ex"},
          display_text: "Listing files"
        })

      message = Message.new_assistant!(%{tool_calls: [tool_call]})
      items = DisplayHelpers.extract_display_items(message)

      # Expected: display_text should be extracted from ToolCall.display_text field
      assert [
               %{
                 type: :tool_call,
                 message_type: :assistant,
                 content: %{
                   "call_id" => "call_123",
                   "name" => "ls",
                   "arguments" => %{"pattern" => "*.ex"},
                   "display_text" => "Listing files"
                 }
               }
             ] = items
    end
  end

  describe "stop_reason/1" do
    test "returns nil for a message the model finished" do
      assert nil == DisplayHelpers.stop_reason(Message.new_assistant!("All done"))
    end

    test "returns :length when the output cap was reached" do
      message = Message.new_assistant!(%{content: "Partial", status: :length})

      assert :length == DisplayHelpers.stop_reason(message)
    end

    test "returns :cancelled when the run was stopped" do
      message = Message.new_assistant!(%{content: "Partial", status: :cancelled})

      assert :cancelled == DisplayHelpers.stop_reason(message)
    end

    test "returns :stream_error when the stream died mid-flight" do
      message =
        Message.new_assistant!(%{
          content: "Partial",
          status: :cancelled,
          metadata: %{
            streaming_error: LangChainError.exception(type: "overloaded", message: "busy")
          }
        })

      assert :stream_error == DisplayHelpers.stop_reason(message)
    end

    test "returns :stream_error for the LangChain status of the same name" do
      # Built as a struct rather than through Message.new/1 so the assertion is
      # about classification alone, independent of which LangChain in the
      # supported range is installed and what its Ecto.Enum accepts.
      message = %Message{role: :assistant, content: "Partial", status: :stream_error}

      assert :stream_error == DisplayHelpers.stop_reason(message)
    end

    test "returns :content_filtered when the provider's filter stopped the response" do
      message = %Message{role: :assistant, content: "Partial", status: :content_filtered}

      assert :content_filtered == DisplayHelpers.stop_reason(message)
    end

    test "a :cancelled message carrying no error is a caller-initiated stop" do
      # `:cancelled` and a dead stream are told apart by the presence of the
      # error in metadata, for the LangChain releases that record both as
      # `:cancelled`. Absence has to mean the caller stopped the run, or every
      # cancellation would report as a connection failure.
      #
      # Durability of that discrimination across an agent-state round trip is
      # covered in `Sagents.Persistence.StateSerializerTest`, which is where the
      # projection that carries it lives.
      message = Message.new_assistant!(%{content: "Partial", status: :cancelled, metadata: %{}})

      assert :cancelled == DisplayHelpers.stop_reason(message)
    end
  end

  describe "streaming_error/1" do
    test "returns the error that killed the stream" do
      error = LangChainError.exception(type: "overloaded", message: "busy")

      message =
        Message.new_assistant!(%{
          content: "Partial",
          status: :cancelled,
          metadata: %{streaming_error: error}
        })

      assert ^error = DisplayHelpers.streaming_error(message)
    end

    test "returns nil for a cancelled message with no streaming error" do
      message = Message.new_assistant!(%{content: "Partial", status: :cancelled})

      assert nil == DisplayHelpers.streaming_error(message)
    end

    test "returns nil for a completed message" do
      assert nil == DisplayHelpers.streaming_error(Message.new_assistant!("All done"))
    end

    test "reads the error whatever status LangChain used to record the stop" do
      error = LangChainError.exception(type: "overloaded", message: "busy")

      message = %Message{
        role: :assistant,
        content: "Partial",
        status: :stream_error,
        metadata: %{streaming_error: error}
      }

      assert ^error = DisplayHelpers.streaming_error(message)
    end
  end

  describe "stop_details/1" do
    test "returns the provider's detail for a refusal" do
      details = %{
        "type" => "refusal",
        "category" => "cyber",
        "explanation" => "Declined to assist."
      }

      message = %Message{
        role: :assistant,
        content: "",
        status: :content_filtered,
        metadata: %{stop_details: details}
      }

      assert ^details = DisplayHelpers.stop_details(message)
    end

    test "returns nil when the stop carries no detail" do
      message = %Message{role: :assistant, content: "Partial", status: :length}

      assert nil == DisplayHelpers.stop_details(message)
    end

    test "returns nil for a finished message" do
      assert nil == DisplayHelpers.stop_details(Message.new_assistant!("All done"))
    end

    test "returns nil when metadata carries something else" do
      error = LangChainError.exception(type: "overloaded", message: "busy")

      message = %Message{
        role: :assistant,
        content: "Partial",
        status: :stream_error,
        metadata: %{streaming_error: error}
      }

      assert nil == DisplayHelpers.stop_details(message)
    end
  end

  describe "extract_display_items/1 stop reason marking" do
    test "marks a lone thinking part that was cut off" do
      message =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("I should start by...")],
          status: :length
        })

      assert [%{type: :thinking, content: content}] =
               DisplayHelpers.extract_display_items(message)

      assert content["stop_reason"] == "length"
      assert content["text"] == "I should start by..."
    end

    test "marks only the final item when thinking is followed by text" do
      message =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("Let me think"), ContentPart.text!("Here is the")],
          status: :length
        })

      assert [thinking, text] = DisplayHelpers.extract_display_items(message)
      refute Map.has_key?(thinking.content, "stop_reason")
      assert text.content["stop_reason"] == "length"
    end

    test "marks the tool call when text is followed by a tool call" do
      message =
        Message.new_assistant!(%{
          content: [ContentPart.text!("Searching now")],
          tool_calls: [
            ToolCall.new!(%{call_id: "1", name: "search", arguments: %{"q" => "elixir"}})
          ],
          status: :length
        })

      assert [text, tool_call] = DisplayHelpers.extract_display_items(message)
      refute Map.has_key?(text.content, "stop_reason")
      assert tool_call.content["stop_reason"] == "length"
    end

    test "a finished message carries no stop_reason key at all" do
      message =
        Message.new_assistant!([ContentPart.thinking!("Thought"), ContentPart.text!("Answer")])

      items = DisplayHelpers.extract_display_items(message)

      assert length(items) == 2
      # Absence, not a nil value. Hosts render on the truthiness of the key.
      Enum.each(items, fn item -> refute Map.has_key?(item.content, "stop_reason") end)
    end

    test "marks a cancelled message as cancelled" do
      message = Message.new_assistant!(%{content: "Partial answ", status: :cancelled})

      assert [%{content: content}] = DisplayHelpers.extract_display_items(message)
      assert content["stop_reason"] == "cancelled"
    end

    test "marks a dead stream as stream_error" do
      message =
        Message.new_assistant!(%{
          content: "Partial answ",
          status: :cancelled,
          metadata: %{
            streaming_error: LangChainError.exception(type: "overloaded", message: "busy")
          }
        })

      assert [%{content: content}] = DisplayHelpers.extract_display_items(message)
      assert content["stop_reason"] == "stream_error"
    end

    test "marks a content filtered message as content_filtered" do
      message = %Message{
        role: :assistant,
        content: [ContentPart.text!("Partial answ")],
        status: :content_filtered
      }

      assert [%{content: content}] = DisplayHelpers.extract_display_items(message)
      assert content["stop_reason"] == "content_filtered"
    end

    test "carries the provider's stop detail alongside the reason" do
      details = %{
        "type" => "refusal",
        "category" => "cyber",
        "explanation" => "Declined to assist."
      }

      message = %Message{
        role: :assistant,
        content: [ContentPart.text!("Partial answ")],
        status: :content_filtered,
        metadata: %{stop_details: details}
      }

      assert [%{content: content}] = DisplayHelpers.extract_display_items(message)
      assert content["stop_reason"] == "content_filtered"
      assert content["stop_details"] == details
    end

    test "marks only the last item with the detail when a message yields several" do
      details = %{"type" => "refusal", "category" => "cyber"}

      message = %Message{
        role: :assistant,
        content: [ContentPart.thinking!("Considering"), ContentPart.text!("Partial answ")],
        status: :content_filtered,
        metadata: %{stop_details: details}
      }

      assert [%{content: thinking}, %{content: text}] =
               DisplayHelpers.extract_display_items(message)

      refute Map.has_key?(thinking, "stop_reason")
      refute Map.has_key?(thinking, "stop_details")
      assert text["stop_reason"] == "content_filtered"
      assert text["stop_details"] == details
    end

    test "a stop with no detail writes no stop_details key" do
      # Absence rather than nil: hosts render on presence, and a nil would make
      # every unfinished message look like it carried detail.
      message = %Message{
        role: :assistant,
        content: [ContentPart.text!("Partial answ")],
        status: :length
      }

      assert [%{content: content}] = DisplayHelpers.extract_display_items(message)
      assert content["stop_reason"] == "length"
      refute Map.has_key?(content, "stop_details")
    end

    test "a finished message writes neither key" do
      message = Message.new_assistant!(%{content: [ContentPart.text!("All done")]})

      assert [%{content: content}] = DisplayHelpers.extract_display_items(message)
      refute Map.has_key?(content, "stop_reason")
      refute Map.has_key?(content, "stop_details")
    end

    test "a message that stopped before producing anything yields no items" do
      message = Message.new_assistant!(%{content: "", status: :length})

      assert [] == DisplayHelpers.extract_display_items(message)
    end
  end
end
