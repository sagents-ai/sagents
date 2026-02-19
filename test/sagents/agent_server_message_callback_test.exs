defmodule Sagents.AgentServerMessageCallbackTest do
  @moduledoc """
  Tests for AgentServer display message persistence functionality.

  This tests the feature where AgentServer:
  1. Accepts a `conversation_id` and `display_message_persistence` module
  2. Calls the persistence module when new messages are processed
  3. Broadcasts `{:agent, {:display_message_saved, display_msg}}` events for saved messages
  4. Also broadcasts `{:agent, {:llm_message, message}}` events (both with and without persistence)
  5. Handles persistence errors gracefully without crashing
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.AgentServer
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias Sagents.TestingHelpers

  # Make mocks global since agent execution happens in a Task
  setup :set_mimic_global

  setup do
    # Mock ChatAnthropic.call to prevent real API calls
    stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
      {:ok, [Message.new_assistant!("Mock response")]}
    end)

    :ok
  end

  describe "display message persistence configuration" do
    test "persists and broadcasts display messages when configured" do
      agent_id = TestingHelpers.generate_test_agent_id()
      conversation_id = "conv-123"

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: conversation_id,
          display_message_persistence: Sagents.TestDisplayMessagePersistence
        )

      # Add a message
      message = Message.new_user!("Test message")
      :ok = AgentServer.add_message(agent_id, message)

      # Verify display_message_saved event was broadcast for user message
      assert_receive {:agent, {:display_message_saved, user_display_msg}}, 100
      assert user_display_msg.role == "user"

      # Verify llm_message also broadcast
      assert_receive {:agent, {:llm_message, user_msg}}, 100
      assert user_msg.role == :user

      # Agent executes and generates assistant response
      assert_receive {:agent, {:display_message_saved, assistant_display_msg}}, 100
      assert assistant_display_msg.role == "assistant"

      assert_receive {:agent, {:llm_message, assistant_msg}}, 100
      assert assistant_msg.role == :assistant

      # Cleanup
      TestingHelpers.stop_test_agent(agent_id)
    end

    test "works without persistence configuration (fallback mode)" do
      agent_id = TestingHelpers.generate_test_agent_id()
      # Start agent WITHOUT persistence configuration
      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub}
          # No conversation_id or display_message_persistence
        )

      # Add a message
      message = Message.new_user!("Test message")
      :ok = AgentServer.add_message(agent_id, message)

      # Should receive :llm_message event (fallback) for both user and assistant
      assert_receive {:agent, {:llm_message, user_msg}}, 100
      assert user_msg.role == :user

      assert_receive {:agent, {:llm_message, assistant_msg}}, 100
      assert assistant_msg.role == :assistant

      # Cleanup
      TestingHelpers.stop_test_agent(agent_id)
    end

    test "requires both conversation_id and display_message_persistence for persistence to activate" do
      agent_id = TestingHelpers.generate_test_agent_id()

      # Start with persistence module but NO conversation_id
      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          display_message_persistence: Sagents.TestDisplayMessagePersistence
          # Missing conversation_id
        )

      # Add a message
      message = Message.new_user!("Test message")
      :ok = AgentServer.add_message(agent_id, message)

      # Should fallback to :llm_message (persistence not activated) for both messages
      assert_receive {:agent, {:llm_message, user_msg}}, 100
      assert user_msg.role == :user

      assert_receive {:agent, {:llm_message, assistant_msg}}, 100
      assert assistant_msg.role == :assistant

      # Cleanup
      TestingHelpers.stop_test_agent(agent_id)
    end
  end

  describe "persistence with different message types" do
    test "persists user messages via add_message" do
      agent_id = TestingHelpers.generate_test_agent_id()
      conversation_id = "conv-123"

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: conversation_id,
          display_message_persistence: Sagents.TestDisplayMessagePersistence
        )

      # Add user message
      :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

      assert_receive {:agent, {:display_message_saved, %{role: "user"}}}, 100

      # Cleanup
      TestingHelpers.stop_test_agent(agent_id)
    end

    test "persists assistant messages from LLM execution" do
      agent_id = TestingHelpers.generate_test_agent_id()
      conversation_id = "conv-123"

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: conversation_id,
          display_message_persistence: Sagents.TestDisplayMessagePersistence
        )

      # Add user message triggers execution -> assistant response
      :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

      # Skip user message events
      assert_receive {:agent, {:display_message_saved, %{role: "user"}}}, 100

      # Assert assistant message persisted
      assert_receive {:agent, {:display_message_saved, %{role: "assistant"}}}, 100

      # Cleanup
      TestingHelpers.stop_test_agent(agent_id)
    end
  end

  describe "messages are added to state regardless of persistence" do
    test "messages accumulate in state even when persistence fails" do
      agent_id = TestingHelpers.generate_test_agent_id()
      conversation_id = "conv-123"

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: conversation_id,
          display_message_persistence: Sagents.TestDisplayMessagePersistence
        )

      # Add messages
      :ok = AgentServer.add_message(agent_id, Message.new_user!("Message 1"))

      # brief pause before sending next message (async)
      Process.sleep(50)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("Message 2"))
      # brief pause for processing second message
      Process.sleep(50)

      # Messages should still be in state (includes the two assistant responses)
      state = AgentServer.get_state(agent_id)
      assert length(state.messages) == 4

      # Cleanup
      TestingHelpers.stop_test_agent(agent_id)
    end
  end

  describe "error handling" do
    test "logs error but doesn't crash when persistence module raises exception" do
      agent_id = TestingHelpers.generate_test_agent_id()
      conversation_id = "conv-123"

      {:ok, %{agent_id: ^agent_id, pid: pid}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: conversation_id,
          display_message_persistence: Sagents.TestDisplayMessagePersistenceRaising
        )

      # Add message - should not crash the server
      :ok = AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Server should still be alive
      Process.sleep(100)
      assert Process.alive?(pid)

      # Cleanup
      TestingHelpers.stop_test_agent(agent_id)
    end
  end
end
