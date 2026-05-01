defmodule Sagents.Middleware.ProcessContextTest do
  @moduledoc """
  End-to-end test that `Sagents.Middleware.ProcessContext` propagates caller-
  process state across all three Sagents process boundaries:

    1. Caller -> AgentServer GenServer  (covered by `on_server_start/2`)
    2. AgentServer -> chain Task        (covered by `before_model/2`)
    3. Chain Task -> per-tool async Task (covered by registering a
       `:on_tool_pre_execution` LangChain callback via `callbacks/1`)

  Also covers the `update/2` API that refreshes the live snapshot for
  long-lived agents whose ambient caller context has changed.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, AgentSupervisor}
  alias Sagents.Middleware.ProcessContext
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.{Function, Message}
  alias LangChain.Message.ToolCall

  setup :set_mimic_global

  # Test-only middleware that exposes the AgentServer GenServer's process
  # dictionary to the test, so we can verify boundary 1 (on_server_start)
  # without coupling that assertion to a specific propagated key.
  defmodule TestProbe do
    @behaviour Sagents.Middleware

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_message({:read_key, key, reply_to}, state, _config) do
      send(reply_to, {:server_dict, key, Process.get(key)})
      {:ok, state}
    end

    def handle_message(_msg, state, _config), do: {:ok, state}
  end

  defp marker_reader_tool(name, async?) do
    test_pid = self()

    Function.new!(%{
      name: name,
      description: "Reads :test_marker from current process dict",
      async: async?,
      parameters_schema: %{type: "object", properties: %{}},
      function: fn _args, _ctx ->
        marker = Process.get(:test_marker)
        send(test_pid, {:tool_saw, name, marker, self()})
        {:ok, marker || "nil"}
      end
    })
  end

  defp build_agent(agent_id, middleware, tools) do
    {:ok, agent} =
      Agent.new(
        %{
          agent_id: agent_id,
          model:
            ChatAnthropic.new!(%{
              model: "claude-sonnet-4-6",
              api_key: "test_key"
            }),
          base_system_prompt: "Test agent",
          middleware: middleware,
          tools: tools
        },
        replace_default_middleware: true
      )

    agent
  end

  defp expect_tool_call_then_done(tool_name) do
    expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
      {:ok,
       [
         Message.new_assistant!(%{
           content: nil,
           tool_calls: [
             ToolCall.new!(%{
               call_id: "call_#{tool_name}_#{:erlang.unique_integer([:positive])}",
               name: tool_name,
               arguments: %{}
             })
           ]
         })
       ]}
    end)

    expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
      {:ok, [Message.new_assistant!("Done")]}
    end)
  end

  defp start_agent_supervised(agent) do
    {:ok, _pid} =
      AgentSupervisor.start_link_sync(
        name: AgentSupervisor.get_name(agent.agent_id),
        agent: agent
      )

    {:ok, _server, _ref} = AgentServer.subscribe(agent.agent_id)
    :ok
  end

  describe "init/1 capture" do
    test "captures process-dict keys from the caller's process" do
      Process.put(:test_marker, "orgA")
      Process.put(:other_key, %{nested: 1})

      agent =
        build_agent(
          "test-#{:erlang.unique_integer([:positive])}",
          [{ProcessContext, keys: [:test_marker, :other_key]}],
          []
        )

      assert [%Sagents.MiddlewareEntry{module: ProcessContext, config: config}] =
               agent.middleware

      assert config.snapshot.keys == [
               {:test_marker, "orgA"},
               {:other_key, %{nested: 1}}
             ]
    end

    test "captures via propagator capture functions" do
      agent_pid = self()

      capture_fn = fn ->
        send(agent_pid, {:capture_ran_in, self()})
        :captured_value
      end

      apply_fn = fn _value -> :ok end

      _agent =
        build_agent(
          "test-#{:erlang.unique_integer([:positive])}",
          [{ProcessContext, propagators: [{capture_fn, apply_fn}]}],
          []
        )

      # capture_fn ran in the test process, not somewhere else
      assert_received {:capture_ran_in, ^agent_pid}
    end

    test "raises on invalid :keys configuration" do
      assert_raise ArgumentError, ~r/:keys must be a list of atoms/, fn ->
        ProcessContext.init(keys: ["not_an_atom"])
      end
    end

    test "raises on invalid :propagators configuration" do
      assert_raise ArgumentError, ~r/:propagators must be a list of/, fn ->
        ProcessContext.init(propagators: [:not_a_tuple])
      end
    end
  end

  describe "boundary 2: chain Task (before_model)" do
    test "propagates to a synchronous tool" do
      Process.put(:test_marker, "orgA")

      agent_id = "test-#{:erlang.unique_integer([:positive])}"
      tool = marker_reader_tool("sync_reader", false)

      agent =
        build_agent(
          agent_id,
          [{ProcessContext, keys: [:test_marker]}],
          [tool]
        )

      expect_tool_call_then_done("sync_reader")
      start_agent_supervised(agent)

      AgentServer.add_message(agent_id, Message.new_user!("Read"))

      assert_receive {:tool_saw, "sync_reader", "orgA", _pid}, 500
      assert_receive {:agent, {:status_changed, :idle, _}}, 500

      AgentServer.stop(agent_id)
    end
  end

  describe "boundary 3: per-tool async Task (on_tool_pre_execution)" do
    test "propagates to an async tool running in a fresh Task" do
      Process.put(:test_marker, "orgA")

      agent_id = "test-#{:erlang.unique_integer([:positive])}"
      tool = marker_reader_tool("async_reader", true)

      agent =
        build_agent(
          agent_id,
          [{ProcessContext, keys: [:test_marker]}],
          [tool]
        )

      expect_tool_call_then_done("async_reader")
      start_agent_supervised(agent)

      AgentServer.add_message(agent_id, Message.new_user!("Read"))

      assert_receive {:tool_saw, "async_reader", marker, tool_pid}, 500
      assert_receive {:agent, {:status_changed, :idle, _}}, 500

      assert marker == "orgA"
      # The tool ran in a different process from the test (async Task spawn)
      assert tool_pid != self()

      AgentServer.stop(agent_id)
    end
  end

  describe "boundary 1: caller -> AgentServer GenServer (on_server_start)" do
    test "propagates into the GenServer's process dictionary" do
      Process.put(:test_marker, "orgA")

      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      agent =
        build_agent(
          agent_id,
          [
            {ProcessContext, keys: [:test_marker]},
            TestProbe
          ],
          []
        )

      start_agent_supervised(agent)

      :ok =
        AgentServer.notify_middleware(
          agent_id,
          TestProbe,
          {:read_key, :test_marker, self()}
        )

      assert_receive {:server_dict, :test_marker, "orgA"}, 1_000

      AgentServer.stop(agent_id)
    end
  end

  describe "propagators (capture/apply pairs)" do
    test "applies captured value via apply_fn at every boundary" do
      Process.delete(:custom_context_holder)

      capture_fn = fn -> "captured_at_init" end

      apply_fn = fn value -> Process.put(:custom_context_holder, value) end

      agent_id = "test-#{:erlang.unique_integer([:positive])}"
      tool_test_pid = self()

      tool =
        Function.new!(%{
          name: "propagator_reader",
          description: "Reads custom context",
          async: true,
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx ->
            send(tool_test_pid, {:propagator_value, Process.get(:custom_context_holder)})
            {:ok, "ok"}
          end
        })

      agent =
        build_agent(
          agent_id,
          [{ProcessContext, propagators: [{capture_fn, apply_fn}]}],
          [tool]
        )

      expect_tool_call_then_done("propagator_reader")
      start_agent_supervised(agent)

      AgentServer.add_message(agent_id, Message.new_user!("Read"))

      assert_receive {:propagator_value, "captured_at_init"}, 500
      assert_receive {:agent, {:status_changed, :idle, _}}, 500

      AgentServer.stop(agent_id)
    end
  end

  describe "update/1 live override" do
    test "second execute sees refreshed marker after update/1" do
      Process.put(:test_marker, "orgA")

      agent_id = "test-#{:erlang.unique_integer([:positive])}"
      tool = marker_reader_tool("async_reader", true)

      agent =
        build_agent(
          agent_id,
          [{ProcessContext, keys: [:test_marker]}],
          [tool]
        )

      # First execute: orgA captured at init time should be visible.
      expect_tool_call_then_done("async_reader")
      start_agent_supervised(agent)

      AgentServer.add_message(agent_id, Message.new_user!("First"))

      assert_receive {:tool_saw, "async_reader", "orgA", _}, 500
      assert_receive {:agent, {:status_changed, :idle, _}}, 500

      # Caller's ambient context changes (e.g. a new request arrives in a
      # LiveView with a different tenant). Refresh the agent before sending
      # the next message — no need to re-specify the spec, the middleware
      # already knows what to capture.
      Process.put(:test_marker, "orgB")
      :ok = ProcessContext.update(agent_id)

      # Second execute: orgB should be visible, proving handle_message
      # replaced the snapshot in state.metadata and on_tool_pre_execution
      # reads the fresh value when the per-tool Task fires.
      expect_tool_call_then_done("async_reader")
      AgentServer.add_message(agent_id, Message.new_user!("Second"))

      assert_receive {:tool_saw, "async_reader", "orgB", _}, 500
      assert_receive {:agent, {:status_changed, :idle, _}}, 500

      AgentServer.stop(agent_id)
    end

    test "update/1 captures via propagator capture_fn at call time" do
      # Use a propagator whose capture_fn reads from the test process dict.
      # The first capture (at init/1) and the second capture (at update/1)
      # should reflect what was in the caller's dict at *each* moment.
      Process.put(:propagator_source, "first")

      apply_fn = fn value -> Process.put(:propagator_target, value) end
      capture_fn = fn -> Process.get(:propagator_source) end

      agent_id = "test-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      tool =
        Function.new!(%{
          name: "propagator_reader",
          description: "Reads :propagator_target",
          async: true,
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx ->
            send(test_pid, {:propagator_target, Process.get(:propagator_target)})
            {:ok, "ok"}
          end
        })

      agent =
        build_agent(
          agent_id,
          [{ProcessContext, propagators: [{capture_fn, apply_fn}]}],
          [tool]
        )

      # First execute uses the init-time capture: "first"
      expect_tool_call_then_done("propagator_reader")
      start_agent_supervised(agent)
      AgentServer.add_message(agent_id, Message.new_user!("First"))

      assert_receive {:propagator_target, "first"}, 500
      assert_receive {:agent, {:status_changed, :idle, _}}, 500

      # Mutate the source, refresh, and the capture_fn should see the new
      # value because update/1 runs it in the caller's process at update time.
      Process.put(:propagator_source, "second")
      :ok = ProcessContext.update(agent_id)

      expect_tool_call_then_done("propagator_reader")
      AgentServer.add_message(agent_id, Message.new_user!("Second"))

      assert_receive {:propagator_target, "second"}, 500
      assert_receive {:agent, {:status_changed, :idle, _}}, 500

      AgentServer.stop(agent_id)
    end

    test "update/1 returns :not_found when the agent is not running" do
      assert ProcessContext.update("nonexistent-agent") == {:error, :not_found}
    end

    test "update/1 returns :no_process_context_middleware when not configured" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"
      agent = build_agent(agent_id, [TestProbe], [])
      start_agent_supervised(agent)

      assert ProcessContext.update(agent_id) == {:error, :no_process_context_middleware}

      AgentServer.stop(agent_id)
    end
  end

  describe "persistence: snapshot lives in state.runtime, not state.metadata" do
    # Regression: the captured snapshot contains tuples and closures that
    # JSON cannot encode. It must live in state.runtime (virtual) so it never
    # reaches the serialized payload that ends up in JSONB.
    test "AgentServer.export_state/1 produces a JSON-encodable payload" do
      Process.put(:test_marker, "orgA")

      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      capture_fn = fn -> :captured_value end
      apply_fn = fn _value -> :ok end

      agent =
        build_agent(
          agent_id,
          [
            {ProcessContext, keys: [:test_marker], propagators: [{capture_fn, apply_fn}]}
          ],
          []
        )

      start_agent_supervised(agent)

      # Synchronize so on_server_start has fully run and the snapshot is in
      # the AgentServer's state.runtime.
      _ = AgentServer.get_state(agent_id)

      exported = AgentServer.export_state(agent_id)

      # The serialized payload has no runtime key (it is virtual) and no
      # ProcessContext entry leaked into metadata.
      refute Map.has_key?(exported["state"], "runtime")
      refute Map.has_key?(exported["state"]["metadata"] || %{}, to_string(ProcessContext))

      # And the whole payload encodes cleanly to JSON for JSONB storage.
      assert {:ok, _json} = Jason.encode(exported)

      AgentServer.stop(agent_id)
    end

    test "the live snapshot still drives propagation (not regressed by the move)" do
      # Sanity: after the metadata→runtime move, the snapshot must still
      # flow through every boundary. We re-prove boundary 3 (per-tool async
      # Task) here as a regression guard.
      Process.put(:test_marker, "orgA")

      agent_id = "test-#{:erlang.unique_integer([:positive])}"
      tool = marker_reader_tool("async_reader", true)

      agent =
        build_agent(
          agent_id,
          [{ProcessContext, keys: [:test_marker]}],
          [tool]
        )

      expect_tool_call_then_done("async_reader")
      start_agent_supervised(agent)

      AgentServer.add_message(agent_id, Message.new_user!("Read"))

      assert_receive {:tool_saw, "async_reader", "orgA", _}, 500
      assert_receive {:agent, {:status_changed, :idle, _}}, 500

      AgentServer.stop(agent_id)
    end
  end

  describe "sub-agent inheritance" do
    # Sub-agents cross another process boundary (parent chain → SubAgentServer).
    # The parent's state.runtime must be copied into the sub-agent's fresh State
    # so its own on_server_start sees the captured snapshot and can re-apply it
    # at every boundary the sub-agent crosses.
    alias Sagents.SubAgent, as: SubAgentStruct

    test "SubAgent.new_from_config/1 copies parent_runtime into the sub-agent's State" do
      Process.put(:test_marker, "orgA")

      {:ok, %{snapshot: snapshot}} =
        ProcessContext.init(
          keys: [:test_marker],
          propagators: [{fn -> :v end, fn _ -> :ok end}]
        )

      parent_runtime = %{ProcessContext => snapshot}

      {:ok, agent_config} =
        Agent.new(
          %{
            agent_id: "sub",
            model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"}),
            base_system_prompt: "Sub agent",
            middleware: [{ProcessContext, keys: [:test_marker]}]
          },
          replace_default_middleware: true
        )

      subagent =
        SubAgentStruct.new_from_config(
          parent_agent_id: "parent",
          instructions: "do work",
          agent_config: agent_config,
          parent_runtime: parent_runtime
        )

      sub_state = subagent.chain.custom_context.state
      assert sub_state.runtime == parent_runtime
      # And metadata is independent — empty by default, not contaminated.
      assert sub_state.metadata == %{}
    end

    test "parent_runtime defaults to %{} when not provided (non-ProcessContext callers)" do
      {:ok, agent_config} =
        Agent.new(
          %{
            agent_id: "sub",
            model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"}),
            base_system_prompt: "Sub agent",
            middleware: []
          },
          replace_default_middleware: true
        )

      subagent =
        SubAgentStruct.new_from_config(
          parent_agent_id: "parent",
          instructions: "do work",
          agent_config: agent_config
        )

      assert subagent.chain.custom_context.state.runtime == %{}
    end
  end
end
