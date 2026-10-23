defmodule Sagents.ToolSearchFallbackTest do
  @moduledoc """
  A fallback chat model receives the same tools and history as the primary,
  including the search tool and another provider's search items. Each chat
  model drops what it cannot send while building its own request, so the
  fallback's request has no search tool and no foreign items, and every tool
  goes out as an ordinary function.
  """
  use Sagents.BaseCase, async: true
  use Mimic

  alias LangChain.ChatModels.{ChatAnthropic, ChatOpenAI}
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.{ContentPart, ToolCall, ToolResult}
  alias LangChain.NativeTool
  alias Sagents.{Agent, State}
  alias Sagents.Middleware.ToolSearch
  alias Sagents.TestNamespacedMiddleware

  @devices [namespace: "devices", description: "Find and restart managed devices."]

  defp agent do
    Agent.new!(
      %{
        model: mock_model(),
        fallback_models: [ChatOpenAI.new!(%{model: "gpt-4.1", api_key: "test_key"})],
        middleware: [
          ToolSearch,
          {TestNamespacedMiddleware, tools: ["devices_list"], tool_search: @devices}
        ]
      },
      replace_default_middleware: true
    )
  end

  # History from a turn on Anthropic that searched and called a loaded tool.
  defp anthropic_history do
    [
      Message.new_user!("How many devices at hq?"),
      Message.new_assistant!(%{
        content: [
          ContentPart.provider_item!("anthropic", %{
            "type" => "server_tool_use",
            "id" => "srvtoolu_1",
            "name" => "tool_search_tool_bm25",
            "input" => %{"query" => "devices"}
          }),
          ContentPart.provider_item!("anthropic", %{
            "type" => "tool_search_tool_result",
            "tool_use_id" => "srvtoolu_1",
            "content" => %{
              "type" => "tool_search_tool_search_result",
              "tool_references" => [%{"type" => "tool_reference", "tool_name" => "devices_list"}]
            }
          })
        ],
        tool_calls: [ToolCall.new!(%{call_id: "toolu_1", name: "devices_list", arguments: %{}})]
      }),
      Message.new_tool_result!(%{
        tool_results: [
          ToolResult.new!(%{tool_call_id: "toolu_1", name: "devices_list", content: "17 devices"})
        ]
      }),
      Message.new_assistant!("There are 17 devices at hq."),
      Message.new_user!("And at the warehouse?")
    ]
  end

  setup do
    test_pid = self()

    stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
      {:error, LangChainError.exception(type: "overloaded_error", message: "Overloaded")}
    end)

    stub(ChatOpenAI, :call, fn model, messages, tools ->
      send(test_pid, {:fallback_request, model, messages, tools})
      {:ok, [Message.new_assistant!("Done.")]}
    end)

    :ok
  end

  test "the fallback is handed the search tool and builds a request without it" do
    state = State.new!(%{messages: [Message.new_user!("List the devices")]})
    assert {:ok, _state} = Agent.execute(agent(), state)

    assert_received {:fallback_request, model, messages, tools}

    # The chain hands every model the same tools.
    assert %NativeTool{name: "tool_search"} = Enum.find(tools, &(&1.name == "tool_search"))

    request = ChatOpenAI.for_api(model, messages, tools)

    assert [%{"type" => "function", "function" => function}] = request.tools
    assert function["name"] == "devices_list"
    refute Map.has_key?(function, "defer_loading")
    refute inspect(request) =~ "tool_search"
  end

  test "the fallback's request skips the primary's search items and keeps the call" do
    state = State.new!(%{messages: anthropic_history()})
    assert {:ok, _state} = Agent.execute(agent(), state)

    assert_received {:fallback_request, model, messages, tools}

    # The history the fallback receives still holds the Anthropic blocks.
    assert Enum.any?(messages, fn message ->
             is_list(message.content) and
               Enum.any?(message.content, &match?(%ContentPart{type: :provider_item}, &1))
           end)

    request = ChatOpenAI.for_api(model, messages, tools)
    encoded = inspect(request.messages)

    refute encoded =~ "server_tool_use"
    refute encoded =~ "srvtoolu_1"
    assert encoded =~ "toolu_1"
    assert encoded =~ "17 devices"
  end
end
