defmodule Sagents.ToolSearchLoadedTest do
  use Sagents.BaseCase, async: false
  use Mimic

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.{ContentPart, ToolCall, ToolResult}
  alias Sagents.{Agent, State, ToolSearch}
  alias Sagents.Middleware.ToolSearch, as: Switch
  alias Sagents.TestNamespacedMiddleware

  @devices [namespace: "devices", description: "Find and restart managed devices."]

  defp function(name, options \\ []),
    do:
      Function.new!(%{
        name: name,
        options: options,
        function: fn _args, _context -> {:ok, "ok"} end
      })

  defp tools do
    namespace = [defer_loading: true, namespace: "devices", namespace_description: "Devices."]

    [
      function("whoami"),
      function("devices_list", namespace),
      function("devices_get", namespace),
      function("billing_invoices",
        defer_loading: true,
        namespace: "billing",
        namespace_description: "Billing."
      )
    ]
  end

  defp assistant(parts, calls \\ nil),
    do: Message.new_assistant!(%{content: parts, tool_calls: calls})

  defp openai_output(entries),
    do:
      ContentPart.provider_item!("openai", %{
        "type" => "tool_search_output",
        "id" => "tso_1",
        "execution" => "server",
        "call_id" => nil,
        "status" => "completed",
        "tools" => entries
      })

  defp anthropic_result(names),
    do:
      ContentPart.provider_item!("anthropic", %{
        "type" => "tool_search_tool_result",
        "tool_use_id" => "srvtoolu_1",
        "content" => %{
          "type" => "tool_search_tool_search_result",
          "tool_references" => Enum.map(names, &%{"type" => "tool_reference", "tool_name" => &1})
        }
      })

  @anthropic_use ContentPart.provider_item!("anthropic", %{
                   "type" => "server_tool_use",
                   "id" => "srvtoolu_1",
                   "name" => "tool_search_tool_bm25",
                   "input" => %{"query" => "devices"}
                 })

  defp call(name), do: ToolCall.new!(%{call_id: "call_#{name}", name: name, arguments: %{}})

  describe "loaded/2" do
    test "an OpenAI search that returns a namespace loads it and its functions" do
      message =
        assistant([
          openai_output([
            %{
              "type" => "namespace",
              "name" => "devices",
              "description" => "Devices.",
              "tools" => [
                %{"type" => "function", "name" => "devices_list"},
                %{"type" => "function", "name" => "devices_get"}
              ]
            }
          ])
        ])

      assert ToolSearch.loaded([message]) ==
               %{namespaces: ["devices"], tools: ["devices_list", "devices_get"]}
    end

    test "an OpenAI search that returns a bare function maps it to its namespace through the tools" do
      message =
        assistant([openai_output([%{"type" => "function", "name" => "billing_invoices"}])])

      assert ToolSearch.loaded([message], tools()) ==
               %{namespaces: ["billing"], tools: ["billing_invoices"]}

      assert ToolSearch.loaded([message]) == %{namespaces: [], tools: ["billing_invoices"]}
    end

    test "an Anthropic search reports tools, and namespaces when the tools are given" do
      message = assistant([@anthropic_use, anthropic_result(["devices_list", "devices_get"])])

      assert ToolSearch.loaded([message], tools()) ==
               %{namespaces: ["devices"], tools: ["devices_list", "devices_get"]}

      assert ToolSearch.loaded([message]) ==
               %{namespaces: [], tools: ["devices_list", "devices_get"]}
    end

    test "an Anthropic search error loads nothing" do
      error =
        ContentPart.provider_item!("anthropic", %{
          "type" => "tool_search_tool_result",
          "tool_use_id" => "srvtoolu_1",
          "content" => %{"type" => "tool_search_tool_result_error", "error_code" => "unavailable"}
        })

      assert ToolSearch.loaded([assistant([@anthropic_use, error])], tools()) ==
               %{namespaces: [], tools: []}
    end

    test "tool references returned by a tool load the tools they name" do
      message =
        Message.new_tool_result!(%{
          tool_results: [
            ToolResult.new!(%{
              tool_call_id: "call_load",
              name: "load_tools",
              content: [ContentPart.tool_reference!("billing_invoices")]
            })
          ]
        })

      assert ToolSearch.loaded([message], tools()) ==
               %{namespaces: ["billing"], tools: ["billing_invoices"]}
    end

    test "a call to a deferred tool counts as loaded; a call to a visible tool does not" do
      message = assistant([], [call("whoami"), call("devices_get")])

      assert ToolSearch.loaded([message], tools()) ==
               %{namespaces: ["devices"], tools: ["devices_get"]}
    end

    test "reads a State, in first-loaded order, without repeats" do
      state =
        State.new!(%{
          messages: [
            Message.new_user!("Devices, then billing."),
            assistant([@anthropic_use, anthropic_result(["devices_list"])], [call("devices_list")]),
            assistant([openai_output([%{"type" => "function", "name" => "billing_invoices"}])]),
            assistant([], [call("devices_list"), call("billing_invoices")])
          ]
        })

      assert ToolSearch.loaded(state, tools()) ==
               %{namespaces: ["devices", "billing"], tools: ["devices_list", "billing_invoices"]}
    end

    test "a conversation without searches has loaded nothing" do
      assert ToolSearch.loaded(State.new!(%{messages: [Message.new_user!("Hi")]}), tools()) ==
               %{namespaces: [], tools: []}
    end
  end

  describe "searches/2" do
    test "counts the search results in one message and leaves out calls" do
      message =
        assistant([@anthropic_use, anthropic_result(["devices_list"])], [call("devices_get")])

      assert ToolSearch.searches(message, tools()) == %{
               count: 1,
               loaded: %{namespaces: ["devices"], tools: ["devices_list"]}
             }

      assert %{count: 0} = ToolSearch.searches(assistant([], [call("devices_get")]), tools())
    end
  end

  describe "telemetry" do
    setup do
      test_pid = self()
      handler = "tool-search-loaded-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:sagents, :tool_search, :loaded],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:loaded_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp agent do
      Agent.new!(
        %{
          agent_id: "tool-search-telemetry",
          model: mock_model(),
          middleware: [
            Switch,
            {TestNamespacedMiddleware, tools: ["devices_list"], tool_search: @devices}
          ]
        },
        replace_default_middleware: true
      )
    end

    test "a response holding a search emits one event with what it loaded" do
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok,
         [
           assistant([
             @anthropic_use,
             anthropic_result(["devices_list"]),
             ContentPart.text!("Found it.")
           ])
         ]}
      end)

      state = State.new!(%{messages: [Message.new_user!("List the devices")]})
      assert {:ok, _state} = Agent.execute(agent(), state)

      assert_received {:loaded_event, %{count: 1}, metadata}

      assert metadata == %{
               agent_id: "tool-search-telemetry",
               namespaces: ["devices"],
               tools: ["devices_list"]
             }

      refute_received {:loaded_event, _measurements, _metadata}
    end

    test "a tool result returning tool references emits an event" do
      load_tools =
        Function.new!(%{
          name: "load_tools",
          function: fn _args, _context -> {:ok, [ContentPart.tool_reference!("devices_list")]} end
        })

      agent =
        Agent.new!(
          %{
            agent_id: "tool-search-telemetry",
            model: mock_model(),
            tools: [load_tools],
            middleware: [
              Switch,
              {TestNamespacedMiddleware, tools: ["devices_list"], tool_search: @devices}
            ]
          },
          replace_default_middleware: true
        )

      stub(ChatAnthropic, :call, fn _model, messages, _tools ->
        if Enum.any?(messages, &(&1.role == :tool)),
          do: {:ok, [Message.new_assistant!("Loaded.")]},
          else: {:ok, [assistant([], [call("load_tools")])]}
      end)

      state = State.new!(%{messages: [Message.new_user!("Load the device tools")]})
      assert {:ok, _state} = Agent.execute(agent, state)

      assert_received {:loaded_event, %{count: 1},
                       %{namespaces: ["devices"], tools: ["devices_list"]}}
    end

    test "a response without a search emits nothing" do
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("No tools needed.")]}
      end)

      state = State.new!(%{messages: [Message.new_user!("Hi")]})
      assert {:ok, _state} = Agent.execute(agent(), state)

      refute_received {:loaded_event, _measurements, _metadata}
    end
  end
end
