defmodule Sagents.SessionTest do
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{AgentServer, AgentsDynamicSupervisor, Session}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(AgentServer)
    Mimic.copy(AgentsDynamicSupervisor)
    :ok
  end

  # ===========================================================================
  # Test doubles
  # ===========================================================================

  defmodule StubPersistence do
    @behaviour Sagents.AgentPersistence

    @impl true
    def persist_state(_scope, _state, _ctx), do: :ok

    @impl true
    def load_state(_scope, ctx) do
      send(self(), {:load_state_called, ctx})

      case Process.get(:stub_load_response, {:error, :not_found}) do
        {:error, :not_found} -> {:error, :not_found}
        {:ok, _payload} = ok -> ok
      end
    end
  end

  defmodule StubDisplayMessagePersistence do
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_scope, _message, _ctx), do: {:ok, []}
    @impl true
    def update_tool_status(_scope, _status, _tool_info, _ctx), do: {:ok, %{}}
    @impl true
    def resolve_tool_result(_scope, _tool_call_id, _result_content, _ctx), do: {:ok, %{}}
    @impl true
    def save_synthetic_message(_scope, _attrs, _ctx), do: {:ok, %{}}
  end

  # Minimal config struct used by the spy router.
  defmodule SpyConfig do
    defstruct [:scope, :conversation_id, :request_opts]
  end

  # Spy router — every call records what it received via the test pid and
  # returns a SpyConfig wrapping the inputs.
  defmodule SpyRouter do
    @behaviour Sagents.FactoryRouter

    @impl true
    def resolve(scope, conversation_id, request_opts) do
      test_pid = Process.get(:spy_test_pid)
      send(test_pid, {:router_resolve, scope, conversation_id, request_opts})

      case Process.get(:spy_router_response) do
        {:error, _reason} = err ->
          err

        _other ->
          factory =
            Process.get(:spy_factory_module, Sagents.SessionTest.HappyFactory)

          config = %Sagents.SessionTest.SpyConfig{
            scope: scope,
            conversation_id: conversation_id,
            request_opts: request_opts
          }

          {:ok, factory, config}
      end
    end
  end

  defmodule HappyFactory do
    @behaviour Sagents.Factory

    @impl true
    def create_agent(agent_id, %Sagents.SessionTest.SpyConfig{} = config) do
      test_pid = Process.get(:spy_test_pid)
      send(test_pid, {:factory_called, agent_id, config})

      agent = %Sagents.Agent{
        agent_id: agent_id,
        model: nil,
        middleware: []
      }

      session_opts = Process.get(:happy_factory_session_opts, [])
      {:ok, agent, session_opts}
    end
  end

  defmodule LegacyShapeFactory do
    # Legacy single-arg shape — must trigger the migration error in
    # Sagents.Session.invoke_factory/3.
    def create_agent(opts) do
      agent = %Sagents.Agent{
        agent_id: Keyword.fetch!(opts, :agent_id),
        model: nil,
        middleware: []
      }

      {:ok, agent}
    end
  end

  defmodule ErrorFactory do
    @behaviour Sagents.Factory

    @impl true
    def create_agent(_agent_id, _config), do: {:error, :boom}
  end

  defmodule BadShapeFactory do
    @behaviour Sagents.Factory

    @impl true
    def create_agent(agent_id, _config) do
      agent = %Sagents.Agent{agent_id: agent_id, model: nil, middleware: []}
      {:ok, agent, :not_a_keyword_list}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp base_config(overrides \\ %{}) do
    Map.merge(
      %{
        factory_router: SpyRouter,
        agent_persistence: StubPersistence,
        display_message_persistence: StubDisplayMessagePersistence,
        pubsub: {Phoenix.PubSub, :test_pubsub},
        presence_module: FakePresence,
        inactivity_timeout: :timer.minutes(10),
        agent_id_fun: fn id -> "conversation-#{id}" end
      },
      overrides
    )
  end

  setup do
    Process.put(:spy_test_pid, self())
    on_exit(fn -> :ok end)
    :ok
  end

  defp stub_supervisor_ok(captured_ref) do
    fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
    monitor_ref = make_ref()

    stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :not_running} end)

    # Subscriber.subscribe_to_agent calls AgentServer.subscribe to set up the
    # producer-side monitor. We don't have a live AgentServer in these tests,
    # so stub it to return a successful subscription tuple referencing our
    # fake pid.
    stub(AgentServer, :subscribe, fn _agent_id, _channel, _subscriber_pid ->
      {:ok, fake_pid, monitor_ref}
    end)

    stub(AgentsDynamicSupervisor, :start_agent_sync, fn opts ->
      send(captured_ref, {:supervisor_config, opts})
      # After the start, simulate the agent being registered.
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)
      {:ok, fake_pid}
    end)

    fake_pid
  end

  # ===========================================================================
  # start/3
  # ===========================================================================

  describe "start/3" do
    test "consults the configured router on every call" do
      _fake_pid = stub_supervisor_ok(self())

      config = base_config()

      assert {:ok, %{conversation_id: 42}} = Session.start(config, 42, scope: :my_scope)

      assert_received {:router_resolve, :my_scope, 42, []}
    end

    test "forwards :request_opts verbatim to the router" do
      _fake_pid = stub_supervisor_ok(self())

      config = base_config()

      Session.start(config, 7,
        scope: :s,
        request_opts: [foo: :bar, conversation: %{id: 7, kind: "x"}]
      )

      assert_received {:router_resolve, :s, 7, [foo: :bar, conversation: %{id: 7, kind: "x"}]}
    end

    test "passes router-returned config verbatim to the factory (no merging)" do
      _fake_pid = stub_supervisor_ok(self())

      config = base_config()

      Session.start(config, 1, scope: :s, request_opts: [project_id: 123])

      assert_receive {:factory_called, agent_id, %SpyConfig{} = received_config}
      assert agent_id == "conversation-1"
      assert received_config.scope == :s
      assert received_config.conversation_id == 1
      assert received_config.request_opts == [project_id: 123]
    end

    test "raises with a clear migration error when factory uses legacy create_agent/1" do
      _fake_pid = stub_supervisor_ok(self())

      Process.put(:spy_factory_module, LegacyShapeFactory)
      config = base_config()

      assert_raise ArgumentError, ~r/legacy\s+`create_agent\/1`/, fn ->
        Session.start(config, 1, scope: :s)
      end
    end

    test "raises when factory returns a non-keyword session_opts" do
      _fake_pid = stub_supervisor_ok(self())

      Process.put(:spy_factory_module, BadShapeFactory)
      config = base_config()

      assert_raise ArgumentError, ~r/not a keyword list/, fn ->
        Session.start(config, 1, scope: :s)
      end
    end

    test "propagates {:error, _} from the factory" do
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :not_running} end)

      Process.put(:spy_factory_module, ErrorFactory)
      config = base_config()

      assert {:error, :boom} = Session.start(config, 1, scope: :s)
    end

    test "propagates {:error, _} from the router" do
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :not_running} end)

      Process.put(:spy_router_response, {:error, :no_route})
      config = base_config()

      assert {:error, :no_route} = Session.start(config, 1, scope: :s)
    end

    test "seeds :fresh_state_attrs from session_opts on fresh state" do
      ref = self()
      _fake_pid = stub_supervisor_ok(ref)

      todos = [%Sagents.Todo{id: "t1", content: "hi", status: :pending}]
      Process.put(:happy_factory_session_opts, fresh_state_attrs: %{todos: todos})

      config = base_config()

      assert {:ok, _info} = Session.start(config, 1, scope: :s)

      assert_receive {:supervisor_config, supervisor_opts}
      initial_state = Keyword.fetch!(supervisor_opts, :initial_state)
      assert initial_state.todos == todos
    end

    test "ignores session_opts[:fresh_state_attrs] when restoring saved state" do
      ref = self()
      _fake_pid = stub_supervisor_ok(ref)

      original = Sagents.State.new!(%{todos: []})
      serialized = Sagents.Persistence.StateSerializer.serialize_state(original)
      Process.put(:stub_load_response, {:ok, %{"state" => serialized}})

      Process.put(
        :happy_factory_session_opts,
        fresh_state_attrs: %{todos: [%Sagents.Todo{id: "seed", content: "x", status: :pending}]}
      )

      config = base_config()

      assert {:ok, _info} = Session.start(config, 5, scope: :s)

      assert_receive {:supervisor_config, supervisor_opts}
      initial_state = Keyword.fetch!(supervisor_opts, :initial_state)
      assert initial_state.todos == []
    end

    test "wires presence, pubsub, and persistence config into the supervisor" do
      ref = self()
      _fake_pid = stub_supervisor_ok(ref)

      config = base_config()

      Session.start(config, 9, scope: :s)

      assert_receive {:supervisor_config, supervisor_opts}
      assert supervisor_opts[:agent_persistence] == StubPersistence
      assert supervisor_opts[:display_message_persistence] == StubDisplayMessagePersistence
      assert supervisor_opts[:pubsub] == {Phoenix.PubSub, :test_pubsub}
      assert supervisor_opts[:presence_module] == FakePresence
      assert supervisor_opts[:conversation_id] == 9
      assert supervisor_opts[:agent_id] == "conversation-9"

      presence_tracking = supervisor_opts[:presence_tracking]
      assert presence_tracking[:enabled] == true
      assert presence_tracking[:topic] == "conversation:9"
      assert presence_tracking[:presence_module] == FakePresence
    end

    test "is idempotent — returns existing session without re-consulting router" do
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)

      config = base_config()

      assert {:ok, info} = Session.start(config, 1, scope: :s)
      assert info.pid == fake_pid

      refute_received {:router_resolve, _, _, _}
    end
  end

  # ===========================================================================
  # ensure_running/2
  # ===========================================================================

  describe "ensure_running/2" do
    test "works without :filesystem_scope in the state map" do
      _fake_pid = stub_supervisor_ok(self())

      config = base_config()

      state = %{
        conversation_id: 1,
        current_scope: :my_scope,
        sagents_subs: %{}
      }

      assert {:ok, %{sagents_subs: subs, agent_id: "conversation-1"}} =
               Session.ensure_running(config, state)

      assert is_map(subs)
    end

    test "upgrades :pending subs entry to :subscribed" do
      fake_pid = stub_supervisor_ok(self())

      config = base_config()

      pending_subs = %{
        {:agent, "conversation-1"} => %{state: :pending, server_pid: nil}
      }

      state = %{
        conversation_id: 1,
        current_scope: :my_scope,
        sagents_subs: pending_subs
      }

      assert {:ok, %{sagents_subs: new_subs}} = Session.ensure_running(config, state)

      entry = Map.fetch!(new_subs, {:agent, "conversation-1"})
      assert entry.state == :subscribed
      assert entry.server_pid == fake_pid
    end

    test "leaves an already-:subscribed entry alone (no duplicate monitor)" do
      fake_pid = stub_supervisor_ok(self())

      config = base_config()

      ref = make_ref()

      already_subbed = %{
        {:agent, "conversation-1"} => %{
          state: :subscribed,
          server_pid: fake_pid,
          monitor_ref: ref
        }
      }

      state = %{
        conversation_id: 1,
        current_scope: :my_scope,
        sagents_subs: already_subbed
      }

      assert {:ok, %{sagents_subs: new_subs}} = Session.ensure_running(config, state)
      assert new_subs == already_subbed
    end

    test "forwards explicit request_opts arg to the router" do
      _fake_pid = stub_supervisor_ok(self())

      config = base_config()

      state = %{conversation_id: 1, current_scope: :my_scope}

      Session.ensure_running(config, state, request_opts: [project_id: 99, timezone: "UTC"])

      assert_receive {:router_resolve, :my_scope, 1, request_opts}
      assert request_opts[:project_id] == 99
      assert request_opts[:timezone] == "UTC"
    end

    test "defaults request_opts to [] when none supplied" do
      _fake_pid = stub_supervisor_ok(self())

      config = base_config()

      state = %{conversation_id: 1, current_scope: :my_scope}

      Session.ensure_running(config, state)

      assert_receive {:router_resolve, :my_scope, 1, []}
    end
  end

  # ===========================================================================
  # stop/2 + running?/2
  # ===========================================================================

  describe "stop/2" do
    test "returns {:ok, :not_running} when no agent is running" do
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :not_running} end)

      assert {:ok, :not_running} = Session.stop(base_config(), 1)
    end

    test "stops the running agent and returns {:ok, :stopped}" do
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)
      stub(AgentServer, :stop, fn _agent_id -> :ok end)

      assert {:ok, :stopped} = Session.stop(base_config(), 1)
    end
  end

  describe "running?/2" do
    test "false when no agent is registered" do
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :not_running} end)
      refute Session.running?(base_config(), 1)
    end

    test "true when an agent is registered" do
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)
      assert Session.running?(base_config(), 1)
    end

    test "raises rather than answering false when the registry cannot answer" do
      # false would be read as "nothing is running", and a caller responds to
      # that by starting a duplicate agent for a conversation that already has
      # one on another node.
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :registry_unavailable} end)

      assert_raise Sagents.RegistryUnavailableError, fn ->
        Session.running?(base_config(), 1)
      end
    end
  end

  describe "fetch_running/2" do
    test "{:ok, false} when no agent is registered" do
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :not_running} end)
      assert {:ok, false} = Session.fetch_running(base_config(), 1)
    end

    test "{:ok, true} when an agent is registered" do
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)
      assert {:ok, true} = Session.fetch_running(base_config(), 1)
    end

    test "keeps 'cannot answer' distinct from 'not running'" do
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :registry_unavailable} end)
      assert {:error, :registry_unavailable} = Session.fetch_running(base_config(), 1)
    end
  end

  # ===========================================================================
  # resume/4
  # ===========================================================================

  describe "resume/4" do
    # The host's process-level state map, as ensure_running/3 expects it.
    defp resume_state(overrides \\ %{}) do
      Map.merge(%{conversation_id: 1, current_scope: :my_scope, sagents_subs: %{}}, overrides)
    end

    test "a live interrupted agent takes the answer in exactly one call" do
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)

      test_pid = self()

      stub(AgentServer, :resume, fn agent_id, resume_data ->
        send(test_pid, {:resume_called, agent_id, resume_data})
        :ok
      end)

      # No supervisor start at all on the fast path.
      stub(AgentsDynamicSupervisor, :start_agent_sync, fn _opts ->
        send(test_pid, :unexpected_start)
        {:error, :should_not_be_called}
      end)

      assert :ok = Session.resume(base_config(), resume_state(), %{type: :answer})

      assert_received {:resume_called, "conversation-1", %{type: :answer}}
      refute_received :unexpected_start
    end

    test "a sleeping agent is started with the answer in hand" do
      test_pid = self()
      _fake_pid = stub_supervisor_ok(test_pid)

      stub(AgentServer, :resume, fn _agent_id, _resume_data ->
        {:error, :agent_not_running}
      end)

      assert {:ok, changes} =
               Session.resume(base_config(), resume_state(), %{type: :answer, selected: ["yes"]})

      assert changes.agent_id == "conversation-1"
      assert Map.has_key?(changes, :sagents_subs)

      # The answer rides into the boot rather than being stashed by the host
      # and replayed against a broadcast.
      assert_receive {:supervisor_config, opts}
      assert opts[:pending_resume] == %{type: :answer, selected: ["yes"]}
      assert opts[:initial_subscribers] == [{:main, self()}]
    end

    test "forwards :request_opts on the wake path so the woken agent is configured normally" do
      test_pid = self()
      _fake_pid = stub_supervisor_ok(test_pid)

      stub(AgentServer, :resume, fn _agent_id, _resume_data -> {:error, :agent_not_running} end)

      Session.resume(base_config(), resume_state(), %{type: :answer},
        request_opts: [timezone: "America/Chicago"]
      )

      assert_received {:router_resolve, :my_scope, 1, [timezone: "America/Chicago"]}
    end

    test "a live agent in the wrong state errors instead of being woken" do
      # Nothing to wake and nothing to resume. Routing this to the wake path
      # would be a no-op that hides a real problem (e.g. the question was
      # already answered from another tab).
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)
      test_pid = self()

      stub(AgentServer, :resume, fn _agent_id, _resume_data ->
        {:error, "Cannot resume, server is not interrupted"}
      end)

      stub(AgentsDynamicSupervisor, :start_agent_sync, fn _opts ->
        send(test_pid, :unexpected_start)
        {:error, :should_not_be_called}
      end)

      assert {:error, "Cannot resume, server is not interrupted"} =
               Session.resume(base_config(), resume_state(), %{type: :answer})

      refute_received :unexpected_start
    end

    test "retries against the process when another caller won the wake race" do
      # Between our failed resume and the start, another tab (or an admin wake)
      # booted the agent. `:pending_resume` is a start-time option, so it was
      # never consumed and the answer would otherwise be silently dropped.
      test_pid = self()
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")

      Process.put(:resume_calls, 0)

      stub(AgentServer, :resume, fn agent_id, resume_data ->
        case Process.get(:resume_calls) do
          0 ->
            Process.put(:resume_calls, 1)
            {:error, :agent_not_running}

          _already_retried ->
            send(test_pid, {:retried, agent_id, resume_data})
            :ok
        end
      end)

      # The agent is up by the time Session.start/3 looks, so it returns
      # started: false without ever reaching the supervisor.
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)

      stub(AgentServer, :subscribe, fn _agent_id, _channel, _pid ->
        {:ok, fake_pid, make_ref()}
      end)

      stub(AgentsDynamicSupervisor, :start_agent_sync, fn _opts ->
        send(test_pid, :unexpected_start)
        {:error, :should_not_be_called}
      end)

      assert {:ok, _changes} = Session.resume(base_config(), resume_state(), %{type: :answer})

      assert_received {:retried, "conversation-1", %{type: :answer}}
      refute_received :unexpected_start
    end

    test "passes a start failure through" do
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :not_running} end)
      stub(AgentServer, :resume, fn _agent_id, _resume_data -> {:error, :agent_not_running} end)
      Process.put(:spy_router_response, {:error, :no_route})

      assert {:error, :no_route} = Session.resume(base_config(), resume_state(), %{type: :answer})
    end
  end

  describe "dismiss/3" do
    test "a live agent holding a halt is dismissed in exactly one call" do
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)

      test_pid = self()

      stub(AgentServer, :dismiss_interrupt, fn agent_id ->
        send(test_pid, {:dismiss_called, agent_id})
        :ok
      end)

      stub(AgentsDynamicSupervisor, :start_agent_sync, fn _opts ->
        send(test_pid, :unexpected_start)
        {:error, :should_not_be_called}
      end)

      assert :ok = Session.dismiss(base_config(), resume_state())

      assert_received {:dismiss_called, "conversation-1"}
      refute_received :unexpected_start
    end

    test "a dormant halt is woken and then dismissed" do
      # The regression this exists to prevent: a halt is restorable, so the
      # panel survives the nap, and before this its only button returned
      # {:error, :agent_not_running} forever.
      test_pid = self()
      _fake_pid = stub_supervisor_ok(test_pid)

      Process.put(:dismiss_calls, 0)

      stub(AgentServer, :dismiss_interrupt, fn agent_id ->
        case Process.get(:dismiss_calls) do
          0 ->
            Process.put(:dismiss_calls, 1)
            {:error, :agent_not_running}

          _after_wake ->
            send(test_pid, {:dismissed_after_wake, agent_id})
            :ok
        end
      end)

      assert {:ok, changes} = Session.dismiss(base_config(), resume_state())

      assert changes.agent_id == "conversation-1"
      assert Map.has_key?(changes, :sagents_subs)
      assert_received {:dismissed_after_wake, "conversation-1"}

      # No :pending_dismiss equivalent rides into the boot; the dismissal is a
      # second call once the agent is up.
      assert_receive {:supervisor_config, opts}
      assert opts[:pending_resume] == nil
      assert opts[:initial_subscribers] == [{:main, self()}]
    end

    test "forwards :request_opts on the wake path so the woken agent is configured normally" do
      test_pid = self()
      _fake_pid = stub_supervisor_ok(test_pid)

      Process.put(:dismiss_calls, 0)

      stub(AgentServer, :dismiss_interrupt, fn _agent_id ->
        case Process.get(:dismiss_calls) do
          0 ->
            Process.put(:dismiss_calls, 1)
            {:error, :agent_not_running}

          _after_wake ->
            :ok
        end
      end)

      Session.dismiss(base_config(), resume_state(), request_opts: [timezone: "America/Chicago"])

      assert_received {:router_resolve, :my_scope, 1, [timezone: "America/Chicago"]}
    end

    test "a live agent in the wrong state errors instead of being woken" do
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)
      test_pid = self()

      stub(AgentServer, :dismiss_interrupt, fn _agent_id ->
        {:error, "Cannot dismiss, server is not interrupted (status: idle)"}
      end)

      stub(AgentsDynamicSupervisor, :start_agent_sync, fn _opts ->
        send(test_pid, :unexpected_start)
        {:error, :should_not_be_called}
      end)

      assert {:error, "Cannot dismiss, server is not interrupted (status: idle)"} =
               Session.dismiss(base_config(), resume_state())

      refute_received :unexpected_start
    end

    test "an interrupt needing an explicit response is not woken and not dismissed" do
      # AskUserQuestion and HITL interrupts must go through resume/4. Waking to
      # retry a dismissal they will refuse again is pointless.
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)
      test_pid = self()

      stub(AgentServer, :dismiss_interrupt, fn _agent_id ->
        {:error, "interrupt requires explicit response (use resume)"}
      end)

      stub(AgentsDynamicSupervisor, :start_agent_sync, fn _opts ->
        send(test_pid, :unexpected_start)
        {:error, :should_not_be_called}
      end)

      assert {:error, "interrupt requires explicit response (use resume)"} =
               Session.dismiss(base_config(), resume_state())

      refute_received :unexpected_start
    end

    test "passes a start failure through" do
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:error, :not_running} end)
      stub(AgentServer, :dismiss_interrupt, fn _agent_id -> {:error, :agent_not_running} end)
      Process.put(:spy_router_response, {:error, :no_route})

      assert {:error, :no_route} = Session.dismiss(base_config(), resume_state())
    end

    test "surfaces a post-wake dismissal failure rather than reporting success" do
      test_pid = self()
      _fake_pid = stub_supervisor_ok(test_pid)

      stub(AgentServer, :dismiss_interrupt, fn _agent_id -> {:error, :agent_not_running} end)

      assert {:error, :agent_not_running} = Session.dismiss(base_config(), resume_state())
    end
  end

  describe "start/3 session_info :started flag" do
    test "true when this call created the process" do
      _fake_pid = stub_supervisor_ok(self())

      assert {:ok, %{started: true}} = Session.start(base_config(), 1, scope: :s)
    end

    test "false when an agent was already running" do
      fake_pid = :erlang.list_to_pid(~c"<0.99999.0>")
      stub(AgentServer, :fetch_pid, fn _agent_id -> {:ok, fake_pid} end)

      assert {:ok, %{started: false}} = Session.start(base_config(), 1, scope: :s)
    end
  end
end
