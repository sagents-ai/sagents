defmodule Sagents.AgentDeltaOrderingTest do
  use Sagents.BaseCase, async: true

  alias Sagents.State
  alias Sagents.Mode.Steps
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatAnthropic

  describe "extract_state_deltas_from_chain/1" do
    test "extracts state deltas in chronological order" do
      # Create a chain with 2 tool messages containing State deltas.
      # The tool messages are in chronological order in chain.messages.
      # After reduce, newest delta (last in list) should win (right-side priority).
      model = ChatAnthropic.new!(%{model: "claude-3-5-sonnet-20241022", api_key: "test"})

      # Build an assistant message with tool calls
      assistant_msg =
        Message.new_assistant!(%{
          tool_calls: [
            ToolCall.new!(%{
              call_id: "call_1",
              name: "tool_a",
              arguments: %{}
            }),
            ToolCall.new!(%{
              call_id: "call_2",
              name: "tool_b",
              arguments: %{}
            })
          ]
        })

      # First tool result sets metadata to %{order: "first"}
      first_state_delta = State.new!(%{metadata: %{order: "first"}})

      tool_msg_1 =
        Message.new_tool_result!(%{
          tool_results: [
            ToolResult.new!(%{
              tool_call_id: "call_1",
              name: "tool_a",
              content: "result_a",
              processed_content: first_state_delta
            })
          ]
        })

      # Second tool result sets metadata to %{order: "second"}
      second_state_delta = State.new!(%{metadata: %{order: "second"}})

      tool_msg_2 =
        Message.new_tool_result!(%{
          tool_results: [
            ToolResult.new!(%{
              tool_call_id: "call_2",
              name: "tool_b",
              content: "result_b",
              processed_content: second_state_delta
            })
          ]
        })

      chain =
        LLMChain.new!(%{llm: model})
        |> Map.put(:messages, [assistant_msg, tool_msg_1, tool_msg_2])

      deltas = Steps.extract_state_deltas_from_chain(chain)

      assert length(deltas) == 2

      # Deltas should be in chronological order so that when reduced
      # left-to-right, the newest (second) wins
      base = State.new!()

      result =
        Enum.reduce(deltas, base, fn delta, acc ->
          State.merge_states(acc, delta)
        end)

      assert result.metadata.order == "second"
    end

    test "single delta returns correctly" do
      model = ChatAnthropic.new!(%{model: "claude-3-5-sonnet-20241022", api_key: "test"})

      assistant_msg =
        Message.new_assistant!(%{
          tool_calls: [
            ToolCall.new!(%{call_id: "call_1", name: "tool_a", arguments: %{}})
          ]
        })

      state_delta = State.new!(%{metadata: %{key: "value"}})

      tool_msg =
        Message.new_tool_result!(%{
          tool_results: [
            ToolResult.new!(%{
              tool_call_id: "call_1",
              name: "tool_a",
              content: "result",
              processed_content: state_delta
            })
          ]
        })

      chain =
        LLMChain.new!(%{llm: model})
        |> Map.put(:messages, [assistant_msg, tool_msg])

      deltas = Steps.extract_state_deltas_from_chain(chain)

      assert length(deltas) == 1
      assert hd(deltas).metadata.key == "value"
    end

    test "no deltas returns empty list" do
      model = ChatAnthropic.new!(%{model: "claude-3-5-sonnet-20241022", api_key: "test"})

      assistant_msg =
        Message.new_assistant!(%{
          tool_calls: [
            ToolCall.new!(%{call_id: "call_1", name: "tool_a", arguments: %{}})
          ]
        })

      tool_msg =
        Message.new_tool_result!(%{
          tool_results: [
            ToolResult.new!(%{
              tool_call_id: "call_1",
              name: "tool_a",
              content: "just a string result"
            })
          ]
        })

      chain =
        LLMChain.new!(%{llm: model})
        |> Map.put(:messages, [assistant_msg, tool_msg])

      deltas = Steps.extract_state_deltas_from_chain(chain)

      assert deltas == []
    end
  end
end
