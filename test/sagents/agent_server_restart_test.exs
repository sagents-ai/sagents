defmodule Sagents.AgentServerRestartTest do
  @moduledoc """
  Every start of an AgentServer, including a restart by its supervisor, boots
  from the conversation as it is persisted now, and an answer carried into the
  boot is applied only to the interrupt it answers.

  The supervisor restarts a crashed AgentServer from the child spec it was
  first started with. Nothing captured in that spec may stand in for the
  conversation: it is the conversation as it was when the supervisor started.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, AgentSupervisor, State}
  alias Sagents.Persistence.StateSerializer
  alias Sagents.TestStoredPersistence, as: StoredPersistence
  alias LangChain.Message
  alias LangChain.Message.{ToolCall, ToolResult}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  setup do
    StoredPersistence.setup()
    Process.flag(:trap_exit, true)
    :ok
  end

  defp question_state(call_id) do
    State.new!(%{
      messages: [
        Message.new_user!("hi"),
        Message.new_assistant!(%{
          tool_calls: [ToolCall.new!(%{call_id: call_id, name: "ask_user", arguments: %{}})]
        }),
        Message.new_tool_result!(%{
          content: nil,
          tool_results: [
            ToolResult.new!(%{
              tool_call_id: call_id,
              name: "ask_user",
              content: "Waiting for user...",
              is_interrupt: true,
              interrupt_data: %{type: :ask_user_question, question: "Continue?"}
            })
          ]
        })
      ]
    })
  end

  defp start_supervisor(agent, opts) do
    {:ok, sup} =
      AgentSupervisor.start_link_sync(
        [
          name: AgentSupervisor.get_name(agent.agent_id),
          agent: agent,
          conversation_id: "conv-#{agent.agent_id}",
          agent_persistence: StoredPersistence
        ] ++ opts
      )

    sup
  end

  defp restart_agent_server(agent_id) do
    {:ok, old_pid} = AgentServer.fetch_pid(agent_id)
    Process.exit(old_pid, :kill)

    wait_until(fn ->
      match?({:ok, pid} when pid != old_pid, AgentServer.fetch_pid(agent_id))
    end)

    :ok
  end

  defp message_count(state_data) do
    {:ok, state} = StateSerializer.deserialize_state("any", state_data["state"])
    length(state.messages)
  end

  describe "restart" do
    test "a restarted AgentServer boots from the latest persisted state, not its child spec" do
      stub(Agent, :execute, fn _agent, state, _opts ->
        {:ok, State.add_message(state, Message.new_assistant!("reply"))}
      end)

      agent = create_test_agent()
      agent_id = agent.agent_id

      sup =
        start_supervisor(agent,
          initial_state: State.new!(%{messages: [Message.new_user!("first")]})
        )

      # Subscribing delivers a status snapshot first, so wait for the run to
      # start before waiting for it to finish.
      {:ok, _server, _ref} = AgentServer.subscribe(agent_id)
      assert_receive {:agent, {:status_changed, :idle, _}}, 1_000
      :ok = AgentServer.add_message(agent_id, Message.new_user!("second"))
      assert_receive {:agent, {:status_changed, :running, _}}, 2_000
      assert_receive {:agent, {:status_changed, :idle, _}}, 2_000
      latest = length(AgentServer.get_state(agent_id).messages)
      assert latest > 1

      restart_agent_server(agent_id)
      assert length(AgentServer.get_state(agent_id).messages) == latest

      # And the shutdown write is the latest conversation, not the spec's.
      Supervisor.stop(sup)
      {:on_shutdown, written} = List.last(StoredPersistence.writes(agent_id))
      assert message_count(written) == latest
    end

    test "a load that fails fails the start and overwrites nothing" do
      agent = create_test_agent()
      StoredPersistence.fail_loads(:database_unavailable)

      assert {:error, {:load_failed, :database_unavailable}} =
               AgentServer.start_link(
                 agent: agent,
                 name: AgentServer.get_name(agent.agent_id),
                 agent_persistence: StoredPersistence,
                 initial_state: State.new!()
               )

      assert StoredPersistence.writes(agent.agent_id) == []
    end
  end

  describe "pending resume" do
    test "is applied once; a restart after the resumed run finished does not apply it again" do
      test_pid = self()

      stub(Agent, :resume, fn _agent, state, _data, _opts ->
        send(test_pid, {:resumed, self()})
        answered = State.cancel_pending_interrupts(state)
        {:ok, State.add_message(answered, Message.new_assistant!("thanks"))}
      end)

      agent = create_test_agent(middleware: [Sagents.Middleware.AskUserQuestion])
      agent_id = agent.agent_id
      StoredPersistence.store(agent_id, question_state("call_1"))

      start_supervisor(agent,
        pending_resume: %{type: :answer, selected: ["yes"]},
        pending_resume_for: ["call_1"]
      )

      assert_receive {:resumed, _task}, 1_000
      assert wait_until(fn -> AgentServer.get_status(agent_id) == :idle end)

      restart_agent_server(agent_id)
      assert AgentServer.get_status(agent_id) == :idle
      refute_receive {:resumed, _task}, 200
    end

    test "an answer for a different interrupt is discarded, and the pending one stays open" do
      Agent
      |> reject(:resume, 4)

      agent = create_test_agent(middleware: [Sagents.Middleware.AskUserQuestion])
      agent_id = agent.agent_id

      # The answer was given for call_1; since then the conversation moved on
      # and is waiting on call_2.
      StoredPersistence.store(agent_id, question_state("call_2"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervisor(agent,
            pending_resume: %{type: :answer, selected: ["yes"]},
            pending_resume_for: ["call_1"]
          )

          assert AgentServer.get_status(agent_id) == :interrupted
        end)

      assert log =~ "no longer pending"
    end
  end
end
