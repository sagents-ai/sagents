defmodule Sagents.AgentServerOrphanedSubAgentTest do
  @moduledoc """
  A run that ends abnormally stops the sub-agents it left running, the way a
  cancel does, and the request is reported with the usage they already spent.

  The `task` tool runs as an async tool. When it outlasts LangChain's
  `async_tool_timeout`, the parent's run dies, but the SubAgentServer lives
  under its own supervisor and would otherwise keep calling the model.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, State, SubAgent}
  alias Sagents.SubAgentsDynamicSupervisor
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.TokenUsage

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:langchain, :async_tool_timeout)
    Application.put_env(:langchain, :async_tool_timeout, 300)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:langchain, :async_tool_timeout, previous),
        else: Application.delete_env(:langchain, :async_tool_timeout)
    end)

    :ok
  end

  # Reports the end of every user request to the test.
  defmodule ReportingPersistence do
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_scope, _message, _context), do: {:ok, []}

    @impl true
    def update_tool_status(_scope, _status, _info, _context), do: {:ok, nil}

    @impl true
    def complete_user_request(_scope, report, _context) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:completed_user_request, report})
      :ok
    end
  end

  defp test_model, do: ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"})

  defp researcher_config do
    SubAgent.Config.new!(%{
      name: "researcher",
      description: "Researches things",
      system_prompt: "You research things for the parent.",
      tools: [
        Function.new!(%{
          name: "lookup",
          description: "Look something up",
          function: fn _args, _ctx -> {:ok, "found"} end
        })
      ]
    })
  end

  defp subagent_call?(messages) do
    Enum.any?(messages, fn
      %Message{role: :system, content: parts} ->
        parts
        |> List.wrap()
        |> Enum.any?(&(is_map(&1) and is_binary(&1.content) and &1.content =~ "research things"))

      _other ->
        false
    end)
  end

  defp with_usage(%Message{} = message, input, output) do
    usage = TokenUsage.new!(%{input: input, output: output})
    %Message{message | metadata: Map.put(message.metadata || %{}, :usage, usage)}
  end

  defp tool_call_message(call_id, name, arguments) do
    Message.new_assistant!(%{
      tool_calls: [ToolCall.new!(%{call_id: call_id, name: name, arguments: arguments})]
    })
  end

  test "an async tool timeout stops the sub-agent and reports what it spent" do
    test_pid = self()
    :persistent_term.put({ReportingPersistence, :test_pid}, test_pid)
    on_exit(fn -> :persistent_term.erase({ReportingPersistence, :test_pid}) end)

    agent_id = "orphan-parent-#{System.unique_integer([:positive])}"

    agent =
      Agent.new!(
        %{agent_id: agent_id, model: test_model(), base_system_prompt: "You delegate."},
        subagent_opts: [subagents: [researcher_config()]]
      )

    {:ok, _sup} = SubAgentsDynamicSupervisor.start_link(agent_id: agent_id)

    stub(ChatAnthropic, :call, fn _model, messages, _tools ->
      cond do
        # The sub-agent's second call never returns, as a slow model would.
        subagent_call?(messages) and Enum.any?(messages, &(&1.role == :tool)) ->
          send(test_pid, {:subagent_blocked, self()})
          Process.sleep(:infinity)

        subagent_call?(messages) ->
          {:ok, [with_usage(tool_call_message("sub_call_1", "lookup", %{}), 100, 10)]}

        true ->
          {:ok,
           [
             with_usage(
               tool_call_message("parent_task_1", "task", %{
                 "instructions" => "research",
                 "task_name" => "researcher"
               }),
               20,
               2
             )
           ]}
      end
    end)

    {:ok, _pid} =
      AgentServer.start_link(
        agent: agent,
        initial_state: State.new!(),
        name: AgentServer.get_name(agent_id),
        display_message_persistence: ReportingPersistence,
        conversation_id: "conv-orphan"
      )

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Research this"))

    assert_receive {:subagent_blocked, _llm_pid}, 2_000
    [{_id, subagent_pid, :worker, _mods}] = subagents(agent_id)
    ref = Process.monitor(subagent_pid)

    assert_receive {:completed_user_request, report}, 3_000

    assert %{seq: 1, status: :error, token_usage: %TokenUsage{input: 120, output: 12}} = report

    assert_receive {:DOWN, ^ref, :process, ^subagent_pid, _reason}, 1_000
    assert subagents(agent_id) == []
  end

  defp subagents(agent_id) do
    agent_id
    |> SubAgentsDynamicSupervisor.whereis()
    |> DynamicSupervisor.which_children()
  end
end
