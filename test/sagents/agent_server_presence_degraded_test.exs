defmodule Sagents.AgentServerPresenceDegradedTest do
  @moduledoc """
  Presence is advisory. A tracker that is slow or gone must not stop, stall, or
  restart an agent, and must not make it give up its run.

  Each test suspends the shard behind `Sagents.TestPresence`, which makes every
  tracker call block until its 5 second timeout, the way a backed-up shard does
  under load.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, PresenceWriter, State}
  alias LangChain.Message
  alias LangChain.Message.{ToolCall, ToolResult}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  @shard :"Elixir.Sagents.TestPresence_shard0"
  @discovery_topic "agent_server:presence"

  # Suspends the shard and resumes it when the test ends, then flushes the
  # writer so writes queued against the suspended shard cannot leak into the
  # next test.
  defp suspend_shard do
    :sys.suspend(@shard)

    on_exit(fn ->
      :sys.resume(@shard)
      PresenceWriter.flush()
    end)
  end

  defp question_state do
    State.new!(%{
      messages: [
        Message.new_user!("hi"),
        Message.new_assistant!(%{
          tool_calls: [ToolCall.new!(%{call_id: "call_1", name: "ask_user", arguments: %{}})]
        }),
        Message.new_tool_result!(%{
          content: nil,
          tool_results: [
            ToolResult.new!(%{
              tool_call_id: "call_1",
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

  defp start_agent(agent, opts \\ []) do
    {:ok, pid} =
      AgentServer.start_link(
        [
          agent: agent,
          name: AgentServer.get_name(agent.agent_id),
          presence_module: Sagents.TestPresence
        ] ++ opts
      )

    pid
  end

  defp discovery_meta(agent_id) do
    PresenceWriter.flush()

    case Map.get(Sagents.TestPresence.list(@discovery_topic), agent_id) do
      %{metas: [meta | _rest]} -> meta
      _other -> nil
    end
  end

  defp elapsed_ms(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  describe "with a backed-up tracker shard" do
    test "an agent boots and answers calls without waiting on presence" do
      Process.flag(:trap_exit, true)
      suspend_shard()
      agent = create_test_agent()

      {ms, pid} = elapsed_ms(fn -> start_agent(agent) end)
      assert ms < 1_000

      {ms, status} = elapsed_ms(fn -> AgentServer.get_status(agent.agent_id) end)
      assert status == :idle
      assert ms < 1_000

      AgentServer.touch(agent.agent_id)
      assert :idle = AgentServer.get_status(agent.agent_id)
      refute_received {:EXIT, ^pid, _reason}
    end

    test "resume returns :ok and the resumed work keeps running" do
      Process.flag(:trap_exit, true)
      test_pid = self()

      stub(Agent, :resume, fn _agent, state, _data, _opts ->
        send(test_pid, {:resume_running, self()})

        receive do
          :finish -> {:ok, state}
        end
      end)

      agent = create_test_agent(middleware: [Sagents.Middleware.AskUserQuestion])
      pid = start_agent(agent, initial_state: question_state())
      assert :interrupted = AgentServer.get_status(agent.agent_id)

      suspend_shard()

      assert :ok = AgentServer.resume(agent.agent_id, %{type: :answer, selected: ["yes"]})
      assert_receive {:resume_running, task_pid}, 1_000

      # Answered promptly, with the resume task alive: nothing waited on the shard.
      assert :running = AgentServer.get_status(agent.agent_id)
      assert Process.alive?(task_pid)

      send(task_pid, :finish)
      assert wait_until(fn -> AgentServer.get_status(agent.agent_id) == :idle end)
      refute_received {:EXIT, ^pid, _reason}
    end

    test "a crash does not wait on the tracker on the way out" do
      Process.flag(:trap_exit, true)
      agent = create_test_agent()
      pid = start_agent(agent)
      :idle = AgentServer.get_status(agent.agent_id)
      suspend_shard()

      {ms, :ok} = elapsed_ms(fn -> GenServer.stop(pid, :boom) end)
      assert ms < 1_000
    end
  end

  describe "discovery entry" do
    test "boot creates the entry once, with the boot status and no warning" do
      agent = create_test_agent()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_agent(agent)
          :idle = AgentServer.get_status(agent.agent_id)
          PresenceWriter.flush()
        end)

      refute log =~ "presence"
      assert %{status: :idle, started_at: started_at} = discovery_meta(agent.agent_id)
      assert %DateTime{} = started_at
    end

    test "writes made while the shard is backed up land once it recovers" do
      agent = create_test_agent()
      start_agent(agent)
      :idle = AgentServer.get_status(agent.agent_id)
      assert %{last_activity_at: first} = discovery_meta(agent.agent_id)

      :sys.suspend(@shard)
      AgentServer.touch(agent.agent_id)
      :idle = AgentServer.get_status(agent.agent_id)
      :sys.resume(@shard)

      assert %{last_activity_at: later} = discovery_meta(agent.agent_id)
      assert DateTime.compare(later, first) in [:gt, :eq]
    end

    test "an orderly stop removes the entry" do
      Process.flag(:trap_exit, true)
      agent = create_test_agent()
      pid = start_agent(agent)
      :idle = AgentServer.get_status(agent.agent_id)
      assert discovery_meta(agent.agent_id)

      GenServer.stop(pid, :shutdown)
      assert discovery_meta(agent.agent_id) == nil
    end
  end

  describe "viewer list failures" do
    defmodule ExitingViewerPresence do
      def list(_topic), do: exit({:timeout, {GenServer, :call, [:shard, :list, 5000]}})
    end

    defmodule RaisingViewerPresence do
      def list(_topic), do: raise(ArgumentError, "tracker not running")
    end

    for presence_mod <- [ExitingViewerPresence, RaisingViewerPresence] do
      test "an unreadable viewer list keeps an idle agent alive (#{inspect(presence_mod)})" do
        Process.flag(:trap_exit, true)
        agent = create_test_agent()

        {:ok, pid} =
          AgentServer.start_link(
            agent: agent,
            name: AgentServer.get_name(agent.agent_id),
            presence_tracking: [
              presence_module: unquote(presence_mod),
              topic: "conversation:degraded",
              check_delay: 10
            ]
          )

        :idle = AgentServer.get_status(agent.agent_id)

        # Both viewer checks: the leave handler and the delayed shutdown.
        send(pid, %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          payload: %{joins: %{}, leaves: %{"user-1" => %{metas: []}}}
        })

        send(pid, :shutdown_no_viewers)

        assert :idle = AgentServer.get_status(agent.agent_id)
        refute_received {:EXIT, ^pid, _reason}
      end
    end
  end

  describe "failed calls" do
    test "a call the agent dies while holding reports an unknown outcome" do
      Process.flag(:trap_exit, true)
      agent = create_test_agent()
      pid = start_agent(agent)
      :idle = AgentServer.get_status(agent.agent_id)

      # The request sits in the mailbox of a suspended server, which is then
      # killed: the caller cannot know whether it was handled.
      :sys.suspend(pid)
      task = Task.async(fn -> AgentServer.cancel(agent.agent_id) end)
      assert wait_until(fn -> match?({:messages, [_ | _]}, Process.info(pid, :messages)) end)
      Process.exit(pid, :kill)

      assert {:error, {:outcome_unknown, :killed}} = Task.await(task)
    end

    test "a call to an agent that is not running reports :agent_not_running" do
      assert {:error, :agent_not_running} = AgentServer.cancel("no-such-agent")
    end
  end
end
