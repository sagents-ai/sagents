defmodule Sagents.AgentServerInactivityTest do
  @moduledoc """
  What the inactivity timer counts and when it stops an agent.

  The timer never stops a running turn; it re-arms instead, without recording
  activity. An idle or interrupted agent stops once the timeout passes with no
  activity. Events the agent publishes, including tool progress, are activity;
  debug events and middleware messages are not.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, AgentSupervisor, State}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.{Function, Message}
  alias LangChain.Message.ToolCall

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  @timeout 50

  # Starts an agent under a real AgentSupervisor, so an inactivity stop takes
  # the whole tree down the way it does in production. Returns the supervisor
  # pid, monitored by the caller.
  defp start_agent(agent, opts \\ []) do
    {:ok, sup_pid} =
      AgentSupervisor.start_link_sync(
        Keyword.merge(
          [
            agent: agent,
            name: AgentSupervisor.get_name(agent.agent_id),
            inactivity_timeout: @timeout,
            initial_state: State.new!(%{messages: [Message.new_user!("Hello")]}),
            initial_subscribers: [{:main, self()}]
          ],
          opts
        )
      )

    # The test process must outlive a tree it watches stop.
    Process.unlink(sup_pid)
    assert_receive {:agent, {:status_changed, :idle, nil}}, 500
    sup_pid
  end

  # A process that calls `fun` every few milliseconds until killed.
  defp spawn_repeating(fun) do
    spawn(fn -> repeat(fun) end)
  end

  defp repeat(fun) do
    fun.()

    receive do
    after
      5 -> repeat(fun)
    end
  end

  # An execution that reports it started and then waits for the test to let
  # it finish, so the test decides how long the turn runs.
  defp expect_blocking_execute(test_pid) do
    expect(Agent, :execute, fn _agent, state, _opts ->
      send(test_pid, {:executing, self()})

      receive do
        :finish -> {:ok, state}
      end
    end)
  end

  describe "a running turn" do
    test "is not stopped by the timeout, and the agent stops once idle" do
      agent = create_test_agent()
      expect_blocking_execute(self())
      sup_pid = start_agent(agent)
      sup_ref = Process.monitor(sup_pid)

      :ok = AgentServer.execute(agent.agent_id)
      assert_receive {:executing, task_pid}

      # Several timeout periods pass while the turn runs.
      refute_receive {:DOWN, ^sup_ref, _, _, _}, @timeout * 5
      assert AgentServer.get_status(agent.agent_id) == :running
      assert AgentServer.get_inactivity_status(agent.agent_id).timer_active

      send(task_pid, :finish)
      assert_receive {:agent, {:status_changed, :idle, nil}}, 500

      # Idle, the agent stops once the timeout passes.
      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, @timeout * 10
    end

    test "re-arming does not count as activity" do
      agent = create_test_agent()
      expect_blocking_execute(self())
      sup_pid = start_agent(agent)

      :ok = AgentServer.execute(agent.agent_id)
      assert_receive {:executing, task_pid}

      before = AgentServer.get_inactivity_status(agent.agent_id).last_activity_at

      # Let the timer fire and re-arm several times.
      refute_receive :unexpected, @timeout * 4

      assert AgentServer.get_inactivity_status(agent.agent_id).last_activity_at == before

      send(task_pid, :finish)
      assert_receive {:agent, {:status_changed, :idle, nil}}, 500
      Supervisor.stop(sup_pid)
    end
  end

  describe "published events" do
    test "count as activity and keep an idle agent alive" do
      agent = create_test_agent()
      sup_pid = start_agent(agent)
      sup_ref = Process.monitor(sup_pid)

      # Publishing at half the timeout carries the agent well past it.
      for _round <- 1..6 do
        :ok = AgentServer.publish_event_from(agent.agent_id, {:custom_event, :tick})
        refute_receive {:DOWN, ^sup_ref, _, _, _}, div(@timeout, 2)
      end

      # Once publishing stops, the agent stops.
      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, @timeout * 10
    end

    test "debug events do not count as activity" do
      agent = create_test_agent()
      sup_pid = start_agent(agent)
      sup_ref = Process.monitor(sup_pid)

      publisher =
        spawn_repeating(fn -> AgentServer.publish_debug_event_from(agent.agent_id, :tick) end)

      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, @timeout * 10
      Process.exit(publisher, :kill)
    end

    @tag capture_log: true
    test "middleware messages do not count as activity" do
      agent = create_test_agent()
      sup_pid = start_agent(agent)
      sup_ref = Process.monitor(sup_pid)

      publisher =
        spawn_repeating(fn -> AgentServer.notify_middleware(agent.agent_id, :nobody, :tick) end)

      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, @timeout * 10
      Process.exit(publisher, :kill)
    end
  end

  describe "report_tool_progress/2" do
    test "reaches subscribers from inside a tool and counts as activity" do
      test_pid = self()

      tool =
        Function.new!(%{
          name: "bulk_tool",
          description: "Runs on several devices",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, context ->
            send(test_pid, {:tool_started, self()})

            receive do
              :report -> AgentServer.report_tool_progress(context, %{done: 1, total: 2})
            end

            receive do
              :finish -> {:ok, "Done"}
            end
          end
        })

      agent = create_test_agent(tools: [tool])

      expect(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             tool_calls: [ToolCall.new!(%{call_id: "call-1", name: "bulk_tool", arguments: %{}})]
           })
         ]}
      end)

      expect(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
        {:ok, [Message.new_assistant!("All done")]}
      end)

      sup_pid = start_agent(agent, inactivity_timeout: 10_000)
      :ok = AgentServer.execute(agent.agent_id)
      assert_receive {:tool_started, tool_pid}, 1_000

      before = AgentServer.get_inactivity_status(agent.agent_id).last_activity_at
      send(tool_pid, :report)

      assert_receive {:agent, {:tool_progress, "call-1", %{done: 1, total: 2}}}, 1_000

      # Unlike a re-arm, progress is activity.
      after_progress = AgentServer.get_inactivity_status(agent.agent_id).last_activity_at
      assert DateTime.compare(after_progress, before) == :gt

      send(tool_pid, :finish)
      assert_receive {:agent, {:status_changed, :idle, nil}}, 1_000
      Supervisor.stop(sup_pid)
    end

    test "does nothing without an agent_id in the context" do
      assert :ok = AgentServer.report_tool_progress(%{tool_call_id: "call-1"}, %{done: 1})
      assert :ok = AgentServer.report_tool_progress(nil, %{done: 1})
    end
  end

  describe "an agent that is not running" do
    test "an interrupted agent stops once the timeout passes" do
      agent = create_test_agent()

      interrupt_data = %{
        action_requests: [%{tool_name: "write_file", arguments: %{"path" => "a.txt"}}],
        review_configs: %{}
      }

      expect(Agent, :execute, fn _agent, state, _opts ->
        {:interrupt, state, interrupt_data}
      end)

      sup_pid = start_agent(agent)
      sup_ref = Process.monitor(sup_pid)

      :ok = AgentServer.execute(agent.agent_id)
      assert_receive {:agent, {:status_changed, :interrupted, _data}}, 500

      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, @timeout * 10
    end
  end
end
