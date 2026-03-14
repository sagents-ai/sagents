defmodule Sagents.AgentServerContextPropagationTest do
  @moduledoc """
  Tests that AgentContext (including middleware-injected process-local state)
  is properly propagated across the Task.async boundary in AgentServer's
  execute and resume handlers.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentContext, AgentServer, State}
  alias Sagents.MiddlewareEntry

  @process_dict_key {__MODULE__, :forked_state}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  # A test middleware that uses on_fork_context to register a restore function.
  # The restore function sets a marker in the child process's process dictionary,
  # proving that on_fork_context callbacks fire at the Task.async boundary.
  # This simulates what OTel middleware would do (capture span ctx, restore it).
  defmodule ProcessDictMiddleware do
    @behaviour Sagents.Middleware

    @impl true
    def on_fork_context(context, _config) do
      # Register a restore function that sets a marker in the child process
      AgentContext.add_restore_fn(context, fn _ctx ->
        Process.put(
          {Sagents.AgentServerContextPropagationTest, :forked_state},
          "restored-by-middleware"
        )
      end)
    end
  end

  defp create_agent_with_fork_middleware do
    middleware_entry = %MiddlewareEntry{
      id: ProcessDictMiddleware,
      module: ProcessDictMiddleware,
      config: %{}
    }

    Agent.new!(%{
      agent_id: generate_test_agent_id(),
      model: mock_model(),
      base_system_prompt: "Test agent",
      replace_default_middleware: true,
      middleware: []
    })
    |> Map.update!(:middleware, fn existing -> existing ++ [middleware_entry] end)
  end

  describe "execute context propagation" do
    test "propagates AgentContext into Task.async via fork_with_middleware" do
      agent = create_agent_with_fork_middleware()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, fn _agent, state, _opts ->
        # Inside Task.async — verify AgentContext was propagated
        ctx = AgentContext.get()
        send(test_pid, {:task_context, ctx})
        {:ok, state}
      end)

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          name: AgentServer.get_name(agent_id),
          pubsub: nil,
          agent_context: %{tenant_id: 42, trace_id: "test-trace"}
        )

      AgentServer.execute(agent_id)

      assert_receive {:task_context, ctx}, 1_000
      assert ctx.tenant_id == 42
      assert ctx.trace_id == "test-trace"
    end

    test "on_fork_context restore functions run in Task.async process" do
      agent = create_agent_with_fork_middleware()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, fn _agent, state, _opts ->
        # Inside Task.async — verify the restore function ran and set the marker
        restored_value = Process.get(@process_dict_key)
        send(test_pid, {:restored_value, restored_value})
        {:ok, state}
      end)

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          name: AgentServer.get_name(agent_id),
          pubsub: nil,
          agent_context: %{tenant_id: 42}
        )

      AgentServer.execute(agent_id)

      assert_receive {:restored_value, restored}, 1_000
      assert restored == "restored-by-middleware"
    end
  end

  describe "resume context propagation" do
    test "propagates AgentContext into Task.async on resume" do
      agent = create_agent_with_fork_middleware()
      agent_id = agent.agent_id
      test_pid = self()

      interrupt_data = %{
        type: :hitl,
        tool_calls: [%{name: "test_tool", call_id: "tc-1"}]
      }

      # First execute — return an interrupt
      Agent
      |> expect(:execute, fn _agent, state, _opts ->
        {:interrupt, state, interrupt_data}
      end)

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          name: AgentServer.get_name(agent_id),
          pubsub: nil,
          agent_context: %{tenant_id: 42, trace_id: "resume-trace"}
        )

      AgentServer.execute(agent_id)

      # Wait for interrupt status
      Process.sleep(50)
      assert AgentServer.get_status(agent_id) == :interrupted

      # Now resume — verify context is propagated
      Agent
      |> expect(:resume, fn _agent, _state, _decisions, _opts ->
        ctx = AgentContext.get()
        send(test_pid, {:resume_context, ctx})
        {:ok, State.new!()}
      end)

      AgentServer.resume(agent_id, [%{tool_call_id: "tc-1", approved: true}])

      assert_receive {:resume_context, ctx}, 1_000
      assert ctx.tenant_id == 42
      assert ctx.trace_id == "resume-trace"
    end

    test "on_fork_context restore functions run in Task.async on resume" do
      agent = create_agent_with_fork_middleware()
      agent_id = agent.agent_id
      test_pid = self()

      interrupt_data = %{
        type: :hitl,
        tool_calls: [%{name: "test_tool", call_id: "tc-1"}]
      }

      # First execute — return an interrupt
      Agent
      |> expect(:execute, fn _agent, state, _opts ->
        {:interrupt, state, interrupt_data}
      end)

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          name: AgentServer.get_name(agent_id),
          pubsub: nil,
          agent_context: %{tenant_id: 42}
        )

      AgentServer.execute(agent_id)

      Process.sleep(50)
      assert AgentServer.get_status(agent_id) == :interrupted

      # Resume — verify the restore function set the process dict marker
      Agent
      |> expect(:resume, fn _agent, _state, _decisions, _opts ->
        restored_value = Process.get(@process_dict_key)
        send(test_pid, {:restored_value, restored_value})
        {:ok, State.new!()}
      end)

      AgentServer.resume(agent_id, [%{tool_call_id: "tc-1", approved: true}])

      assert_receive {:restored_value, restored}, 1_000
      assert restored == "restored-by-middleware"
    end
  end
end
