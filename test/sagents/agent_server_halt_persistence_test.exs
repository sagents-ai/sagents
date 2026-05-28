defmodule Sagents.AgentServerHaltPersistenceTest do
  @moduledoc """
  Integration tests for the `:halt` interrupt's automatic synthetic
  assistant-message persistence.

  When a tool emits a `:halt` interrupt, `AgentServer.handle_execution_result/2`
  saves the halt's `:message` field as a synthetic assistant display
  message so the user's recommended-actions text survives banner
  dismissal, follow-up turns, and page reload. These tests exercise
  that path end-to-end by mocking `Sagents.Agent.execute/3` to return
  the desired `{:interrupt, state, halt_data}` shape and asserting on
  the `DisplayMessagePersistence` callback + the broadcast.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, State}
  alias Sagents.TestDisplayMessagePersistenceForwarding, as: Forwarder
  alias Sagents.TestingHelpers
  alias LangChain.Message

  # Make mocks global since agent execution happens in a Task
  setup :set_mimic_global

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  setup do
    Forwarder.register_test_process(self())
    Forwarder.clear_synthetic_response()
    on_exit(fn -> Forwarder.clear_synthetic_response() end)
    :ok
  end

  defp expect_halt_interrupt(halt_data) do
    expect(Agent, :execute, fn _agent, state, _callbacks ->
      {:interrupt, state, halt_data}
    end)
  end

  describe ":halt interrupt persists as synthetic assistant message" do
    test "saves message_type=assistant, content_type=text with halt's :message text" do
      agent_id = TestingHelpers.generate_test_agent_id()
      conversation_id = "conv-halt-1"

      halt_text = "Subdivide the outline before drafting — add H2/H3 headers."

      halt = %{
        type: :halt,
        message: halt_text,
        source_tool: "scout_outline",
        tool_call_id: "call_42"
      }

      expect_halt_interrupt(halt)

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: conversation_id,
          display_message_persistence: Forwarder
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("scout the outline"))

      # The Forwarder receives the synthetic-message save with the halt's text.
      assert_receive {:saved_synthetic_message, _scope, attrs, context}, 500
      assert attrs.message_type == "assistant"
      assert attrs.content_type == "text"
      assert attrs.content == %{"text" => halt_text}
      assert context.agent_id == agent_id
      assert context.conversation_id == conversation_id

      # And the broadcast fires for any subscribed LiveView.
      assert_receive {:agent, {:display_message_saved, %{attrs: ^attrs}}}, 500

      # Sanity: the agent is in the :interrupted state with the halt as the
      # interrupt_data.
      assert AgentServer.get_status(agent_id) == :interrupted

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "does not persist when halt :message is nil" do
      agent_id = TestingHelpers.generate_test_agent_id()

      halt = %{type: :halt, message: nil, source_tool: "scout"}
      expect_halt_interrupt(halt)

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-halt-nil",
          display_message_persistence: Forwarder
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))

      # Wait for execution to settle by polling status (Forwarder send is sync,
      # so if a save HAD fired we'd already have the message).
      assert_receive {:agent, {:status_changed, :interrupted, _}}, 500

      refute_received {:saved_synthetic_message, _, _, _}

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "does not persist when halt :message is empty string" do
      agent_id = TestingHelpers.generate_test_agent_id()

      halt = %{type: :halt, message: "", source_tool: "scout"}
      expect_halt_interrupt(halt)

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-halt-empty",
          display_message_persistence: Forwarder
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))

      assert_receive {:agent, {:status_changed, :interrupted, _}}, 500
      refute_received {:saved_synthetic_message, _, _, _}

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "no-op when display_message_persistence is not configured" do
      agent_id = TestingHelpers.generate_test_agent_id()

      halt = %{type: :halt, message: "stop", source_tool: "scout"}
      expect_halt_interrupt(halt)

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-no-persistence"
          # no display_message_persistence
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))

      # Server still alive and interrupts correctly.
      assert_receive {:agent, {:status_changed, :interrupted, %{type: :halt}}}, 500
      refute_received {:saved_synthetic_message, _, _, _}
      refute_received {:agent, {:display_message_saved, _}}

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "no-op when conversation_id is not configured" do
      agent_id = TestingHelpers.generate_test_agent_id()

      halt = %{type: :halt, message: "stop", source_tool: "scout"}
      expect_halt_interrupt(halt)

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          display_message_persistence: Forwarder
          # no conversation_id
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))

      assert_receive {:agent, {:status_changed, :interrupted, %{type: :halt}}}, 500
      refute_received {:saved_synthetic_message, _, _, _}

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "persists one synthetic message per halt inside :multiple_interrupts" do
      agent_id = TestingHelpers.generate_test_agent_id()

      halt_a = %{type: :halt, message: "halt A", source_tool: "scout_a"}
      halt_b = %{type: :halt, message: "halt B", source_tool: "scout_b"}
      question = %{type: :ask_user_question, question: "?"}

      data = %{
        type: :multiple_interrupts,
        interrupts: [halt_a, question, halt_b]
      }

      expect_halt_interrupt(data)

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-multi-halt",
          display_message_persistence: Forwarder
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))

      assert_receive {:saved_synthetic_message, _s1, %{content: %{"text" => "halt A"}}, _c1}, 500

      assert_receive {:saved_synthetic_message, _s2, %{content: %{"text" => "halt B"}}, _c2}, 500

      # The sibling question does NOT get persisted via this path.
      refute_received {:saved_synthetic_message, _, %{content: %{"text" => "?"}}, _}

      TestingHelpers.stop_test_agent(agent_id)
    end

    test "non-halt interrupts do not trigger halt persistence" do
      agent_id = TestingHelpers.generate_test_agent_id()

      question = %{
        type: :ask_user_question,
        question: "Which DB?",
        response_type: :single_select,
        options: [],
        allow_other: false,
        allow_cancel: true,
        tool_call_id: "call_q"
      }

      expect(Agent, :execute, fn _agent, state, _callbacks ->
        {:interrupt, state, question}
      end)

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-question",
          display_message_persistence: Forwarder
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("ask me"))

      assert_receive {:agent, {:status_changed, :interrupted, %{type: :ask_user_question}}}, 500
      refute_received {:saved_synthetic_message, _, _, _}

      TestingHelpers.stop_test_agent(agent_id)
    end
  end

  describe "halt persistence survives cancellation" do
    test "synthetic assistant message remains in transcript after cancel_pending_interrupts" do
      agent_id = TestingHelpers.generate_test_agent_id()

      halt_text = "Use H3 headers to split this scene."

      halt = %{
        type: :halt,
        message: halt_text,
        source_tool: "scout_outline",
        tool_call_id: "call_persist_1"
      }

      # On the first execution, return the halt. On the second (after the
      # user sends a new message and the agent transitions to :idle and
      # re-executes), return a successful completion so the test doesn't
      # hang waiting for further interrupts.
      expect(Agent, :execute, fn _agent, state, _callbacks ->
        {:interrupt, state, halt}
      end)

      expect(Agent, :execute, fn _agent, _state, _callbacks ->
        {:ok, State.new!()}
      end)

      {:ok, %{agent_id: ^agent_id}} =
        TestingHelpers.start_test_agent(
          agent_id: agent_id,
          pubsub: {Phoenix.PubSub, :test_pubsub},
          conversation_id: "conv-cancel-halt",
          display_message_persistence: Forwarder
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("scout"))

      # Halt fires → synthetic message persisted.
      assert_receive {:saved_synthetic_message, _scope, attrs, _context}, 500
      assert attrs.content == %{"text" => halt_text}

      # User moves on: send a follow-up. AgentServer demotes the interrupt
      # via cancel_pending_interrupts and transitions to :idle. The synthetic
      # message was already persisted by the prior step and is NOT undone.
      :ok = AgentServer.add_message(agent_id, Message.new_user!("ok, will fix"))

      # No second persistence call for the halt (it only fires at emit time).
      refute_received {:saved_synthetic_message, _, %{content: %{"text" => ^halt_text}}, _},
                      "halt's transcript entry must not be re-persisted on follow-up"

      TestingHelpers.stop_test_agent(agent_id)
    end
  end
end
