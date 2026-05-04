defmodule Sagents.AgentServerSyntheticMessageTest do
  @moduledoc """
  Tests for `AgentServer.save_synthetic_message_from/2`: the public hook
  middleware uses to record user-facing transcript entries that don't come
  from an LLM (e.g., a user's answer to an `ask_user` question).
  """

  use Sagents.BaseCase, async: false

  alias Sagents.AgentServer
  alias Sagents.TestDisplayMessagePersistenceForwarding, as: Forwarder
  alias Sagents.TestingHelpers

  setup do
    Forwarder.register_test_process(self())
    Forwarder.clear_synthetic_response()

    on_exit(fn -> Forwarder.clear_synthetic_response() end)

    :ok
  end

  describe "save_synthetic_message_from/2" do
    test "persists via the configured callback and broadcasts :display_message_saved" do
      agent_id = TestingHelpers.generate_test_agent_id()
      conversation_id = "conv-synth-1"

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: conversation_id,
          display_message_persistence: Forwarder
        )

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "PostgreSQL"}
      }

      :ok = AgentServer.save_synthetic_message_from(agent_id, attrs)

      assert_receive {:saved_synthetic_message, _scope, ^attrs, context}, 200
      assert context.agent_id == agent_id
      assert context.conversation_id == conversation_id

      assert_receive {:agent, {:display_message_saved, %{attrs: ^attrs}}}, 200

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "no-op when conversation_id is missing" do
      agent_id = TestingHelpers.generate_test_agent_id()

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          display_message_persistence: Forwarder
          # no conversation_id
        )

      :ok =
        AgentServer.save_synthetic_message_from(agent_id, %{
          message_type: "user",
          content_type: "text",
          content: %{"text" => "ignored"}
        })

      # Sync via get_state to flush mailbox.
      _ = AgentServer.get_state(agent_id)

      refute_received {:saved_synthetic_message, _, _, _}
      refute_received {:agent, {:display_message_saved, _}}

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "no-op when no persistence module is configured" do
      agent_id = TestingHelpers.generate_test_agent_id()

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-x"
          # no display_message_persistence
        )

      :ok =
        AgentServer.save_synthetic_message_from(agent_id, %{
          message_type: "user",
          content_type: "text",
          content: %{"text" => "ignored"}
        })

      _ = AgentServer.get_state(agent_id)

      refute_received {:saved_synthetic_message, _, _, _}
      refute_received {:agent, {:display_message_saved, _}}

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "logs and continues when persistence callback returns {:error, _}" do
      agent_id = TestingHelpers.generate_test_agent_id()

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-err",
          display_message_persistence: Forwarder
        )

      Forwarder.set_synthetic_response({:error, :db_down})

      :ok =
        AgentServer.save_synthetic_message_from(agent_id, %{
          message_type: "user",
          content_type: "text",
          content: %{"text" => "x"}
        })

      assert_receive {:saved_synthetic_message, _scope, _attrs, _context}, 200
      refute_received {:agent, {:display_message_saved, _}}

      # Server still alive after the failure
      assert is_map(AgentServer.get_state(agent_id))

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "logs and continues when persistence callback raises" do
      agent_id = TestingHelpers.generate_test_agent_id()

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-raise",
          display_message_persistence: Forwarder
        )

      Forwarder.set_synthetic_response(:raise)

      :ok =
        AgentServer.save_synthetic_message_from(agent_id, %{
          message_type: "user",
          content_type: "text",
          content: %{"text" => "x"}
        })

      assert_receive {:saved_synthetic_message, _scope, _attrs, _context}, 200
      refute_received {:agent, {:display_message_saved, _}}

      assert is_map(AgentServer.get_state(agent_id))

      TestingHelpers.stop_test_agent(agent_id)
    end
  end
end
