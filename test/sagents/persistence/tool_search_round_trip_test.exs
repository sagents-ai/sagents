defmodule Sagents.Persistence.ToolSearchRoundTripTest do
  use Sagents.BaseCase, async: true

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.ChatModels.ChatOpenAIResponses
  alias LangChain.Message
  alias LangChain.Message.{ContentPart, ToolCall, ToolResult}
  alias Sagents.Message.DisplayHelpers
  alias Sagents.Persistence.StateSerializer
  alias Sagents.State

  @openai_search_call %{
    "type" => "tool_search_call",
    "id" => "tsc_1",
    "execution" => "server",
    "call_id" => nil,
    "status" => "completed",
    "arguments" => %{"paths" => ["devices"]}
  }

  @openai_search_output %{
    "type" => "tool_search_output",
    "id" => "tso_1",
    "execution" => "server",
    "call_id" => nil,
    "status" => "completed",
    "tools" => [
      %{
        "type" => "namespace",
        "name" => "devices",
        "description" => "Managed devices.",
        "tools" => [%{"type" => "function", "name" => "devices_list", "defer_loading" => true}]
      }
    ]
  }

  @anthropic_server_tool_use %{
    "type" => "server_tool_use",
    "id" => "srvtoolu_1",
    "name" => "tool_search_tool_bm25",
    "input" => %{"query" => "devices"}
  }

  @anthropic_search_result %{
    "type" => "tool_search_tool_result",
    "tool_use_id" => "srvtoolu_1",
    "content" => %{
      "type" => "tool_search_tool_search_result",
      "tool_references" => [%{"type" => "tool_reference", "tool_name" => "devices_list"}]
    }
  }

  defp openai_history do
    [
      Message.new_user!("How many devices at hq?"),
      Message.new_assistant!(%{
        content: [
          ContentPart.provider_item!("openai", @openai_search_call),
          ContentPart.provider_item!("openai", @openai_search_output)
        ],
        tool_calls: [
          ToolCall.new!(%{
            call_id: "call_1",
            name: "devices_list",
            arguments: %{"site" => "hq"},
            metadata: %{"namespace" => "devices"}
          })
        ]
      }),
      Message.new_tool_result!(%{
        tool_results: [
          ToolResult.new!(%{tool_call_id: "call_1", name: "devices_list", content: "17 devices"})
        ]
      })
    ]
  end

  defp anthropic_history do
    [
      Message.new_user!("How many devices at hq?"),
      Message.new_assistant!(%{
        content: [
          ContentPart.text!("Searching."),
          ContentPart.provider_item!("anthropic", @anthropic_server_tool_use),
          ContentPart.provider_item!("anthropic", @anthropic_search_result)
        ],
        tool_calls: [
          ToolCall.new!(%{call_id: "toolu_1", name: "load_tools", arguments: %{}})
        ]
      }),
      Message.new_tool_result!(%{
        tool_results: [
          ToolResult.new!(%{
            tool_call_id: "toolu_1",
            name: "load_tools",
            content: [
              ContentPart.tool_reference!("devices_list"),
              ContentPart.tool_reference!("devices_get")
            ]
          })
        ]
      })
    ]
  end

  # Serializes the way a host persists state: through JSON, so atoms become
  # strings and keyword lists become objects.
  defp round_trip(messages) do
    state = State.new!(%{messages: messages})

    json =
      state
      |> StateSerializer.serialize_state()
      |> Jason.encode!()
      |> Jason.decode!()

    {:ok, restored} = StateSerializer.deserialize_state(generate_test_agent_id(), json)
    restored.messages
  end

  # The serializer restores options from a JSON object, so their order is not
  # kept. Chat models read them by key.
  defp provider_item(%ContentPart{type: :provider_item, options: options}),
    do: {Keyword.fetch!(options, :provider), Keyword.fetch!(options, :item)}

  describe "OpenAI search items" do
    test "provider items and the call's namespace restore unchanged" do
      original = openai_history()
      restored = round_trip(original)

      assert [_user, assistant, _tool] = restored

      assert [{"openai", @openai_search_call}, {"openai", @openai_search_output}] =
               Enum.map(assistant.content, &provider_item/1)

      assert [%ToolCall{name: "devices_list", metadata: %{"namespace" => "devices"}}] =
               assistant.tool_calls
    end

    test "the restored history encodes for the Responses API as the original does" do
      model = ChatOpenAIResponses.new!(%{model: "gpt-5.4"})
      original = openai_history()

      assert ChatOpenAIResponses.for_api(model, round_trip(original), []).input ==
               ChatOpenAIResponses.for_api(model, original, []).input
    end
  end

  describe "Anthropic search blocks and tool references" do
    test "provider items and tool references restore unchanged" do
      restored = round_trip(anthropic_history())

      assert [_user, assistant, tool] = restored

      assert [%ContentPart{type: :text, content: "Searching."} | blocks] = assistant.content

      assert [{"anthropic", @anthropic_server_tool_use}, {"anthropic", @anthropic_search_result}] =
               Enum.map(blocks, &provider_item/1)

      assert [%ToolResult{content: references}] = tool.tool_results

      assert [
               %ContentPart{type: :tool_reference, content: "devices_list"},
               %ContentPart{type: :tool_reference, content: "devices_get"}
             ] = references
    end

    test "the restored history encodes for the Messages API as the original does" do
      model = ChatAnthropic.new!(%{model: "claude-sonnet-5-5"})
      original = anthropic_history()

      assert ChatAnthropic.for_api(model, round_trip(original), []).messages ==
               ChatAnthropic.for_api(model, original, []).messages
    end
  end

  describe "display" do
    test "provider items produce no display items and raise nothing" do
      for message <- round_trip(openai_history() ++ anthropic_history()) do
        items = DisplayHelpers.extract_display_items(message)
        refute Enum.any?(items, &(&1.type == :provider_item))
      end
    end

    test "only the text beside the search blocks is displayed" do
      [_user, assistant, _tool] = round_trip(anthropic_history())

      assert [%{type: :text, content: %{"text" => "Searching."}} | _rest] =
               DisplayHelpers.extract_display_items(assistant)
    end
  end
end
