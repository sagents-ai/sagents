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

    # Extra rail tools, each returning its State delta with its result, or the
    # result its function builds from the tool context.
    rail_deltas = Keyword.get(opts, :rail_deltas, %{})
    rail_results = Keyword.get(opts, :rail_results, %{})

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
            mw(
              "rail_mw",
              ["whoami", "ask_human", "approve_me"] ++
                Map.keys(rail_deltas) ++ Map.keys(rail_results),
              "Rail fragment.",
              interrupting_tools: ["ask_human"],
              deltas: rail_deltas,
              results: rail_results
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

      assert %{active: "billing"} = chain.custom_context.ability_sets
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

    test "the switch result names the mode and no tools", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert [%ToolResult{name: "switch_mode"} = result] = tool_results(final_state.messages)

      assert ContentPart.content_to_string(result.content) ==
               "Switched to the Devices mode. Your tools now match this mode; use the tool definitions you have."
    end

    test "a batched call to the switched-to set's tool is told to retry, and the retry succeeds",
         %{
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
               "list_devices is in the Devices mode. The switch to Devices applies; retry on your next step."

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

    test "the model switches as often as the run needs", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        tool_calls_message([{"c1", "list_devices", %{}}]),
        tool_calls_message([switch_call("s2", "billing")]),
        tool_calls_message([{"c2", "list_invoices", %{}}]),
        tool_calls_message([switch_call("s3", "devices")]),
        tool_calls_message([{"c3", "deploy_package", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      tools_per_call = Enum.map(received_llm_calls(), fn {_messages, tools} -> tools end)
      assert length(tools_per_call) == 7

      for {tools, tool} <-
            Enum.zip(Enum.drop(tools_per_call, 1), [
              "list_devices",
              "list_devices",
              "list_invoices",
              "list_invoices",
              "deploy_package",
              "deploy_package"
            ]) do
        assert tool in tools
      end

      assert_received {:tool_ran, "list_devices", _context}
      assert_received {:tool_ran, "list_invoices", _context}
      assert_received {:tool_ran, "deploy_package", _context}

      refute Enum.any?(tool_results(final_state.messages), & &1.is_error)
      assert final_state.metadata["active_ability_set"] == "devices"
      assert_received {:switched, _, %{from: nil, to: "devices"}}
      assert_received {:switched, _, %{from: "devices", to: "billing"}}
      assert_received {:switched, _, %{from: "billing", to: "devices"}}
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

    test "a tool reads the active set the chain carries", %{agent: agent} do
      expect_responses([
        tool_calls_message([switch_call("s1", "devices")]),
        tool_calls_message([{"c1", "whoami", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, _state} = Agent.execute(agent, state())

      assert_received {:tool_ran, "whoami", %{ability_sets: %{active: "devices"}}}
    end
  end

  describe "one switch per tool batch" do
    setup do
      test_pid = self()

      on_switch = fn info -> send(test_pid, {:on_switch, info}) end
      %{on_switch: on_switch}
    end

    test "only the first of two switches applies, and the second is told so", %{
      on_switch: on_switch
    } do
      agent = new_agent!(switcher: [on_switch: on_switch])

      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), switch_call("s2", "billing")]),
        tool_calls_message([{"c1", "list_devices", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert [_first, {_messages, second_tools}, {_messages3, third_tools}] =
               received_llm_calls()

      for tools <- [second_tools, third_tools] do
        assert "list_devices" in tools
        refute "list_invoices" in tools
      end

      results = tool_results(final_state.messages)
      assert %ToolResult{is_error: false} = Enum.find(results, &(&1.tool_call_id == "s1"))

      assert %ToolResult{is_error: true} =
               second = Enum.find(results, &(&1.tool_call_id == "s2"))

      assert result_text(second) ==
               "Only one mode switch per step. The switch to Devices applies; its tools arrive on your next step."

      assert %ToolResult{is_error: false} = Enum.find(results, &(&1.tool_call_id == "c1"))
      assert final_state.metadata["active_ability_set"] == "devices"
      assert_received {:on_switch, %{from: nil, to: "devices"}}
      refute_received {:on_switch, _info}
    end

    test "a later switch back to the starting set is refused, not told it is already there" do
      agent = new_agent!()

      expect_responses([
        tool_calls_message([switch_call("s1", "billing"), switch_call("s2", "devices")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} =
               Agent.execute(agent, state(%{"active_ability_set" => "devices"}))

      second = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "s2"))
      assert second.is_error
      assert result_text(second) =~ "Only one mode switch per step. The switch to Billing applies"
      assert final_state.metadata["active_ability_set"] == "billing"
    end

    test "a later unknown mode keeps its own error" do
      agent = new_agent!()

      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), switch_call("s2", "tickets")]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      second = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "s2"))
      assert result_text(second) =~ "Unknown mode"
    end

    test "another tool's later switch is dropped, and the rest of its delta lands" do
      todo = Sagents.Todo.new!(%{id: 1, content: "Check invoices"})

      agent =
        new_agent!(
          rail_deltas: %{
            "open_billing" =>
              State.delta(%{todos: [todo], metadata: %{"active_ability_set" => "billing"}})
          }
        )

      expect_responses([
        tool_calls_message([switch_call("s1", "devices"), {"c1", "open_billing", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert final_state.metadata["active_ability_set"] == "devices"
      assert [%{content: "Check invoices"}] = final_state.todos

      opened = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "c1"))
      refute opened.is_error
      assert result_text(opened) == "open_billing result"
    end

    test "after approval, the batch settles the same way" do
      agent = new_agent!(interrupt_on: %{"approve_me" => true})

      expect_responses([
        tool_calls_message([
          switch_call("s1", "devices"),
          switch_call("s2", "billing"),
          {"c1", "approve_me", %{}}
        ])
      ])

      assert {:interrupt, interrupted_state, _data} = Agent.execute(agent, state())
      assert [_first] = received_llm_calls()

      expect_responses([Message.new_assistant!("Done")])

      assert {:ok, final_state} = Agent.resume(agent, interrupted_state, [%{type: :approve}])

      assert [{_messages, tools}] = received_llm_calls()
      assert "list_devices" in tools
      assert final_state.metadata["active_ability_set"] == "devices"

      second = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "s2"))
      assert second.is_error
      assert result_text(second) =~ "Only one mode switch per step"
    end
  end

  describe "switching from another tool" do
    setup do
      test_pid = self()
      handler_id = "ability-set-request-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:sagents, :ability_sets, :switched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:switched, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      %{on_switch: fn info -> send(test_pid, {:on_switch, info}) end}
    end

    defp open_devices(context) do
      {:ok, switch} = AbilitySetSwitcher.request_mode_switch(context, "devices")
      {:ok, "Devices command activated.", switch}
    end

    test "a tool's requested switch gets everything a switch_mode call gets", %{
      on_switch: on_switch
    } do
      agent =
        new_agent!(
          rail_results: %{"open_devices" => &open_devices/1},
          switcher: [on_switch: on_switch]
        )

      with_thinking =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("The devices command needs device tools.")],
          tool_calls: [ToolCall.new!(%{call_id: "c1", name: "open_devices", arguments: %{}})]
        })

      expect_responses([with_thinking, Message.new_assistant!("Done")])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert [_first, {messages, tools}] = received_llm_calls()
      assert "list_devices" in tools
      assert "deploy_package" in tools
      assert system_text(messages) =~ "Current mode: devices."
      assert system_text(messages) =~ "Devices fragment."

      refute Enum.any?(messages, fn message ->
               is_list(message.content) and Enum.any?(message.content, &(&1.type == :thinking))
             end)

      assert_received {:before_model, "devices_mw"}
      assert final_state.metadata["active_ability_set"] == "devices"

      opened = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "c1"))
      assert result_text(opened) == "Devices command activated."

      assert_received {:on_switch, %{from: nil, to: "devices"}}
      refute_received {:on_switch, _info}
      assert_received {:switched, %{count: 1}, %{from: nil, to: "devices"}}
      refute_received {:switched, _measurements, _metadata}
    end

    test "the tool's message expansion arrives on the first call after the switch" do
      material = "Device fleet: 12 gateways, 3 offline."

      load_devices = fn context ->
        {:ok, switch} = AbilitySetSwitcher.request_mode_switch(context, "devices")

        {:ok, result} =
          LangChain.MessageExpansion.expand(
            "Loaded the fleet.\n\n" <> material,
            [Message.new_user!(material)],
            result_content: "Loaded the fleet."
          )

        {:ok, %ToolResult{result | processed_content: switch}}
      end

      agent = new_agent!(rail_results: %{"load_devices" => load_devices})

      expect_responses([
        tool_calls_message([{"c1", "load_devices", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())

      assert [_first, {messages, tools}] = received_llm_calls()
      assert "list_devices" in tools

      assert Enum.any?(messages, fn message ->
               message.role == :user and
                 ContentPart.content_to_string(message.content) == material
             end)

      assert final_state.metadata["active_ability_set"] == "devices"
    end

    test "a switch_mode call earlier in the batch wins over it" do
      agent = new_agent!(rail_results: %{"open_devices" => &open_devices/1})

      expect_responses([
        tool_calls_message([switch_call("s1", "billing"), {"c1", "open_devices", %{}}]),
        Message.new_assistant!("Done")
      ])

      assert {:ok, final_state} = Agent.execute(agent, state())
      assert final_state.metadata["active_ability_set"] == "billing"

      opened = Enum.find(tool_results(final_state.messages), &(&1.tool_call_id == "c1"))
      refute opened.is_error
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
