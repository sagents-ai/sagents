defmodule Sagents.AbilitySetsAgentServerTest do
  @moduledoc """
  A switch inside a run started by an AgentServer reaches subscribers as
  `{:agent, {:ability_set_changed, from, to}}`.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias LangChain.ChatModels.ChatOpenAICompatible
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias Sagents.{Agent, AgentServer, AgentSupervisor, State}
  alias Sagents.Middleware.AbilitySetSwitcher
  alias Sagents.TestAbilityMiddleware

  setup :set_mimic_global
  setup :verify_on_exit!

  test "publishes ability_set_changed when the model switches" do
    agent_id = generate_test_agent_id()

    agent =
      Agent.new!(
        %{
          agent_id: agent_id,
          model:
            ChatOpenAICompatible.new!(%{
              endpoint: "http://localhost/v1/chat/completions",
              model: "glm"
            }),
          middleware: [
            {AbilitySetSwitcher,
             sets: %{
               "devices" => %{
                 when_to_use: "Devices.",
                 middleware: [{TestAbilityMiddleware, id: "devices_mw", tools: ["list_devices"]}]
               }
             }}
          ]
        },
        replace_default_middleware: true
      )

    expect(ChatOpenAICompatible, :call, fn _model, _messages, _tools ->
      {:ok,
       [
         Message.new_assistant!(%{
           tool_calls: [
             ToolCall.new!(%{
               call_id: "s1",
               name: "switch_mode",
               arguments: %{"mode" => "devices"}
             })
           ]
         })
       ]}
    end)

    expect(ChatOpenAICompatible, :call, fn _model, _messages, tools ->
      assert "list_devices" in Enum.map(tools, & &1.name)
      {:ok, [Message.new_assistant!("Done")]}
    end)

    {:ok, _supervisor} =
      AgentSupervisor.start_link_sync(
        name: AgentSupervisor.get_name(agent_id),
        agent: agent,
        pubsub: {Phoenix.PubSub, :test_pubsub}
      )

    {:ok, _server, _ref} = AgentServer.subscribe(agent_id)

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Which devices are offline?"))

    assert_receive {:agent, {:ability_set_changed, nil, "devices"}}, 5_000
    assert_receive {:agent, {:status_changed, :idle, _data}}, 5_000

    assert %State{metadata: %{"active_ability_set" => "devices"}} =
             AgentServer.get_state(agent_id)

    AgentServer.stop(agent_id)
  end
end
