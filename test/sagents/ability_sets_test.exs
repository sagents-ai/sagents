defmodule Sagents.AbilitySetsTest do
  use Sagents.BaseCase, async: true

  import ExUnit.CaptureLog

  alias LangChain.ChatModels.ChatOpenAICompatible
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias Sagents.AbilitySet
  alias Sagents.AbilitySets
  alias Sagents.Agent
  alias Sagents.Middleware.AbilitySetSwitcher
  alias Sagents.MiddlewareEntry
  alias Sagents.State
  alias Sagents.TestAbilityMiddleware

  defp model do
    ChatOpenAICompatible.new!(%{endpoint: "http://localhost/v1/chat/completions", model: "glm"})
  end

  defp mw(id, tools, prompt \\ ""),
    do: {TestAbilityMiddleware, id: id, tools: tools, prompt: prompt}

  defp sets do
    %{
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
  end

  defp new_agent(switcher_opts, extra \\ []) do
    Agent.new(
      %{
        agent_id: "ability-sets-test",
        model: model(),
        base_system_prompt: "You are the IT operations assistant.",
        middleware:
          [
            mw("rail_mw", ["whoami"], "Rail fragment."),
            {AbilitySetSwitcher, Keyword.merge([sets: sets()], switcher_opts)},
            mw("trailing_mw", [], "Trailing fragment.")
          ] ++ extra
      },
      replace_default_middleware: true
    )
  end

  defp new_agent!(switcher_opts \\ []) do
    {:ok, agent} = new_agent(switcher_opts)
    agent
  end

  defp tool_names(tools), do: Enum.map(tools, & &1.name)
  defp ids(middleware), do: Enum.map(middleware, & &1.id)

  defp errors_text({:error, changeset}), do: inspect(changeset.errors)

  describe "expansion in Agent.new/2" do
    test "splices each set's middleware at the switcher's position, tagged with its sets" do
      agent = new_agent!()

      assert [
               %MiddlewareEntry{id: "rail_mw", ability_sets: nil},
               %MiddlewareEntry{id: AbilitySetSwitcher, ability_sets: nil},
               %MiddlewareEntry{id: "billing_mw", ability_sets: ["billing"]},
               %MiddlewareEntry{id: "devices_mw", ability_sets: ["devices"]},
               %MiddlewareEntry{id: "deployments_mw", ability_sets: ["devices"]},
               %MiddlewareEntry{id: "trailing_mw", ability_sets: nil}
             ] = agent.middleware
    end

    test "injects agent context into set middleware, and the switcher keeps no nested specs" do
      agent = new_agent!()

      assert %MiddlewareEntry{config: %{agent_id: "ability-sets-test"}} =
               Enum.find(agent.middleware, &(&1.id == "devices_mw"))

      switcher = Enum.find(agent.middleware, &(&1.id == AbilitySetSwitcher))
      assert Enum.all?(Map.values(switcher.config.sets), &(&1.middleware == []))
    end

    test "agent.tools is the union of every set's tools" do
      agent = new_agent!()

      assert Enum.sort(tool_names(agent.tools)) ==
               Enum.sort([
                 "whoami",
                 "switch_mode",
                 "list_invoices",
                 "list_devices",
                 "deploy_package"
               ])
    end

    test "a middleware listed in two sets is initialized once with both names" do
      shared = mw("shared_mw", ["lookup_customer"], "Shared fragment.")

      sets =
        sets()
        |> update_in(["devices", :middleware], &(&1 ++ [shared]))
        |> update_in(["billing", :middleware], &(&1 ++ [shared]))

      {:ok, agent} = new_agent(sets: sets)

      assert [%MiddlewareEntry{ability_sets: ["billing", "devices"]}] =
               Enum.filter(agent.middleware, &(&1.id == "shared_mw"))

      assert "lookup_customer" in tool_names(AbilitySets.effective(agent, "devices").tools)
      assert "lookup_customer" in tool_names(AbilitySets.effective(agent, "billing").tools)
    end

    test "an agent without a switcher is unchanged" do
      {:ok, agent} =
        Agent.new(
          %{
            model: model(),
            base_system_prompt: "Base.",
            middleware: [mw("rail_mw", ["whoami"], "Rail fragment.")]
          },
          replace_default_middleware: true
        )

      assert agent.ability_index == nil
      assert [%MiddlewareEntry{ability_sets: nil}] = agent.middleware
      assert agent.assembled_system_prompt == "Base.\n\nRail fragment."

      assert AbilitySets.active(agent, State.new!(%{metadata: %{"active_ability_set" => "x"}})) ==
               nil

      assert AbilitySets.effective(agent, nil) == %{
               middleware: agent.middleware,
               tools: agent.tools,
               system_prompt: agent.assembled_system_prompt
             }
    end
  end

  describe "validation" do
    test "rejects a set name that is not a lowercase identifier" do
      sets = %{"Devices" => %{when_to_use: "x", middleware: []}}
      assert errors_text(new_agent(sets: sets)) =~ "must match"
    end

    test "rejects a set without when_to_use" do
      sets = %{"devices" => %{middleware: []}}
      assert errors_text(new_agent(sets: sets)) =~ "when_to_use: can't be blank"
    end

    test "rejects a default naming no set" do
      assert errors_text(new_agent(default: "tickets")) =~ "does not exist"
    end

    test "rejects a tool name provided by two sets" do
      sets = put_in(sets(), ["billing", :middleware], [mw("billing_mw", ["list_devices"])])

      assert errors_text(new_agent(sets: sets)) =~
               "tool \\\"list_devices\\\" is provided by more than one"
    end

    test "rejects a set tool that a rail also provides" do
      sets = put_in(sets(), ["billing", :middleware], [mw("billing_mw", ["whoami"])])
      assert errors_text(new_agent(sets: sets)) =~ "more than one middleware"
    end

    test "rejects a switcher nested in a set" do
      nested = {AbilitySetSwitcher, sets: %{"inner" => %{when_to_use: "x"}}}
      sets = put_in(sets(), ["billing", :middleware], [nested])
      assert errors_text(new_agent(sets: sets)) =~ "contains another"
    end

    test "rejects a set middleware that is also a rail" do
      sets = put_in(sets(), ["billing", :middleware], [mw("rail_mw", ["whoami"])])
      assert errors_text(new_agent(sets: sets)) =~ "also outside every set"
    end

    test "rejects two switchers" do
      second = {AbilitySetSwitcher, id: "second", sets: %{"other" => %{when_to_use: "x"}}}
      assert errors_text(new_agent([], [second])) =~ "only one"
    end

    test "rejects one id in two sets with different options" do
      sets =
        sets()
        |> put_in(["billing", :middleware], [mw("shared_mw", ["a"])])
        |> put_in(["devices", :middleware], [mw("shared_mw", ["b"])])

      assert errors_text(new_agent(sets: sets)) =~ "different options"
    end

    test "warns about a set with many tools" do
      tools = Enum.map(1..16, &"tool_#{&1}")
      sets = put_in(sets(), ["billing", :middleware], [mw("billing_mw", tools)])

      log = capture_log(fn -> assert {:ok, _agent} = new_agent(sets: sets) end)
      assert log =~ "Ability set \"billing\" has 16 tools"
    end
  end

  describe "active/2" do
    test "reads the state key" do
      agent = new_agent!()
      state = State.new!(%{metadata: %{"active_ability_set" => "billing"}})
      assert AbilitySets.active(agent, state) == "billing"
    end

    test "falls back to the default when the state names none" do
      assert AbilitySets.active(new_agent!(), State.new!()) == nil
      assert AbilitySets.active(new_agent!(default: "devices"), State.new!()) == "devices"
    end

    test "maps an unknown value to the default with a warning" do
      agent = new_agent!(default: "devices")
      state = State.new!(%{metadata: %{"active_ability_set" => "tickets"}})

      log = capture_log(fn -> assert AbilitySets.active(agent, state) == "devices" end)
      assert log =~ "\"tickets\" in state is not declared"
    end

    test "uses a configured state key" do
      agent = new_agent!(state_key: "mode")
      state = State.new!(%{metadata: %{"mode" => "billing"}})
      assert AbilitySets.active(agent, state) == "billing"
    end
  end

  describe "effective/2" do
    test "rails only for nil" do
      effective = AbilitySets.effective(new_agent!(), nil)

      assert ids(effective.middleware) == ["rail_mw", AbilitySetSwitcher, "trailing_mw"]
      assert tool_names(effective.tools) == ["whoami", "switch_mode"]
      refute effective.system_prompt =~ "Devices fragment."
      assert effective.system_prompt =~ "Current mode: none."
    end

    test "rails plus the set's entries, in stack order" do
      effective = AbilitySets.effective(new_agent!(), "devices")

      assert ids(effective.middleware) ==
               ["rail_mw", AbilitySetSwitcher, "devices_mw", "deployments_mw", "trailing_mw"]

      assert tool_names(effective.tools) ==
               ["whoami", "switch_mode", "list_devices", "deploy_package"]

      positions =
        Enum.map(
          [
            "You are the IT operations assistant.",
            "Rail fragment.",
            "## Modes\n\nYou work in modes.",
            "Current mode: devices.",
            "Devices fragment.",
            "Deployments fragment.",
            "Trailing fragment."
          ],
          fn text -> effective.system_prompt |> :binary.match(text) |> elem(0) end
        )

      assert positions == Enum.sort(positions)
      refute effective.system_prompt =~ "Billing fragment."
    end

    test "a set's prompt is identical across two Agent.new calls" do
      assert AbilitySets.effective(new_agent!(), "billing").system_prompt ==
               AbilitySets.effective(new_agent!(), "billing").system_prompt
    end

    test "base tools are rails" do
      extra_tool =
        LangChain.Function.new!(%{
          name: "base_tool",
          function: fn _args, _context -> {:ok, "ok"} end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: model(),
            tools: [extra_tool],
            middleware: [{AbilitySetSwitcher, sets: sets()}]
          },
          replace_default_middleware: true
        )

      assert "base_tool" in tool_names(AbilitySets.effective(agent, nil).tools)
      assert "base_tool" in tool_names(AbilitySets.effective(agent, "billing").tools)
    end

    test "assembled_system_prompt is the default set's prompt" do
      agent = new_agent!(default: "billing")

      assert agent.assembled_system_prompt ==
               AbilitySets.effective(agent, "billing").system_prompt
    end
  end

  describe "system prompt structure" do
    # The same stack without a switcher: the set's middleware sit at the
    # switcher's position, preceded by a stand-in that contributes the
    # catalog fragment the switcher would.
    defp flat_agent!(switcher_agent, set, replace_defaults) do
      catalog = AbilitySetSwitcher.catalog_prompt(switcher_agent.ability_index.config, set)
      members = if set, do: sets()[set].middleware, else: []

      {:ok, agent} =
        Agent.new(
          %{
            agent_id: "ability-sets-test",
            model: model(),
            base_system_prompt: "You are the IT operations assistant.",
            middleware:
              [mw("rail_mw", ["whoami"], "Rail fragment."), mw("catalog", [], catalog)] ++
                members ++ [mw("trailing_mw", [], "Trailing fragment.")]
          },
          replace_default_middleware: replace_defaults
        )

      agent
    end

    for replace_defaults <- [true, false], set <- [nil, "devices", "billing"] do
      test "#{inspect(set)} set, replace_default_middleware: #{replace_defaults}, matches the flat stack" do
        {:ok, agent} =
          Agent.new(
            %{
              agent_id: "ability-sets-test",
              model: model(),
              base_system_prompt: "You are the IT operations assistant.",
              middleware: [
                mw("rail_mw", ["whoami"], "Rail fragment."),
                {AbilitySetSwitcher, sets: sets()},
                mw("trailing_mw", [], "Trailing fragment.")
              ]
            },
            replace_default_middleware: unquote(replace_defaults)
          )

        flat = flat_agent!(agent, unquote(set), unquote(replace_defaults))

        assert AbilitySets.effective(agent, unquote(set)).system_prompt ==
                 flat.assembled_system_prompt
      end
    end

    test "the full prompt for a set, fragment by fragment" do
      agent = new_agent!()
      catalog = AbilitySetSwitcher.catalog_prompt(agent.ability_index.config, "devices")

      assert AbilitySets.effective(agent, "devices").system_prompt ==
               Enum.join(
                 [
                   "You are the IT operations assistant.",
                   "Rail fragment.",
                   catalog,
                   "Devices fragment.",
                   "Deployments fragment.",
                   "Trailing fragment."
                 ],
                 "\n\n"
               )
    end
  end

  describe "strip_reasoning_if_switched/3" do
    defp thinking_state(metadata) do
      State.new!(%{
        metadata: metadata,
        messages: [
          Message.new_user!("Hi"),
          Message.new_assistant!(%{
            content: [ContentPart.thinking!("I need devices.")],
            tool_calls: [ToolCall.new!(%{call_id: "s1", name: "switch_mode", arguments: %{}})]
          }),
          Message.new_tool_result!(%{
            tool_results: [
              ToolResult.new!(%{tool_call_id: "s1", name: "switch_mode", content: "Switched"})
            ]
          })
        ]
      })
    end

    test "strips every reasoning part when the state names another set" do
      state = thinking_state(%{"active_ability_set" => "devices"})

      assert %State{messages: [_user, %Message{content: [], tool_calls: [_call]}, _result]} =
               AbilitySets.strip_reasoning_if_switched(new_agent!(), state, nil)
    end

    test "leaves the state alone when the set did not change" do
      state = thinking_state(%{"active_ability_set" => "devices"})
      assert AbilitySets.strip_reasoning_if_switched(new_agent!(), state, "devices") == state
    end

    test "leaves the state alone without a switcher" do
      {:ok, agent} = Agent.new(%{model: model()}, replace_default_middleware: true)
      state = thinking_state(%{"active_ability_set" => "devices"})
      assert AbilitySets.strip_reasoning_if_switched(agent, state, nil) == state
    end
  end

  def switch_text(%{name: name}, greeting), do: "#{greeting}, #{name}."

  describe "Sagents.Middleware.AbilitySetSwitcher" do
    defp switcher_config(opts \\ []) do
      {:ok, config} = AbilitySetSwitcher.init(Keyword.merge([sets: sets()], opts))
      config
    end

    defp switch_tool(config), do: hd(AbilitySetSwitcher.tools(config))

    test "init/1 is idempotent on its own output" do
      config = switcher_config(default: "devices", max_switches_per_run: 2)
      assert {:ok, ^config} = AbilitySetSwitcher.init(Map.to_list(config))
    end

    test "init/1 defaults a set's display name" do
      config = switcher_config(sets: %{"tickets" => %{when_to_use: "Support tickets."}})
      assert config.sets["tickets"].name == "Tickets"
    end

    test "the catalog lists every set and names the current mode" do
      prompt = AbilitySetSwitcher.catalog_prompt(switcher_config(), "billing")

      assert prompt =~ "- billing: Invoices, balances, and payment status."
      assert prompt =~ "- devices: Device inventory, packages, and deployments to devices."
      assert prompt =~ "Current mode: billing."
      assert prompt =~ "Call switch_mode only when"
    end

    test "the tool's mode parameter is an enum of the set names" do
      tool = switch_tool(switcher_config())

      assert tool.name == "switch_mode"
      assert tool.parameters_schema.properties.mode.enum == ["billing", "devices"]
    end

    test "a switch returns a metadata delta that keeps the todo list" do
      tool = switch_tool(switcher_config())
      context = %{ability_sets: %{active: nil, switches: 0}}

      assert {:ok, "Switched to the Devices mode.",
              %State{todos: nil, metadata: %{"active_ability_set" => "devices"}} = delta} =
               tool.function.(%{"mode" => "devices"}, context)

      todo = Sagents.Todo.new!(%{id: 1, content: "Keep me"})
      state = State.new!(%{todos: [todo]})
      assert State.merge_states(state, delta).todos == [todo]
    end

    test "a set's switch_message is the tool result for switching to it" do
      sets =
        put_in(sets(), ["billing", :switch_message], "Switching to focus on billing questions.")

      tool = switch_tool(switcher_config(sets: sets))
      context = %{ability_sets: %{active: nil, switches: 0}}

      assert {:ok, "Switching to focus on billing questions.", _delta} =
               tool.function.(%{"mode" => "billing"}, context)

      assert {:ok, "Switched to the Devices mode.", _delta} =
               tool.function.(%{"mode" => "devices"}, context)
    end

    test "the default switch_message lists the tools the target set adds" do
      tool = switch_tool(switcher_config())

      # "lookup" is in both sets, so switching between them does not add it.
      tool_sets = %{
        "list_devices" => ["devices"],
        "deploy_package" => ["devices"],
        "lookup" => ["billing", "devices"],
        "list_invoices" => ["billing"]
      }

      from_rails = %{ability_sets: %{active: nil, switches: 0, tool_sets: tool_sets}}
      from_billing = %{ability_sets: %{active: "billing", switches: 0, tool_sets: tool_sets}}

      assert {:ok,
              "Switched to the Devices mode. Tools now available: deploy_package, list_devices, lookup.",
              _delta} = tool.function.(%{"mode" => "devices"}, from_rails)

      assert {:ok,
              "Switched to the Devices mode. Tools now available: deploy_package, list_devices.",
              _delta} = tool.function.(%{"mode" => "devices"}, from_billing)
    end

    test "a switch_message callback builds the text from the switch" do
      test_pid = self()

      message = fn info ->
        send(test_pid, {:switch_info, info})
        "Focusing on #{info.name}: #{Enum.join(info.tools, ", ")}."
      end

      sets = put_in(sets(), ["billing", :switch_message], message)
      tool = switch_tool(switcher_config(sets: sets))
      tool_sets = %{"list_invoices" => ["billing"], "list_devices" => ["devices"]}
      context = %{ability_sets: %{active: "devices", switches: 0, tool_sets: tool_sets}}

      assert {:ok, "Focusing on Billing: list_invoices.", _delta} =
               tool.function.(%{"mode" => "billing"}, context)

      assert_received {:switch_info,
                       %{
                         from: "devices",
                         to: "billing",
                         name: "Billing",
                         tools: ["list_invoices"]
                       }}
    end

    test "a switch_message may be a {module, function, args} tuple" do
      sets = put_in(sets(), ["billing", :switch_message], {__MODULE__, :switch_text, ["Ahoy"]})
      tool = switch_tool(switcher_config(sets: sets))
      context = %{ability_sets: %{active: nil, switches: 0}}

      assert {:ok, "Ahoy, Billing.", _delta} = tool.function.(%{"mode" => "billing"}, context)
    end

    test "a switch_message callback that fails falls back to the default" do
      context = %{ability_sets: %{active: nil, switches: 0}}

      for callback <- [fn _info -> raise "boom" end, fn _info -> :not_text end] do
        sets = put_in(sets(), ["billing", :switch_message], callback)
        tool = switch_tool(switcher_config(sets: sets))

        capture_log(fn ->
          assert {:ok, "Switched to the Billing mode.", _delta} =
                   tool.function.(%{"mode" => "billing"}, context)
        end)
      end
    end

    test "init/1 accepts an on_switch function or tuple and rejects anything else" do
      on_switch = fn _info -> :ok end

      assert switcher_config(on_switch: on_switch).on_switch == on_switch

      assert switcher_config(on_switch: {__MODULE__, :switch_text, []}).on_switch ==
               {__MODULE__, :switch_text, []}

      assert switcher_config().on_switch == nil

      for bad <- ["announce", fn -> :ok end, {__MODULE__, :switch_text}] do
        assert {:error, message} = AbilitySetSwitcher.init(sets: sets(), on_switch: bad)
        assert message =~ ":on_switch"
      end
    end

    test "init/1 accepts AbilitySet structs and fills in the display name" do
      sets = %{
        "billing" => AbilitySet.new!(%{when_to_use: "Invoices."}),
        "devices" => AbilitySet.new!(%{name: "Device Fleet", when_to_use: "Devices."})
      }

      config = switcher_config(sets: sets)

      assert %AbilitySet{name: "Billing", when_to_use: "Invoices."} = config.sets["billing"]
      assert config.sets["devices"].name == "Device Fleet"
      assert {:ok, ^config} = AbilitySetSwitcher.init(Map.to_list(config))
    end

    test "init/1 rejects an unknown key in a plain-map set" do
      sets = put_in(sets(), ["billing", :switch_mesage], "Typo.")

      assert {:error, message} = AbilitySetSwitcher.init(sets: sets)
      assert message =~ ~s(ability set "billing")
      assert message =~ "unknown keys [:switch_mesage]"
    end

    test "init/1 rejects an unknown option and accepts the keys Agent.new injects" do
      assert {:error, message} =
               AbilitySetSwitcher.init(sets: sets(), on_swich: fn _info -> :ok end)

      assert message =~ "unknown"
      assert message =~ ":on_swich"

      assert {:ok, _config} =
               AbilitySetSwitcher.init(
                 sets: sets(),
                 agent_id: "a1",
                 model: nil,
                 filesystem_scope: nil
               )
    end

    test "init/1 rejects a switch_message that is not a string or a callback" do
      for bad <- ["", 42, fn -> "no arity" end] do
        sets = put_in(sets(), ["billing", :switch_message], bad)

        assert {:error, message} = AbilitySetSwitcher.init(sets: sets)
        assert message =~ "switch_message: must be"
      end
    end

    test "init/1 is idempotent with a switch_message" do
      sets = put_in(sets(), ["billing", :switch_message], "Switching to billing.")
      config = switcher_config(sets: sets)

      assert {:ok, ^config} = AbilitySetSwitcher.init(Map.to_list(config))
    end

    test "switching to the current mode is an error" do
      tool = switch_tool(switcher_config())
      context = %{ability_sets: %{active: "devices", switches: 0}}

      assert {:error, "Already in the Devices mode."} =
               tool.function.(%{"mode" => "devices"}, context)
    end

    test "switching past the per-run limit is an error" do
      tool = switch_tool(switcher_config())
      context = %{ability_sets: %{active: "devices", switches: 1}}

      assert {:error, "Mode already switched in this turn." <> _rest} =
               tool.function.(%{"mode" => "billing"}, context)

      tool = switch_tool(switcher_config(max_switches_per_run: 2))
      assert {:ok, _text, _delta} = tool.function.(%{"mode" => "billing"}, context)
    end

    test "an unknown mode is an error" do
      tool = switch_tool(switcher_config())

      assert {:error, "Unknown mode" <> _rest} =
               tool.function.(%{"mode" => "tickets"}, %{ability_sets: %{active: nil, switches: 0}})
    end

    test "outside an agent chain the state is read" do
      tool = switch_tool(switcher_config())
      context = %{state: State.new!(%{metadata: %{"active_ability_set" => "billing"}})}

      assert {:error, "Already in the Billing mode."} =
               tool.function.(%{"mode" => "billing"}, context)
    end
  end

  describe "MiddlewareEntry.to_raw_spec/1" do
    test "ignores ability_sets" do
      entry = %MiddlewareEntry{
        id: "devices_mw",
        module: TestAbilityMiddleware,
        config: %{id: "devices_mw", tools: []},
        ability_sets: ["devices"]
      }

      assert MiddlewareEntry.to_raw_spec(entry) == {TestAbilityMiddleware, [tools: []]}
    end
  end
end
