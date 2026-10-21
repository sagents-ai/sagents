defmodule Sagents.AbilitySetsExecutionTest do
  @moduledoc """
  An agent with ability sets builds each chain for the active set, and a
  `switch_mode` call continues the same `Agent.execute/3` on a chain built for
  the new set.
  """

  use Sagents.BaseCase, async: true
  use Mimic

  alias LangChain.ChatModels.ChatOpenAICompatible
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias Sagents.AbilitySets
  alias Sagents.Agent
  alias Sagents.Middleware.AbilitySetSwitcher
  alias Sagents.MiddlewareEntry
  alias Sagents.State
  alias Sagents.TestAbilityMiddleware

  setup :verify_on_exit!

  @rail_tools ["whoami", "ask_human", "approve_me", "switch_mode"]

  defp model do
    ChatOpenAICompatible.new!(%{endpoint: "http://localhost/v1/chat/completions", model: "glm"})
  end

  defp mw(id, tools, prompt, extra \\ []) do
    {TestAbilityMiddleware, [id: id, tools: tools, prompt: prompt, test_pid: self()] ++ extra}
  end

  defp new_agent!(opts \\ []) do
    sets = %{
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

    hitl =
      case Keyword.get(opts, :interrupt_on) do
        nil -> []
        interrupt_on -> [{Sagents.Middleware.HumanInTheLoop, interrupt_on: interrupt_on}]
      end

    Agent.new!(
      %{
        agent_id:
          Keyword.get(opts, :agent_id, "ability-sets-#{System.unique_integer([:positive])}"),
        model: model(),
        base_system_prompt: "You are the IT operations assistant.",
        max_runs: Keyword.get(opts, :max_runs),
        middleware:
          [
            mw("rail_mw", ["whoami", "ask_human", "approve_me"], "Rail fragment.",
              interrupting_tools: ["ask_human"]
            ),
            {AbilitySetSwitcher, [sets: sets] ++ Keyword.get(opts, :switcher, [])},
            mw("trailing_mw", [], "Trailing fragment.")
          ] ++ hitl
      },
      replace_default_middleware: true
    )
  end

  defp state(metadata \\ %{}) do
    State.new!(%{messages: [Message.new_user!("Help me.")], metadata: metadata})
  end

  # Each response is returned by one model call, in order. Every call reports
  # the messages and tool names it was given.
  defp expect_responses(responses) do
    test_pid = self()

    for response <- responses do
      expect(ChatOpenAICompatible, :call, fn _model, messages, tools ->
        send(test_pid, {:llm_call, messages, Enum.map(tools, & &1.name)})
        {:ok, [response]}
      end)
    end
  end

  defp tool_calls_message(specs) do
    Message.new_assistant!(%{
      tool_calls:
        Enum.map(specs, fn {id, name, args} ->
          ToolCall.new!(%{call_id: id, name: name, arguments: args})
        end)
    })
  end

  defp switch_call(id, mode), do: {id, "switch_mode", %{"mode" => mode}}

  defp received_llm_calls(acc \\ []) do
    receive do
      {:llm_call, messages, tools} -> received_llm_calls([{messages, tools} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp received(tag, acc \\ []) do
    receive do
      {^tag, id} -> received(tag, [id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp system_text([%Message{role: :system} = system | _rest]),
    do: ContentPart.content_to_string(system.content)

  defp tool_results(messages) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(& &1.tool_results)
  end

  defp result_text(%ToolResult{content: content}), do: ContentPart.content_to_string(content)

  defp has_reasoning?(%Message{content: parts}) when is_list(parts),
    do: Enum.any?(parts, &ContentPart.reasoning?/1)

  defp has_reasoning?(%Message{}), do: false

  describe "chain build from the active set" do
    test "sends only the rails plus the active set's tools and prompt" do
      expect_responses([Message.new_assistant!("Done")])
      agent = new_agent!()

      assert {:ok, _state} = Agent.execute(agent, state(%{"active_ability_set" => "billing"}))

      assert [{messages, tools}] = received_llm_calls()
      assert tools == @rail_tools ++ ["list_invoices"]

      prompt = system_text(messages)
      assert prompt =~ "Billing fragment."
      assert prompt =~ "Current mode: billing."
      refute prompt =~ "Devices fragment."
    end

    test "a new conversation carries the rails only" do
      expect_responses([Message.new_assistant!("Done")])

      assert {:ok, _state} = Agent.execute(new_agent!(), state())

      assert [{messages, @rail_tools}] = received_llm_calls()
      assert system_text(messages) =~ "Current mode: none."
    end

    test "before_model and after_model run only for active entries" do
      expect_responses([Message.new_assistant!("Done")])

      assert {:ok, _state} =
               Agent.execute(new_agent!(), state(%{"active_ability_set" => "billing"}))

      assert received(:before_model) == ["rail_mw", "billing_mw", "trailing_mw"]
      assert received(:after_model) == ["trailing_mw", "billing_mw", "rail_mw"]
    end

    test "a dynamic sub-agent inherits the effective middleware, without the switcher" do
      agent = new_agent!()

      {:ok, chain} =
        Agent.build_chain(agent, [], state(%{"active_ability_set" => "billing"}), [])

      assert Enum.map(chain.custom_context.parent_middleware, & &1.id) ==
               ["rail_mw", "billing_mw", "trailing_mw"]

      assert Enum.map(chain.custom_context.parent_tools, & &1.name) ==
               @rail_tools ++ ["list_invoices"]
    end

    test "records the active set on the chain and its spans" do
      {:ok, chain} =
        Agent.build_chain(new_agent!(), [], state(%{"active_ability_set" => "billing"}), [])

      assert %{active: "billing", switches: 0} = chain.custom_context.ability_sets
      assert chain.custom_context.otel_attributes["sagents.ability_set"] == "billing"
    end

    test "an agent without a switcher has no ability set context" do
      {:ok, agent} = Agent.new(%{model: model()}, replace_default_middleware: true)
      {:ok, chain} = Agent.build_chain(agent, [], state(), [])

      refute Map.has_key?(chain.custom_context, :ability_sets)
      refute Map.has_key?(chain.custom_context.otel_attributes, "sagents.ability_set")
    end
  end

  describe "switching within one execute" do
    setup do
      agent = new_agent!()
      handler_id = "ability-set-switch-#{agent.agent_id}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:sagents, :ability_sets, :switched],
        fn _event, measurements, metadata, _config ->
          if metadata.agent_id == agent.agent_id,
            do: send(test_pid, {:switched, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{agent: agent}
    end

    test "the next LLM call carries the new set's tools and prompt", %{agent: agent} do
      switch_with_thinking =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("This needs device tools.")],
          tool_calls: [
            ToolCall.new!(%{
              call_id: "s1",
              name: "switch_mode",
              arguments: %{"mode" => "devices"}
            })
          ]
        })

      expect_responses([
        switch_with_thinking,
        tool_calls_message([{"c1", "list_devices", %{}}]),
        Message.new_assistant!("Two devices are offline.")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert [{first_messages, first_tools}, {second_messages, second_tools}, _third] =
               received_llm_calls()

      # The first chain carried the rails; the second, the devices set.
      assert first_tools == @rail_tools
      assert second_tools == @rail_tools ++ ["list_devices", "deploy_package"]
      assert system_text(second_messages) =~ "Devices fragment."
      assert system_text(second_messages) =~ "Current mode: devices."

      # The second chain holds the first chain's messages plus the switch call,
      # with its reasoning stripped, and the switch result.
      [_system | first_history] = first_messages
      [_system | second_history] = second_messages

      assert [user, %Message{role: :assistant, content: []} = switch, %Message{role: :tool}] =
               second_history

      assert [user] == first_history
      assert [%ToolCall{name: "switch_mode"}] = switch.tool_calls

      # The tool from the new set ran, and the state records the set.
      assert_received {:tool_ran, "list_devices", _context}
      assert final_state.metadata["active_ability_set"] == "devices"

      refute Enum.any?(final_state.messages, &has_reasoning?/1)

      assert_received {:switched, %{count: 1},
                       %{from: nil, to: "devices", mid_run: true, agent_id: agent_id}}

      assert agent_id == agent.agent_id
    end

    test "model hooks run once per entry, and after_model for the final set", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, _state} = Agent.execute(agent, state())

      assert received(:before_model) ==
               ["rail_mw", "trailing_mw", "devices_mw", "deployments_mw"]

      assert received(:after_model) ==
               ["trailing_mw", "deployments_mw", "devices_mw", "rail_mw"]
    end

    test "the max_runs budget spans both chains" do
      agent = new_agent!(max_runs: 2)

      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        tool_calls_message([{"c1", "list_devices", %{}}])
      ])

      assert {:error, %LangChainError{type: "exceeded_max_runs"}} =
               Agent.execute(agent, state())

      assert [_first, _second] = received_llm_calls()
    end

    test "an interrupt in the same batch ends the call and records the switch", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), {"c1", "ask_human", %{}}])
      ])

      assert {:interrupt, interrupted_state, %{type: :test_interrupt}} =
               Agent.execute(agent, state())

      assert interrupted_state.metadata["active_ability_set"] == "devices"
      assert [_only_call] = received_llm_calls()
      assert_received {:switched, %{count: 1}, %{from: nil, to: "devices"}}
      refute_received {:switched, _measurements, _metadata}
    end

    test "reasoning from before a switch is dropped even when the call ends without a rebuild",
         %{agent: agent} do
      expect_responses([
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("Switch, then ask.")],
          tool_calls: [
            ToolCall.new!(%{
              call_id: "s1",
              name: "switch_mode",
              arguments: %{"mode" => "devices"}
            }),
            ToolCall.new!(%{call_id: "c1", name: "ask_human", arguments: %{}})
          ]
        })
      ])

      assert {:interrupt, interrupted_state, _data} = Agent.execute(agent, state())
      refute Enum.any?(interrupted_state.messages, &has_reasoning?/1)
    end

    test "reasoning produced after the switch is kept", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!([ContentPart.thinking!("Devices now."), ContentPart.text!("Done")])
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())
      assert %Message{} = last = List.last(final_state.messages)
      assert has_reasoning?(last)
    end

    test "reasoning is kept when nothing switches", %{agent: agent} do
      expect_responses([
        tool_calls_message([{"c1", "whoami", %{}}]),
        Message.new_assistant!([ContentPart.thinking!("Answering."), ContentPart.text!("Done")])
      ])

      thinking_call =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("Earlier.")],
          tool_calls: [ToolCall.new!(%{call_id: "c0", name: "whoami", arguments: %{}})]
        })

      earlier =
        State.new!(%{
          messages: [
            Message.new_user!("Who am I?"),
            thinking_call,
            Message.new_tool_result!(%{
              tool_results: [ToolResult.new!(%{tool_call_id: "c0", name: "whoami", content: "x"})]
            }),
            Message.new_user!("Again.")
          ]
        })

      assert {:ok, final_state} = Agent.execute(agent, earlier)
      assert [_user, kept | _rest] = final_state.messages
      assert has_reasoning?(kept)
    end

    test "an until_tool hit in the same batch ends the call and records the switch", %{
      agent: agent
    } do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), {"c1", "whoami", %{}}])
      ])

      assert {:ok, final_state, %ToolResult{name: "whoami"}} =
               Agent.execute(agent, state(), until_tool: "whoami")

      assert final_state.metadata["active_ability_set"] == "devices"
      assert [_only_call] = received_llm_calls()
      assert_received {:switched, %{count: 1}, %{from: nil, to: "devices"}}
      refute_received {:switched, _measurements, _metadata}
    end

    test "the switch result lists the tools the switch makes available", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert [%ToolResult{name: "switch_mode"} = result] = tool_results(final_state.messages)

      assert ContentPart.content_to_string(result.content) ==
               "Switched to the Devices mode. Tools now available: deploy_package, list_devices."
    end

    test "a batched call to the new set's tool gets a hint, and the retry succeeds", %{
      agent: agent
    } do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), {"c1", "list_devices", %{}}]),
        tool_calls_message([{"c2", "list_devices", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert [_first, {second_messages, _tools}, _third] = received_llm_calls()

      assert %ToolResult{is_error: true} =
               hint = Enum.find(tool_results(second_messages), &(&1.tool_call_id == "c1"))

      assert result_text(hint) ==
               ~s(list_devices is in the Devices mode. Call switch_mode with "devices" first, then retry.)

      assert %ToolResult{is_error: false} =
               Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "c2"))

      # Only the retry ran the tool.
      assert_received {:tool_ran, "list_devices", _context}
      refute_received {:tool_ran, "list_devices", _context}
    end

    test "a call to a tool in no set keeps the generic error", %{agent: agent} do
      expect_responses([
        tool_calls_message([{"c1", "made_up_tool", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert %ToolResult{is_error: true} =
               result = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "c1"))

      assert result_text(result) =~ "tool not found"
    end

    test "a second switch in one execute is refused", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        tool_calls_message([switch_call("s2", "billing")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert [_first, _second, {_messages, third_tools}] = received_llm_calls()
      assert "list_devices" in third_tools
      refute "list_invoices" in third_tools

      assert %ToolResult{is_error: true} =
               refused = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "s2"))

      assert result_text(refused) =~ "Mode already switched in this turn."
      assert final_state.metadata["active_ability_set"] == "devices"
    end

    test "the switch limit resets with each execute", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done"),
        tool_calls_message([switch_call("s2", "billing")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, %State{} = first_state} = Agent.execute(agent, state())

      next_state = %State{
        first_state
        | messages: first_state.messages ++ [Message.new_user!("Now invoices.")]
      }

      assert {:ok, second_state} = Agent.execute(agent, next_state)
      assert second_state.metadata["active_ability_set"] == "billing"
    end

    test "switching to the current mode is refused", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} =
               Agent.execute(agent, state(%{"active_ability_set" => "devices"}))

      assert %ToolResult{is_error: true} =
               refused = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "s1"))

      assert result_text(refused) == "Already in the Devices mode."
      assert [_first, _second] = received_llm_calls()
    end

    test "resume after a switch builds from the new set" do
      agent = new_agent!(interrupt_on: %{"approve_me" => true})

      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), {"c1", "approve_me", %{}}])
      ])

      assert {:interrupt, interrupted_state, %{action_requests: [%{tool_name: "approve_me"}]}} =
               Agent.execute(agent, state())

      assert [{_messages, @rail_tools}] = received_llm_calls()

      expect_responses([Message.new_assistant!("Done")])

      assert {:ok, final_state} = Agent.resume(agent, interrupted_state, [%{type: :approve}])

      assert [{messages, tools}] = received_llm_calls()
      assert tools == @rail_tools ++ ["list_devices", "deploy_package"]
      assert system_text(messages) =~ "Current mode: devices."
      assert final_state.metadata["active_ability_set"] == "devices"
      assert_received {:tool_ran, "approve_me", _context}
    end

    test "the switch tool reads the switch count the chain carries", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        tool_calls_message([{"c1", "whoami", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, _state} = Agent.execute(agent, state())

      assert_received {:tool_ran, "whoami", %{ability_sets: %{active: "devices", switches: 1}}}
    end
  end

  describe "on_switch" do
    defp on_switch_agent!(on_switch, opts \\ []) do
      new_agent!(Keyword.merge([switcher: [on_switch: on_switch]], opts))
    end

    defp report_to(test_pid), do: fn info -> send(test_pid, {:on_switch, info}) end

    test "runs once for a switch that continues on a new chain" do
      agent = on_switch_agent!(report_to(self()))

      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, _state} = Agent.execute(agent, state())

      assert_received {:on_switch, info}
      assert info == %{agent_id: agent.agent_id, from: nil, to: "devices", mid_run: true}
      refute_received {:on_switch, _info}
    end

    test "accepts a {module, function, args} tuple, called with the info first" do
      agent = on_switch_agent!({__MODULE__, :report_switch, [self()]})

      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, _state} = Agent.execute(agent, state())
      assert_received {:on_switch, %{to: "devices"}}
    end

    test "runs for a switch in the same batch as an interrupt" do
      agent = on_switch_agent!(report_to(self()))

      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), {"c1", "ask_human", %{}}])
      ])

      assert {:interrupt, _state, _data} = Agent.execute(agent, state())
      assert_received {:on_switch, %{from: nil, to: "devices"}}
      refute_received {:on_switch, _info}
    end

    test "runs when a switch held by an interrupt takes effect on resume" do
      agent = on_switch_agent!(report_to(self()), interrupt_on: %{"approve_me" => true})

      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), {"c1", "approve_me", %{}}])
      ])

      assert {:interrupt, interrupted_state, _data} = Agent.execute(agent, state())
      refute_received {:on_switch, _info}

      expect_responses([Message.new_assistant!("Done")])

      assert {:ok, _state} = Agent.resume(agent, interrupted_state, [%{type: :approve}])
      assert_received {:on_switch, %{from: nil, to: "devices"}}
      refute_received {:on_switch, _info}
    end

    test "a failing callback is logged and the run completes" do
      agent = on_switch_agent!(fn _info -> raise "announcement failed" end)

      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done")
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, final_state} = Agent.execute(agent, state())
          assert final_state.metadata["active_ability_set"] == "devices"
        end)

      assert log =~ "announcement failed"
    end
  end

  def report_switch(info, test_pid), do: send(test_pid, {:on_switch, info})

  describe "an entry in two sets" do
    test "does not run before_model again when the call switches into another of its sets" do
      shared = mw("shared_mw", ["lookup_customer"], "Shared fragment.")

      sets = %{
        "devices" => %{when_to_use: "Devices.", middleware: [shared, mw("devices_mw", [], "")]},
        "billing" => %{when_to_use: "Billing.", middleware: [shared]}
      }

      agent =
        Agent.new!(%{model: model(), middleware: [{AbilitySetSwitcher, sets: sets}]},
          replace_default_middleware: true
        )

      assert [%MiddlewareEntry{id: "shared_mw", ability_sets: ["billing", "devices"]}] =
               Enum.filter(agent.middleware, &(&1.id == "shared_mw"))

      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} =
               Agent.execute(agent, state(%{"active_ability_set" => "billing"}))

      assert received(:before_model) == ["shared_mw", "devices_mw"]
      assert AbilitySets.active(agent, final_state) == "devices"
    end
  end
end
