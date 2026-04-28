defmodule Sagents.AgentServerDebugPubSubTest do
  use Sagents.BaseCase, async: false

  alias Sagents.{AgentServer, State, Middleware}
  alias LangChain.Message

  # Simple test middleware that can trigger state updates
  defmodule TestMiddleware do
    @behaviour Middleware

    @impl true
    def init(opts) do
      config = Enum.into(opts, %{})
      {:ok, config}
    end

    @impl true
    def before_model(_state, _middleware_state), do: {:ok, %{}}

    @impl true
    def after_model(_state, _middleware_state), do: {:ok, %{}}

    @impl true
    def handle_message(:test_message, state, _middleware_state) do
      updated_state = State.put_metadata(state, "test_key", "test_value")
      {:ok, updated_state}
    end

    @impl true
    def handle_message(_message, state, _middleware_state) do
      {:ok, state}
    end
  end

  describe "subscribe_debug/1" do
    test "subscribes to debug events successfully" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      assert {:ok, server_pid, ref} = AgentServer.subscribe_debug(agent_id)
      assert is_pid(server_pid)
      assert is_reference(ref)
    end

    test "returns process_not_found when no AgentServer is running" do
      assert {:error, :process_not_found} =
               AgentServer.subscribe_debug("never-started-#{System.unique_integer([:positive])}")
    end
  end

  describe "debug event broadcasting" do
    test "broadcasts agent_state_update on middleware message" do
      agent = create_test_agent(middleware: [{TestMiddleware, []}])
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      {:ok, _pid, _ref} = AgentServer.subscribe_debug(agent_id)

      :ok = AgentServer.notify_middleware(agent_id, TestMiddleware, :test_message)

      assert_receive {:agent, {:debug, {:agent_state_update, TestMiddleware, %State{}}}}, 100
    end

    test "main subscribers do not receive debug events" do
      agent = create_test_agent(middleware: [{TestMiddleware, []}])
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id)

      :ok = AgentServer.notify_middleware(agent_id, TestMiddleware, :test_message)

      refute_receive {:agent, {:debug, {:agent_state_update, _, _}}}, 100
    end
  end

  describe "debug events with state restoration" do
    test "debug subscriptions work after restoring from persisted state" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      initial_state = State.new!(%{messages: [Message.new_user!("Test message")]})

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          initial_state: initial_state
        )

      exported_state = AgentServer.export_state(agent_id)
      :ok = AgentServer.stop(agent_id)
      Process.sleep(100)

      new_agent_id = "restored-agent-#{System.unique_integer([:positive])}"
      restored_agent = create_test_agent(agent_id: new_agent_id)

      assert {:ok, _pid} =
               AgentServer.start_link_from_state(
                 exported_state,
                 agent: restored_agent,
                 agent_id: new_agent_id
               )

      assert {:ok, _pid, _ref} = AgentServer.subscribe_debug(new_agent_id)
    end
  end

  describe "multiple agents" do
    test "debug events are isolated per agent" do
      agent1 = create_test_agent(middleware: [{TestMiddleware, []}])
      agent2 = create_test_agent(middleware: [{TestMiddleware, []}])

      {:ok, _pid1} = AgentServer.start_link(agent: agent1)
      {:ok, _pid2} = AgentServer.start_link(agent: agent2)

      # Subscribe to agent1's debug events only
      {:ok, _pid, _ref} = AgentServer.subscribe_debug(agent1.agent_id)

      # Send message to agent2 — we should not see its events
      :ok = AgentServer.notify_middleware(agent2.agent_id, TestMiddleware, :test_message)
      refute_receive {:agent, {:debug, {:agent_state_update, _, _}}}, 100

      # Send message to agent1 — we should see this one
      :ok = AgentServer.notify_middleware(agent1.agent_id, TestMiddleware, :test_message)
      assert_receive {:agent, {:debug, {:agent_state_update, TestMiddleware, %State{}}}}, 100
    end
  end
end
