defmodule Sagents.ToolSearchTest do
  use Sagents.BaseCase, async: true

  import ExUnit.CaptureLog

  alias LangChain.Function
  alias LangChain.NativeTool
  alias Sagents.AbilitySet
  alias Sagents.AbilitySets
  alias Sagents.Agent
  alias Sagents.Middleware.AbilitySetSwitcher
  alias Sagents.Middleware.ToolSearch
  alias Sagents.MiddlewareEntry
  alias Sagents.TestNamespacedMiddleware

  @devices [namespace: "devices", description: "Find and restart managed devices."]

  defp mw(id, tools, opts \\ []),
    do: {TestNamespacedMiddleware, Keyword.merge([id: id, tools: tools], opts)}

  defp new_agent(middleware, tools \\ []) do
    Agent.new(
      %{model: mock_model(), tools: tools, middleware: middleware},
      replace_default_middleware: true
    )
  end

  defp errors_text({:error, changeset}),
    do: Enum.map_join(changeset.errors, "\n", fn {_field, {message, _opts}} -> message end)

  defp function(agent, name), do: Enum.find(agent.tools, &(&1.name == name))

  defp stamp(%Function{} = function),
    do:
      {Function.deferred?(function), Function.namespace(function),
       Function.namespace_description(function)}

  describe "stamping" do
    test "a declared namespace defers its middleware's functions and groups them" do
      {:ok, agent} =
        new_agent([
          ToolSearch,
          mw("rail_mw", ["whoami"]),
          mw("devices_mw", ["devices_list", "devices_restart"], tool_search: @devices)
        ])

      assert [
               %NativeTool{name: "tool_search"},
               %Function{name: "whoami"} = rail,
               %Function{name: "devices_list"} = list,
               %Function{name: "devices_restart"} = restart
             ] = agent.tools

      refute Function.deferred?(rail)
      assert Function.namespace(rail) == nil

      for function <- [list, restart] do
        assert stamp(function) == {true, "devices", "Find and restart managed devices."}
      end
    end

    test "options a function sets itself win over the stamp" do
      {:ok, agent} =
        new_agent([
          ToolSearch,
          mw("devices_mw", ["devices_lookup", "devices_list", "sites_list"],
            tool_search: @devices,
            tool_options: %{
              "devices_lookup" => [defer_loading: false],
              "sites_list" => [namespace: "sites", namespace_description: "Sites and locations."]
            }
          )
        ])

      assert {false, "devices", _description} = stamp(function(agent, "devices_lookup"))
      assert {true, "devices", _description} = stamp(function(agent, "devices_list"))
      assert {true, "sites", "Sites and locations."} = stamp(function(agent, "sites_list"))
    end

    test "the search tool's variant comes from the switch" do
      {:ok, agent} = new_agent([{ToolSearch, variant: :regex}])
      assert [%NativeTool{} = search] = agent.tools
      assert search == NativeTool.tool_search(variant: :regex)
    end

    test "without the switch, tool_search/1 is never consulted and nothing changes" do
      {:ok, agent} = new_agent([mw("devices_mw", ["devices_list"], tool_search: @devices)])

      assert [%Function{name: "devices_list"} = list] = agent.tools
      assert stamp(list) == {false, nil, nil}
      assert agent.tool_search_index == nil
      assert [%MiddlewareEntry{tool_search: nil}] = agent.middleware
    end

    test "base tools are left as given" do
      base = Function.new!(%{name: "echo", function: fn _args, _context -> {:ok, "ok"} end})
      {:ok, agent} = new_agent([ToolSearch], [base])

      assert [%Function{name: "echo"} = echo, %NativeTool{}] = agent.tools
      refute Function.deferred?(echo)
    end
  end

  describe "overrides" do
    test "an override makes a middleware without tool_search/1 a namespace" do
      {:ok, agent} =
        new_agent([
          {ToolSearch,
           namespaces: %{"billing_mw" => [namespace: "billing", description: "Invoices."]}},
          mw("billing_mw", ["billing_invoices"])
        ])

      assert {true, "billing", "Invoices."} = stamp(function(agent, "billing_invoices"))

      assert %MiddlewareEntry{tool_search: %{namespace: "billing", description: "Invoices."}} =
               Enum.find(agent.middleware, &(&1.id == "billing_mw"))
    end

    test "an override's keys replace the middleware's own, and the rest are kept" do
      {:ok, agent} =
        new_agent([
          {ToolSearch, namespaces: %{"devices_mw" => [namespace: "fleet"]}},
          mw("devices_mw", ["devices_list"], tool_search: @devices)
        ])

      assert {true, "fleet", "Find and restart managed devices."} =
               stamp(function(agent, "devices_list"))
    end

    test "false keeps a declaring middleware's tools visible" do
      {:ok, agent} =
        new_agent([
          {ToolSearch, namespaces: %{"devices_mw" => false}},
          mw("devices_mw", ["devices_list"], tool_search: @devices)
        ])

      assert stamp(function(agent, "devices_list")) == {false, nil, nil}
    end

    test "a switch configured by the caller has its overrides checked" do
      assert {:ok, config} = ToolSearch.init(namespaces: %{"devices_mw" => false})
      refute Map.has_key?(config, :overrides_checked)
    end

    test "an override naming no entry is an error" do
      result =
        new_agent([
          {ToolSearch, namespaces: %{"devcies_mw" => [namespace: "devices", description: "x"]}},
          mw("devices_mw", ["devices_list"])
        ])

      assert errors_text(result) =~ "names no middleware entry"
      assert errors_text(result) =~ "devcies_mw"
    end
  end

  describe "the index" do
    test "lists each namespace with its description, tools and contributing entries" do
      {:ok, agent} =
        new_agent([
          ToolSearch,
          mw("rail_mw", ["whoami"]),
          mw("devices_mw", ["devices_list", "devices_restart"], tool_search: @devices),
          mw("more_devices_mw", ["devices_get"], tool_search: @devices)
        ])

      assert agent.tool_search_index == %{
               "devices" => %{
                 description: "Find and restart managed devices.",
                 tools: ["devices_list", "devices_restart", "devices_get"],
                 entry_ids: ["devices_mw", "more_devices_mw"]
               }
             }
    end

    test "a switch with nothing deferred is valid" do
      assert {:ok, %Agent{tool_search_index: index}} =
               new_agent([ToolSearch, mw("rail_mw", ["whoami"])])

      assert index == %{}
    end

    test "ten or more functions in one namespace logs a warning" do
      names = for n <- 1..10, do: "devices_#{n}"

      log =
        capture_log(fn ->
          assert {:ok, _agent} =
                   new_agent([ToolSearch, mw("devices_mw", names, tool_search: @devices)])
        end)

      assert log =~ ~s(namespace "devices" holds 10 functions)
    end
  end

  describe "validation" do
    test "a namespace without a description is an error" do
      result =
        new_agent([
          ToolSearch,
          mw("devices_mw", ["devices_list"], tool_search: [namespace: "devices"])
        ])

      assert errors_text(result) =~ ~s(namespace "devices" needs a :description)
    end

    test "a namespace name outside the pattern is an error" do
      for bad <- ["Devices", "1devices", "devices-list", String.duplicate("a", 65)] do
        result =
          new_agent([
            ToolSearch,
            mw("devices_mw", ["devices_list"], tool_search: [namespace: bad, description: "x"])
          ])

        assert errors_text(result) =~ "must match"
      end
    end

    test "two declarations giving one namespace different descriptions is an error" do
      result =
        new_agent([
          ToolSearch,
          mw("devices_mw", ["devices_list"], tool_search: @devices),
          mw("more_devices_mw", ["devices_get"],
            tool_search: [namespace: "devices", description: "Something else."]
          )
        ])

      assert errors_text(result) =~ ~s(namespace "devices" has different descriptions)
    end

    test "a function setting its own namespace without any description is an error" do
      result =
        new_agent([
          ToolSearch,
          mw("devices_mw", ["devices_list"],
            tool_options: %{"devices_list" => [namespace: "devices"]}
          )
        ])

      assert errors_text(result) =~ ~s(namespace "devices" has no description)
    end

    test "an unknown declaration key is an error" do
      result =
        new_agent([
          ToolSearch,
          mw("devices_mw", ["devices_list"], tool_search: @devices ++ [descripton: "typo"])
        ])

      assert errors_text(result) =~ "unknown key(s) [:descripton]"

      result =
        new_agent([
          ToolSearch,
          mw("devices_mw", ["devices_list"], tool_search: @devices ++ [system_prompt: :drop])
        ])

      assert errors_text(result) =~ "unknown key(s) [:system_prompt]"
    end

    test "a tool_search/1 that returns something other than a keyword list is an error" do
      result =
        new_agent([
          ToolSearch,
          mw("devices_mw", ["devices_list"], tool_search: %{namespace: "devices"})
        ])

      assert errors_text(result) =~ "must be a keyword list"
    end

    test "unknown switch options and bad values are errors" do
      assert errors_text(new_agent([{ToolSearch, varient: :bm25}])) =~
               "unknown option(s) [:varient]"

      assert errors_text(new_agent([{ToolSearch, variant: :fuzzy}])) =~ ":variant must be one of"
      assert errors_text(new_agent([{ToolSearch, namespaces: [devices: true]}])) =~ ":namespaces"
    end
  end

  describe "the switch's config" do
    test "init/1 accepts its own output, as a sub-agent rebuilding from the parent passes it" do
      {:ok, agent} =
        new_agent([
          {ToolSearch,
           variant: :regex,
           catalog: false,
           namespaces: %{"billing_mw" => [namespace: "billing", description: "Invoices."]}},
          mw("billing_mw", ["billing_invoices"])
        ])

      switch = Enum.find(agent.middleware, &(&1.module == ToolSearch))
      {ToolSearch, opts} = MiddlewareEntry.to_raw_spec(switch)

      assert {:ok, config} = ToolSearch.init(opts)

      keys = [:variant, :catalog, :namespaces, :overrides_checked]
      assert Map.take(config, keys) == Map.take(switch.config, keys)
      assert config.overrides_checked == true
    end
  end

  describe "the catalog" do
    @billing [namespace: "billing", description: "Invoices and balances."]

    test "lists each namespace with deferred tools, in stack order, at the switch's position" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            base_system_prompt: "You are the IT operations assistant.",
            middleware: [
              mw("rail_mw", ["whoami"], prompt: "Rail fragment."),
              ToolSearch,
              mw("billing_mw", ["billing_invoices"], tool_search: @billing),
              mw("devices_mw", ["devices_list"],
                tool_search: @devices,
                prompt: "To restart a device that is not responding, load the devices tools."
              )
            ]
          },
          replace_default_middleware: true
        )

      assert agent.assembled_system_prompt ==
               """
               You are the IT operations assistant.

               Rail fragment.

               Some tools load on demand. Search for tools when you need one of these:
               - billing: Invoices and balances.
               - devices: Find and restart managed devices.

               To restart a device that is not responding, load the devices tools.\
               """
    end

    test "a namespace whose tools are all visible is not listed" do
      {:ok, agent} =
        new_agent([
          ToolSearch,
          mw("devices_mw", ["devices_lookup"],
            tool_search: @devices,
            tool_options: %{"devices_lookup" => [defer_loading: false]}
          ),
          mw("billing_mw", ["billing_invoices"], tool_search: @billing)
        ])

      refute agent.assembled_system_prompt =~ "- devices:"
      assert agent.assembled_system_prompt =~ "- billing: Invoices and balances."
    end

    test "a base tool's own namespace is listed" do
      base =
        Function.new!(%{
          name: "reports_run",
          options: [defer_loading: true, namespace: "reports", namespace_description: "Reports."],
          function: fn _args, _context -> {:ok, "ok"} end
        })

      {:ok, agent} = new_agent([ToolSearch], [base])

      assert agent.assembled_system_prompt =~ "- reports: Reports."
    end

    test "nothing deferred means no catalog" do
      {:ok, agent} = new_agent([ToolSearch, mw("rail_mw", ["whoami"], prompt: "Rail fragment.")])
      assert agent.assembled_system_prompt == "Rail fragment."
    end

    test "catalog: false leaves it out, and the namespace's own fragment is still sent" do
      {:ok, agent} =
        new_agent([
          {ToolSearch, catalog: false},
          mw("devices_mw", ["devices_list"], tool_search: @devices, prompt: "Devices fragment.")
        ])

      assert agent.assembled_system_prompt == "Devices fragment."
    end

    test "the assembled prompt is the same for two agents with the same config" do
      middleware = [
        ToolSearch,
        mw("billing_mw", ["billing_invoices"], tool_search: @billing),
        mw("devices_mw", ["devices_list"], tool_search: @devices)
      ]

      {:ok, first} = new_agent(middleware)
      {:ok, second} = new_agent(middleware)

      assert first.assembled_system_prompt == second.assembled_system_prompt
      assert first.assembled_system_prompt =~ "- billing:"
    end
  end

  describe "with ability sets" do
    defp sets do
      %{
        "devices" =>
          AbilitySet.new!(%{
            name: "Devices",
            when_to_use: "Device inventory.",
            middleware: [mw("devices_mw", ["devices_list"], tool_search: @devices)]
          }),
        "billing" =>
          AbilitySet.new!(%{
            name: "Billing",
            when_to_use: "Invoices.",
            middleware: [mw("billing_mw", ["billing_invoices"])]
          })
      }
    end

    test "a namespaced middleware inside a set sends its stamped tools when the set is active" do
      {:ok, agent} =
        new_agent([ToolSearch, mw("rail_mw", ["whoami"]), {AbilitySetSwitcher, sets: sets()}])

      devices_tools = AbilitySets.effective(agent, "devices").tools
      billing_tools = AbilitySets.effective(agent, "billing").tools

      assert %NativeTool{name: "tool_search"} =
               Enum.find(devices_tools, &(&1.name == "tool_search"))

      assert %NativeTool{name: "tool_search"} =
               Enum.find(billing_tools, &(&1.name == "tool_search"))

      assert {true, "devices", _description} =
               stamp(Enum.find(devices_tools, &(&1.name == "devices_list")))

      assert {false, nil, nil} = stamp(Enum.find(billing_tools, &(&1.name == "billing_invoices")))
    end

    test "each set's prompt lists only the namespaces of the tools that set sends" do
      {:ok, agent} =
        new_agent([
          ToolSearch,
          mw("rail_mw", ["whoami"]),
          mw("reports_mw", ["reports_run"],
            tool_search: [namespace: "reports", description: "Reports."]
          ),
          {AbilitySetSwitcher, sets: sets()}
        ])

      devices_prompt = AbilitySets.effective(agent, "devices").system_prompt
      billing_prompt = AbilitySets.effective(agent, "billing").system_prompt
      rails_prompt = AbilitySets.effective(agent, nil).system_prompt

      assert devices_prompt =~ "- reports: Reports."
      assert devices_prompt =~ "- devices: Find and restart managed devices."

      assert billing_prompt =~ "- reports: Reports."
      refute billing_prompt =~ "- devices: Find and restart managed devices."

      assert rails_prompt =~ "- reports: Reports."
      refute rails_prompt =~ "- devices: Find and restart managed devices."
    end

    test "the switch inside an ability set is an error" do
      in_set =
        Map.put(
          sets(),
          "search",
          AbilitySet.new!(%{name: "Search", when_to_use: "Search.", middleware: [ToolSearch]})
        )

      result = new_agent([{AbilitySetSwitcher, sets: in_set}])

      assert errors_text(result) =~ "must not be in an ability set"
    end
  end
end
