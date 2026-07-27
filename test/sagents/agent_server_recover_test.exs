defmodule Sagents.AgentServerRecoverTest do
  @moduledoc """
  Recovering an errored AgentServer without discarding the conversation.

  A run that fails partway through leaves the server in `:error`, where
  `execute/1` refuses. Before `recover/1` the only way out was `reset/1`,
  which clears the whole message log — so a transient provider fault cost the
  conversation. These tests drive a real failing execution and assert what the
  recovery leaves behind.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, State}
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  setup do
    agent = create_test_agent()
    {:ok, agent: agent, agent_id: agent.agent_id}
  end

  defp start_server(agent, messages) do
    {:ok, _pid} =
      AgentServer.start_link(
        agent: agent,
        initial_state: State.new!(%{messages: messages}),
        name: AgentServer.get_name(agent.agent_id),
        pubsub: nil
      )

    :ok
  end

  # Fails the run the way a provider fault does: the model's tool-call message
  # has already been appended to the live state through the turn-update cast,
  # and then the execution answers an error.
  defp fail_mid_turn(agent, unanswered_call) do
    Agent
    |> expect(:execute, fn ^agent, _state, _opts ->
      server = AgentServer.get_name(agent.agent_id)
      seq = :sys.get_state(GenServer.whereis(server)).execution_seq

      GenServer.cast(server, {:turn_state_update, seq, unanswered_call})

      # The cast lands in the server's mailbox before the task's result does,
      # so the message is in the live state by the time the failure is handled.
      {:error, "rate_limit_error: 429"}
    end)
  end

  defp assistant_calling(name) do
    Message.new_assistant!(%{
      content: nil,
      tool_calls: [
        ToolCall.new!(%{type: :function, call_id: "call-#{name}", name: name, arguments: "{}"})
      ]
    })
  end

  defp tool_answering(name) do
    Message.new_tool_result!(%{
      tool_results: [
        ToolResult.new!(%{
          type: :function,
          tool_call_id: "call-#{name}",
          name: name,
          content: "ok"
        })
      ]
    })
  end

  describe "recover/1 from an errored run" do
    test "returns the server to idle and preserves the failure reason", %{
      agent: agent,
      agent_id: agent_id
    } do
      start_server(agent, [Message.new_user!("Read the ledger")])
      fail_mid_turn(agent, assistant_calling("read_ledger"))

      assert :ok = AgentServer.execute(agent_id)
      Process.sleep(50)
      assert AgentServer.get_status(agent_id) == :error

      assert {:ok, %{reason: "rate_limit_error: 429", dropped: 1}} =
               AgentServer.recover(agent_id)

      assert AgentServer.get_status(agent_id) == :idle
      assert AgentServer.get_info(agent_id).error == nil
    end

    test "trims the unanswered tool call and keeps everything before it", %{
      agent: agent,
      agent_id: agent_id
    } do
      history = [
        Message.new_user!("Read the ledger"),
        assistant_calling("read_ledger"),
        tool_answering("read_ledger"),
        Message.new_assistant!("41 rows."),
        Message.new_user!("Export it")
      ]

      start_server(agent, history)
      fail_mid_turn(agent, assistant_calling("export"))

      assert :ok = AgentServer.execute(agent_id)
      Process.sleep(50)

      assert {:ok, %{dropped: 1}} = AgentServer.recover(agent_id)

      assert AgentServer.get_state(agent_id).messages == history
    end

    test "keeps the log untouched when the failure landed on a well-formed boundary", %{
      agent: agent,
      agent_id: agent_id
    } do
      history = [Message.new_user!("Read the ledger")]
      start_server(agent, history)

      Agent
      |> expect(:execute, fn ^agent, _state, _opts -> {:error, "connection refused"} end)

      assert :ok = AgentServer.execute(agent_id)
      Process.sleep(50)

      assert {:ok, %{reason: "connection refused", dropped: 0}} = AgentServer.recover(agent_id)
      assert AgentServer.get_state(agent_id).messages == history
    end

    test "the next execution runs, which is the whole point", %{agent: agent, agent_id: agent_id} do
      start_server(agent, [Message.new_user!("Read the ledger")])
      fail_mid_turn(agent, assistant_calling("read_ledger"))

      assert :ok = AgentServer.execute(agent_id)
      Process.sleep(50)
      assert {:error, _refused} = AgentServer.execute(agent_id)

      assert {:ok, _info} = AgentServer.recover(agent_id)

      Agent
      |> expect(:execute, fn ^agent, state, _opts ->
        {:ok, State.add_message(state, Message.new_assistant!("41 rows."))}
      end)

      assert :ok = AgentServer.execute(agent_id)
      Process.sleep(50)

      assert AgentServer.get_status(agent_id) == :idle

      assert %Message{role: :assistant, content: [%{content: "41 rows."}]} =
               List.last(AgentServer.get_state(agent_id).messages)
    end

    test "broadcasts the transition to idle", %{agent: agent, agent_id: agent_id} do
      start_server(agent, [Message.new_user!("Read the ledger")])
      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id)

      fail_mid_turn(agent, assistant_calling("read_ledger"))

      assert :ok = AgentServer.execute(agent_id)
      assert_receive {:agent, {:status_changed, :error, "rate_limit_error: 429"}}, 500

      assert {:ok, _info} = AgentServer.recover(agent_id)
      assert_receive {:agent, {:status_changed, :idle, nil}}, 500
    end

    test "is refused when the server is not in error", %{agent: agent, agent_id: agent_id} do
      start_server(agent, [])

      assert {:error, message} = AgentServer.recover(agent_id)
      assert message =~ "status: idle"
    end
  end

  describe "State.trim_unfinished_turn/1" do
    test "drops an assistant message whose tool calls were never answered" do
      state = State.new!(%{messages: [Message.new_user!("Go"), assistant_calling("read")]})

      assert {trimmed, 1} = State.trim_unfinished_turn(state)
      assert Enum.map(trimmed.messages, & &1.role) == [:user]
    end

    test "drops a partially answered batch whole" do
      calls =
        Message.new_assistant!(%{
          content: nil,
          tool_calls: [
            ToolCall.new!(%{type: :function, call_id: "call-a", name: "a", arguments: "{}"}),
            ToolCall.new!(%{type: :function, call_id: "call-b", name: "b", arguments: "{}"})
          ]
        })

      answer_a =
        Message.new_tool_result!(%{
          tool_results: [
            ToolResult.new!(%{type: :function, tool_call_id: "call-a", name: "a", content: "ok"})
          ]
        })

      state = State.new!(%{messages: [Message.new_user!("Go"), calls, answer_a]})

      # `call-b` has no result, so the assistant message is unmatched and the
      # result that did land goes with it — a lone tool result answering a call
      # that is no longer in the log is exactly the shape being removed.
      assert {trimmed, 2} = State.trim_unfinished_turn(state)
      assert Enum.map(trimmed.messages, & &1.role) == [:user]
    end

    test "leaves a well-formed log alone" do
      messages = [
        Message.new_user!("Go"),
        assistant_calling("read"),
        tool_answering("read"),
        Message.new_assistant!("Done.")
      ]

      state = State.new!(%{messages: messages})

      assert {trimmed, 0} = State.trim_unfinished_turn(state)
      assert trimmed.messages == messages
    end

    test "is idempotent" do
      state = State.new!(%{messages: [Message.new_user!("Go"), assistant_calling("read")]})

      {once, 1} = State.trim_unfinished_turn(state)
      assert {^once, 0} = State.trim_unfinished_turn(once)
    end

    test "keeps a trailing user message, which a provider accepts" do
      messages = [
        Message.new_user!("Go"),
        Message.new_assistant!("Sure."),
        Message.new_user!("More")
      ]

      state = State.new!(%{messages: messages})

      assert {trimmed, 0} = State.trim_unfinished_turn(state)
      assert trimmed.messages == messages
    end

    test "answers an empty log unchanged" do
      assert {%State{messages: []}, 0} = State.trim_unfinished_turn(State.new!(%{}))
    end
  end
end
