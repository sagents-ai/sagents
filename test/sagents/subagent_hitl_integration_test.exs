defmodule Sagents.SubAgentHitlIntegrationTest do
  @moduledoc """
  End-to-end integration tests for sub-agent HITL propagation.

  Tests the complete round-trip:
    parent agent executes task tool
    → SubAgentServer.execute
    → sub-agent LLM calls HITL-gated tool
    → sub-agent interrupts
    → interrupt propagates through task tool → LLMChain → pipeline
    → parent returns {:interrupt, state, data}
    → caller resumes with decisions
    → Agent.resume → SubAgentServer.resume
    → sub-agent executes approved tool → completes
    → result patched into parent state
    → parent LLM continues

  Mocking strategy: Mock ChatAnthropic.call/3 (the LLM model) rather than
  LLMChain.run/2, so the full execution pipeline (mode steps, tool execution,
  HITL checks) runs with real code.
  """

  use ExUnit.Case, async: false
  use Mimic

  import Sagents.TestingHelpers, only: [wait_until: 1]

  alias Sagents.{Agent, State}
  alias Sagents.SubAgent
  alias Sagents.SubAgentServer
  alias Sagents.SubAgentsDynamicSupervisor
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    unless Process.whereis(Sagents.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Sagents.Registry)
    end

    Mimic.copy(ChatAnthropic)

    :ok
  end

  defp test_model do
    ChatAnthropic.new!(%{
      model: "claude-sonnet-4-6",
      api_key: "test_key"
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

    # Start the SubAgentsDynamicSupervisor that SubAgent middleware needs
    {:ok, _} = SubAgentsDynamicSupervisor.start_link(agent_id: agent.agent_id)

    agent
  end

  # Build an assistant message with tool calls (what the LLM returns)
  defp assistant_with_tool_calls(tool_calls) do
    Message.new_assistant!(%{tool_calls: tool_calls})
  end

  # Build a final assistant message (what the LLM returns when done)
  defp assistant_response(content) do
    Message.new_assistant!(%{content: content})
  end

  describe "sub-agent HITL propagation" do
    test "parent surfaces sub-agent interrupt and resumes successfully" do
      subagent_config =
        SubAgent.Config.new!(%{
          name: "writer",
          description: "Writes files",
          system_prompt: "You write files.",
          tools: [
            LangChain.Function.new!(%{
              name: "file_write",
              description: "Write a file",
              function: fn _args, _context -> {:ok, "File written successfully"} end
            })
          ],
          interrupt_on: %{"file_write" => true}
        })

      agent = make_parent_agent([subagent_config])

      # Track calls with a counter — both parent and sub-agent LLM calls go through here
      call_count = :counters.new(1, [:atomics])

      ChatAnthropic
      |> stub(:call, fn _model, _messages, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        cond do
          # Call 0: Parent LLM → task tool call
          count == 0 ->
            msg =
              assistant_with_tool_calls([
                ToolCall.new!(%{
                  call_id: "parent_tc_1",
                  name: "task",
                  arguments: %{
                    "instructions" => "Write a test file",
                    "task_name" => "writer"
                  }
                })
              ])

            {:ok, [msg]}

          # Call 1: Sub-agent LLM → file_write tool call (HITL gated)
          count == 1 ->
            msg =
              assistant_with_tool_calls([
                ToolCall.new!(%{
                  call_id: "sub_tc_1",
                  name: "file_write",
                  arguments: %{"path" => "test.txt", "content" => "hello"}
                })
              ])

            {:ok, [msg]}

          # Call 2: Sub-agent LLM after tool executes → final response
          count == 2 ->
            {:ok, [assistant_response("File has been written to test.txt")]}

          # Call 3: Parent LLM after sub-agent result → final response
          count == 3 ->
            {:ok, [assistant_response("The file was written successfully.")]}
        end
      end)

      # Execute parent agent
      initial_state =
        State.new!(%{messages: [Message.new_user!("Write a file called test.txt")]})

      result = Agent.execute(agent, initial_state)

      # Should interrupt (sub-agent hit HITL)
      assert {:interrupt, interrupted_state, interrupt_data} = result

      # Verify interrupt data structure
      assert interrupt_data.type == :subagent_hitl
      assert is_binary(interrupt_data.sub_agent_id)
      assert interrupt_data.task_name == "writer"
      assert is_binary(interrupt_data.tool_call_id)

      # Verify inner interrupt data
      inner = interrupt_data.interrupt_data
      assert is_list(inner.action_requests)
      [action_req] = inner.action_requests
      assert action_req.tool_name == "file_write"

      # Verify state has a placeholder tool result with is_interrupt: true
      has_interrupt_placeholder =
        Enum.any?(interrupted_state.messages, fn msg ->
          msg.role == :tool &&
            Enum.any?(msg.tool_results, & &1.is_interrupt)
        end)

      assert has_interrupt_placeholder

      # SubAgentServer should still be alive
      assert SubAgentServer.whereis(interrupt_data.sub_agent_id) != nil

      # Resume with approve decision
      decisions = [%{type: :approve}]
      resume_result = Agent.resume(agent, interrupted_state, decisions)

      # Should complete successfully
      assert {:ok, final_state} = resume_result

      # Placeholder should be replaced with real result
      has_remaining_interrupt =
        Enum.any?(final_state.messages, fn msg ->
          msg.role == :tool &&
            Enum.any?(msg.tool_results, & &1.is_interrupt)
        end)

      refute has_remaining_interrupt

      # SubAgentServer should be stopped (D.1)
      # The Registry processes its :DOWN message asynchronously after
      # GenServer.stop returns, so poll briefly until the entry clears.
      assert wait_until(fn ->
               SubAgentServer.whereis(interrupt_data.sub_agent_id) == nil
             end)

      # Final state should have the parent's completion message
      last_msg = List.last(final_state.messages)
      assert last_msg.role == :assistant

      last_text =
        last_msg.content
        |> Enum.map(& &1.content)
        |> Enum.join()

      assert last_text =~ "written"
    end

    test "sub-agent interrupts again after first resume" do
      subagent_config =
        SubAgent.Config.new!(%{
          name: "editor",
          description: "Edits files",
          system_prompt: "You edit files.",
          tools: [
            LangChain.Function.new!(%{
              name: "file_write",
              description: "Write a file",
              function: fn _args, _context -> {:ok, "Written"} end
            }),
            LangChain.Function.new!(%{
              name: "file_delete",
              description: "Delete a file",
              function: fn _args, _context -> {:ok, "Deleted"} end
            })
          ],
          interrupt_on: %{"file_write" => true, "file_delete" => true}
        })

      agent = make_parent_agent([subagent_config])

      call_count = :counters.new(1, [:atomics])

      ChatAnthropic
      |> stub(:call, fn _model, _messages, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        cond do
          # Call 0: Parent LLM → task tool call
          count == 0 ->
            msg =
              assistant_with_tool_calls([
                ToolCall.new!(%{
                  call_id: "parent_tc_1",
                  name: "task",
                  arguments: %{
                    "instructions" => "Edit files",
                    "task_name" => "editor"
                  }
                })
              ])

            {:ok, [msg]}

          # Call 1: Sub-agent LLM → file_write (HITL)
          count == 1 ->
            msg =
              assistant_with_tool_calls([
                ToolCall.new!(%{
                  call_id: "sub_tc_write",
                  name: "file_write",
                  arguments: %{"path" => "a.txt"}
                })
              ])

            {:ok, [msg]}

          # Call 2: After first resume, sub-agent LLM → file_delete (HITL again)
          count == 2 ->
            msg =
              assistant_with_tool_calls([
                ToolCall.new!(%{
                  call_id: "sub_tc_delete",
                  name: "file_delete",
                  arguments: %{"path" => "old.txt"}
                })
              ])

            {:ok, [msg]}

          # Call 3: After second resume, sub-agent LLM → done
          count == 3 ->
            {:ok, [assistant_response("Files managed.")]}

          # Call 4: Parent LLM → done
          count == 4 ->
            {:ok, [assistant_response("All file operations complete.")]}
        end
      end)

      initial_state =
        State.new!(%{messages: [Message.new_user!("Edit some files")]})

      # First execution → interrupt for file_write
      assert {:interrupt, state1, data1} = Agent.execute(agent, initial_state)
      assert data1.type == :subagent_hitl
      [req1] = data1.interrupt_data.action_requests
      assert req1.tool_name == "file_write"

      # First resume → re-interrupt for file_delete
      assert {:interrupt, state2, data2} = Agent.resume(agent, state1, [%{type: :approve}])
      assert data2.type == :subagent_hitl
      [req2] = data2.interrupt_data.action_requests
      assert req2.tool_name == "file_delete"

      # Second resume → completes
      assert {:ok, final_state} = Agent.resume(agent, state2, [%{type: :approve}])

      last_msg = List.last(final_state.messages)
      assert last_msg.role == :assistant
    end

    test "handles SubAgentServer crash gracefully" do
      subagent_config =
        SubAgent.Config.new!(%{
          name: "crashy",
          description: "May crash",
          system_prompt: "You crash.",
          tools: [
            LangChain.Function.new!(%{
              name: "risky_op",
              description: "Risky operation",
              function: fn _args, _context -> {:ok, "done"} end
            })
          ],
          interrupt_on: %{"risky_op" => true}
        })

      agent = make_parent_agent([subagent_config])

      call_count = :counters.new(1, [:atomics])

      ChatAnthropic
      |> stub(:call, fn _model, _messages, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        cond do
          # Call 0: Parent LLM → task tool call
          count == 0 ->
            msg =
              assistant_with_tool_calls([
                ToolCall.new!(%{
                  call_id: "parent_tc_1",
                  name: "task",
                  arguments: %{
                    "instructions" => "Do risky thing",
                    "task_name" => "crashy"
                  }
                })
              ])

            {:ok, [msg]}

          # Call 1: Sub-agent LLM → risky_op (HITL)
          count == 1 ->
            msg =
              assistant_with_tool_calls([
                ToolCall.new!(%{
                  call_id: "sub_tc_risky",
                  name: "risky_op",
                  arguments: %{}
                })
              ])

            {:ok, [msg]}

          # Call 2: Parent LLM after seeing error → recovery response
          count == 2 ->
            {:ok, [assistant_response("The sub-agent failed, moving on.")]}
        end
      end)

      initial_state =
        State.new!(%{messages: [Message.new_user!("Do something risky")]})

      # Execute → interrupt
      assert {:interrupt, interrupted_state, interrupt_data} =
               Agent.execute(agent, initial_state)

      sub_agent_id = interrupt_data.sub_agent_id

      # Kill the SubAgentServer process manually
      pid = SubAgentServer.whereis(sub_agent_id)
      assert pid != nil
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      # Wait for the process to actually die, then for the Registry to
      # process its :DOWN message and clear the entry.
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      assert wait_until(fn -> SubAgentServer.whereis(sub_agent_id) == nil end)

      # Resume → should handle the dead process gracefully
      assert {:ok, final_state} = Agent.resume(agent, interrupted_state, [%{type: :approve}])

      # The tool result should be an error (sub-agent process was gone)
      has_error =
        Enum.any?(final_state.messages, fn msg ->
          msg.role == :tool &&
            Enum.any?(msg.tool_results, & &1.is_error)
        end)

      assert has_error
    end
  end
end
