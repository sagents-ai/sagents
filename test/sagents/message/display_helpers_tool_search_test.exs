defmodule Sagents.Message.DisplayHelpersToolSearchTest do
  use ExUnit.Case, async: true

  alias LangChain.Message
  alias LangChain.Message.{ContentPart, ToolCall, ToolResult}
  alias Sagents.Message.DisplayHelpers

  @anthropic_use ContentPart.provider_item!("anthropic", %{
                   "type" => "server_tool_use",
                   "id" => "srvtoolu_1",
                   "name" => "tool_search_tool_bm25",
                   "input" => %{"query" => "restart devices"}
                 })

  defp anthropic_result(names, id \\ "srvtoolu_1"),
    do:
      ContentPart.provider_item!("anthropic", %{
        "type" => "tool_search_tool_result",
        "tool_use_id" => id,
        "content" => %{
          "type" => "tool_search_tool_search_result",
          "tool_references" => Enum.map(names, &%{"type" => "tool_reference", "tool_name" => &1})
        }
      })

  @openai_call ContentPart.provider_item!("openai", %{
                 "type" => "tool_search_call",
                 "id" => "tsc_1",
                 "execution" => "server",
                 "call_id" => nil,
                 "status" => "completed",
                 "arguments" => %{"paths" => ["devices"]}
               })

  @openai_output ContentPart.provider_item!("openai", %{
                   "type" => "tool_search_output",
                   "id" => "tso_1",
                   "execution" => "server",
                   "call_id" => nil,
                   "status" => "completed",
                   "tools" => [
                     %{
                       "type" => "namespace",
                       "name" => "devices",
                       "description" => "Devices.",
                       "tools" => [
                         %{"type" => "function", "name" => "devices_list"},
                         %{"type" => "function", "name" => "devices_restart"}
                       ]
                     }
                   ]
                 })

  defp items(message), do: DisplayHelpers.extract_display_items(message, tool_search: true)

  describe "with tool_search: true" do
    test "an Anthropic search sits between the text around it, with its query" do
      message =
        Message.new_assistant!(%{
          content: [
            ContentPart.text!("Searching."),
            @anthropic_use,
            anthropic_result(["devices_restart"]),
            ContentPart.text!("Found it.")
          ],
          tool_calls: [
            ToolCall.new!(%{call_id: "toolu_1", name: "devices_restart", arguments: %{}})
          ]
        })

      assert [
               %{type: :text, content: %{"text" => "Searching."}},
               %{
                 type: :tool_search,
                 message_type: :assistant,
                 content:
                   %{
                     "provider" => "anthropic",
                     "query" => "restart devices",
                     "tools" => ["devices_restart"],
                     "namespaces" => []
                   } = content
               },
               %{type: :text, content: %{"text" => "Found it."}},
               %{type: :tool_call, content: %{"name" => "devices_restart"}}
             ] = items(message)

      refute Map.has_key?(content, "error")
      refute Map.has_key?(content, "tool_call_id")
    end

    test "an OpenAI search reports its namespace, its tools, and the paths it looked up" do
      message =
        Message.new_assistant!(%{
          content: [@openai_call, @openai_output],
          tool_calls: [ToolCall.new!(%{call_id: "call_1", name: "devices_list", arguments: %{}})]
        })

      assert [
               %{
                 type: :tool_search,
                 content: %{
                   "provider" => "openai",
                   "query" => "devices",
                   "namespaces" => ["devices"],
                   "tools" => ["devices_list", "devices_restart"]
                 }
               },
               %{type: :tool_call}
             ] = items(message)
    end

    test "a failed search is marked and loads nothing" do
      error =
        ContentPart.provider_item!("anthropic", %{
          "type" => "tool_search_tool_result",
          "tool_use_id" => "srvtoolu_1",
          "content" => %{"type" => "tool_search_tool_result_error", "error_code" => "unavailable"}
        })

      message = Message.new_assistant!(%{content: [@anthropic_use, error]})

      assert [%{type: :tool_search, content: %{"error" => true, "tools" => []}}] = items(message)
    end

    test "a search that found nothing is still shown" do
      message = Message.new_assistant!(%{content: [@anthropic_use, anthropic_result([])]})

      assert [%{type: :tool_search, content: %{"tools" => [], "query" => "restart devices"}}] =
               items(message)
    end

    test "a tool result returning tool references is followed by the load it made" do
      message =
        Message.new_tool_result!(%{
          tool_results: [
            ToolResult.new!(%{
              tool_call_id: "call_load",
              name: "load_tools",
              content: [
                ContentPart.tool_reference!("billing_invoices"),
                ContentPart.tool_reference!("billing_refund")
              ]
            }),
            ToolResult.new!(%{tool_call_id: "call_echo", name: "echo", content: "hi"})
          ]
        })

      assert [
               %{type: :tool_result, content: %{"tool_call_id" => "call_load"}},
               %{
                 type: :tool_search,
                 message_type: :tool,
                 content:
                   %{
                     "tool_call_id" => "call_load",
                     "tools" => ["billing_invoices", "billing_refund"],
                     "namespaces" => []
                   } = content
               },
               %{type: :tool_result, content: %{"tool_call_id" => "call_echo"}}
             ] = items(message)

      refute Map.has_key?(content, "provider")
      refute Map.has_key?(content, "query")
    end

    test "provider items that are not searches produce nothing" do
      other =
        ContentPart.provider_item!("anthropic", %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_2",
          "name" => "web_search",
          "input" => %{"query" => "elixir"}
        })

      message = Message.new_assistant!(%{content: [ContentPart.text!("Hi."), other]})

      assert [%{type: :text, content: %{"text" => "Hi."}}] = items(message)
    end

    test "the stop reason still marks the last item" do
      message =
        %{content: [@anthropic_use, anthropic_result(["devices_list"])]}
        |> Message.new_assistant!()
        |> Map.put(:status, :length)

      assert [%{type: :tool_search, content: %{"stop_reason" => "length"}}] = items(message)
    end
  end

  describe "without the option" do
    test "search items produce no display items" do
      message =
        Message.new_assistant!(%{
          content: [ContentPart.text!("Searching."), @anthropic_use, anthropic_result(["x"])]
        })

      assert [%{type: :text}] = DisplayHelpers.extract_display_items(message)

      assert DisplayHelpers.extract_display_items(message) ==
               DisplayHelpers.extract_display_items(message, tool_search: false)
    end
  end
end
