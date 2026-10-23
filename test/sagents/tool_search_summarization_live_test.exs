defmodule Sagents.ToolSearchSummarizationLiveTest do
  @moduledoc """
  Whether a provider accepts a history holding a call to a deferred tool
  without the search that loaded it. Summarization produces that history: a
  later turn can call a loaded tool directly, and the turn whose search loaded
  it can be summarized away.

  Each chat model runs two tests:

  - **Natural.** Two live turns, then real summarization keeping only the
    second, then a third turn. Whether the second turn searched again is the
    model's choice, so it is printed; when it did, this test does not reach the
    case in question.
  - **Constructed.** One live turn, then the same history with the search
    items taken out of the assistant message, then a second turn. This reaches
    the case every run.

  On OpenAI the replayed call carries its `namespace`. On Anthropic it is a
  `tool_use` for a deferred tool with no `tool_search_tool_result` before it.

  Run with:

      mix test test/sagents/tool_search_summarization_live_test.exs --include live_open_ai --include live_anthropic
  """
  use ExUnit.Case, async: false

  alias LangChain.ChatModels.{ChatAnthropic, ChatOpenAIResponses, ChatReqLLM}
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.{ContentPart, ToolCall}
  alias Sagents.{Agent, State}
  alias Sagents.Middleware.{Summarization, ToolSearch}

  @moduletag live_call: true
  @moduletag timeout: 600_000

  @counts %{"hq" => "17", "warehouse" => "42"}

  defp device_tools do
    namespace = [
      defer_loading: true,
      namespace: "devices",
      namespace_description: "List, inspect, and restart the managed devices at a site."
    ]

    [
      Function.new!(%{
        name: "devices_list",
        description: "List the managed devices at a site, with the device count.",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{"site" => %{"type" => "string", "description" => "hq or warehouse"}},
          "required" => ["site"]
        },
        options: namespace,
        function: fn %{"site" => site}, _context ->
          {:ok,
           "Site #{site} has #{Map.get(@counts, String.downcase(site), "0")} managed devices."}
        end
      }),
      Function.new!(%{
        name: "devices_restart",
        description: "Restart a managed device by its id.",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"]
        },
        options: namespace,
        function: fn _args, _context -> {:ok, "Restarted."} end
      })
    ]
  end

  defp agent(model) do
    Agent.new!(
      %{
        model: model,
        base_system_prompt: """
        You are an IT operations assistant. Always use a tool to answer questions
        about devices; never guess or reuse an earlier answer. Reply in one short sentence.
        """,
        tools: device_tools(),
        middleware: [ToolSearch]
      },
      replace_default_middleware: true
    )
  end

  defp ask(agent, %State{} = state, question) do
    state = State.add_message(state, Message.new_user!(question))

    case Agent.execute(agent, state) do
      {:ok, state} -> state
      other -> flunk("Run failed: #{inspect(other, limit: :infinity)}")
    end
  end

  defp last_text(%State{messages: messages}),
    do: messages |> List.last() |> Map.fetch!(:content) |> ContentPart.content_to_string()

  defp provider_item_types(messages) do
    for %Message{content: parts} when is_list(parts) <- messages,
        %ContentPart{type: :provider_item} = part <- parts,
        do: Keyword.fetch!(part.options, :item)["type"]
  end

  defp calls(messages) do
    for %Message{tool_calls: calls} when is_list(calls) <- messages,
        %ToolCall{} = call <- calls,
        do: call
  end

  defp strip_provider_items(messages) do
    Enum.map(messages, fn
      %Message{content: parts} = message when is_list(parts) ->
        %Message{message | content: Enum.reject(parts, &(&1.type == :provider_item))}

      message ->
        message
    end)
  end

  defp natural(model) do
    agent = agent(model)
    turn_one = ask(agent, State.new!(%{}), "How many managed devices are at the hq site?")
    turn_two_start = length(turn_one.messages)
    turn_two = ask(agent, turn_one, "And how many at the warehouse site?")

    turn_two_messages = Enum.drop(turn_two.messages, turn_two_start)

    IO.puts("""

    [#{inspect(model.__struct__)}] natural run
      turn one search items: #{inspect(provider_item_types(turn_one.messages))}
      turn two search items: #{inspect(provider_item_types(turn_two_messages))}
      turn two calls: #{inspect(Enum.map(calls(turn_two_messages), &{&1.name, &1.metadata}))}
    """)

    {:ok, config} =
      Summarization.init(
        model: model,
        max_tokens_before_summary: 1,
        token_counter: fn _messages -> 2 end,
        messages_to_keep: length(turn_two_messages)
      )

    {:ok, summarized} = Summarization.before_model(turn_two, config)

    IO.puts(
      "  search items after summarizing: #{inspect(provider_item_types(summarized.messages))}"
    )

    turn_three = ask(agent, summarized, "Check the hq site once more.")
    assert last_text(turn_three) =~ "17"
  end

  defp constructed(model) do
    agent = agent(model)
    turn_one = ask(agent, State.new!(%{}), "How many managed devices are at the hq site?")

    assert [_first | _rest] = provider_item_types(turn_one.messages),
           "turn one did not search, so the constructed history would not test anything"

    stripped = %{turn_one | messages: strip_provider_items(turn_one.messages)}

    IO.puts("""

    [#{inspect(model.__struct__)}] constructed run
      calls kept without their search: #{inspect(Enum.map(calls(stripped.messages), &{&1.name, &1.metadata}))}
    """)

    turn_two = ask(agent, stripped, "And how many at the warehouse site?")
    assert last_text(turn_two) =~ "42"
  end

  defp responses_model,
    do:
      ChatOpenAIResponses.new!(%{
        model: "gpt-5.4",
        store: false,
        include: ["reasoning.encrypted_content"],
        receive_timeout: 120_000
      })

  defp req_llm_openai_model,
    do:
      ChatReqLLM.new!(%{
        model: "openai:gpt-5.4",
        receive_timeout: 120_000,
        provider_opts: %{provider_options: [store: false]}
      })

  defp anthropic_model,
    do:
      ChatAnthropic.new!(%{
        model: "claude-sonnet-5-5",
        max_tokens: 4_000,
        receive_timeout: 120_000
      })

  describe "ChatOpenAIResponses" do
    @describetag live_open_ai: true
    test "natural", do: natural(responses_model())
    test "constructed", do: constructed(responses_model())
  end

  describe "ChatReqLLM openai:" do
    @describetag live_open_ai: true
    test "natural", do: natural(req_llm_openai_model())
    test "constructed", do: constructed(req_llm_openai_model())
  end

  describe "ChatAnthropic" do
    @describetag live_anthropic: true
    test "natural", do: natural(anthropic_model())
    test "constructed", do: constructed(anthropic_model())
  end
end
