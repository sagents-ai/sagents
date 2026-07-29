defmodule Sagents.AgentServerConversationIdTest do
  @moduledoc """
  The AgentServer stamps its `conversation_id` onto the `State` it hands to
  `Agent.execute/3`, which is what carries it into `LLMChain.custom_context` and
  onto the trace as `gen_ai.conversation.id`.

  Worth an integration test rather than a unit test because the value's whole
  journey is the point: it lives on `ServerState`, and `State` is replaced wholesale
  by each execute result, so anything written once at init would be silently dropped
  after the first turn.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer}
  alias Sagents.TestingHelpers
  alias LangChain.Message

  # Agent execution runs in a Task, so mocks must be global.
  setup :set_mimic_global

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  # Captures the state Agent.execute/3 was called with and completes normally.
  defp expect_execute_capturing(test_pid) do
    expect(Agent, :execute, fn _agent, state, _callbacks ->
      send(test_pid, {:executed_with, state})
      {:ok, state}
    end)
  end

  test "conversation_id from the server reaches the state passed to Agent.execute/3" do
    agent_id = TestingHelpers.generate_test_agent_id()
    expect_execute_capturing(self())

    {:ok, _session} =
      TestingHelpers.start_test_agent(
        agent_id: agent_id,
        pubsub: {Phoenix.PubSub, :test_pubsub},
        conversation_id: "conv-abc"
      )

    :ok = AgentServer.add_message(agent_id, Message.new_user!("hi"))

    assert_receive {:executed_with, state}, 500
    assert state.conversation_id == "conv-abc"

    TestingHelpers.stop_test_agent(agent_id)
  end

  test "is nil when the server was started without a conversation" do
    agent_id = TestingHelpers.generate_test_agent_id()
    expect_execute_capturing(self())

    {:ok, _session} =
      TestingHelpers.start_test_agent(
        agent_id: agent_id,
        pubsub: {Phoenix.PubSub, :test_pubsub}
      )

    :ok = AgentServer.add_message(agent_id, Message.new_user!("hi"))

    assert_receive {:executed_with, state}, 500
    assert state.conversation_id == nil

    TestingHelpers.stop_test_agent(agent_id)
  end

  # The regression this guards: Agent.execute/3's result replaces server_state.state
  # wholesale. Stamping once at init would work for turn one and silently stop
  # working for every turn after it — the kind of bug that only shows up as missing
  # trace grouping on long conversations.
  test "is re-stamped on a later turn, not just the first" do
    agent_id = TestingHelpers.generate_test_agent_id()
    test_pid = self()

    expect(Agent, :execute, 2, fn _agent, state, _callbacks ->
      send(test_pid, {:executed_with, state})
      # Return a state with the field cleared, imitating any path that rebuilds
      # State without carrying the virtual field across.
      {:ok, %{state | conversation_id: nil}}
    end)

    {:ok, _session} =
      TestingHelpers.start_test_agent(
        agent_id: agent_id,
        pubsub: {Phoenix.PubSub, :test_pubsub},
        conversation_id: "conv-xyz"
      )

    :ok = AgentServer.add_message(agent_id, Message.new_user!("first"))
    assert_receive {:executed_with, first}, 500
    assert first.conversation_id == "conv-xyz"

    :ok = AgentServer.add_message(agent_id, Message.new_user!("second"))
    assert_receive {:executed_with, second}, 500
    assert second.conversation_id == "conv-xyz"

    TestingHelpers.stop_test_agent(agent_id)
  end
end
