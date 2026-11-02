defmodule Sagents.SubAgentProcessContextTest do
  @moduledoc """
  A sub-agent's chain runs in its server's process, which crosses none of the
  boundaries `Sagents.Middleware.ProcessContext` hooks. `Sagents.SubAgent`
  applies the parent's snapshot there before the chain runs, on execute and on
  resume, so code that runs before a tool's own `:on_tool_pre_execution` (an
  `:on_tool_call_review` handler, a sync tool) sees the parent's context.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias LangChain.ChatModels.ChatOpenAICompatible
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias Sagents.Agent
  alias Sagents.Middleware.AbilitySetSwitcher
  alias Sagents.Middleware.HumanInTheLoop
  alias Sagents.Middleware.ProcessContext
  alias Sagents.Middleware.SubAgent, as: SubAgentMiddleware
  alias Sagents.State
  alias Sagents.SubAgentServer
  alias Sagents.SubAgentsDynamicSupervisor
  alias Sagents.TestAbilityMiddleware
  alias Sagents.TestProcessContextProbe

  # The sub-agent runs in its own process, so the model stub must be global.
  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    agent_id = "parent-#{System.unique_integer([:positive])}"
    {:ok, _sup} = start_supervised({SubAgentsDynamicSupervisor, agent_id: agent_id})

    # ProcessContext captures from the process that builds the agent.
    Process.put(:tenant, "acme")
    on_exit(fn -> Process.delete(:tenant) end)

    %{agent_id: agent_id}
  end

  defp model do
    ChatOpenAICompatible.new!(%{endpoint: "http://localhost/v1/chat/completions", model: "glm"})
  end

  defp new_agent!(agent_id, opts \\ []) do
    process_context =
      if Keyword.get(opts, :process_context, true),
        do: [{ProcessContext, keys: [:tenant]}],
        else: []

    hitl =
      case Keyword.get(opts, :interrupt_on) do
        nil -> []
        interrupt_on -> [{HumanInTheLoop, interrupt_on: interrupt_on}]
      end

    Agent.new!(
      %{
        agent_id: agent_id,
        model: model(),
        base_system_prompt: "You delegate.",
        middleware:
          process_context ++
            [
              {TestProcessContextProbe, test_pid: self()},
              {SubAgentMiddleware,
               [model: model(), subagents: [], block_middleware: Keyword.get(opts, :block, [])]},
              {AbilitySetSwitcher,
               sets: %{
                 "devices" => %{
                   when_to_use: "Devices.",
                   middleware: [
                     {TestAbilityMiddleware, id: "devices_mw", tools: ["list_devices"]}
                   ]
                 }
               }}
            ] ++ hitl
      },
      replace_default_middleware: true
    )
  end

  # The state an AgentServer hands its chain: `on_server_start/2` has copied
  # the init-time snapshot into `state.runtime`.
  defp state_for(agent) do
    %{config: %{snapshot: snapshot}} = Enum.find(agent.middleware, &(&1.module == ProcessContext))

    State.new!(%{
      messages: [Message.new_user!("Probe it.")],
      runtime: %{ProcessContext => snapshot}
    })
  end

  defp plain_state, do: State.new!(%{messages: [Message.new_user!("Probe it.")]})

  defp tool_call(id, name, args \\ %{}) do
    Message.new_assistant!(%{
      tool_calls: [ToolCall.new!(%{call_id: id, name: name, arguments: args})]
    })
  end

  # A request carrying `task` is the parent's; the rest are the sub-agent's.
  defp stub_model(parent_responses, subagent_responses) do
    parent = :counters.new(1, [:atomics])
    subagent = :counters.new(1, [:atomics])

    stub(ChatOpenAICompatible, :call, fn _model, _messages, tools ->
      {counter, responses} =
        if Enum.any?(tools, &(&1.name == "task")),
          do: {parent, parent_responses},
          else: {subagent, subagent_responses}

      index = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      {:ok, [Enum.fetch!(responses, index)]}
    end)
  end

  defp delegate(args) do
    stub_model(
      [
        tool_call("task_1", "task", Map.merge(%{"instructions" => "Probe."}, args)),
        Message.new_assistant!("Done")
      ],
      [tool_call("p1", "probe"), Message.new_assistant!("Probed.")]
    )
  end

  for {label, args} <- [
        {"without a mode", %{"task_name" => "general-purpose"}},
        {"with a mode", %{"task_name" => "general-purpose", "mode" => "devices"}}
      ] do
    test "the review and a sync tool in the sub-agent see the parent's context, #{label}", %{
      agent_id: agent_id
    } do
      delegate(unquote(Macro.escape(args)))
      agent = new_agent!(agent_id)

      assert {:ok, _state} = Agent.execute(agent, state_for(agent))

      assert_received {:probe_review, "acme"}
      assert_received {:probe_tool, "acme"}
    end
  end

  test "resume applies the context itself", %{agent_id: agent_id} do
    delegate(%{"task_name" => "general-purpose"})
    agent = new_agent!(agent_id, interrupt_on: %{"probe" => true})

    assert {:interrupt, interrupted_state, %{type: :subagent_hitl} = data} =
             Agent.execute(agent, state_for(agent))

    # Resume must not depend on what execute left in the server's process.
    pid = SubAgentServer.whereis(data.sub_agent_id)

    :sys.replace_state(pid, fn server_state ->
      Process.delete(:tenant)
      server_state
    end)

    assert {:ok, _state} = Agent.resume(agent, interrupted_state, [%{type: :approve}])

    assert_received {:probe_review, "acme"}
    assert_received {:probe_tool, "acme"}
  end

  test "a parent without ProcessContext passes nothing on", %{agent_id: agent_id} do
    delegate(%{"task_name" => "general-purpose"})
    agent = new_agent!(agent_id, process_context: false)

    assert {:ok, _state} = Agent.execute(agent, plain_state())

    assert_received {:probe_review, nil}
    assert_received {:probe_tool, nil}
  end

  test "a sub-agent that blocks ProcessContext is left alone", %{agent_id: agent_id} do
    delegate(%{"task_name" => "general-purpose"})
    agent = new_agent!(agent_id, block: [ProcessContext])

    assert {:ok, _state} = Agent.execute(agent, state_for(agent))

    assert_received {:probe_review, nil}
    assert_received {:probe_tool, nil}
  end

  test "apply_from_state/1 is a no-op without a snapshot" do
    Process.delete(:tenant)

    assert :ok = ProcessContext.apply_from_state(nil)
    assert :ok = ProcessContext.apply_from_state(State.new!())
    assert Process.get(:tenant) == nil
  end
end
