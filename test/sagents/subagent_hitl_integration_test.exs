defmodule Sagents.SubagentHitlIntegrationTest do
  @moduledoc """
  Integration tests for sub-agent HITL interrupt propagation through the
  Agent execution pipeline.

  These tests verify the full lifecycle:
  - Agent executes → tool returns InterruptSignal → Agent returns {:interrupt, ...}
  - Agent.resume → re-executes task tool with resume_info → sub-agent completes
  - Multiple interrupt-resume cycles work correctly
  """

  use Sagents.BaseCase, async: true
  use Mimic

  alias Sagents.{Agent, State}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  setup :verify_on_exit!

  # Helper: create a task tool that simulates sub-agent behavior
  defp build_mock_task_tool(test_pid) do
    LangChain.Function.new!(%{
      name: "task",
      description: "Delegate to sub-agent",
      parameters_schema: %{
        type: "object",
        required: ["instructions", "subagent_type"],
        properties: %{
          "instructions" => %{type: "string"},
          "subagent_type" => %{type: "string"}
        }
      },
      function: fn args, context ->
        # Notify test process so we can track calls
        send(test_pid, {:task_tool_called, args, context})

        case Map.get(context, :resume_info) do
          nil ->
            # First execution: return interrupt signal
            {:ok, "SubAgent 'researcher' requires human approval.",
             %Sagents.InterruptSignal{
               type: :subagent_hitl,
               sub_agent_id: "sub-1",
               subagent_type: Map.get(args, "subagent_type", "researcher"),
               interrupt_data: %{
                 action_requests: [
                   %{tool_call_id: "inner-tc-1", tool_name: "search", arguments: %{"q" => "test"}}
                 ]
               }
             }}

          %{sub_agent_id: _} ->
            # Resume: return completion
            {:ok, "Research completed: found 42 results"}
        end
      end
    })
  end

  describe "sub-agent HITL interrupt propagates through Agent.execute" do
    test "full interrupt-resume cycle completes successfully" do
      test_pid = self()
      task_tool = build_mock_task_tool(test_pid)

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [task_tool],
            middleware: []
          },
          replace_default_middleware: true,
          interrupt_on: %{"task" => true}
        )

      # Phase 1: LLM decides to call the task tool
      tool_call =
        ToolCall.new!(%{
          call_id: "call-1",
          name: "task",
          arguments: %{"instructions" => "research something", "subagent_type" => "researcher"}
        })

      # First LLM call returns tool call; second returns final response
      call_count = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          0 ->
            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}

          _ ->
            {:ok, [Message.new_assistant!("Here are the research results: 42 items found.")]}
        end
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Research AI topics")]})

      # Execute should return interrupt
      assert {:interrupt, interrupted_state, interrupt_data} =
               Agent.execute(agent, initial_state)

      assert interrupt_data.type == :subagent_hitl
      assert interrupt_data.sub_agent_id == "sub-1"
      assert interrupted_state.interrupt_data == interrupt_data

      # Verify tool was called (first execution)
      assert_received {:task_tool_called, _args, context}
      refute Map.has_key?(context, :resume_info)

      # Phase 2: Resume with decisions
      decisions = [%{type: :approve}]

      assert {:ok, final_state} = Agent.resume(agent, interrupted_state, decisions)

      # Verify tool was called again (resume)
      assert_received {:task_tool_called, _args, resume_context}
      assert resume_context.resume_info.sub_agent_id == "sub-1"

      # Final state should have completion
      assert %State{} = final_state
      assert final_state.interrupt_data == nil
    end

    test "multiple interrupt-resume cycles work correctly" do
      test_pid = self()
      cycle_count = :counters.new(1, [:atomics])

      # Tool that interrupts twice, then completes
      task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate to sub-agent",
          parameters_schema: %{
            type: "object",
            required: ["instructions", "subagent_type"],
            properties: %{
              "instructions" => %{type: "string"},
              "subagent_type" => %{type: "string"}
            }
          },
          function: fn _args, context ->
            send(test_pid, {:task_tool_called, :counters.get(cycle_count, 1)})

            case Map.get(context, :resume_info) do
              nil ->
                # First execution: interrupt
                :counters.add(cycle_count, 1, 1)

                {:ok, "SubAgent requires approval.",
                 %Sagents.InterruptSignal{
                   type: :subagent_hitl,
                   sub_agent_id: "sub-1",
                   subagent_type: "researcher",
                   interrupt_data: %{
                     action_requests: [
                       %{
                         tool_call_id: "inner-tc-1",
                         tool_name: "search",
                         arguments: %{"q" => "cycle 1"}
                       }
                     ]
                   }
                 }}

              %{sub_agent_id: "sub-1"} ->
                count = :counters.get(cycle_count, 1)
                :counters.add(cycle_count, 1, 1)

                if count < 2 do
                  # Second time: another interrupt
                  {:ok, "SubAgent requires approval again.",
                   %Sagents.InterruptSignal{
                     type: :subagent_hitl,
                     sub_agent_id: "sub-1",
                     subagent_type: "researcher",
                     interrupt_data: %{
                       action_requests: [
                         %{
                           tool_call_id: "inner-tc-2",
                           tool_name: "write_file",
                           arguments: %{"path" => "/output.txt"}
                         }
                       ]
                     }
                   }}
                else
                  # Third time: complete
                  {:ok, "Research completed successfully"}
                end
            end
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [task_tool],
            middleware: []
          },
          replace_default_middleware: true,
          interrupt_on: %{"task" => true}
        )

      tool_call =
        ToolCall.new!(%{
          call_id: "call-1",
          name: "task",
          arguments: %{"instructions" => "research", "subagent_type" => "researcher"}
        })

      llm_call_count = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        count = :counters.get(llm_call_count, 1)
        :counters.add(llm_call_count, 1, 1)

        case count do
          0 ->
            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}

          _ ->
            {:ok, [Message.new_assistant!("Done with all research.")]}
        end
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Research")]})

      # Cycle 1: execute → interrupt
      assert {:interrupt, state1, data1} = Agent.execute(agent, initial_state)
      assert data1.type == :subagent_hitl

      # Cycle 2: resume → interrupt again
      assert {:interrupt, state2, data2} = Agent.resume(agent, state1, [%{type: :approve}])
      assert data2.type == :subagent_hitl
      # No stale interrupt_data from cycle 1
      refute data2.interrupt_data == data1.interrupt_data

      # Cycle 3: resume → complete
      assert {:ok, final_state} = Agent.resume(agent, state2, [%{type: :approve}])
      assert final_state.interrupt_data == nil
    end
  end

  describe "parallel sub-agent multi-interrupt resolution" do
    test "parallel sub-agent interrupts resolved sequentially" do
      test_pid = self()
      resume_count = :counters.new(1, [:atomics])

      # Tool that returns InterruptSignal with different sub_agent_id based on subagent_type
      task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate to sub-agent",
          parameters_schema: %{
            type: "object",
            required: ["instructions", "subagent_type"],
            properties: %{
              "instructions" => %{type: "string"},
              "subagent_type" => %{type: "string"}
            }
          },
          function: fn args, context ->
            send(test_pid, {:task_tool_called, args, context})
            subagent_type = Map.get(args, "subagent_type", "unknown")

            case Map.get(context, :resume_info) do
              nil ->
                # First execution: return interrupt signal
                {:ok, "SubAgent '#{subagent_type}' requires human approval.",
                 %Sagents.InterruptSignal{
                   type: :subagent_hitl,
                   sub_agent_id: "sub-#{subagent_type}",
                   subagent_type: subagent_type,
                   interrupt_data: %{
                     action_requests: [
                       %{
                         tool_call_id: "inner-tc-#{subagent_type}",
                         tool_name: "action_#{subagent_type}",
                         arguments: %{"q" => subagent_type}
                       }
                     ]
                   }
                 }}

              %{sub_agent_id: _} ->
                # Resume: return completion
                :counters.add(resume_count, 1, 1)
                {:ok, "#{subagent_type} completed successfully"}
            end
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [task_tool],
            middleware: []
          },
          replace_default_middleware: true,
          interrupt_on: %{"task" => true}
        )

      # LLM returns TWO parallel task tool calls
      tool_call1 =
        ToolCall.new!(%{
          call_id: "call-1",
          name: "task",
          arguments: %{"instructions" => "research", "subagent_type" => "researcher"}
        })

      tool_call2 =
        ToolCall.new!(%{
          call_id: "call-2",
          name: "task",
          arguments: %{"instructions" => "write code", "subagent_type" => "coder"}
        })

      llm_call_count = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        count = :counters.get(llm_call_count, 1)
        :counters.add(llm_call_count, 1, 1)

        case count do
          0 ->
            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call1, tool_call2]})]}

          _ ->
            {:ok, [Message.new_assistant!("All tasks completed.")]}
        end
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Do both tasks")]})

      # Execute → should interrupt with first signal, queue second
      assert {:interrupt, state1, data1} = Agent.execute(agent, initial_state)
      assert data1.type == :subagent_hitl
      assert data1.sub_agent_id == "sub-researcher"
      assert data1.tool_call_id == "call-1"
      assert length(data1.pending_interrupts) == 1

      [pending] = data1.pending_interrupts
      assert pending.sub_agent_id == "sub-coder"
      assert pending.tool_call_id == "call-2"

      # Resume first → should pop second interrupt
      assert {:interrupt, state2, data2} = Agent.resume(agent, state1, [%{type: :approve}])
      assert data2.type == :subagent_hitl
      assert data2.sub_agent_id == "sub-coder"
      assert data2.tool_call_id == "call-2"
      assert data2.pending_interrupts == []

      # Resume second → should complete
      assert {:ok, final_state} = Agent.resume(agent, state2, [%{type: :approve}])
      assert final_state.interrupt_data == nil

      # Both resumes should have happened
      assert :counters.get(resume_count, 1) == 2
    end

    test "parallel sub-agents where one completes and one interrupts" do
      test_pid = self()

      # Tool returns InterruptSignal for "researcher" but completes for "coder"
      task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate to sub-agent",
          parameters_schema: %{
            type: "object",
            required: ["instructions", "subagent_type"],
            properties: %{
              "instructions" => %{type: "string"},
              "subagent_type" => %{type: "string"}
            }
          },
          function: fn args, context ->
            send(test_pid, {:task_tool_called, args, context})
            subagent_type = Map.get(args, "subagent_type", "unknown")

            case Map.get(context, :resume_info) do
              nil ->
                # First execution: researcher interrupts, coder completes
                case subagent_type do
                  "researcher" ->
                    {:ok, "SubAgent 'researcher' requires human approval.",
                     %Sagents.InterruptSignal{
                       type: :subagent_hitl,
                       sub_agent_id: "sub-researcher",
                       subagent_type: "researcher",
                       interrupt_data: %{
                         action_requests: [
                           %{
                             tool_call_id: "inner-tc-1",
                             tool_name: "search",
                             arguments: %{"q" => "test"}
                           }
                         ]
                       }
                     }}

                  "coder" ->
                    {:ok, "Code written successfully"}
                end

              %{sub_agent_id: "sub-researcher"} ->
                {:ok, "Research completed successfully"}
            end
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [task_tool],
            middleware: []
          },
          replace_default_middleware: true,
          interrupt_on: %{"task" => true}
        )

      tool_call1 =
        ToolCall.new!(%{
          call_id: "call-1",
          name: "task",
          arguments: %{"instructions" => "research", "subagent_type" => "researcher"}
        })

      tool_call2 =
        ToolCall.new!(%{
          call_id: "call-2",
          name: "task",
          arguments: %{"instructions" => "write code", "subagent_type" => "coder"}
        })

      llm_call_count = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        count = :counters.get(llm_call_count, 1)
        :counters.add(llm_call_count, 1, 1)

        case count do
          0 ->
            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call1, tool_call2]})]}

          _ ->
            {:ok, [Message.new_assistant!("All done.")]}
        end
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Do both tasks")]})

      # Execute → only researcher interrupts, coder completes
      assert {:interrupt, state1, data1} = Agent.execute(agent, initial_state)
      assert data1.type == :subagent_hitl
      assert data1.sub_agent_id == "sub-researcher"
      assert data1.pending_interrupts == []

      # Resume researcher → should complete
      assert {:ok, final_state} = Agent.resume(agent, state1, [%{type: :approve}])
      assert final_state.interrupt_data == nil
    end
  end
end
