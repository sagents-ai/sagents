defmodule Sagents.AgentCancelSubAgentTest do
  @moduledoc """
  Integration test for the main-agent-cancel → sub-agent-cancel contract.

  When the main agent is cancelled, every running SubAgentServer must die too
  (the parent won't consume the sub-agent's result) AND the debugger must see
  a terminal :subagent_cancelled event before the sub-agent vanishes.

  Tagged :slow because it mocks a sub-agent that sleeps 5 seconds; the test
  asserts the sub-agent dies well before that. Without the fix the sub-agent
  runs to completion and the assertion times out.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, State, SubAgent}
  alias Sagents.SubAgentsDynamicSupervisor
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(ChatAnthropic)
    :ok
  end

  defp test_model do
    ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"})
  end

  defp make_parent_agent(agent_id, subagent_configs) do
    Agent.new!(
      %{
        agent_id: agent_id,
        model: test_model(),
        system_prompt: "You delegate tasks to sub-agents."
      },
      subagent_opts: [subagents: subagent_configs]
    )
  end

  @tag :slow
  test "cancelling main agent kills running sub-agent and broadcasts :subagent_cancelled" do
    agent_id = "parent-cancel-#{System.unique_integer([:positive])}"

    subagent_config =
      SubAgent.Config.new!(%{
        name: "slow-researcher",
        description: "Performs slow research",
        system_prompt: "You research things slowly.",
        tools: [
          Function.new!(%{
            name: "noop",
            description: "Placeholder tool; never actually called in this test.",
            function: fn _args, _ctx -> {:ok, "noop"} end
          })
        ]
      })

    agent = make_parent_agent(agent_id, [subagent_config])

    # Start the SubAgentsDynamicSupervisor that the SubAgent middleware needs.
    {:ok, _sup} = SubAgentsDynamicSupervisor.start_link(agent_id: agent_id)

    # Subscribe later (after AgentServer starts) via the new direct transport.

    test_pid = self()

    # Mock LLM: parent's first call returns a task tool call; the sub-agent's
    # first call sleeps 5s to simulate being stuck mid-LLM-call. If cancel
    # doesn't kill the sub-agent, the full sleep elapses and the test times out.
    ChatAnthropic
    |> stub(:call, fn _model, messages, _tools ->
      is_subagent_call =
        Enum.any?(messages, fn
          %Message{role: :system, content: parts} ->
            text =
              parts
              |> List.wrap()
              |> Enum.map_join("", fn
                %{content: c} when is_binary(c) -> c
                _ -> ""
              end)

            text =~ "research things slowly"

          _ ->
            false
        end)

      cond do
        is_subagent_call ->
          send(test_pid, :subagent_llm_started)
          Process.sleep(5_000)
          {:ok, [Message.new_assistant!(%{content: "done"})]}

        true ->
          msg =
            Message.new_assistant!(%{
              tool_calls: [
                ToolCall.new!(%{
                  call_id: "parent_tc_1",
                  name: "task",
                  arguments: %{
                    "instructions" => "do slow research",
                    "task_name" => "slow-researcher"
                  }
                })
              ]
            })

          {:ok, [msg]}
      end
    end)

    initial_state = State.new!(%{messages: [Message.new_user!("Research")]})

    {:ok, _pid} =
      AgentServer.start_link(
        agent: agent,
        initial_state: initial_state,
        name: AgentServer.get_name(agent_id)
      )

    {:ok, _server, _ref_main} = AgentServer.subscribe(agent_id)
    {:ok, _server, _ref_debug} = AgentServer.subscribe_debug(agent_id)

    assert :ok = AgentServer.execute(agent_id)

    # Wait for the sub-agent's LLM call to actually start. This proves the
    # sub-agent process is up and blocked inside Process.sleep(5_000).
    assert_receive :subagent_llm_started, 2_000

    # Find the sub-agent pid by enumerating the per-agent supervisor's children.
    sup_pid = SubAgentsDynamicSupervisor.whereis(agent_id)
    assert is_pid(sup_pid)

    [{_, sub_pid, :worker, _}] = DynamicSupervisor.which_children(sup_pid)
    assert is_pid(sub_pid)

    ref = Process.monitor(sub_pid)

    # Cancel the main agent.
    assert :ok = AgentServer.cancel(agent_id)

    # Assert 1: sub-agent process actually dies well before the 5s sleep would
    # have completed naturally.
    assert_receive {:DOWN, ^ref, :process, ^sub_pid, _reason}, 2_000

    # Assert 2: observability — the terminal :subagent_cancelled event fired.
    # Context is empty in this test because the sub-agent was blocked in an
    # LLM call and the parent fallback-broadcasts without state -- the
    # debugger already has the per-turn messages from its own stream.
    assert_receive {:agent, {:debug, {:subagent, _sub_id, {:subagent_cancelled, ctx}}}},
                   1_000

    assert is_map(ctx)

    # Assert 3: no :subagent_completed or :subagent_error fires after cancel.
    # Drain the mailbox briefly and check nothing terminal-but-successful snuck through.
    refute_receive {:agent, {:debug, {:subagent, _sub_id, {:subagent_completed, _}}}},
                   300

    refute_receive {:agent, {:debug, {:subagent, _sub_id, {:subagent_error, _}}}},
                   0

    # Assert 4: main agent is cancelled.
    assert AgentServer.get_status(agent_id) == :cancelled

    # Assert 5: the main agent's task tool call received a :cancelled status
    # update so the chat UI can stop showing a spinner for the abandoned work.
    assert_receive {:agent,
                    {:tool_execution_update, :cancelled, %{call_id: "parent_tc_1", name: "task"}}},
                   1_000
  end
end
