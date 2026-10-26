defmodule Sagents.AgentServerNameConflictTest do
  @moduledoc """
  Exit signals reaching an AgentServer from linked processes.

  An AgentServer that loses a registry name conflict stops itself and the
  AgentSupervisor it was started under, without persisting. Any other linked
  exit, including one arriving after a turn has ended, leaves it running.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.AgentServer
  alias Sagents.AgentSupervisor
  alias Sagents.TestAgentPersistence
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
      {:ok, [Message.new_assistant!("Mock response")]}
    end)

    TestAgentPersistence.setup()
    :ok
  end

  # The exit Horde.Registry sends the process that loses a name it resolved
  # between two registries.
  defp name_conflict_exit(agent_id, winner) do
    {:EXIT, winner, {:name_conflict, {{:agent_server, agent_id}, nil}, Sagents.Registry, winner}}
  end

  defp start_supervised_agent(opts \\ []) do
    agent = create_test_agent()

    {:ok, sup_pid} =
      AgentSupervisor.start_link_sync(
        Keyword.merge([agent: agent, name: AgentSupervisor.get_name(agent.agent_id)], opts)
      )

    # The test process must outlive a tree it watches stop.
    Process.unlink(sup_pid)

    {agent.agent_id, sup_pid, AgentServer.get_pid(agent.agent_id)}
  end

  describe "losing a name conflict" do
    test "stops the server and its own AgentSupervisor" do
      {agent_id, sup_pid, server_pid} = start_supervised_agent()
      server_ref = Process.monitor(server_pid)
      sup_ref = Process.monitor(sup_pid)

      send(server_pid, name_conflict_exit(agent_id, spawn(fn -> :ok end)))

      assert_receive {:DOWN, ^server_ref, :process, ^server_pid, {:shutdown, :name_conflict}},
                     1_000

      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, 1_000
    end

    test "leaves another agent's tree running" do
      {agent_id, sup_pid, server_pid} = start_supervised_agent()
      {other_id, other_sup_pid, other_server_pid} = start_supervised_agent()
      sup_ref = Process.monitor(sup_pid)

      send(server_pid, name_conflict_exit(agent_id, other_server_pid))
      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, 1_000

      assert Process.alive?(other_sup_pid)
      assert AgentServer.get_status(other_id) == :idle

      Supervisor.stop(other_sup_pid)
    end

    test "does not persist state on the way out" do
      {agent_id, sup_pid, server_pid} =
        start_supervised_agent(agent_persistence: TestAgentPersistence)

      sup_ref = Process.monitor(sup_pid)

      send(server_pid, name_conflict_exit(agent_id, spawn(fn -> :ok end)))
      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, 1_000

      lifecycles =
        for {_id, _scope, _data, context} <- TestAgentPersistence.get_calls_for(agent_id),
            do: context.lifecycle

      refute :on_shutdown in lifecycles
    end

    test "an ordinary stop still persists, so the test above measures the conflict path" do
      {agent_id, sup_pid, _server_pid} =
        start_supervised_agent(agent_persistence: TestAgentPersistence)

      :ok = Supervisor.stop(sup_pid)

      lifecycles =
        for {_id, _scope, _data, context} <- TestAgentPersistence.get_calls_for(agent_id),
            do: context.lifecycle

      assert :on_shutdown in lifecycles
    end

    test "tells subscribers the agent shut down" do
      {agent_id, sup_pid, server_pid} = start_supervised_agent()
      {:ok, _server_pid, _ref} = AgentServer.subscribe(agent_id)
      sup_ref = Process.monitor(sup_pid)

      send(server_pid, name_conflict_exit(agent_id, spawn(fn -> :ok end)))

      assert_receive {:agent, {:agent_shutdown, %{reason: {:shutdown, :name_conflict}}}}, 1_000
      assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _reason}, 1_000
    end

    test "a server started without an AgentSupervisor stops alone" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, server_pid} =
        AgentServer.start_link(agent: agent, name: AgentServer.get_name(agent_id), pubsub: nil)

      Process.unlink(server_pid)

      server_ref = Process.monitor(server_pid)

      send(server_pid, name_conflict_exit(agent_id, spawn(fn -> :ok end)))

      assert_receive {:DOWN, ^server_ref, :process, ^server_pid, {:shutdown, :name_conflict}},
                     1_000
    end
  end

  describe "other linked exits" do
    test "an exit arriving after a turn has ended leaves the server running" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, server_pid} =
        AgentServer.start_link(
          agent: agent,
          name: AgentServer.get_name(agent_id),
          pubsub: nil,
          initial_subscribers: [{:main, self()}]
        )

      assert_receive {:agent, {:status_changed, :idle, nil}}, 200

      :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))
      assert_receive {:agent, {:status_changed, :running, nil}}, 1_000
      assert_receive {:agent, {:status_changed, :idle, nil}}, 1_000

      send(server_pid, {:EXIT, spawn(fn -> :ok end), :some_reason})

      # A synchronous call proves the exit was handled without a crash.
      assert AgentServer.get_status(agent_id) == :idle
      assert Process.alive?(server_pid)
    end
  end
end
