defmodule Sagents.AgentReadinessRaceTest do
  @moduledoc """
  `AgentsDynamicSupervisor.start_agent_sync/1` returns only once the AgentServer
  is registered. These pin down which registry key that promise is checked
  against.

  An AgentSupervisor registers `{:agent_supervisor, agent_id}` in
  `:gen.init_it`, before `init/1` runs. Its AgentServer child registers
  `{:agent_server, agent_id}` later, after `init/1` has loaded persisted state.
  Callers of a started agent look up the second key.
  """
  use ExUnit.Case, async: false

  alias LangChain.ChatModels.ChatOpenAI
  alias Sagents.Agent
  alias Sagents.AgentServer
  alias Sagents.AgentSupervisor
  alias Sagents.AgentsDynamicSupervisor

  # Holds `AgentSupervisor.init/1` open at the point where it loads persisted
  # state: after the supervisor's own `:via` name is registered, and before its
  # AgentServer child exists.
  defmodule BlockingPersistence do
    @behaviour Sagents.AgentPersistence

    @impl true
    def persist_state(_scope, _state_data, _context), do: :ok

    @impl true
    def load_state(_scope, context) do
      send(:readiness_race_test, {:loading, context.agent_id, self()})

      receive do
        :release -> {:error, :not_found}
      after
        5_000 -> {:error, :not_found}
      end
    end
  end

  setup do
    Process.register(self(), :readiness_race_test)
    :ok
  end

  defp build_agent do
    agent_id = "readiness-race-#{System.unique_integer([:positive])}"
    {:ok, model} = ChatOpenAI.new(%{model: "gpt-4", api_key: "test-key"})
    {:ok, agent} = Agent.new(%{agent_id: agent_id, model: model})
    agent
  end

  # An AgentSupervisor parked inside `init/1`, started outside the dynamic
  # supervisor so that other starters are not serialized behind it. That is the
  # arrangement under Horde, where the supervisor is placed on another node.
  defp start_blocked_agent_supervisor(agent) do
    agent_id = agent.agent_id

    {:ok, holder} =
      Task.start(fn ->
        AgentSupervisor.start_link(
          agent: agent,
          name: AgentSupervisor.get_name(agent_id),
          agent_persistence: BlockingPersistence,
          pubsub: nil
        )

        Process.sleep(:infinity)
      end)

    assert_receive {:loading, ^agent_id, sup_pid}, 1_000

    on_exit(fn -> release_and_stop(holder, sup_pid, agent_id) end)

    sup_pid
  end

  # Let `init/1` finish before taking the supervisor down, so teardown does not
  # log a crash for a supervisor that was only ever parked mid-startup.
  defp release_and_stop(holder, sup_pid, agent_id) do
    if AgentServer.fetch_pid(agent_id) == {:error, :not_running} do
      send(sup_pid, :release)
      await_registered(agent_id, System.monotonic_time(:millisecond) + 1_000)
    end

    if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :normal)
    Process.exit(holder, :kill)
  end

  defp await_registered(agent_id, deadline) do
    cond do
      match?({:ok, _pid}, AgentServer.fetch_pid(agent_id)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(10)
        await_registered(agent_id, deadline)
    end
  end

  test "the two registry keys appear at different points in startup" do
    agent = build_agent()
    _sup_pid = start_blocked_agent_supervisor(agent)

    assert {:ok, _pid} = AgentSupervisor.get_pid(agent.agent_id)
    assert {:error, :not_running} = AgentServer.fetch_pid(agent.agent_id)
  end

  test "start_agent_sync waits for the AgentServer, not just its supervisor" do
    agent = build_agent()
    agent_id = agent.agent_id
    sup_pid = start_blocked_agent_supervisor(agent)
    test_pid = self()

    {:ok, starter} =
      Task.start(fn ->
        result =
          AgentsDynamicSupervisor.start_agent_sync(
            agent_id: agent_id,
            agent: agent,
            startup_timeout: 2_000
          )

        send(test_pid, {:started, result})
      end)

    on_exit(fn -> Process.exit(starter, :kill) end)

    # `start_agent` returns `:already_started` immediately here, since the
    # AgentSupervisor is registered. The readiness wait still holds, because the
    # AgentServer every caller looks up does not exist yet.
    refute_receive {:started, _}, 300
    assert {:error, :not_running} = AgentServer.fetch_pid(agent_id)

    send(sup_pid, :release)

    assert_receive {:started, {:ok, returned_pid}}, 2_000

    # The AgentSupervisor pid is what callers get back, not the AgentServer's.
    assert returned_pid == sup_pid
    assert {:ok, _server_pid} = AgentServer.fetch_pid(agent_id)
  end

  test "start_agent_sync times out rather than reporting a half-started agent" do
    agent = build_agent()
    _sup_pid = start_blocked_agent_supervisor(agent)

    assert {:error, :timeout_waiting_for_agent} =
             AgentsDynamicSupervisor.start_agent_sync(
               agent_id: agent.agent_id,
               agent: agent,
               startup_timeout: 100
             )
  end

  test "a fresh start on one node serializes concurrent starters" do
    agent = build_agent()
    agent_id = agent.agent_id
    test_pid = self()

    # Children start synchronously inside the dynamic supervisor's own
    # handle_call, so a slow `AgentSupervisor.init/1` blocks the dynamic
    # supervisor for the whole startup.
    {:ok, first} =
      Task.start(fn ->
        AgentsDynamicSupervisor.start_agent_sync(
          agent_id: agent_id,
          agent: agent,
          agent_persistence: BlockingPersistence,
          startup_timeout: 2_000
        )
      end)

    on_exit(fn ->
      Process.exit(first, :kill)
      AgentsDynamicSupervisor.stop_agent(agent_id)
    end)

    assert_receive {:loading, ^agent_id, sup_pid}, 1_000

    {:ok, second} =
      Task.start(fn ->
        result =
          AgentsDynamicSupervisor.start_agent_sync(
            agent_id: agent_id,
            agent: agent,
            startup_timeout: 2_000
          )

        send(test_pid, {:second_returned, result})
      end)

    on_exit(fn -> Process.exit(second, :kill) end)

    # A second starter on the same node never reaches the readiness wait while
    # the first is still in `init/1`, so it cannot observe the gap.
    refute_receive {:second_returned, _}, 300

    send(sup_pid, :release)

    assert_receive {:second_returned, {:ok, _pid}}, 3_000
    assert {:ok, _pid} = AgentServer.fetch_pid(agent_id)
  end
end
