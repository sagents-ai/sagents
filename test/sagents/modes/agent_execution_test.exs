defmodule Sagents.Modes.AgentExecutionTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sagents.Modes.AgentExecution
  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias LangChain.LangChainError
  alias LangChain.Function
  alias Sagents.MiddlewareEntry
  alias Sagents.Middleware.HumanInTheLoop
  alias LangChain.Message.ContentPart
  alias LangChain.MessageExpansion

  setup :verify_on_exit!

  # ── Helpers ──────────────────────────────────────────────────────

  defp mock_model do
    ChatAnthropic.new!(%{
      model: "claude-sonnet-4-6",
      api_key: "test_key"
    })
  end

  defp build_chain(tools, messages) do
    chain =
      LLMChain.new!(%{
        llm: mock_model(),
        tools: tools
      })

    Enum.reduce(messages, chain, fn msg, acc ->
      LLMChain.add_message(acc, msg)
    end)
  end

  defp submit_tool do
    Function.new!(%{
      name: "submit_report",
      description: "Submit a report",
      parameters_schema: %{
        type: "object",
        properties: %{"title" => %{type: "string"}}
      },
      function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
    })
  end

  defp stateful_submit_tool do
    Function.new!(%{
      name: "submit_report",
      description: "Submit a report",
      parameters_schema: %{
        type: "object",
        properties: %{"title" => %{type: "string"}}
      },
      function: fn args, _ctx ->
        {:ok, Jason.encode!(args), Sagents.State.new!(%{metadata: %{approved: true}})}
      end
    })
  end

  defp other_tool do
    Function.new!(%{
      name: "search",
      description: "Search for information",
      parameters_schema: %{
        type: "object",
        properties: %{"query" => %{type: "string"}}
      },
      function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
    })
  end

  defp finalize_tool do
    Function.new!(%{
      name: "finalize",
      description: "Finalize the work",
      parameters_schema: %{
        type: "object",
        properties: %{"status" => %{type: "string"}}
      },
      function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
    })
  end

  # Submit tool whose body validates business rules: only "good" titles
  # succeed; anything else returns {:error, ...} (an error ToolResult).
  defp validating_submit_tool do
    Function.new!(%{
      name: "submit_report",
      description: "Submit a report",
      parameters_schema: %{
        type: "object",
        properties: %{"title" => %{type: "string"}}
      },
      function: fn
        %{"title" => "good"} = args, _ctx -> {:ok, Jason.encode!(args)}
        _args, _ctx -> {:error, "title must be 'good'"}
      end
    })
  end

  defp assistant_with_tool_call(tool_name, args, call_id \\ "call_1") do
    tool_call =
      ToolCall.new!(%{
        status: :complete,
        call_id: call_id,
        name: tool_name,
        arguments: args
      })

    Message.new_assistant!(%{tool_calls: [tool_call]})
  end

  defp plain_assistant_message(content) do
    Message.new_assistant!(%{content: content})
  end

  # ── Test: Standard execution (no until_tool) ─────────────────────

  describe "standard execution (no until_tool)" do
    test "mode runs normally and returns {:ok, chain} when LLM stops" do
      tools = [submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Hello")])

      # First call: LLM returns a tool call
      # Second call: LLM returns a plain assistant message (loop ends)
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "Test"})]}
      end)
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [plain_assistant_message("All done.")]}
      end)

      result = AgentExecution.run(chain, [])

      assert {:ok, %LLMChain{}} = result
    end
  end

  # ── Test: until_tool target tool called ──────────────────────────

  describe "until_tool: target tool called" do
    test "returns {:ok, chain, tool_result} when target tool is called" do
      tools = [submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Write a report")])

      # LLM calls the target tool
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "My Report"})]}
      end)

      result = AgentExecution.run(chain, until_tool: "submit_report")

      assert {:ok, %LLMChain{}, %ToolResult{name: "submit_report"}} = result
    end
  end

  # ── Test: until_tool LLM stops without calling target ────────────

  describe "until_tool: LLM stops without calling target" do
    test "returns error when LLM finishes without calling the target tool" do
      tools = [submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Hello")])

      # LLM returns a plain assistant message (no tool calls)
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [plain_assistant_message("I'm done talking.")]}
      end)

      result = AgentExecution.run(chain, until_tool: "submit_report")

      assert {:error, %LLMChain{}, %LangChainError{type: "until_tool_not_called"} = error} =
               result

      assert error.message =~ "submit_report"
    end
  end

  # ── Test: until_tool with multiple targets ───────────────────────

  describe "until_tool: multiple target tools" do
    test "matches any of the target tools" do
      tools = [submit_tool(), finalize_tool()]
      chain = build_chain(tools, [Message.new_user!("Complete the task")])

      # LLM calls "finalize" which is one of the targets
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("finalize", %{"status" => "complete"})]}
      end)

      result = AgentExecution.run(chain, until_tool: ["submit_report", "finalize"])

      assert {:ok, %LLMChain{}, %ToolResult{name: "finalize"}} = result
    end
  end

  # ── Test: target tool called after multiple iterations ───────────

  describe "until_tool: target called after multiple iterations" do
    test "LLM calls other tools first, then target tool" do
      tools = [other_tool(), submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Research and report")])

      # Iteration 1: LLM calls "search" (not the target)
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("search", %{"query" => "test"}, "call_1")]}
      end)
      # Iteration 2: LLM needs to respond after search results, calls target
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "Found it"}, "call_2")]}
      end)

      result = AgentExecution.run(chain, until_tool: "submit_report")

      assert {:ok, %LLMChain{}, %ToolResult{name: "submit_report"}} = result
    end
  end

  # ── Test: HITL interrupt works with until_tool ───────────────────

  describe "HITL interrupt works with until_tool" do
    test "interrupt short-circuits and returns {:interrupt, chain, data}" do
      tools = [submit_tool()]

      chain =
        build_chain(tools, [Message.new_user!("Write a report")])
        |> LLMChain.update_custom_context(%{
          state: Sagents.State.new!(%{agent_id: "test-hitl-agent"})
        })

      # LLM calls submit_report, but HITL will intercept before tool execution
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "Report"})]}
      end)

      hitl_config = %{
        interrupt_on: %{
          "submit_report" => %{
            allowed_decisions: [:approve, :reject]
          }
        }
      }

      middleware = [
        %MiddlewareEntry{module: HumanInTheLoop, config: hitl_config}
      ]

      result =
        AgentExecution.run(chain,
          until_tool: "submit_report",
          middleware: middleware
        )

      assert {:interrupt, %LLMChain{}, interrupt_data} = result
      assert is_map(interrupt_data)
      assert Map.has_key?(interrupt_data, :action_requests)
    end

    test "approval executes a target tool returned on the final allowed call" do
      tools = [stateful_submit_tool()]

      chain =
        build_chain(tools, [Message.new_user!("Write a report")])
        |> LLMChain.update_custom_context(%{
          state: Sagents.State.new!(%{agent_id: "test-hitl-agent"})
        })

      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "Report"})]}
      end)

      middleware = [
        %MiddlewareEntry{
          module: HumanInTheLoop,
          config: %{
            interrupt_on: %{
              "submit_report" => %{allowed_decisions: [:approve, :reject]}
            }
          }
        }
      ]

      opts = [until_tool: "submit_report", middleware: middleware, max_runs: 1]

      assert {:interrupt, interrupted_chain, _interrupt_data} =
               AgentExecution.run(chain, opts)

      tool_calls = interrupted_chain.last_message.tool_calls

      resumed_chain =
        LLMChain.execute_tool_calls_with_decisions(
          interrupted_chain,
          tool_calls,
          [%{type: :approve}]
        )

      assert {:ok, final_chain, %ToolResult{name: "submit_report", is_error: false}} =
               AgentExecution.run(resumed_chain, opts)

      assert final_chain.custom_context.state.metadata.approved
    end
  end

  # ── Test: max_runs exceeded with until_tool active ───────────────

  describe "until_tool: max_runs exceeded" do
    test "executes a successful target tool returned on the final allowed call" do
      tools = [other_tool(), submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Research and report")])

      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("search", %{query: "test"}, "call_1")]}
      end)
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{title: "done"}, "call_2")]}
      end)

      result = AgentExecution.run(chain, until_tool: "submit_report", max_runs: 2)

      assert {:ok, %LLMChain{}, %ToolResult{name: "submit_report", is_error: false}} = result
    end

    test "max_runs exceeded with until_tool active returns error" do
      tools = [other_tool(), submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Research and report")])

      # LLM always calls "search" and never calls "submit_report"
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            status: :complete,
            call_id: "call_#{System.unique_integer([:positive])}",
            name: "search",
            arguments: %{"query" => "test"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      result = AgentExecution.run(chain, until_tool: "submit_report", max_runs: 3)

      assert {:error, %LLMChain{}, %LangChainError{type: "exceeded_max_runs"} = error} = result
      assert error.message =~ "Exceeded maximum number of runs (3/3)"
    end
  end

  describe "require_tool_success: true (retry on error)" do
    test "retries on an error result and terminates on the later success" do
      tools = [validating_submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Write a report")])

      # Iteration 1: bad args -> tool returns {:error, ...} -> loop continues
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "bad"}, "call_1")]}
      end)
      # Iteration 2: corrected args -> success -> terminate
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "good"}, "call_2")]}
      end)

      result =
        AgentExecution.run(chain, until_tool: "submit_report", require_tool_success: true)

      assert {:ok, %LLMChain{}, %ToolResult{name: "submit_report", is_error: false}} = result
    end

    test "exhausts max_runs when the target tool always errors" do
      tools = [validating_submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Write a report")])

      # LLM always submits bad args -> always an error result -> never terminates
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "bad"}, "call_x")]}
      end)

      result =
        AgentExecution.run(chain,
          until_tool: "submit_report",
          require_tool_success: true,
          max_runs: 3
        )

      assert {:error, %LLMChain{}, %LangChainError{type: "exceeded_max_runs"}} = result
    end
  end

  describe "until_tool: target name (stop on call)" do
    test "terminates on the first call even when the result is an error" do
      tools = [validating_submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Write a report")])

      # A single bad call. Call-based until_tool terminates on the error result.
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "bad"}, "call_1")]}
      end)

      result = AgentExecution.run(chain, until_tool: "submit_report")

      assert {:ok, %LLMChain{}, %ToolResult{name: "submit_report", is_error: true}} = result
    end
  end

  # ── Test: normalize_until_tool_opts ──────────────────────────────

  describe "normalize_until_tool_opts (tested through run/2)" do
    test "string is converted to list and active flag" do
      tools = [submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Report")])

      # LLM calls the target tool (verifies normalization happened)
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("submit_report", %{"title" => "Test"})]}
      end)

      result = AgentExecution.run(chain, until_tool: "submit_report")

      assert {:ok, %LLMChain{}, %ToolResult{name: "submit_report"}} = result
    end

    test "list is preserved and active flag is set" do
      tools = [submit_tool(), finalize_tool()]
      chain = build_chain(tools, [Message.new_user!("Finalize")])

      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("finalize", %{"status" => "done"})]}
      end)

      result = AgentExecution.run(chain, until_tool: ["submit_report", "finalize"])

      assert {:ok, %LLMChain{}, %ToolResult{name: "finalize"}} = result
    end

    test "nil until_tool means no until_tool behavior" do
      tools = [submit_tool()]
      chain = build_chain(tools, [Message.new_user!("Hello")])

      # LLM returns a plain message (no tool calls), should complete normally
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [plain_assistant_message("Just chatting.")]}
      end)

      result = AgentExecution.run(chain, [])

      assert {:ok, %LLMChain{}} = result
    end
  end

  # ── Test: Tool results that expand into messages ─────────────────

  describe "tool results that expand into messages" do
    @material "POLICY SECTION 4: refunds are issued within 30 days."

    defp loading_tool do
      Function.new!(%{
        name: "load_reference",
        description: "Load the reference material",
        parameters_schema: %{type: "object", properties: %{}},
        function: fn _args, _ctx ->
          MessageExpansion.expand(
            "Loaded 1 document.\n\n" <> @material,
            [
              Message.new_assistant!(@material),
              Message.new_user!("Answer using the policy above.")
            ],
            result_content: "Loaded 1 document."
          )
        end
      })
    end

    defp text_of(%Message{content: content}) when is_list(content) do
      content
      |> Enum.filter(&match?(%ContentPart{type: :text}, &1))
      |> Enum.map_join(" ", & &1.content)
    end

    defp text_of(%Message{content: content}) when is_binary(content), do: content
    defp text_of(%Message{}), do: ""

    test "the material is in the conversation for the next LLM call, in the same run" do
      chain = build_chain([loading_tool(), other_tool()], [Message.new_user!("Policy?")])
      test_pid = self()

      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("load_reference", %{})]}
      end)
      # The model keeps working rather than stopping. This is the turn where a
      # run-boundary delivery leaves the model with nothing.
      |> expect(:call, fn _model, messages, _tools ->
        send(test_pid, {:turn_2, messages})
        {:ok, [assistant_with_tool_call("search", %{"query" => "refunds"}, "call_2")]}
      end)
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [plain_assistant_message("30 days.")]}
      end)

      assert {:ok, %LLMChain{}} = AgentExecution.run(chain, [])

      assert_received {:turn_2, turn_2}

      assert Enum.any?(turn_2, fn message ->
               message.role == :assistant and text_of(message) =~ @material
             end)

      assert %Message{role: :user} = List.last(turn_2)
      assert text_of(List.last(turn_2)) =~ "Answer using the policy above."
    end

    test "the bulky payload leaves the tool result once expanded" do
      chain = build_chain([loading_tool()], [Message.new_user!("Policy?")])
      test_pid = self()

      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("load_reference", %{})]}
      end)
      |> expect(:call, fn _model, messages, _tools ->
        send(test_pid, {:turn_2, messages})
        {:ok, [plain_assistant_message("30 days.")]}
      end)

      assert {:ok, %LLMChain{}} = AgentExecution.run(chain, [])

      assert_received {:turn_2, turn_2}
      tool_message = Enum.find(turn_2, &(&1.role == :tool))

      assert [%ToolResult{content: [%ContentPart{content: "Loaded 1 document."}]}] =
               tool_message.tool_results

      assert 1 = Enum.count(turn_2, &(text_of(&1) =~ @material))
    end

    test "expands a result produced outside the pipeline, as a resume does" do
      # The shape `HumanInTheLoop` hands back: the approved tool already ran, so
      # the chain is rebuilt from stored messages and `exchanged_messages` is
      # empty. Nothing in the loop produced this tool message.
      {:ok, staged} =
        MessageExpansion.expand(
          "Loaded 1 document.\n\n" <> @material,
          [
            Message.new_assistant!(@material),
            Message.new_user!("Answer using the policy above.")
          ],
          result_content: "Loaded 1 document."
        )

      result = %ToolResult{staged | tool_call_id: "call_1", name: "load_reference"}

      chain =
        build_chain([loading_tool()], [
          Message.new_user!("Policy?"),
          assistant_with_tool_call("load_reference", %{}),
          Message.new_tool_result!(%{content: nil, tool_results: [result]})
        ])

      test_pid = self()

      expect(ChatAnthropic, :call, fn _model, messages, _tools ->
        send(test_pid, {:first_call, messages})
        {:ok, [plain_assistant_message("30 days.")]}
      end)

      assert {:ok, %LLMChain{}} = AgentExecution.run(chain, [])

      assert_received {:first_call, messages}

      assert Enum.any?(messages, fn message ->
               message.role == :assistant and text_of(message) =~ @material
             end)
    end

    test "a satisfied until_tool contract ends the run with nothing expanded" do
      chain = build_chain([loading_tool()], [Message.new_user!("Policy?")])

      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [assistant_with_tool_call("load_reference", %{})]}
      end)

      assert {:ok, final_chain, %ToolResult{name: "load_reference"}} =
               AgentExecution.run(chain, until_tool: "load_reference")

      assert %Message{role: :tool} = final_chain.last_message
      refute Enum.any?(final_chain.messages, &(text_of(&1) =~ @material))
    end

    test "an interrupted turn ends with nothing expanded" do
      interrupting_tool =
        Function.new!(%{
          name: "gated",
          description: "Needs approval",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:interrupt, "Needs approval", %{type: :halt}} end
        })

      chain =
        build_chain([loading_tool(), interrupting_tool], [Message.new_user!("Policy?")])

      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        calls = [
          ToolCall.new!(%{
            status: :complete,
            call_id: "call_1",
            name: "load_reference",
            arguments: %{}
          }),
          ToolCall.new!(%{status: :complete, call_id: "call_2", name: "gated", arguments: %{}})
        ]

        {:ok, [Message.new_assistant!(%{tool_calls: calls})]}
      end)

      assert {:interrupt, interrupted_chain, _data} = AgentExecution.run(chain, [])

      assert %Message{role: :tool} = interrupted_chain.last_message
      refute Enum.any?(interrupted_chain.messages, &(text_of(&1) =~ @material))

      # Fail-open: the material is still readable, in the untrimmed result.
      assert Enum.any?(interrupted_chain.last_message.tool_results, fn result ->
               match?([%ContentPart{content: text}] when is_binary(text), result.content) and
                 hd(result.content).content =~ @material
             end)
    end
  end
end
