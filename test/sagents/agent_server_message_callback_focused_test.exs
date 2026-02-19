defmodule Sagents.AgentServerMessageCallbackFocusedTest do
  @moduledoc """
  Focused unit tests for AgentServer display message persistence functionality.

  These tests verify the persistence infrastructure without triggering full agent execution.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.AgentServer
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message

  setup :set_mimic_global

  setup do
    # Mock ChatAnthropic to prevent execution
    stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
      {:ok, [Message.new_assistant!("Mock response")]}
    end)

    # Start PubSub
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.PubSub.Supervisor.start_link(name: pubsub_name, adapter_name: Phoenix.PubSub.PG2)

    agent_id = generate_test_agent_id()

    {:ok, pubsub: pubsub_name, agent_id: agent_id}
  end

  describe "persistence configuration" do
    test "accepts and stores conversation_id", %{agent_id: agent_id, pubsub: pubsub} do
      agent = create_test_agent(agent_id: agent_id)
      conversation_id = "conv-test-123"

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          conversation_id: conversation_id,
          pubsub: {Phoenix.PubSub, pubsub}
        )

      # Verify server started successfully (proves config was accepted)
      assert AgentServer.get_pid(agent_id) != nil
      assert AgentServer.get_status(agent_id) == :idle

      AgentServer.stop(agent_id)
    end

    test "accepts and stores display_message_persistence", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      agent = create_test_agent(agent_id: agent_id)

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          conversation_id: "conv-123",
          display_message_persistence: Sagents.TestDisplayMessagePersistence,
          pubsub: {Phoenix.PubSub, pubsub}
        )

      # Verify server started successfully (proves config was accepted)
      assert AgentServer.get_pid(agent_id) != nil
      assert AgentServer.get_status(agent_id) == :idle

      AgentServer.stop(agent_id)
    end

    test "works without persistence options (backward compatibility)", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      agent = create_test_agent(agent_id: agent_id)

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          pubsub: {Phoenix.PubSub, pubsub}
          # No conversation_id or display_message_persistence
        )

      # Verify server started successfully
      assert AgentServer.get_pid(agent_id) != nil
      assert AgentServer.get_status(agent_id) == :idle

      AgentServer.stop(agent_id)
    end
  end

  describe "persistence invocation" do
    test "persistence module is invoked when adding user message", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      agent = create_test_agent(agent_id: agent_id)
      conversation_id = "conv-123"

      # Subscribe to events
      Phoenix.PubSub.subscribe(pubsub, "agent_server:#{agent_id}")

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          conversation_id: conversation_id,
          display_message_persistence: Sagents.TestDisplayMessagePersistence,
          pubsub: {Phoenix.PubSub, pubsub}
        )

      # Add a user message
      message = Message.new_user!("Test message")
      :ok = AgentServer.add_message(agent_id, message)

      # Verify display_message_saved was broadcast (persistence was invoked)
      assert_receive {:agent, {:display_message_saved, %{role: "user"}}}

      AgentServer.stop(agent_id)
    end

    test "persistence is not invoked when conversation_id is missing", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      agent = create_test_agent(agent_id: agent_id)

      # Subscribe to events
      Phoenix.PubSub.subscribe(pubsub, "agent_server:#{agent_id}")

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          # Has persistence module but missing conversation_id
          display_message_persistence: Sagents.TestDisplayMessagePersistence,
          pubsub: {Phoenix.PubSub, pubsub}
        )

      message = Message.new_user!("Test")
      :ok = AgentServer.add_message(agent_id, message)

      # Should get llm_message (fallback), not display_message_saved
      assert_receive {:agent, {:llm_message, %{role: :user}}}
      refute_receive {:agent, {:display_message_saved, _}}

      AgentServer.stop(agent_id)
    end
  end

  describe "error handling" do
    test "persistence exception doesn't crash server", %{agent_id: agent_id, pubsub: pubsub} do
      agent = create_test_agent(agent_id: agent_id)

      {:ok, pid} =
        AgentServer.start_link(
          agent: agent,
          conversation_id: "conv-123",
          display_message_persistence: Sagents.TestDisplayMessagePersistenceRaising,
          pubsub: {Phoenix.PubSub, pubsub}
        )

      message = Message.new_user!("Test")
      :ok = AgentServer.add_message(agent_id, message)

      # Server should still be alive (status may be :running or :idle)
      assert Process.alive?(pid)
      status = AgentServer.get_status(agent_id)
      assert status in [:idle, :running]

      AgentServer.stop(agent_id)
    end
  end

  describe "message state management" do
    test "messages added to state regardless of persistence success", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      agent = create_test_agent(agent_id: agent_id)

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          conversation_id: "conv-123",
          display_message_persistence: Sagents.TestDisplayMessagePersistenceRaising,
          pubsub: {Phoenix.PubSub, pubsub}
        )

      # Add a message
      message = Message.new_user!("Test message")
      :ok = AgentServer.add_message(agent_id, message)

      # Message should still be in state even though persistence failed
      state = AgentServer.get_state(agent_id)
      assert length(state.messages) >= 1

      AgentServer.stop(agent_id)
    end
  end
end
