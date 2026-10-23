defmodule Sagents.ToolSearchSubAgentTest do
  @moduledoc """
  Tool search in sub-agents. A dynamic general-purpose sub-agent rebuilds its
  stack from the parent's middleware, so it inherits `ToolSearch` and its
  namespaces. A configured sub-agent opts in by listing `ToolSearch` in its own
  middleware.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.NativeTool
  alias Sagents.{AbilitySet, AbilitySets, Agent, State, SubAgentsDynamicSupervisor}
  alias Sagents.Middleware.AbilitySetSwitcher
  alias Sagents.Middleware.SubAgent, as: SubAgentMiddleware
  alias Sagents.Middleware.ToolSearch
  alias Sagents.TestNamespacedMiddleware

  @devices [namespace: "devices", description: "Find and restart managed devices."]

  # A nil id leaves the entry id as the module.
  defp mw(id, tools, opts \\ []) do
    id_opts = if id, do: [id: id], else: []
    {TestNamespacedMiddleware, id_opts ++ Keyword.merge([tools: tools], opts)}
  end

  # The sub-agent runs in its own process, so the model stub must be global.
  setup :set_mimic_global

  setup do
    agent_id = "parent-#{System.unique_integer([:positive])}"
    {:ok, _sup} = start_supervised({SubAgentsDynamicSupervisor, agent_id: agent_id})

    test_pid = self()

    stub(ChatAnthropic, :call, fn _model, messages, tools ->
      send(test_pid, {:subagent_request, messages, tools})
      {:ok, [Message.new_assistant!("Done.")]}
    end)

    %{agent_id: agent_id}
  end

  defp parent(agent_id, middleware, subagent_opts \\ []) do
    Agent.new!(
      %{
        agent_id: agent_id,
        model: mock_model(),
        middleware:
          middleware ++
            [
              {SubAgentMiddleware,
               Keyword.merge([model: mock_model(), subagents: []], subagent_opts)}
            ]
      },
      replace_default_middleware: true
    )
  end

  # Runs the parent's `task` tool the way the parent's chain would: with the
  # middleware of the active ability set (all of it, without sets), less the
  # switcher, as `Sagents.Agent` puts it in the chain's context.
  defp run_task(parent, task_name) do
    task = Enum.find(parent.tools, &(&1.name == "task"))

    parent_middleware =
      parent
      |> AbilitySets.effective(nil)
      |> Map.fetch!(:middleware)
      |> AbilitySets.inheritable_middleware()

    context = %{state: State.new!(%{messages: []}), parent_middleware: parent_middleware}

    task.function.(%{"instructions" => "List the hq devices.", "task_name" => task_name}, context)
  end

  # `SubAgent.Config` requires at least one base tool of its own.
  defp echo_tool,
    do: Function.new!(%{name: "echo", function: fn _args, _context -> {:ok, "ok"} end})

  defp stamp(%Function{} = function),
    do: {Function.deferred?(function), Function.namespace(function)}

  describe "a dynamic sub-agent" do
    test "inherits the search tool and the stamped tools", %{agent_id: agent_id} do
      parent =
        parent(agent_id, [
          ToolSearch,
          mw("rail_mw", ["whoami"]),
          mw("devices_mw", ["devices_list"], tool_search: @devices)
        ])

      assert {:ok, "Done."} = run_task(parent, "general-purpose")
      assert_received {:subagent_request, _messages, tools}

      assert %NativeTool{} = Enum.find(tools, &(&1.name == "tool_search"))
      assert {true, "devices"} = stamp(Enum.find(tools, &(&1.name == "devices_list")))
      assert {false, nil} = stamp(Enum.find(tools, &(&1.name == "whoami")))
      refute Enum.find(tools, &(&1.name == "task"))
    end

    test "inherits an override keyed by module, and the catalog", %{agent_id: agent_id} do
      parent =
        parent(agent_id, [
          {ToolSearch,
           namespaces: %{
             TestNamespacedMiddleware => [namespace: "billing", description: "Invoices."]
           }},
          mw(nil, ["billing_invoices"])
        ])

      assert {:ok, "Done."} = run_task(parent, "general-purpose")
      assert_received {:subagent_request, messages, tools}

      assert {true, "billing"} = stamp(Enum.find(tools, &(&1.name == "billing_invoices")))

      assert [%Message{role: :system} = system | _rest] = messages
      assert ContentPart.content_to_string(system.content) =~ "- billing: Invoices."
    end

    test "inherits an override keyed by a custom entry id", %{agent_id: agent_id} do
      parent =
        parent(agent_id, [
          {ToolSearch,
           namespaces: %{"billing_mw" => [namespace: "billing", description: "Invoices."]}},
          mw("billing_mw", ["billing_invoices"])
        ])

      assert {:ok, "Done."} = run_task(parent, "general-purpose")
      assert_received {:subagent_request, _messages, tools}
      assert {true, "billing"} = stamp(Enum.find(tools, &(&1.name == "billing_invoices")))
    end

    test "starts when block_middleware removes middleware an override names", %{
      agent_id: agent_id
    } do
      parent =
        parent(
          agent_id,
          [
            {ToolSearch,
             namespaces: %{
               TestNamespacedMiddleware => [namespace: "billing", description: "Invoices."]
             }},
            mw(nil, ["billing_invoices"]),
            mw("rail_mw", ["whoami"])
          ],
          block_middleware: [TestNamespacedMiddleware]
        )

      assert {:ok, "Done."} = run_task(parent, "general-purpose")
    end
  end

  describe "a configured sub-agent" do
    test "opts in by listing ToolSearch in its own middleware", %{agent_id: agent_id} do
      config =
        Sagents.SubAgent.Config.new!(%{
          name: "devices",
          description: "Handles device questions.",
          system_prompt: "You manage devices.",
          tools: [echo_tool()],
          middleware: [ToolSearch, mw(nil, ["devices_list"], tool_search: @devices)]
        })

      parent = parent(agent_id, [], subagents: [config])

      assert {:ok, "Done."} = run_task(parent, "devices")
      assert_received {:subagent_request, messages, tools}

      assert %NativeTool{} = Enum.find(tools, &(&1.name == "tool_search"))
      assert {true, "devices"} = stamp(Enum.find(tools, &(&1.name == "devices_list")))

      assert [%Message{role: :system} = system | _rest] = messages
      assert ContentPart.content_to_string(system.content) =~ "- devices: Find and restart"
    end

    test "does not inherit the parent's ToolSearch", %{agent_id: agent_id} do
      config =
        Sagents.SubAgent.Config.new!(%{
          name: "devices",
          description: "Handles device questions.",
          system_prompt: "You manage devices.",
          tools: [echo_tool()],
          middleware: [mw(nil, ["devices_list"], tool_search: @devices)]
        })

      parent = parent(agent_id, [ToolSearch], subagents: [config])

      assert {:ok, "Done."} = run_task(parent, "devices")
      assert_received {:subagent_request, _messages, tools}

      refute Enum.find(tools, &(&1.name == "tool_search"))
      assert {false, nil} = stamp(Enum.find(tools, &(&1.name == "devices_list")))
    end
  end

  describe "a dynamic sub-agent of an agent with ability sets" do
    test "starts when an override names middleware outside the inherited set", %{
      agent_id: agent_id
    } do
      sets = %{
        "devices" =>
          AbilitySet.new!(%{
            name: "Devices",
            when_to_use: "Device inventory.",
            middleware: [
              {Sagents.TestDeferredToolsMiddleware,
               namespace: "devices", description: "Devices.", tools: ["devices_list"]}
            ]
          })
      }

      parent =
        parent(agent_id, [
          {ToolSearch,
           namespaces: %{
             Sagents.TestDeferredToolsMiddleware => [
               namespace: "devices",
               description: "Devices."
             ]
           }},
          mw(nil, ["whoami"]),
          {AbilitySetSwitcher, sets: sets}
        ])

      # With no set active, the sub-agent inherits only the rails.
      assert {:ok, "Done."} = run_task(parent, "general-purpose")
    end
  end
end
