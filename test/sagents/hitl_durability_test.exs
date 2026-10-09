defmodule Sagents.HitlDurabilityTest do
  @moduledoc """
  A HumanInTheLoop approval survives the agent process, from the moment it is
  asked to the moment the approved tools' results are persisted.

  - The pending approval is persisted as placeholder results, and a boot
    rebuilds the interrupt exactly as it was raised.
  - An approval is recorded, and persisted, before any approved tool starts.
    A boot that finds approved calls still marked as running applies their
    tools' `:recovery` policy: report the outcome as unknown (the default), or
    run them again.
  - The real results replace the placeholders, in the canonical state and in
    the rolling state, so every call has exactly one result.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, AgentSupervisor, State}
  alias Sagents.Middleware.HumanInTheLoop
  alias Sagents.Persistence.StateSerializer
  alias Sagents.TestStoredPersistence, as: StoredPersistence
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.{ToolCall, ToolResult}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    StoredPersistence.setup()
    Process.flag(:trap_exit, true)
    :ok
  end

  ## Helpers

  # A gated tool that reports each run to the test and then waits to be told
  # to finish, so a test can act while it is running.
  defp run_command_tool(test_pid) do
    LangChain.Function.new!(%{
      name: "run_command",
      function: fn _args, _context ->
        send(test_pid, {:tool_started, self()})

        receive do
          :finish -> {:ok, "command finished"}
        after
          5_000 -> {:ok, "command finished late"}
        end
      end
    })
  end

  # Holds a run in its before_model hooks once the conversation has tool
  # results, which is where a slow hook (summarization, say) would hold it.
  defmodule BlockAfterToolMiddleware do
    @behaviour Sagents.Middleware

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def before_model(state, %{test_pid: test_pid}) do
      case List.last(state.messages) do
        %Message{role: :tool} ->
          send(test_pid, {:before_model_waiting, self()})

          receive do
            :never -> {:ok, state}
          end

        _other ->
          {:ok, state}
      end
    end
  end

  # The model asks for run_command, then answers once it has a tool result.
  defp stub_model do
    stub(ChatAnthropic, :call, fn _model, messages, _tools ->
      case List.last(messages) do
        %Message{role: :tool} ->
          {:ok, [Message.new_assistant!("all done")]}

        _other ->
          {:ok,
           [
             Message.new_assistant!(%{
               tool_calls: [
                 ToolCall.new!(%{
                   call_id: "call_1",
                   name: "run_command",
                   arguments: %{"cmd" => "reboot"}
                 })
               ]
             })
           ]}
      end
    end)
  end

  defp hitl_agent(tool_config \\ true, extra_middleware \\ []) do
    Agent.new!(
      %{
        agent_id: generate_test_agent_id(),
        model: mock_model(),
        tools: [run_command_tool(self())],
        middleware:
          [{HumanInTheLoop, [interrupt_on: %{"run_command" => tool_config}]}] ++ extra_middleware
      },
      replace_default_middleware: true
    )
  end

  # Runs the agent to its approval interrupt and persists that, as the
  # AgentServer would at :on_interrupt.
  defp persist_pending_approval(agent) do
    assert {:interrupt, interrupted, interrupt_data} =
             Agent.execute(agent, State.new!(%{messages: [Message.new_user!("reboot it")]}))

    StoredPersistence.store(agent.agent_id, interrupted)
    {interrupted, interrupt_data}
  end

  defp start_agent(agent) do
    {:ok, sup} =
      AgentSupervisor.start_link_sync(
        name: AgentSupervisor.get_name(agent.agent_id),
        agent: agent,
        conversation_id: "conv-#{agent.agent_id}",
        agent_persistence: StoredPersistence,
        initial_subscribers: [{:main, self()}]
      )

    sup
  end

  defp kill_agent_server(agent_id) do
    {:ok, pid} = AgentServer.fetch_pid(agent_id)
    Process.exit(pid, :kill)
    wait_until(fn -> match?({:ok, new} when new != pid, AgentServer.fetch_pid(agent_id)) end)
  end

  defp persisted(agent_id, lifecycle) do
    StoredPersistence.writes(agent_id)
    |> Enum.filter(fn {written, _data} -> written == lifecycle end)
    |> Enum.map(fn {_lifecycle, data} ->
      {:ok, state} = StateSerializer.deserialize_state(agent_id, data["state"])
      state
    end)
  end

  defp results_for(%State{messages: messages}, call_id) do
    for %Message{role: :tool, tool_results: results} <- messages,
        %ToolResult{tool_call_id: ^call_id} = result <- results,
        do: result
  end

  defp text(%ToolResult{content: content}),
    do: LangChain.Message.ContentPart.content_to_string(content)

  ## Tests

  describe "a pending approval" do
    test "is persisted with the conversation and boots :interrupted as it was raised" do
      stub_model()
      agent = hitl_agent()
      {interrupted, interrupt_data} = persist_pending_approval(agent)

      assert %Message{role: :tool, tool_results: [placeholder]} = List.last(interrupted.messages)
      assert placeholder.is_interrupt
      assert State.interrupt_restorable?(interrupt_data, agent.middleware)

      start_agent(agent)
      assert_receive {:agent, {:status_changed, :interrupted, ^interrupt_data}}, 1_000
    end

    test "is cancelled into a valid conversation when the user sends a message instead" do
      stub_model()
      agent = hitl_agent()
      {interrupted, _data} = persist_pending_approval(agent)

      cancelled = State.cancel_pending_interrupts(interrupted)
      assert [result] = results_for(cancelled, "call_1")
      refute result.is_interrupt
      assert text(result) =~ "did not respond"
    end
  end

  describe "an approval" do
    test "is persisted before the tool starts, and the result replaces the placeholders" do
      stub_model()
      agent = hitl_agent()
      persist_pending_approval(agent)
      start_agent(agent)
      assert_receive {:agent, {:status_changed, :interrupted, _data}}, 1_000

      assert :ok = AgentServer.resume(agent.agent_id, [%{type: :approve}])
      assert_receive {:tool_started, tool}, 1_000

      # Recorded before the tool ran.
      assert [checkpoint] = persisted(agent.agent_id, :on_resume)

      assert [%ToolResult{interrupt_data: %{in_flight: in_flight}}] =
               results_for(checkpoint, "call_1")

      assert in_flight.outcomes == %{"call_1" => :started}
      assert in_flight.recovery == :report_unknown

      send(tool, :finish)
      assert wait_until(fn -> AgentServer.get_status(agent.agent_id) == :idle end)

      final = AgentServer.get_state(agent.agent_id)
      assert [result] = results_for(final, "call_1")
      refute result.is_interrupt
      assert text(result) == "command finished"
    end

    test "cancelled after the tool finished keeps one result per call" do
      # Cancelled while the follow-up run is in its before_model hooks: the
      # rolling state has the tool's results, and the run has not yet replaced
      # it with its own prepared state.
      stub_model()
      agent = hitl_agent(true, [{BlockAfterToolMiddleware, [test_pid: self()]}])
      persist_pending_approval(agent)
      start_agent(agent)
      assert_receive {:agent, {:status_changed, :interrupted, _data}}, 1_000

      :ok = AgentServer.resume(agent.agent_id, [%{type: :approve}])
      assert_receive {:tool_started, tool}, 1_000
      send(tool, :finish)
      assert_receive {:before_model_waiting, _caller}, 1_000

      :ok = AgentServer.cancel(agent.agent_id)

      assert [cancelled] = persisted(agent.agent_id, :on_cancel)
      assert [result] = results_for(cancelled, "call_1")
      assert text(result) == "command finished"
    end

    test "whose run finishes while the agent stops is persisted, not dropped" do
      stub_model()
      agent = hitl_agent()
      persist_pending_approval(agent)
      start_agent(agent)
      assert_receive {:agent, {:status_changed, :interrupted, _data}}, 1_000

      :ok = AgentServer.resume(agent.agent_id, [%{type: :approve}])
      assert_receive {:tool_started, tool}, 1_000

      {:ok, server} = AgentServer.fetch_pid(agent.agent_id)
      stopping = Task.async(fn -> GenServer.stop(server, :shutdown) end)
      send(tool, :finish)
      Task.await(stopping, 5_000)

      assert [completed] = persisted(agent.agent_id, :on_completion)
      assert [result] = results_for(completed, "call_1")
      assert text(result) == "command finished"
      assert %Message{role: :assistant} = List.last(completed.messages)
    end
  end

  describe "an agent stopped while approved tools were running" do
    test "reports their outcome as unknown by default, and does not run them again" do
      stub_model()
      agent = hitl_agent()
      persist_pending_approval(agent)
      start_agent(agent)
      assert_receive {:agent, {:status_changed, :interrupted, _data}}, 1_000

      :ok = AgentServer.resume(agent.agent_id, [%{type: :approve}])
      assert_receive {:tool_started, _tool}, 1_000

      kill_agent_server(agent.agent_id)

      assert AgentServer.get_status(agent.agent_id) == :idle
      assert [result] = results_for(AgentServer.get_state(agent.agent_id), "call_1")
      assert result.is_error
      assert text(result) =~ "outcome is unknown"
      refute_receive {:tool_started, _tool}, 200
    end

    test "runs them again when their tools allow it" do
      stub_model()
      agent = hitl_agent(%{allowed_decisions: [:approve, :reject], recovery: :reexecute})
      persist_pending_approval(agent)
      start_agent(agent)
      assert_receive {:agent, {:status_changed, :interrupted, _data}}, 1_000

      :ok = AgentServer.resume(agent.agent_id, [%{type: :approve}])
      assert_receive {:tool_started, _first}, 1_000

      kill_agent_server(agent.agent_id)

      assert_receive {:tool_started, second}, 1_000
      send(second, :finish)
      assert wait_until(fn -> AgentServer.get_status(agent.agent_id) == :idle end)

      assert [result] = results_for(AgentServer.get_state(agent.agent_id), "call_1")
      assert text(result) == "command finished"
    end
  end

  describe "in-flight records" do
    defp in_flight_state(outcome, recovery) do
      data = %{
        action_requests: [%{tool_call_id: "call_1", tool_name: "run_command", arguments: %{}}],
        review_configs: %{"run_command" => %{allowed_decisions: [:approve, :reject]}},
        hitl_tool_call_ids: ["call_1"],
        in_flight: %{
          decisions: [%{type: :reject}],
          outcomes: %{"call_1" => outcome},
          recovery: recovery
        }
      }

      State.new!(%{
        messages: [
          Message.new_user!("reboot it"),
          Message.new_assistant!(%{
            tool_calls: [ToolCall.new!(%{call_id: "call_1", name: "run_command", arguments: %{}})]
          }),
          Message.new_tool_result!(%{
            content: nil,
            tool_results: [
              ToolResult.new!(%{
                tool_call_id: "call_1",
                name: "run_command",
                content: "Waiting for a human to review this tool call.",
                is_interrupt: true,
                interrupt_data: data
              })
            ]
          })
        ]
      })
    end

    test "a rejected call is recorded as rejected, not as an error" do
      agent = hitl_agent()

      cleaned =
        State.clean_stale_interrupts(
          in_flight_state(:rejected, :report_unknown),
          agent.middleware
        )

      assert [result] = results_for(cleaned, "call_1")
      refute result.is_interrupt
      refute result.is_error
      assert text(result) =~ "rejected by a human reviewer"
    end

    test "a cancelled one says its outcome is unknown, not that the user did not answer" do
      cancelled = State.cancel_pending_interrupts(in_flight_state(:started, :reexecute))

      assert [result] = results_for(cancelled, "call_1")
      assert text(result) =~ "outcome is unknown"
    end
  end

  describe "configuration" do
    test "an unknown :recovery policy is refused" do
      assert_raise ArgumentError, ~r/invalid :recovery/, fn ->
        HumanInTheLoop.init(interrupt_on: %{"run_command" => %{recovery: :retry}})
      end
    end
  end

  describe "middleware callbacks" do
    defmodule ToolDoneMiddleware do
      @behaviour Sagents.Middleware

      @impl true
      def init(opts), do: {:ok, Map.new(opts)}

      @impl true
      def callbacks(%{test_pid: pid}) do
        %{
          on_tool_execution_completed: fn _chain, call, _result ->
            send(pid, {:middleware_saw, call.name})
          end
        }
      end
    end

    test "fire for the tool executions a human approved" do
      stub_model()
      agent = hitl_agent(true, [{ToolDoneMiddleware, [test_pid: self()]}])

      {:interrupt, interrupted, _data} =
        Agent.execute(agent, State.new!(%{messages: [Message.new_user!("reboot it")]}))

      resume = Task.async(fn -> Agent.resume(agent, interrupted, [%{type: :approve}]) end)
      assert_receive {:tool_started, tool}, 1_000
      send(tool, :finish)
      assert {:ok, _final} = Task.await(resume)

      assert_receive {:middleware_saw, "run_command"}, 1_000
    end
  end
end
