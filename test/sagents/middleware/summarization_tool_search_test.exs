defmodule Sagents.Middleware.SummarizationToolSearchTest do
  @moduledoc """
  Summarization of a conversation that used provider tool search. Summarized
  turns go with their search items, kept turns keep theirs unchanged, and the
  summary transcript holds no search item content.
  """
  use Sagents.BaseCase, async: true
  use Mimic

  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Message.{ContentPart, ToolCall, ToolResult}
  alias Sagents.Middleware.Summarization
  alias Sagents.State

  @search_call %{
    "type" => "tool_search_call",
    "id" => "tsc_1",
    "execution" => "server",
    "call_id" => nil,
    "status" => "completed",
    "arguments" => %{"paths" => ["devices"]}
  }

  @search_output %{
    "type" => "tool_search_output",
    "id" => "tso_1",
    "execution" => "server",
    "call_id" => nil,
    "status" => "completed",
    "tools" => [%{"type" => "namespace", "name" => "devices", "description" => "Devices."}]
  }

  defp call(id),
    do:
      ToolCall.new!(%{
        call_id: id,
        name: "devices_list",
        arguments: %{"site" => "hq"},
        metadata: %{"namespace" => "devices"}
      })

  defp result(id, text),
    do:
      Message.new_tool_result!(%{
        tool_results: [ToolResult.new!(%{tool_call_id: id, name: "devices_list", content: text})]
      })

  # Turn one searches and calls the loaded tool. Turn two calls it again
  # without searching, which a provider allows once the tool is loaded.
  defp conversation do
    [
      Message.new_system!("You are the IT operations assistant."),
      Message.new_user!("How many devices at hq?"),
      Message.new_assistant!(%{
        content: [
          ContentPart.provider_item!("openai", @search_call),
          ContentPart.provider_item!("openai", @search_output)
        ],
        tool_calls: [call("call_1")]
      }),
      result("call_1", "17 devices"),
      Message.new_assistant!("There are 17 devices at hq."),
      Message.new_user!("Check again."),
      Message.new_assistant!(%{tool_calls: [call("call_2")]}),
      result("call_2", "17 devices"),
      Message.new_assistant!("Still 17.")
    ]
  end

  defp summarize(messages_to_keep) do
    test_pid = self()

    stub(ChatOpenAI, :call, fn _model, messages, _tools ->
      send(test_pid, {:summarizer_messages, messages})
      {:ok, [Message.new_assistant!("Summary of the device questions.")]}
    end)

    {:ok, config} =
      Summarization.init(
        model: ChatOpenAI.new!(%{model: "gpt-4", stream: false}),
        max_tokens_before_summary: 100,
        token_counter: fn _msgs -> 1_000 end,
        messages_to_keep: messages_to_keep
      )

    state = State.new!(%{agent_id: generate_test_agent_id(), messages: conversation()})
    {:ok, state} = Summarization.before_model(state, config)
    state.messages
  end

  defp provider_items(messages) do
    for %Message{content: parts} when is_list(parts) <- messages,
        %ContentPart{type: :provider_item} = part <- parts,
        do: part
  end

  test "a summarized turn takes its search items with it, and the transcript holds none" do
    messages = summarize(4)

    assert [] = provider_items(messages)

    assert_received {:summarizer_messages, summarizer_messages}

    transcript =
      Enum.map_join(summarizer_messages, "\n", &ContentPart.content_to_string(&1.content))

    refute transcript =~ "tool_search"
    refute transcript =~ "tsc_1"
    assert transcript =~ "17 devices"
  end

  test "a later call to the loaded tool is kept with its namespace and without the search" do
    messages = summarize(4)

    assert [
             %Message{role: :system},
             %Message{role: :user},
             %Message{role: :assistant},
             %Message{role: :user, content: [%ContentPart{content: "Check again."}]},
             %Message{role: :assistant, tool_calls: [kept_call]},
             %Message{role: :tool},
             %Message{role: :assistant}
           ] = messages

    assert %ToolCall{name: "devices_list", metadata: %{"namespace" => "devices"}} = kept_call
  end

  test "a kept turn keeps its search items unchanged and in place" do
    messages = summarize(7)

    assert [%Message{role: :assistant, tool_calls: [%ToolCall{call_id: "call_1"}]} = searched] =
             Enum.filter(
               messages,
               &match?(%Message{content: [%ContentPart{type: :provider_item} | _rest]}, &1)
             )

    assert [
             %ContentPart{
               type: :provider_item,
               options: [provider: "openai", item: @search_call]
             },
             %ContentPart{
               type: :provider_item,
               options: [provider: "openai", item: @search_output]
             }
           ] = searched.content
  end
end
