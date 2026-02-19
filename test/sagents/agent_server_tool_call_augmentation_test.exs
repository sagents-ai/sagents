defmodule Sagents.AgentServerToolCallAugmentationTest do
  @moduledoc """
  Tests that verify LLMChain augments tool_calls with display_text from Function definitions.

  This test mocks the LLM to return tool_calls WITHOUT display_text (as real LLMs do),
  then verifies that LLMChain.augment_tool_calls_with_display_text adds display_text
  to the ToolCall.display_text field before the message is persisted.

  This is a focused unit test that doesn't require API keys or live LLM calls.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, State}
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function

  require Logger

  # AgentServer runs execution in a Task, so we need global Mimic mode
  setup :set_mimic_global

  describe "tool_call augmentation with display_text" do
    test "LLMChain augments tool_calls with display_text before persistence" do
      # Create a function with display_text
      search_tool =
        Function.new!(%{
          name: "search_db",
          display_text: "Searching database",
          description: "Searches the database",
          parameters_schema: %{
            type: "object",
            properties: %{
              query: %{type: "string"}
            }
          },
          function: fn %{"query" => _query}, _context ->
            {:ok, "Search results"}
          end
        })

      {:ok, model} = ChatAnthropic.new(%{model: "claude-3-5-haiku-latest", api_key: "test"})

      {:ok, agent} =
        Agent.new(%{
          agent_id: "augment-test",
          model: model,
          tools: [search_tool]
        })

      # Register test process to receive forwarded messages
      Sagents.TestDisplayMessagePersistenceForwarding.register_test_process(self())

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          initial_state: State.new!(),
          pubsub: nil,
          conversation_id: "test-conv",
          display_message_persistence: Sagents.TestDisplayMessagePersistenceForwarding
        )

      # Mock the LLM to return an assistant message with a tool_call
      # WITHOUT metadata (this is how real LLMs return tool_calls)
      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call_without_metadata =
          ToolCall.new!(%{
            call_id: "call_123",
            name: "search_db",
            arguments: %{"query" => "test"},
            # NO metadata - this is how LLMs return tool_calls
            metadata: nil
          })

        assistant_message =
          Message.new_assistant!(%{
            tool_calls: [tool_call_without_metadata]
          })

        {:ok, assistant_message}
      end)

      # Add a user message to trigger agent execution
      user_message = Message.new_user!("Search for something")
      :ok = AgentServer.add_message("augment-test", user_message)

      # Wait for user message to be saved
      assert_receive {:saved_message, %Message{role: :user}, _}

      # Wait for assistant message with tool_call to be saved
      assert_receive {:saved_message, %Message{role: :assistant} = assistant_msg, display_items}

      Logger.info("\n=== VERIFICATION ===")

      # Verify the assistant message has tool_calls
      assert [tool_call] = assistant_msg.tool_calls
      assert tool_call.name == "search_db"

      # CRITICAL: Check if display_text was added to ToolCall by LLMChain
      Logger.info("Tool call display_text: #{inspect(tool_call.display_text)}")

      assert tool_call.display_text == "Searching database",
             "LLMChain should augment ToolCall.display_text from Function definition"

      # Verify DisplayHelpers extracted display_text to content
      assert [tool_call_item] = display_items
      assert tool_call_item.type == :tool_call
      assert tool_call_item.content["name"] == "search_db"

      assert tool_call_item.content["display_text"] == "Searching database",
             "DisplayMessage content should include display_text for database persistence"

      # Cleanup
      AgentServer.stop("augment-test")
    end

    test "tool_call without display_text in Function definition gets humanized fallback" do
      # Create a function WITHOUT display_text
      plain_tool =
        Function.new!(%{
          name: "plain_tool",
          # NO display_text
          description: "Plain tool",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _, _ -> {:ok, "Done"} end
        })

      {:ok, model} = ChatAnthropic.new(%{model: "claude-3-5-haiku-latest", api_key: "test"})

      {:ok, agent} =
        Agent.new(%{
          agent_id: "plain-test",
          model: model,
          tools: [plain_tool]
        })

      # Register test process to receive forwarded messages
      Sagents.TestDisplayMessagePersistenceForwarding.register_test_process(self())

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          initial_state: State.new!(),
          pubsub: nil,
          conversation_id: "plain-conv",
          display_message_persistence: Sagents.TestDisplayMessagePersistenceForwarding
        )

      # Mock LLM to return tool_call without metadata
      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "plain_123",
            name: "plain_tool",
            arguments: %{},
            metadata: nil
          })

        {:ok, Message.new_assistant!(%{tool_calls: [tool_call]})}
      end)

      :ok = AgentServer.add_message("plain-test", Message.new_user!("Test"))

      assert_receive {:saved_message, %Message{role: :user}, _}
      assert_receive {:saved_message, %Message{role: :assistant} = msg, items}

      # Tool should have a humanized fallback display_text
      [tool_call] = msg.tool_calls

      # display_text should be the humanized tool name since Function didn't define one
      assert tool_call.display_text == "Plain tool",
             "Should use humanized fallback when Function doesn't define display_text"

      # DisplayMessage content should have the humanized display_text
      [item] = items
      assert item.content["display_text"] == "Plain tool"

      AgentServer.stop("plain-test")
    end
  end
end
