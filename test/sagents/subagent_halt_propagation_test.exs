defmodule Sagents.SubAgentHaltPropagationTest do
  @moduledoc """
  A `:halt` raised by a tool *inside a sub-agent* must reach the parent as a
  halt.

  `Sagents.Middleware.Haltable` defines a halt as terminal: the framework does
  not invoke the LLM again, the author-facing `:message` is surfaced, and the
  interrupt survives cold start so a UI can re-render it. Halt was originally
  designed for a tool called directly by a top-level agent; these tests cover
  the sub-agent case.

  Previously `Middleware.SubAgent` wrapped *every* sub-agent interrupt as
  `%{type: :subagent_hitl}` with the message "requires human approval". The
  halt survived nested under `:interrupt_data`, but everything that enforces
  halt semantics dispatches on the *outer* type, so all three guarantees were
  lost: the loop kept running, `Haltable` refused to claim it, and the UI
  rendered an empty approval prompt instead of the halt message.
  """

  use ExUnit.Case, async: false
  use Mimic

  import Sagents.TestingHelpers, only: [wait_until: 1]

  alias Sagents.{Agent, AgentUtils, State, SubAgent, SubAgentServer}
  alias Sagents.Middleware.Haltable
  alias Sagents.SubAgentsDynamicSupervisor
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    unless Process.whereis(Sagents.Registry) do
      {:ok, _pid} = Registry.start_link(keys: :unique, name: Sagents.Registry)
    end

    Mimic.copy(ChatAnthropic)

    :ok
  end

  @halt_message "The outline is missing required sections. Fix and retry."

  defp test_model do
    ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"})
  end

  # Halts from inside its body, exactly as the Haltable moduledoc documents.
  defp halting_tool do
    Function.new!(%{
      name: "gate_check",
      description: "Checks a policy gate",
      function: fn _args, _context ->
        {:interrupt, "Workflow halted: policy gate failed",
         %{type: :halt, source_tool: "gate_check", message: @halt_message}}
      end
    })
  end

  # Emits a non-halt tool interrupt, to prove the HITL path is untouched.
  defp escalating_tool do
    Function.new!(%{
      name: "escalate",
      description: "Escalates for approval",
      function: fn _args, _context ->
        {:interrupt, "Escalation required", %{type: :escalation, capability: "finance_export"}}
      end
    })
  end

  defp make_parent_agent(subagent_configs) do
    agent =
      Agent.new!(
        %{
          agent_id: "parent-#{System.unique_integer([:positive])}",
          model: test_model(),
          system_prompt: "You delegate tasks to sub-agents."
        },
        subagent_opts: [subagents: subagent_configs]
      )

    {:ok, _pid} = SubAgentsDynamicSupervisor.start_link(agent_id: agent.agent_id)

    agent
  end

  defp subagent_config(tool) do
    SubAgent.Config.new!(%{
      name: "scout",
      description: "Scouts an outline",
      system_prompt: "You scout outlines.",
      tools: [tool]
    })
  end

  # Parent calls `task`; the sub-agent calls `tool_name`, which interrupts.
  # Any further LLM call means the interrupt failed to stop the loop, so the
  # stub raises rather than quietly letting the run continue.
  defp stub_llm(tool_name) do
    call_count = :counters.new(1, [:atomics])

    ChatAnthropic
    |> stub(:call, fn _model, _messages, _tools ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      case count do
        0 ->
          {:ok,
           [
             Message.new_assistant!(%{
               tool_calls: [
                 ToolCall.new!(%{
                   call_id: "parent_tc_1",
                   name: "task",
                   arguments: %{"instructions" => "Scout the outline", "task_name" => "scout"}
                 })
               ]
             })
           ]}

        1 ->
          {:ok,
           [
             Message.new_assistant!(%{
               tool_calls: [
                 ToolCall.new!(%{call_id: "sub_tc_1", name: tool_name, arguments: %{}})
               ]
             })
           ]}

        n ->
          raise "LLM called again (##{n}) after the sub-agent interrupted"
      end
    end)

    call_count
  end

  defp run_until_interrupt(tool) do
    agent = make_parent_agent([subagent_config(tool)])
    call_count = stub_llm(tool.name)
    initial_state = State.new!(%{messages: [Message.new_user!("Scout the outline")]})

    {Agent.execute(agent, initial_state), call_count}
  end

  describe "a :halt raised inside a sub-agent" do
    test "reaches the parent as a :halt, preserving the author-facing message" do
      {result, _count} = run_until_interrupt(halting_tool())

      assert {:interrupt, _state, interrupt_data} = result

      assert interrupt_data.type == :halt
      assert interrupt_data.message == @halt_message

      # Provenance is preserved: which tool halted, and which task it ran under.
      assert interrupt_data.source_tool == "gate_check"
      assert interrupt_data.source_task == "scout"
    end

    test "stops the loop without another LLM call" do
      # The central Haltable guarantee: "the framework does NOT invoke the LLM
      # again". Two calls total: the parent's `task` and the sub-agent's
      # `gate_check`. A third would mean the halt was demoted to a tool result.
      {result, call_count} = run_until_interrupt(halting_tool())

      assert {:interrupt, _state, _data} = result
      assert :counters.get(call_count, 1) == 2
    end

    test "is claimed by Haltable, so it survives cold start" do
      {result, _count} = run_until_interrupt(halting_tool())

      assert {:interrupt, _state, interrupt_data} = result
      assert Haltable.restorable_interrupt?(interrupt_data)
    end

    test "surfaces the halt message to the UI instead of an empty approval prompt" do
      {result, _count} = run_until_interrupt(halting_tool())

      assert {:interrupt, _state, interrupt_data} = result

      changes = AgentUtils.interrupt_session_changes(interrupt_data)

      assert %{pending_halt: %{message: @halt_message}} = changes
      assert Map.get(changes, :pending_tools, []) == []
    end

    test "carries no reference to the sub-agent process, so it is pure data" do
      # A restorable interrupt must not point at a process that will not
      # survive a reboot. This is why the halt is propagated rather than
      # wrapped: the `:subagent_hitl` wrapper carries :sub_agent_id.
      {result, _count} = run_until_interrupt(halting_tool())

      assert {:interrupt, _state, interrupt_data} = result

      refute Map.has_key?(interrupt_data, :sub_agent_id)

      # LangChain refills :tool_call_id with the *parent's* task call, not the
      # sub-agent's inner call.
      assert interrupt_data.tool_call_id == "parent_tc_1"
    end

    test "stops the sub-agent process, since there is nothing to resume" do
      agent = make_parent_agent([subagent_config(halting_tool())])
      stub_llm("gate_check")
      initial_state = State.new!(%{messages: [Message.new_user!("Scout the outline")]})

      assert {:interrupt, _state, _data} = Agent.execute(agent, initial_state)

      # No sub-agent processes should be left running under this parent. The
      # propagated halt carries no :sub_agent_id to look up, so check the
      # parent's sub-agent supervisor directly.
      supervisor = SubAgentsDynamicSupervisor.whereis(agent.agent_id)

      assert wait_until(fn ->
               DynamicSupervisor.count_children(supervisor).active == 0
             end)
    end
  end

  describe "halt wins inside :multiple_interrupts" do
    test "a halt sibling propagates as a halt" do
      batch = %{
        type: :multiple_interrupts,
        interrupts: [
          %{type: :ask_user_question, question: "Which one?", tool_call_id: "a"},
          %{type: :halt, source_tool: "gate_check", message: @halt_message, tool_call_id: "b"}
        ]
      }

      assert %{type: :halt, message: @halt_message} = find_halt_via_public_behaviour(batch)
    end

    test "a batch with no halt is left to the HITL path" do
      batch = %{
        type: :multiple_interrupts,
        interrupts: [%{type: :ask_user_question, question: "Which one?", tool_call_id: "a"}]
      }

      assert find_halt_via_public_behaviour(batch) == nil
    end
  end

  describe "non-halt sub-agent interrupts" do
    test "still propagate as :subagent_hitl and keep the sub-agent alive" do
      # Regression guard: the halt branch must not swallow ordinary tool-raised
      # interrupts, which still need the approval round-trip.
      {result, _count} = run_until_interrupt(escalating_tool())

      assert {:interrupt, _state, interrupt_data} = result

      assert interrupt_data.type == :subagent_hitl
      assert interrupt_data.task_name == "scout"
      assert %{type: :escalation} = interrupt_data.interrupt_data

      # Kept alive for the resume leg.
      assert SubAgentServer.whereis(interrupt_data.sub_agent_id) != nil
    end
  end

  # `find_halt/1` is private. Exercise the same policy through the behaviour it
  # drives: Haltable claims exactly the batches that contain a halt, which is
  # the rule `find_halt/1` implements.
  defp find_halt_via_public_behaviour(%{type: :multiple_interrupts, interrupts: subs} = batch) do
    if Haltable.restorable_interrupt?(batch) do
      Enum.find(subs, &match?(%{type: :halt}, &1))
    end
  end
end
