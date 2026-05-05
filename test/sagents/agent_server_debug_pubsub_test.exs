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

  describe "subscribe/3 debug channel" do
    test "subscribes to debug events successfully" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      assert {:ok, server_pid, ref} = AgentServer.subscribe(agent_id, :debug)
      assert is_pid(server_pid)
      assert is_reference(ref)
    end

    test "returns process_not_found when no AgentServer is running" do
      assert {:error, :process_not_found} =
               AgentServer.subscribe(
                 "never-started-#{System.unique_integer([:positive])}",
                 :debug
               )
    end
  end

  describe "debug event broadcasting" do
    test "broadcasts agent_state_update on middleware message" do
      agent = create_test_agent(middleware: [{TestMiddleware, []}])
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id, :debug)

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

  describe "after_middleware_broadcast" do
    # The on_after_middleware callback closure runs in the execution Task and
    # would normally broadcast against a frozen snapshot of subscribers. Routing
    # through the GenServer (this cast) ensures subscribers that joined AFTER
    # execute started — e.g. a debugger that opened mid-turn — still receive
    # the post-middleware state. Reconciling server_state.state with
    # prepared_state also makes mid-turn `get_state/1` reflect middleware
    # injections (e.g. a foundation-document preamble).

    test "broadcasts :after_middleware_state to debug subscribers and reconciles state" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      # Force the server into :running with a known execution_seq so the
      # cast's gate matches.
      :sys.replace_state(AgentServer.get_pid(agent_id), fn server_state ->
        %{server_state | status: :running, execution_seq: 1}
      end)

      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id, :debug)

      injected_user = Message.new_user!("synthetic kickoff")
      injected_assistant = Message.new_assistant!("synthetic reference dump")
      real_user = Message.new_user!("real first message")

      prepared_state =
        State.new!(%{messages: [injected_user, injected_assistant, real_user]})

      GenServer.cast(
        AgentServer.get_pid(agent_id),
        {:after_middleware_broadcast, 1, prepared_state}
      )

      assert_receive {:agent, {:debug, {:after_middleware_state, broadcast_state}}}, 200
      assert length(broadcast_state.messages) == 3

      # Reconciliation: get_state now returns prepared_state's messages,
      # not the empty pre-middleware list. This is what makes mid-turn
      # snapshots correct for newly-arrived debugger views.
      reconciled = AgentServer.get_state(agent_id)
      assert length(reconciled.messages) == 3
    end

    test "drops cast when execution_seq is stale" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      :sys.replace_state(AgentServer.get_pid(agent_id), fn server_state ->
        %{server_state | status: :running, execution_seq: 5}
      end)

      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id, :debug)

      stale_state = State.new!(%{messages: [Message.new_user!("from old run")]})

      GenServer.cast(
        AgentServer.get_pid(agent_id),
        {:after_middleware_broadcast, 1, stale_state}
      )

      refute_receive {:agent, {:debug, {:after_middleware_state, _}}}, 100

      # State unchanged.
      assert AgentServer.get_state(agent_id).messages == []
    end

    test "drops cast when status is not :running" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      # Server starts in :idle.
      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id, :debug)

      prepared_state = State.new!(%{messages: [Message.new_user!("ignored")]})

      GenServer.cast(
        AgentServer.get_pid(agent_id),
        {:after_middleware_broadcast, 0, prepared_state}
      )

      refute_receive {:agent, {:debug, {:after_middleware_state, _}}}, 100
      assert AgentServer.get_state(agent_id).messages == []
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

      assert {:ok, _pid, _ref} = AgentServer.subscribe(new_agent_id, :debug)
    end
  end

  describe "multiple agents" do
    test "debug events are isolated per agent" do
      agent1 = create_test_agent(middleware: [{TestMiddleware, []}])
      agent2 = create_test_agent(middleware: [{TestMiddleware, []}])

      {:ok, _pid1} = AgentServer.start_link(agent: agent1)
      {:ok, _pid2} = AgentServer.start_link(agent: agent2)

      # Subscribe to agent1's debug events only
      {:ok, _pid, _ref} = AgentServer.subscribe(agent1.agent_id, :debug)

      # Send message to agent2 — we should not see its events
      :ok = AgentServer.notify_middleware(agent2.agent_id, TestMiddleware, :test_message)
      refute_receive {:agent, {:debug, {:agent_state_update, _, _}}}, 100

      # Send message to agent1 — we should see this one
      :ok = AgentServer.notify_middleware(agent1.agent_id, TestMiddleware, :test_message)
      assert_receive {:agent, {:debug, {:agent_state_update, TestMiddleware, %State{}}}}, 100
    end
  end

  describe "subscribe/3 with explicit subscriber_pid" do
    test "delivers events to the foreign pid, not the caller" do
      agent = create_test_agent(middleware: [{TestMiddleware, []}])
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      parent = self()

      foreign =
        spawn_link(fn ->
          send(parent, :foreign_ready)

          receive do
            msg -> send(parent, {:foreign_got, msg})
          end
        end)

      assert_receive :foreign_ready

      {:ok, _server, _ref} = AgentServer.subscribe(agent_id, :debug, foreign)

      :ok = AgentServer.notify_middleware(agent_id, TestMiddleware, :test_message)

      # The foreign pid receives the wrapped debug event...
      assert_receive {:foreign_got,
                      {:agent, {:debug, {:agent_state_update, TestMiddleware, %State{}}}}},
                     200

      # ...but the caller, who subscribed on behalf of the foreign pid,
      # does not receive it directly.
      refute_receive {:agent, {:debug, {:agent_state_update, _, _}}}, 50
    end
  end

  describe "subscribe/3 idempotency" do
    test "re-subscribing returns the same monitor_ref" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      {:ok, server_pid_1, ref_1} = AgentServer.subscribe(agent_id, :debug)
      {:ok, server_pid_2, ref_2} = AgentServer.subscribe(agent_id, :debug)

      assert server_pid_1 == server_pid_2
      assert ref_1 == ref_2
    end
  end

  describe "unsubscribe/3" do
    test "stops debug delivery on the :debug channel" do
      agent = create_test_agent(middleware: [{TestMiddleware, []}])
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      {:ok, _server, _ref} = AgentServer.subscribe(agent_id, :debug)

      :ok = AgentServer.notify_middleware(agent_id, TestMiddleware, :test_message)
      assert_receive {:agent, {:debug, {:agent_state_update, _, _}}}, 100

      :ok = AgentServer.unsubscribe(agent_id, :debug)

      :ok = AgentServer.notify_middleware(agent_id, TestMiddleware, :test_message)
      refute_receive {:agent, {:debug, {:agent_state_update, _, _}}}, 100
    end

    test "returns :ok when the AgentServer is not running" do
      assert :ok =
               AgentServer.unsubscribe(
                 "never-started-#{System.unique_integer([:positive])}",
                 :debug
               )
    end
  end
end
