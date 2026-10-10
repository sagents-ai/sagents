defmodule Sagents.Middleware.HumanInTheLoopUnrunnableCallsTest do
  @moduledoc """
  HumanInTheLoop asks a human only about calls that would actually run.

  Each gated call is parsed by its own tool, with the context it would run
  with, before anyone is asked. A call its tool refuses is answered with the
  tool's message and never executed, not even if it would parse by the time the
  batch is resumed. Approved calls are parsed again when they run, and the body
  receives that run's result.
  """
  use Sagents.BaseCase, async: true
  use Mimic

  alias Sagents.Agent
  alias Sagents.AgentUtils
  alias Sagents.Middleware.HumanInTheLoop
  alias Sagents.Persistence.StateSerializer
  alias Sagents.State
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult

  setup :verify_on_exit!

  setup do
    ledger = :ets.new(:ledger, [:set, :public])
    :ets.insert(ledger, {"tx_1", %{id: "tx_1", category: "food"}})
    %{ledger: ledger}
  end

  # ── Fixtures ────────────────────────────────────────────────────

  # A gated write whose parser resolves the transaction from the ledger in the
  # tool context, refuses an id it cannot find, and hands the body the row it
  # found. The body reports what it was given.
  defp update_transaction_tool(name \\ "update_transaction") do
    Function.new!(%{
      name: name,
      parameters_schema: %{
        type: "object",
        properties: %{id: %{type: "string"}, category: %{type: "string"}},
        required: ["id", "category"]
      },
      parse_args: fn %{"id" => id} = args, %{ledger: ledger} ->
        case :ets.lookup(ledger, id) do
          [{^id, tx}] -> {:ok, %{transaction: tx, category: args["category"]}}
          [] -> {:error, "No transaction #{id} exists for this account."}
        end
      end,
      function: fn parsed, %{test_pid: test_pid} ->
        send(test_pid, {:body_ran, name, parsed})
        {:ok, "Updated #{parsed.transaction.id}."}
      end
    })
  end

  # A gated write with no parser, so only the required-key check applies.
  defp write_note_tool do
    Function.new!(%{
      name: "write_note",
      parameters_schema: %{
        type: "object",
        properties: %{path: %{type: "string"}, content: %{type: "string"}},
        required: ["path", "content"]
      },
      function: fn args, %{test_pid: test_pid} ->
        send(test_pid, {:body_ran, "write_note", args})
        {:ok, "Wrote #{args["path"]}."}
      end
    })
  end

  defp read_balance_tool do
    Function.new!(%{
      name: "read_balance",
      function: fn _args, %{test_pid: test_pid} ->
        send(test_pid, {:body_ran, "read_balance", %{}})
        {:ok, "Balance is $10."}
      end
    })
  end

  defp new_agent(ledger, interrupt_on, tools) do
    {:ok, agent} =
      Agent.new(
        %{
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6", stream: false}),
          tools: tools,
          tool_context: %{ledger: ledger, test_pid: self()},
          middleware: [{HumanInTheLoop, [interrupt_on: interrupt_on]}]
        },
        replace_default_middleware: true
      )

    agent
  end

  defp gated(tool_names),
    do: Map.new(tool_names, &{&1, %{allowed_decisions: [:approve, :reject]}})

  defp call(id, name, arguments),
    do: ToolCall.new!(%{call_id: id, name: name, arguments: arguments})

  # The model asks for `tool_calls` once, then answers in plain text.
  defp mock_model(tool_calls) do
    stub(ChatAnthropic, :call, fn _model, messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, [Message.new_assistant!(%{content: "Done."})]}
      else
        {:ok, [Message.new_assistant!(%{content: "Working on it.", tool_calls: tool_calls})]}
      end
    end)
  end

  defp start_state, do: State.new!(%{messages: [Message.new_user!("Fix my transactions")]})

  defp results_by_id(%State{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(& &1.tool_results)
    |> Map.new(&{&1.tool_call_id, &1})
  end

  defp text(%ToolResult{content: content}), do: ContentPart.parts_to_string(content)

  # ── No call needs a human ───────────────────────────────────────

  describe "when every gated call is refused by its tool" do
    test "no human is asked, and the model gets the tool's message in the same turn", %{
      ledger: ledger
    } do
      mock_model([call("c1", "update_transaction", %{"id" => "tx_404", "category" => "rent"})])
      agent = new_agent(ledger, gated(["update_transaction"]), [update_transaction_tool()])

      assert {:ok, state} = Agent.execute(agent, start_state())

      assert %{"c1" => %ToolResult{is_error: true} = result} = results_by_id(state)
      assert text(result) == "No transaction tx_404 exists for this account."
      assert %Message{role: :assistant} = List.last(state.messages)
      refute_received {:body_ran, _, _}
    end

    test "an ungated call in the same batch still runs", %{ledger: ledger} do
      mock_model([
        call("c1", "update_transaction", %{"id" => "tx_404", "category" => "rent"}),
        call("c2", "read_balance", %{})
      ])

      agent =
        new_agent(ledger, gated(["update_transaction"]), [
          update_transaction_tool(),
          read_balance_tool()
        ])

      assert {:ok, state} = Agent.execute(agent, start_state())

      assert %{"c1" => %ToolResult{is_error: true}, "c2" => %ToolResult{is_error: false} = ok} =
               results_by_id(state)

      assert text(ok) == "Balance is $10."
      assert_received {:body_ran, "read_balance", _}
      refute_received {:body_ran, "update_transaction", _}
    end

    test "a call missing a required argument is refused on a tool with no parser", %{
      ledger: ledger
    } do
      mock_model([call("c1", "write_note", %{"path" => "a.md"})])
      agent = new_agent(ledger, gated(["write_note"]), [write_note_tool()])

      assert {:ok, state} = Agent.execute(agent, start_state())

      assert %{"c1" => %ToolResult{is_error: true} = result} = results_by_id(state)
      assert text(result) =~ "Missing required parameters"
      refute_received {:body_ran, _, _}
    end

    test "a call to a gated tool the agent does not have is refused", %{ledger: ledger} do
      mock_model([call("c1", "delete_account", %{})])
      agent = new_agent(ledger, gated(["delete_account"]), [read_balance_tool()])

      assert {:ok, state} = Agent.execute(agent, start_state())

      assert %{"c1" => %ToolResult{is_error: true} = result} = results_by_id(state)
      assert text(result) == "Tool 'delete_account' not found"
    end
  end

  # ── Some calls need a human ─────────────────────────────────────

  describe "when a batch has a valid and a refused gated call" do
    setup %{ledger: ledger} do
      mock_model([
        call("good", "update_transaction", %{"id" => "tx_1", "category" => "rent"}),
        call("bad", "update_transaction", %{"id" => "tx_404", "category" => "rent"})
      ])

      agent = new_agent(ledger, gated(["update_transaction"]), [update_transaction_tool()])
      {:interrupt, state, interrupt_data} = Agent.execute(agent, start_state())

      %{agent: agent, state: state, interrupt_data: interrupt_data}
    end

    test "only the valid call is put to a human", %{interrupt_data: interrupt_data} do
      assert %{
               action_requests: [%{tool_call_id: "good"}],
               hitl_tool_call_ids: ["good"],
               pre_decided: %{
                 "bad" => %{
                   type: :reject,
                   is_error: true,
                   message: "No transaction tx_404 exists for this account."
                 }
               }
             } = interrupt_data

      refute_received {:body_ran, _, _}
    end

    test "the refused call's placeholder carries its refusal", %{state: state} do
      assert %{"good" => good, "bad" => bad} = results_by_id(state)
      assert text(good) == "Waiting for a human to review this tool call."
      assert text(bad) == "No transaction tx_404 exists for this account."
    end

    test "after approval, the refused call carries its refusal, not an approval", %{
      agent: agent,
      state: state
    } do
      assert {:ok, resumed} = Agent.resume(agent, state, [%{type: :approve}])

      assert %{"good" => %ToolResult{is_error: false}, "bad" => %ToolResult{is_error: true} = bad} =
               results_by_id(resumed)

      assert text(bad) == "No transaction tx_404 exists for this account."
      assert_received {:body_ran, "update_transaction", %{transaction: %{id: "tx_1"}}}
      refute_received {:body_ran, "update_transaction", %{transaction: %{id: "tx_404"}}}
    end

    test "the refused call stays refused even when it would now parse", %{
      agent: agent,
      state: state,
      ledger: ledger
    } do
      :ets.insert(ledger, {"tx_404", %{id: "tx_404", category: "misc"}})

      assert {:ok, resumed} = Agent.resume(agent, state, [%{type: :approve}])

      assert %{"bad" => %ToolResult{is_error: true}} = results_by_id(resumed)
      refute_received {:body_ran, "update_transaction", %{transaction: %{id: "tx_404"}}}
    end

    test "the refusal survives persisting and restoring the interrupt", %{
      agent: agent,
      state: state,
      ledger: ledger
    } do
      serialized = StateSerializer.serialize_state(state)
      {:ok, restored} = StateSerializer.deserialize_state(agent.agent_id, serialized)

      # A boot rebuilds the interrupt from the placeholders' payload.
      %Message{role: :tool, tool_results: [placeholder | _rest]} = List.last(restored.messages)
      assert placeholder.interrupt_data == state.interrupt_data
      restored = %{restored | interrupt_data: placeholder.interrupt_data}

      :ets.insert(ledger, {"tx_404", %{id: "tx_404", category: "misc"}})

      assert {:ok, resumed} = Agent.resume(agent, restored, [%{type: :approve}])
      assert %{"bad" => %ToolResult{is_error: true}} = results_by_id(resumed)
      refute_received {:body_ran, "update_transaction", %{transaction: %{id: "tx_404"}}}
    end
  end

  describe "an approved call" do
    setup %{ledger: ledger} do
      mock_model([call("c1", "update_transaction", %{"id" => "tx_1", "category" => "rent"})])
      agent = new_agent(ledger, gated(["update_transaction"]), [update_transaction_tool()])
      {:interrupt, state, _interrupt_data} = Agent.execute(agent, start_state())

      %{agent: agent, state: state}
    end

    test "is refused when its arguments no longer parse by the time it runs", %{
      agent: agent,
      state: state,
      ledger: ledger
    } do
      :ets.delete(ledger, "tx_1")

      assert {:ok, resumed} = Agent.resume(agent, state, [%{type: :approve}])

      assert %{"c1" => %ToolResult{is_error: true} = result} = results_by_id(resumed)
      assert text(result) == "No transaction tx_1 exists for this account."
      refute_received {:body_ran, _, _}
    end

    test "runs with the arguments parsed when it executes, not when it was asked", %{
      agent: agent,
      state: state,
      ledger: ledger
    } do
      :ets.insert(ledger, {"tx_1", %{id: "tx_1", category: "groceries"}})

      assert {:ok, _resumed} = Agent.resume(agent, state, [%{type: :approve}])

      assert_received {:body_ran, "update_transaction",
                       %{transaction: %{id: "tx_1", category: "groceries"}, category: "rent"}}
    end
  end

  # ── Recovery bookkeeping ───────────────────────────────────────

  describe "resume_checkpoint/3" do
    test "records a pre-decided call as rejected, not started", %{ledger: ledger} do
      mock_model([
        call("good", "update_transaction", %{"id" => "tx_1", "category" => "rent"}),
        call("bad", "remove_transaction", %{"id" => "tx_404", "category" => "x"})
      ])

      # The approved call may run again after a crash; the refused call's tool
      # may not. Were the refused call recorded as started, it would make the
      # whole batch unsafe to run again.
      interrupt_on = %{
        "update_transaction" => %{allowed_decisions: [:approve, :reject], recovery: :reexecute},
        "remove_transaction" => %{allowed_decisions: [:approve, :reject]}
      }

      agent =
        new_agent(ledger, interrupt_on, [
          update_transaction_tool(),
          update_transaction_tool("remove_transaction")
        ])

      {:interrupt, state, _interrupt_data} = Agent.execute(agent, start_state())

      assert {:ok, checkpoint} =
               HumanInTheLoop.resume_checkpoint(state, [%{type: :approve}], agent.middleware)

      %Message{tool_results: [%ToolResult{interrupt_data: %{in_flight: in_flight}} | _rest]} =
        List.last(checkpoint.messages)

      assert in_flight.outcomes == %{"good" => :started, "bad" => :rejected}
      assert in_flight.recovery == :reexecute
    end
  end

  describe "a sub-agent" do
    test "keeps a refused call refused on resume, even when it would now parse", %{
      ledger: ledger
    } do
      test_pid = self()

      tool =
        Function.new!(%{
          name: "update_transaction",
          parse_args: fn %{"id" => id}, _context ->
            case :ets.lookup(ledger, id) do
              [{^id, tx}] -> {:ok, %{transaction: tx}}
              [] -> {:error, "No transaction #{id} exists for this account."}
            end
          end,
          function: fn parsed, _context ->
            send(test_pid, {:body_ran, "update_transaction", parsed})
            {:ok, "Updated."}
          end
        })

      mock_model([
        call("good", "update_transaction", %{"id" => "tx_1"}),
        call("bad", "update_transaction", %{"id" => "tx_404"})
      ])

      {:ok, agent} =
        Agent.new(
          %{
            model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6", stream: false}),
            tools: [tool],
            middleware: [{HumanInTheLoop, [interrupt_on: gated(["update_transaction"])]}]
          },
          replace_default_middleware: true
        )

      subagent =
        Sagents.SubAgent.new_from_config(
          parent_agent_id: "parent",
          instructions: "Fix the transactions",
          agent_config: agent,
          parent_state: State.new!(%{messages: []})
        )

      assert {:interrupt, interrupted} = Sagents.SubAgent.execute(subagent)

      assert %{hitl_tool_call_ids: ["good"], pre_decided: %{"bad" => _rejection}} =
               interrupted.interrupt_data

      :ets.insert(ledger, {"tx_404", %{id: "tx_404", category: "misc"}})

      assert {:ok, completed} = Sagents.SubAgent.resume(interrupted, [%{type: :approve}])

      bad_result =
        completed.chain.messages
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.flat_map(& &1.tool_results)
        |> Enum.find(&(&1.tool_call_id == "bad"))

      assert %ToolResult{is_error: true} = bad_result
      assert_received {:body_ran, "update_transaction", %{transaction: %{id: "tx_1"}}}
      refute_received {:body_ran, "update_transaction", %{transaction: %{id: "tx_404"}}}
    end
  end

  describe "AgentUtils.build_full_decisions/5" do
    test "uses a pre-decided rejection ahead of auto-approval" do
      calls = [call("asked", "a", %{}), call("settled", "a", %{}), call("ungated", "b", %{})]
      rejection = %{type: :reject, message: "Cannot run.", is_error: true}

      assert [%{type: :approve, tool_call_id: "asked"}, ^rejection, %{type: :approve}] =
               AgentUtils.build_full_decisions(
                 calls,
                 ["asked"],
                 [%{type: :approve, tool_call_id: "asked"}],
                 [%{tool_call_id: "asked"}],
                 %{"settled" => rejection}
               )
    end
  end
end
