defmodule Sagents.AgentServerDormantInterruptTest do
  @moduledoc """
  Covers what happens to an open interrupt when the agent process goes away.

  Interrupts are durable: `interrupt_data` is persisted with the state, and
  `derive_boot_status/1` rebuilds it on the next boot. So an agent that naps
  while a human is composing an answer has not lost anything. The two pieces
  that make that usable to a host are exercised here:

  1. The `{:agent_shutdown, _}` event reports whether the pending interrupt can
     be rebuilt (`:interrupt_restorable`), which is the only signal a host needs
     to decide whether to leave the prompt on screen. It is answered *here*
     rather than by the host because this is the only place that has both the
     interrupt payload and the agent's middleware in scope.

  2. `:pending_resume` lets an answer submitted against a dead agent ride into
     the boot, so the woken server applies it before it broadcasts anything.
     Subscribers see one `:running` event, not an `:interrupted` snapshot for a
     question that is already answered.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, State}
  alias LangChain.Message
  alias LangChain.Message.{ToolCall, ToolResult}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  # A state whose trailing tool message carries interrupted tool results, which
  # is what derive_boot_status/1 scans for.
  defp interrupted_state(entries) do
    tool_calls =
      Enum.map(entries, fn {call_id, _data} ->
        ToolCall.new!(%{call_id: call_id, name: "ask_user", arguments: %{}})
      end)

    tool_results =
      Enum.map(entries, fn {call_id, data} ->
        ToolResult.new!(%{
          tool_call_id: call_id,
          name: "ask_user",
          content: "Waiting for user...",
          is_interrupt: true,
          interrupt_data: data
        })
      end)

    State.new!(%{
      messages: [
        Message.new_user!("hi"),
        Message.new_assistant!(%{tool_calls: tool_calls}),
        Message.new_tool_result!(%{content: nil, tool_results: tool_results})
      ]
    })
  end

  defp question_state(data \\ %{type: :ask_user_question, question: "Continue?"}) do
    interrupted_state([{"call_1", data}])
  end

  defp ask_agent(opts \\ []) do
    create_test_agent(Keyword.merge([middleware: [Sagents.Middleware.AskUserQuestion]], opts))
  end

  defp start_server(agent, opts) do
    {:ok, pid} =
      AgentServer.start_link(
        [
          agent: agent,
          name: AgentServer.get_name(agent.agent_id),
          pubsub: nil
        ] ++ opts
      )

    pid
  end

  # ── Shutdown payload ─────────────────────────────────────────────

  describe "{:agent_shutdown, _} payload" do
    @payload_keys [
      :agent_id,
      :interrupt_restorable,
      :last_activity_at,
      :reason,
      :shutdown_at,
      :status
    ]

    test "the inactivity timer emits the documented shape" do
      agent = ask_agent()

      start_server(agent,
        initial_state: State.new!(),
        inactivity_timeout: 30,
        initial_subscribers: [{:main, self()}]
      )

      assert_receive {:agent, {:agent_shutdown, payload}}, 500

      assert Enum.sort(Map.keys(payload)) == @payload_keys
      assert payload.agent_id == agent.agent_id
      assert payload.reason == :inactivity
    end

    test "terminate/2 emits the same shape, not a two-key variant" do
      # A single shutdown delivers this event more than once, from different
      # sites. Hosts must not need a clause per site.
      agent = ask_agent()

      pid =
        start_server(agent,
          initial_state: State.new!(),
          initial_subscribers: [{:main, self()}]
        )

      :ok = GenServer.stop(pid, :normal)

      assert_receive {:agent, {:agent_shutdown, payload}}, 500

      assert Enum.sort(Map.keys(payload)) == @payload_keys
      # The old terminate/2 payload omitted agent_id, which is the one field a
      # host needs in order to correlate the event.
      assert payload.agent_id == agent.agent_id
      assert payload.reason == :normal
    end

    test "reports interrupt_restorable: true for a question the next boot can rebuild" do
      agent = ask_agent()

      start_server(agent,
        initial_state: question_state(),
        inactivity_timeout: 30,
        initial_subscribers: [{:main, self()}]
      )

      assert_receive {:agent, {:agent_shutdown, payload}}, 500
      assert payload.status == :interrupted
      assert payload.interrupt_restorable == true
    end

    test "reports interrupt_restorable: false when no middleware claims the interrupt" do
      # Same interrupt, but the agent has no AskUserQuestion middleware, so
      # clean_stale_interrupts/2 would demote it on the next boot. Telling the
      # host to keep the prompt would offer an answer no agent could accept.
      agent = create_test_agent(middleware: [])

      start_server(agent,
        initial_state: question_state(),
        inactivity_timeout: 30,
        initial_subscribers: [{:main, self()}]
      )

      assert_receive {:agent, {:agent_shutdown, payload}}, 500
      assert payload.interrupt_restorable == false
    end

    test "reports interrupt_restorable: false for a sub-agent approval" do
      agent =
        create_test_agent(
          middleware: [
            Sagents.Middleware.AskUserQuestion,
            Sagents.Middleware.HumanInTheLoop
          ]
        )

      state = interrupted_state([{"call_1", %{type: :subagent_hitl, sub_agent_id: "sa-1"}}])

      start_server(agent,
        initial_state: state,
        inactivity_timeout: 30,
        initial_subscribers: [{:main, self()}]
      )

      assert_receive {:agent, {:agent_shutdown, payload}}, 500
      assert payload.status == :interrupted
      assert payload.interrupt_restorable == false
    end

    test "reports interrupt_restorable: false when there is no interrupt at all" do
      agent = ask_agent()

      start_server(agent,
        initial_state: State.new!(),
        inactivity_timeout: 30,
        initial_subscribers: [{:main, self()}]
      )

      assert_receive {:agent, {:agent_shutdown, payload}}, 500
      assert payload.status == :idle
      assert payload.interrupt_restorable == false
    end
  end

  # ── :pending_resume ──────────────────────────────────────────────

  describe ":pending_resume on boot" do
    test "applies the answer and broadcasts :running, never :interrupted" do
      test_pid = self()

      Agent
      |> expect(:resume, fn _agent, state, resume_data, _opts ->
        send(test_pid, {:resumed_with, resume_data})
        {:ok, state}
      end)

      agent = ask_agent()

      start_server(agent,
        initial_state: question_state(),
        initial_subscribers: [{:main, self()}],
        pending_resume: %{type: :answer, selected: ["yes"]}
      )

      assert_receive {:resumed_with, %{type: :answer, selected: ["yes"]}}, 1_000

      # The whole point: the one boot broadcast reports the status this server
      # genuinely has. A subscriber must never be told to re-present a question
      # that is already answered.
      assert_receive {:agent, {:status_changed, :running, nil}}, 1_000
      refute_received {:agent, {:status_changed, :interrupted, _}}
    end

    test "a subscriber that arrives later snapshots :running, not :interrupted" do
      test_pid = self()

      Agent
      |> stub(:resume, fn _agent, state, _resume_data, _opts ->
        send(test_pid, :resumed)

        receive do
          :finish -> {:ok, state}
        after
          2_000 -> {:ok, state}
        end
      end)

      agent = ask_agent()
      agent_id = agent.agent_id

      start_server(agent,
        initial_state: question_state(),
        pending_resume: %{type: :answer, selected: ["yes"]}
      )

      assert_receive :resumed, 1_000

      # A second tab subscribing mid-resume gets the on_subscribed snapshot.
      task =
        Task.async(fn ->
          {:ok, _pid, _ref} = AgentServer.subscribe(agent_id)

          receive do
            {:agent, {:status_changed, status, _data}} -> status
          after
            1_000 -> :timeout
          end
        end)

      assert Task.await(task, 2_000) == :running
    end

    test "is discarded with the honest status when the boot is not interrupted" do
      # The interrupt was answered from another tab (or demoted) before this
      # boot. Applying the stale answer to whatever the agent is doing now would
      # be far worse than dropping it.
      Agent
      |> reject(:resume, 4)

      agent = ask_agent()

      start_server(agent,
        initial_state: State.new!(%{messages: [Message.new_user!("hi")]}),
        initial_subscribers: [{:main, self()}],
        pending_resume: %{type: :answer, selected: ["yes"]}
      )

      assert_receive {:agent, {:status_changed, :idle, nil}}, 1_000
    end

    test "is discarded when the interrupt is not restorable by this agent's middleware" do
      # No AskUserQuestion, so clean_stale_interrupts/2 demotes the tool result
      # and the boot lands :idle rather than :interrupted.
      Agent
      |> reject(:resume, 4)

      agent = create_test_agent(middleware: [])

      state =
        State.clean_stale_interrupts(
          interrupted_state([{"call_1", %{type: :subagent_hitl, sub_agent_id: "sa-1"}}]),
          agent.middleware
        )

      start_server(agent,
        initial_state: state,
        initial_subscribers: [{:main, self()}],
        pending_resume: %{type: :answer, selected: ["yes"]}
      )

      assert_receive {:agent, {:status_changed, :idle, nil}}, 1_000
    end

    test "a boot without :pending_resume still broadcasts the restored :interrupted" do
      # Guard against over-reach: the boot snapshot is how every subscriber
      # learns current state, and it must keep firing for an ordinary wake.
      data = %{type: :ask_user_question, question: "Continue?"}
      enriched = Map.put(data, :tool_call_id, "call_1")

      start_server(ask_agent(),
        initial_state: question_state(data),
        initial_subscribers: [{:main, self()}]
      )

      assert_receive {:agent, {:status_changed, :interrupted, ^enriched}}, 500
    end
  end

  # ── Dismissing a halt that was rebuilt at boot ───────────────────

  describe "dismiss_interrupt/1 against a restored halt" do
    # `Sagents.Session.dismiss/3` wakes a sleeping agent and then immediately
    # dismisses against whatever `init/1` rebuilt. That only works if a halt
    # survives the round trip in a shape `dismiss_interrupt/1` still recognizes
    # as a halt. If it did not, the wake would succeed and the dismissal would
    # fail, leaving the panel stuck with no signal to the host.
    defp halt_state(data \\ %{type: :halt, message: "Blocked by policy"}) do
      interrupted_state([{"call_1", data}])
    end

    test "a restored halt boots :interrupted and is then dismissible" do
      agent = create_test_agent(middleware: [Sagents.Middleware.Haltable])

      start_server(agent,
        initial_state: halt_state(),
        initial_subscribers: [{:main, self()}]
      )

      assert_receive {:agent, {:status_changed, :interrupted, %{type: :halt}}}, 500

      assert :ok = AgentServer.dismiss_interrupt(agent.agent_id)
      assert_receive {:agent, {:status_changed, :idle, nil}}, 500
      assert AgentServer.get_status(agent.agent_id) == :idle
    end

    test "a restored question is not dismissible and says so" do
      # The other half of the contract Session.dismiss/3 relies on: an interrupt
      # needing a real response must refuse, so dismiss/3 can pass the error
      # through instead of waking an agent that will refuse again.
      agent = ask_agent()

      start_server(agent,
        initial_state: question_state(),
        initial_subscribers: [{:main, self()}]
      )

      agent_id = agent.agent_id
      assert AgentServer.get_status(agent_id) == :interrupted

      assert {:error, "interrupt requires explicit response (use resume)"} =
               AgentServer.dismiss_interrupt(agent_id)

      assert AgentServer.get_status(agent_id) == :interrupted
    end
  end
end
