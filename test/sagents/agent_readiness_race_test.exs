defmodule Sagents.AgentReadinessRaceTest do
  @moduledoc """
  `AgentsDynamicSupervisor.start_agent_sync/1` returns only once the AgentServer
  is registered, and a registered AgentServer answers with the conversation it
  loaded.

  An AgentSupervisor registers `{:agent_supervisor, agent_id}` in
  `:gen.init_it`, before its `init/1` runs. Its AgentServer child registers
  `{:agent_server, agent_id}` the same way, before its own `init/1` loads
  persisted state. A call that reaches the AgentServer during that load waits
  in its mailbox and is answered once the load completes.
  """
  use ExUnit.Case, async: false

  alias LangChain.ChatModels.ChatOpenAI
  alias Sagents.Agent
  alias Sagents.AgentServer
  alias Sagents.AgentSupervisor
  alias Sagents.AgentsDynamicSupervisor

  # Holds `AgentServer.init/1` open at the point where it loads persisted
  # state: after both `:via` names are registered, and before the AgentServer
  # can answer a call.
  defmodule BlockingPersistence do
    @behaviour Sagents.AgentPersistence

    @impl true
    def persist_state(_scope, _state_data, _context), do: :ok

    @impl true
    def load_state(_scope, context) do
      send(:readiness_race_test, {:loading, context.agent_id, self()})

      receive do
        :release -> loaded_state()
      after
        5_000 -> loaded_state()
      end
    end

    # A persisted conversation with one message, so a test can tell the loaded
    # state from the empty fallback.
    def loaded_state do
      state = Sagents.State.new!(%{messages: [LangChain.Message.new_user!("persisted")]})
      {:ok, Sagents.Persistence.StateSerializer.serialize_server_state(nil, state)}
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

  # An AgentServer parked inside `init/1`, under an AgentSupervisor started outside the dynamic
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

    assert_receive {:loading, ^agent_id, loader_pid}, 1_000

    on_exit(fn -> release_and_stop(holder, loader_pid, agent_id) end)

    loader_pid
  end

  # Let `init/1` finish before taking the supervisor down, so teardown does not
  # log a crash for a supervisor that was only ever parked mid-startup.
  defp release_and_stop(holder, loader_pid, agent_id) do
    send(loader_pid, :release)

    case AgentSupervisor.get_pid(agent_id) do
      {:ok, sup_pid} -> if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid, :normal)
      _other -> :ok
    end

    Process.exit(holder, :kill)
  catch
    :exit, _reason -> Process.exit(holder, :kill)
  end

  test "an AgentServer is registered while it loads, and answers once loaded" do
    agent = build_agent()
    loader_pid = start_blocked_agent_supervisor(agent)

    assert {:ok, _pid} = AgentSupervisor.get_pid(agent.agent_id)
    assert {:ok, ^loader_pid} = AgentServer.fetch_pid(agent.agent_id)

    call = Task.async(fn -> AgentServer.get_state(agent.agent_id) end)
    assert Task.yield(call, 200) == nil

    send(loader_pid, :release)
    assert %{messages: [_persisted]} = Task.await(call, 2_000)
  end

  test "start_agent_sync returns an agent whose first answer reflects the loaded state" do
    agent = build_agent()
    agent_id = agent.agent_id
    loader_pid = start_blocked_agent_supervisor(agent)

    # `start_agent` finds the AgentSupervisor registered and reports
    # `:already_started`; the readiness wait finds the AgentServer registered.
    assert {:ok, _sup_pid} =
             AgentsDynamicSupervisor.start_agent_sync(
               agent_id: agent_id,
               agent: agent,
               startup_timeout: 2_000
             )

    call = Task.async(fn -> AgentServer.get_state(agent_id) end)
    assert Task.yield(call, 200) == nil

    send(loader_pid, :release)
    assert %{messages: [_persisted]} = Task.await(call, 2_000)
  end

  test "a fresh start on one node serializes concurrent starters" do
    agent = build_agent()
    agent_id = agent.agent_id
    test_pid = self()

    # Children start synchronously inside the dynamic supervisor's own
    # handle_call, and an AgentSupervisor starts its AgentServer synchronously
    # in its own init/1, so a slow load blocks the dynamic supervisor for the
    # whole startup.
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

    assert_receive {:loading, ^agent_id, loader_pid}, 1_000

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

    send(loader_pid, :release)

    assert_receive {:second_returned, {:ok, _pid}}, 3_000
    assert {:ok, _pid} = AgentServer.fetch_pid(agent_id)
  end
end
