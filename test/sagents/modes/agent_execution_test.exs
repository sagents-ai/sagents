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
  alias LangChain.Function, as: LFunction
  alias Sagents.MiddlewareEntry
  alias Sagents.Middleware.HumanInTheLoop

  setup :verify_on_exit!

  # ── Helpers ──────────────────────────────────────────────────────

  defp mock_model do
    ChatAnthropic.new!(%{
      model: "claude-3-5-sonnet-20241022",
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
    LFunction.new!(%{
      name: "submit_report",
      description: "Submit a report",
      parameters_schema: %{
        type: "object",
        properties: %{"title" => %{type: "string"}}
      },
      function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
    })
  end

  defp other_tool do
    LFunction.new!(%{
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
    LFunction.new!(%{
      name: "finalize",
      description: "Finalize the work",
      parameters_schema: %{
        type: "object",
        properties: %{"status" => %{type: "string"}}
      },
      function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
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
  end

  # ── Test: max_runs exceeded with until_tool active ───────────────

  describe "until_tool: max_runs exceeded" do
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
      assert error.message =~ "Exceeded maximum number of runs"
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
end
