defmodule Sagents.AbilitySetSubAgentTest do
  @moduledoc """
  A general-purpose sub-agent started with the `task` tool's `mode` works in
  the named ability set, while the parent stays in its own.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias LangChain.ChatModels.ChatOpenAICompatible
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias Sagents.Agent
  alias Sagents.Middleware.AbilitySetSwitcher
  alias Sagents.Middleware.SubAgent, as: SubAgentMiddleware
  alias Sagents.State
  alias Sagents.SubAgent
  alias Sagents.SubAgentsDynamicSupervisor
  alias Sagents.TestAbilityMiddleware

  # The sub-agent runs in its own process, so the model stub must be global.
  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    agent_id = "parent-#{System.unique_integer([:positive])}"
    {:ok, _sup} = start_supervised({SubAgentsDynamicSupervisor, agent_id: agent_id})
    %{agent_id: agent_id}
  end

  defp model do
    ChatOpenAICompatible.new!(%{endpoint: "http://localhost/v1/chat/completions", model: "glm"})
  end

  defp mw(id, tools, prompt),
    do: {TestAbilityMiddleware, id: id, tools: tools, prompt: prompt, test_pid: self()}

  defp new_agent!(agent_id, opts \\ []) do
    sets = %{
      "devices" => %{
        name: "Devices",
        when_to_use: "Device inventory, packages, and deployments to devices.",
        middleware: [
          mw("devices_mw", ["list_devices"], "Devices fragment."),
          mw("deployments_mw", ["deploy_package"], "Deployments fragment.")
        ]
      },
      "billing" => %{
        name: "Billing",
        when_to_use: "Invoices, balances, and payment status.",
        middleware: [mw("billing_mw", ["list_invoices"], "Billing fragment.")]
      }
    }

    # `interrupt_on` appends HumanInTheLoop only to the default stack, so a
    # replaced stack lists it itself.
    hitl =
      case Keyword.get(opts, :interrupt_on) do
        nil -> []
        interrupt_on -> [{Sagents.Middleware.HumanInTheLoop, interrupt_on: interrupt_on}]
      end

    Agent.new!(
      %{
        agent_id: agent_id,
        model: model(),
        base_system_prompt: "You are the IT operations assistant.",
        middleware:
          [
            mw("rail_mw", ["whoami"], "Rail fragment."),
            {SubAgentMiddleware, [model: model(), subagents: Keyword.get(opts, :subagents, [])]},
            {AbilitySetSwitcher, sets: sets}
          ] ++ hitl
      },
      replace_default_middleware: true
    )
  end

  defp billing_state do
    State.new!(%{
      messages: [Message.new_user!("Build the acme package, then deploy it to staging.")],
      metadata: %{"active_ability_set" => "billing"}
    })
  end

  defp task_call(args) do
    Message.new_assistant!(%{
      tool_calls: [
        ToolCall.new!(%{
          call_id: "task_1",
          name: "task",
          arguments: Map.merge(%{"instructions" => "Deploy acme to staging."}, args)
        })
      ]
    })
  end

  # Every model call goes through one stub. A request carrying the `task` tool
  # is the parent's (a sub-agent has no SubAgent middleware); the others are
  # the sub-agent's. Each side answers from its own list, in order, and every
  # call is reported to the test.
  defp stub_model(parent_responses, subagent_responses) do
    test_pid = self()
    parent = :counters.new(1, [:atomics])
    subagent = :counters.new(1, [:atomics])

    stub(ChatOpenAICompatible, :call, fn _model, messages, tools ->
      names = Enum.map(tools, & &1.name)

      {who, counter, responses} =
        if "task" in names,
          do: {:parent, parent, parent_responses},
          else: {:subagent, subagent, subagent_responses}

      index = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      send(test_pid, {who, messages, names})
      {:ok, [Enum.fetch!(responses, index)]}
    end)
  end

  defp system_text([%Message{role: :system} = system | _rest]),
    do: ContentPart.content_to_string(system.content)

  defp task_result(state) do
    state.messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(& &1.tool_results)
    |> Enum.find(&(&1.tool_call_id == "task_1"))
  end

  test "the task tool offers every declared mode", %{agent_id: agent_id} do
    task = Enum.find(new_agent!(agent_id).tools, &(&1.name == "task"))
    assert task.parameters_schema.properties["mode"].enum == ["billing", "devices"]
  end

  test "a sub-agent started in another mode works there, and the parent stays put", %{
    agent_id: agent_id
  } do
    stub_model(
      [
        task_call(%{"task_name" => "general-purpose", "mode" => "devices"}),
        Message.new_assistant!("Done")
      ],
      [Message.new_assistant!("Deployed acme to staging.")]
    )

    assert {:ok, final_state} = Agent.execute(new_agent!(agent_id), billing_state())

    assert_received {:parent, _messages, _first_tools}
    assert_received {:subagent, sub_messages, sub_tools}

    assert Enum.sort(sub_tools) == ["deploy_package", "list_devices", "whoami"]
    assert system_text(sub_messages) =~ "Devices fragment."
    assert system_text(sub_messages) =~ "Deployments fragment."
    refute system_text(sub_messages) =~ "Billing fragment."
    refute system_text(sub_messages) =~ "## Modes"

    assert_received {:parent, _messages, parent_tools}
    assert "list_invoices" in parent_tools
    refute "list_devices" in parent_tools

    assert %ToolResult{is_error: false} = result = task_result(final_state)
    assert ContentPart.content_to_string(result.content) == "Deployed acme to staging."
    assert final_state.metadata["active_ability_set"] == "billing"
  end

  test "without a mode the sub-agent works in the parent's current set", %{agent_id: agent_id} do
    stub_model(
      [task_call(%{"task_name" => "general-purpose"}), Message.new_assistant!("Done")],
      [Message.new_assistant!("Nothing to bill.")]
    )

    assert {:ok, _final_state} = Agent.execute(new_agent!(agent_id), billing_state())

    assert_received {:subagent, _messages, sub_tools}
    assert Enum.sort(sub_tools) == ["list_invoices", "whoami"]
  end

  test "the started event names the set and whether the task chose it", %{agent_id: agent_id} do
    agent = new_agent!(agent_id)

    # A parent AgentServer relays the sub-agent's debug events.
    {:ok, _server} = Sagents.AgentServer.start_link(agent: agent)
    {:ok, _server_pid, _ref} = Sagents.AgentServer.subscribe(agent_id, :debug)

    for {args, set, source} <- [
          {%{"task_name" => "general-purpose", "mode" => "devices"}, "devices", :requested},
          {%{"task_name" => "general-purpose"}, "billing", :inherited}
        ] do
      stub_model([task_call(args), Message.new_assistant!("Done")], [
        Message.new_assistant!("Finished.")
      ])

      assert {:ok, _state} = Agent.execute(agent, billing_state())

      assert_receive {:agent, {:debug, {:subagent, _id, {:subagent_started, data}}}}, 1_000
      assert data.ability_set == set
      assert data.ability_set_source == source
    end
  end

  test "an unknown mode, or a mode for a pre-configured task, is an error", %{
    agent_id: agent_id
  } do
    scout =
      SubAgent.Config.new!(%{
        name: "scout",
        description: "Scouts an outline",
        system_prompt: "You scout outlines.",
        tools: [Function.new!(%{name: "echo", function: fn _args, _context -> {:ok, "ok"} end})]
      })

    agent = new_agent!(agent_id, subagents: [scout])

    for {args, error} <- [
          {%{"task_name" => "general-purpose", "mode" => "tickets"},
           ~s(Unknown mode "tickets". Available modes: billing, devices.)},
          {%{"task_name" => "scout", "mode" => "devices"},
           "mode applies only to the general-purpose task"}
        ] do
      stub_model([task_call(args), Message.new_assistant!("Done")], [])

      assert {:ok, final_state} = Agent.execute(agent, billing_state())

      assert %ToolResult{is_error: true} = result = task_result(final_state)
      assert ContentPart.content_to_string(result.content) == error
      refute_received {:subagent, _messages, _tools}
    end
  end

  test "a gated tool in the sub-agent interrupts the parent for approval", %{agent_id: agent_id} do
    stub_model(
      [
        task_call(%{"task_name" => "general-purpose", "mode" => "devices"}),
        Message.new_assistant!("Done")
      ],
      [
        Message.new_assistant!(%{
          tool_calls: [ToolCall.new!(%{call_id: "d1", name: "deploy_package", arguments: %{}})]
        }),
        Message.new_assistant!("Deployed acme to staging.")
      ]
    )

    agent = new_agent!(agent_id, interrupt_on: %{"deploy_package" => true})

    assert {:interrupt, interrupted_state, %{type: :subagent_hitl} = data} =
             Agent.execute(agent, billing_state())

    assert [%{tool_name: "deploy_package"}] = data.interrupt_data.action_requests
    refute_received {:tool_ran, "deploy_package", _context}

    assert {:ok, final_state} = Agent.resume(agent, interrupted_state, [%{type: :approve}])

    assert_received {:tool_ran, "deploy_package", _context}
    assert ContentPart.content_to_string(task_result(final_state).content) =~ "Deployed acme"
    assert final_state.metadata["active_ability_set"] == "billing"
  end
end
