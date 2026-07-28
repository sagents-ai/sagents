defmodule Sagents.SubAgentHaltSemanticsTest do
  @moduledoc """
  Pins what happens when a tool *inside a sub-agent* emits a `:halt`.

  `Sagents.Middleware.Haltable` defines a halt as terminal: the framework must
  not invoke the LLM again, the halt's `:message` is surfaced to the user, and
  the interrupt survives cold start so a UI can re-render it.

  Those guarantees hold for a halt raised in a top-level agent. Raised inside a
  sub-agent they do not, because `Middleware.SubAgent`'s `execute_subagent/2`
  wraps *every* sub-agent interrupt into `%{type: :subagent_hitl}` with the
  message "requires human approval". The `:halt` type is still present nested
  under `:interrupt_data`, but nothing that enforces halt semantics looks
  there — `Haltable.restorable_interrupt?/1` and
  `AgentUtils.interrupt_session_changes/1` both dispatch on the *outer* type.

  These tests document current behaviour so a future fix has a baseline. They
  are deliberately written to pass both before and after the `SubAgent.resume/3`
  fix: that fix runs only on the resume leg, after the wrapping above has
  already happened, so it neither causes nor worsens the loss recorded here.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Sagents.{Agent, AgentUtils, State, SubAgent}
  alias Sagents.Middleware.Haltable
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias Sagents.SubAgentsDynamicSupervisor

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

  # A tool that halts the workflow from inside its body, exactly as the
  # Haltable moduledoc documents.
  defp halting_tool do
    Function.new!(%{
      name: "gate_check",
      description: "Checks a policy gate",
      function: fn _args, _context ->
        {:interrupt, "Workflow halted: policy gate failed",
         %{
           type: :halt,
           source_tool: "gate_check",
           message: @halt_message
         }}
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

  defp halting_subagent_config do
    SubAgent.Config.new!(%{
      name: "scout",
      description: "Scouts an outline",
      system_prompt: "You scout outlines.",
      tools: [halting_tool()]
    })
  end

  # Drives: parent calls the `task` tool, sub-agent calls `gate_check`, which
  # halts. Any LLM call after that means the halt failed to stop the loop.
  defp stub_llm_until_halt(extra_responses \\ []) do
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
                 ToolCall.new!(%{call_id: "sub_tc_1", name: "gate_check", arguments: %{}})
               ]
             })
           ]}

        n ->
          case Enum.at(extra_responses, n - 2) do
            nil -> raise "unexpected LLM call ##{n} after halt"
            response -> {:ok, [Message.new_assistant!(%{content: response})]}
          end
      end
    end)

    call_count
  end

  describe "a :halt raised inside a sub-agent" do
    test "reaches the parent as :subagent_hitl, with the halt buried one level down" do
      agent = make_parent_agent([halting_subagent_config()])
      stub_llm_until_halt()

      initial_state = State.new!(%{messages: [Message.new_user!("Scout the outline")]})

      assert {:interrupt, _state, interrupt_data} = Agent.execute(agent, initial_state)

      # The outer type is an approval request, not a halt. This is the loss:
      # every consumer that dispatches on `interrupt_data.type` now sees a
      # HITL approval where the tool asked to terminate the workflow.
      assert interrupt_data.type == :subagent_hitl
      refute interrupt_data.type == :halt

      # The halt itself does survive, nested — a future fix has something to
      # unwrap rather than having to reconstruct it.
      assert %{type: :halt, message: @halt_message, source_tool: "gate_check"} =
               interrupt_data.interrupt_data
    end

    test "is not claimed by Haltable, so it does not survive cold start as a halt" do
      wrapped = %{
        type: :subagent_hitl,
        sub_agent_id: "sub-1",
        task_name: "scout",
        tool_call_id: "parent_tc_1",
        interrupt_data: %{type: :halt, message: @halt_message, source_tool: "gate_check"}
      }

      # A bare halt is restorable; the same halt inside a sub-agent wrapper is not.
      assert Haltable.restorable_interrupt?(wrapped.interrupt_data)
      refute Haltable.restorable_interrupt?(wrapped)
    end

    test "renders as an empty approval prompt rather than the halt message" do
      wrapped = %{
        type: :subagent_hitl,
        sub_agent_id: "sub-1",
        task_name: "scout",
        tool_call_id: "parent_tc_1",
        interrupt_data: %{type: :halt, message: @halt_message, source_tool: "gate_check"}
      }

      changes = AgentUtils.interrupt_session_changes(wrapped)

      # A bare halt populates :pending_halt with the author-facing message.
      assert %{pending_halt: %{message: @halt_message}} =
               AgentUtils.interrupt_session_changes(wrapped.interrupt_data)

      # The wrapped halt falls through to the HITL presenter, which finds no
      # :action_requests inside a halt — so the user sees an approval prompt
      # with nothing in it, and never sees @halt_message.
      assert Map.get(changes, :pending_halt) == nil
      assert Map.get(changes, :pending_tools) == []
    end
  end

  describe "resuming a sub-agent that halted" do
    test "returns a named error rather than crashing the caller" do
      # The resume leg. Before the SubAgent.resume/3 fix this raised
      # `KeyError: key :action_requests not found` from inside SubAgentServer
      # and took the calling process down with it.
      interrupt_data = %{
        type: :halt,
        message: @halt_message,
        source_tool: "gate_check",
        tool_call_id: "sub_tc_1"
      }

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Scout the outline",
          agent_config:
            Sagents.Agent.new!(%{
              model: test_model(),
              base_system_prompt: "You scout outlines.",
              replace_default_middleware: true,
              middleware: [],
              tools: [halting_tool()]
            }),
          parent_state: %{messages: []}
        )

      halted = %{subagent | status: :interrupted, interrupt_data: interrupt_data}

      assert {:error, {:unsupported_interrupt, :tool_raised}} =
               SubAgent.resume(halted, [%{type: :approve}])
    end

    test "the parent turns that error into a tool result and keeps going" do
      # Documents the consequence, and the reason this is worth a follow-up:
      # a halt asked the framework to stop calling the LLM, but the parent
      # resumes and calls it again. That is a semantic gap in the *wrapping*,
      # not in the resume fix — before the fix this path crashed instead.
      agent = make_parent_agent([halting_subagent_config()])
      call_count = stub_llm_until_halt(["I could not complete the scouting task."])

      initial_state = State.new!(%{messages: [Message.new_user!("Scout the outline")]})

      assert {:interrupt, interrupted_state, _data} = Agent.execute(agent, initial_state)

      # Two LLM calls so far: the parent's `task` call and the sub-agent's
      # `gate_check` call. The halt fired on the second.
      assert :counters.get(call_count, 1) == 2

      assert {:ok, final_state} = Agent.resume(agent, interrupted_state, [%{type: :approve}])

      # The guarantee Haltable states is "the framework does NOT invoke the LLM
      # again". Here it does — a third call happened after the halt. This is the
      # concrete semantic violation, and it is caused by the `:subagent_hitl`
      # wrapping, not by the resume fix.
      assert :counters.get(call_count, 1) == 3

      # The interrupt placeholder was demoted to a concrete result...
      refute Enum.any?(final_state.messages, fn msg ->
               msg.role == :tool and Enum.any?(msg.tool_results, & &1.is_interrupt)
             end)

      # ...and it is an error result naming the unsupported interrupt.
      error_result =
        final_state.messages
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.flat_map(& &1.tool_results)
        |> Enum.find(& &1.is_error)

      assert error_result != nil
      assert result_text(error_result.content) =~ "unsupported_interrupt"
    end
  end

  defp result_text(content) when is_binary(content), do: content

  defp result_text(content) when is_list(content),
    do: Enum.map_join(content, "", fn %{content: c} -> to_string(c) end)

  defp result_text(other), do: inspect(other)
end
