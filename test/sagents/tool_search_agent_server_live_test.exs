defmodule Sagents.ToolSearchAgentServerLiveTest do
  @moduledoc """
  Provider tool search through a running `Sagents.AgentServer`, against the live
  APIs.

  Each run starts an agent with `Sagents.Middleware.ToolSearch` and two
  namespaced middleware (`devices` and `billing`), then:

  1. asks a question only a deferred device tool can answer, so the model
     searches, loads the namespace and calls the tool,
  2. exports the state, stops the server, and starts a new one from the
     exported state, as a host does across a restart,
  3. asks a follow-up that needs the same tool, which the restored
     conversation must still be able to call.

  The OpenAI runs go with the catalog on and off. A namespace's name and
  description are shown to the model by OpenAI itself, so the pair measures
  what the catalog adds there. Each run prints the searches it took and the
  input tokens it used.

  Run with:

      mix test test/sagents/tool_search_agent_server_live_test.exs --include live_open_ai --include live_anthropic
  """
  use ExUnit.Case, async: false

  alias LangChain.ChatModels.{ChatAnthropic, ChatOpenAIResponses, ChatReqLLM}
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.TokenUsage
  alias Sagents.{Agent, AgentServer, State, ToolSearch}
  alias Sagents.Middleware.ToolSearch, as: Switch
  alias Sagents.TestInventoryMiddleware

  @moduletag live_call: true
  @moduletag timeout: 600_000

  @system_prompt """
  You are an IT operations assistant. Always use a tool to answer questions
  about devices or billing; never guess or reuse an earlier answer. Reply in
  one short sentence.
  """

  setup do
    test_pid = self()
    handler = "tool-search-live-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sagents, :tool_search, :loaded],
      fn _event, %{count: count}, metadata, _config ->
        send(test_pid, {:searched, count, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp agent(agent_id, model, catalog?) do
    Agent.new!(
      %{
        agent_id: agent_id,
        model: model,
        base_system_prompt: @system_prompt,
        middleware: [
          {Switch, catalog: catalog?},
          {TestInventoryMiddleware, id: "devices_mw", domain: :devices, test_pid: self()},
          {TestInventoryMiddleware, id: "billing_mw", domain: :billing, test_pid: self()}
        ]
      },
      replace_default_middleware: true
    )
  end

  defp start(agent, state) do
    {:ok, _pid} = AgentServer.start_link(agent: agent, initial_state: state, pubsub: nil)
    {:ok, _server, _ref} = AgentServer.subscribe(agent.agent_id)
    :ok
  end

  defp restart(agent, exported) do
    {:ok, _pid} =
      AgentServer.start_link_from_state(exported,
        agent: agent,
        agent_id: agent.agent_id,
        pubsub: nil
      )

    {:ok, _server, _ref} = AgentServer.subscribe(agent.agent_id)
    :ok
  end

  defp stop(agent_id) do
    pid = GenServer.whereis(AgentServer.get_name(agent_id))
    ref = Process.monitor(pid)
    AgentServer.stop(agent_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000
  end

  # Sends a question and waits for the run it starts to end. Returns the state.
  # The server can report `:idle` before the run begins, so the wait starts
  # once the run is `:running`.
  defp ask(agent_id, question) do
    :ok = AgentServer.add_message(agent_id, Message.new_user!(question))
    await_status(:running)
    await_status(:idle)
    AgentServer.get_state(agent_id)
  end

  defp await_status(wanted) do
    receive do
      {:agent, {:status_changed, ^wanted, _data}} ->
        :ok

      {:agent, {:status_changed, :error, reason}} ->
        flunk("Run failed: #{inspect(reason)}")

      {:agent, {:status_changed, :interrupted, data}} ->
        flunk("Run interrupted: #{inspect(data)}")

      {:agent, _other} ->
        await_status(wanted)
    after
      180_000 -> flunk("The agent never reached #{inspect(wanted)}")
    end
  end

  defp last_text(%State{messages: messages}),
    do: messages |> List.last() |> Map.fetch!(:content) |> ContentPart.content_to_string()

  defp searches_received do
    receive do
      {:searched, count, _metadata} -> count + searches_received()
    after
      0 -> 0
    end
  end

  defp input_tokens(messages) do
    for %Message{role: :assistant} = message <- messages,
        %TokenUsage{input: input} <- [TokenUsage.get(message)],
        is_integer(input),
        reduce: 0,
        do: (total -> total + input)
  end

  defp run(label, model, catalog?) do
    agent_id = "tool-search-live-#{System.unique_integer([:positive])}"
    agent = agent(agent_id, model, catalog?)

    # Turn one: a question only a deferred device tool can answer.
    :ok = start(agent, State.new!(%{}))
    turn_one = ask(agent_id, "How many managed devices are at the hq site?")

    assert_received {:tool_ran, "devices_list", %{"site" => _site}}
    assert last_text(turn_one) =~ "17"

    loaded = ToolSearch.loaded(turn_one, agent.tools)
    assert "devices_list" in loaded.tools
    refute "billing_balance" in loaded.tools

    turn_one_searches = searches_received()
    turn_one_tokens = input_tokens(turn_one.messages)

    # Persist and restore, as a host does across a restart.
    exported = AgentServer.export_state(agent_id)
    stop(agent_id)
    :ok = restart(agent(agent_id, model, catalog?), exported)

    restored = AgentServer.get_state(agent_id)
    assert ToolSearch.loaded(restored, agent.tools) == loaded

    # Turn two: the same tool again, from the restored conversation.
    turn_two_start = length(restored.messages)
    turn_two = ask(agent_id, "And how many at the warehouse site?")

    assert_received {:tool_ran, "devices_list", %{"site" => _site}}
    assert last_text(turn_two) =~ "42"

    turn_two_searches = searches_received()
    turn_two_tokens = input_tokens(Enum.drop(turn_two.messages, turn_two_start))

    stop(agent_id)

    IO.puts("""

    [#{label}] catalog: #{catalog?}
      turn one: #{turn_one_searches} search result(s), #{turn_one_tokens} input tokens
      turn two: #{turn_two_searches} search result(s), #{turn_two_tokens} input tokens
      loaded: #{inspect(ToolSearch.loaded(turn_two, agent.tools))}
    """)
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
    test "catalog on", do: run("ChatOpenAIResponses", responses_model(), true)
    test "catalog off", do: run("ChatOpenAIResponses", responses_model(), false)
  end

  describe "ChatReqLLM openai:" do
    @describetag live_open_ai: true
    test "catalog on", do: run("ChatReqLLM openai:", req_llm_openai_model(), true)
    test "catalog off", do: run("ChatReqLLM openai:", req_llm_openai_model(), false)
  end

  describe "ChatAnthropic" do
    @describetag live_anthropic: true
    test "catalog on", do: run("ChatAnthropic", anthropic_model(), true)
  end
end
