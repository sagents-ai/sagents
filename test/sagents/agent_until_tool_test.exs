defmodule Sagents.AgentUntilToolTest do
  use Sagents.BaseCase, async: true
  use Mimic

  alias Sagents.{Agent, State}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult

  # A simple tool that returns a string result
  defp make_tool(name, result \\ nil) do
    result = result || "#{name}_result"

    LangChain.Function.new!(%{
      name: name,
      description: "Test tool: #{name}",
      function: fn _args, _context -> {:ok, result} end
    })
  end

  # A tool that returns processed_content (structured data)
  defp make_tool_with_processed(name) do
    LangChain.Function.new!(%{
      name: name,
      description: "Test tool: #{name}",
      function: fn _args, _context -> {:ok, "text_result", %{structured: true}} end
    })
  end

  defp make_agent(tools) do
    Agent.new!(
      %{
        model: mock_model(),
        tools: tools,
        middleware: []
      },
      replace_default_middleware: true
    )
  end

  defp initial_state do
    State.new!(%{messages: [Message.new_user!("Do the thing")]})
  end

  defp make_agent_with_hitl(tools, interrupt_on) do
    Agent.new!(
      %{
        model: mock_model(),
        tools: tools,
        middleware: [
          {Sagents.Middleware.HumanInTheLoop, [interrupt_on: interrupt_on]}
        ]
      },
      replace_default_middleware: true
    )
  end

  describe "execute/3 with until_tool option" do
    test "returns 3-tuple when target tool is called on first turn" do
      submit_tool = make_tool("submit")
      agent = make_agent([submit_tool])

      stub(ChatAnthropic, :call, fn _model, messages, _tools ->
        # Count non-system messages to determine turn
        user_and_assistant = Enum.reject(messages, &(&1.role == :system))

        case length(user_and_assistant) do
          # First call: user message only -> LLM calls "submit"
          1 ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_1",
                name: "submit",
                arguments: %{"data" => "result"},
                status: :complete
              })

            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}

          # Should not be reached
          _ ->
            {:ok, [Message.new_assistant!("Unexpected call")]}
        end
      end)

      assert {:ok, state, %ToolResult{name: "submit"} = tool_result} =
               Agent.execute(agent, initial_state(), until_tool: "submit")

      assert [%LangChain.Message.ContentPart{content: "submit_result"}] = tool_result.content
      assert %State{} = state
      # Messages: user, assistant (tool_call), tool (result)
      assert length(state.messages) == 3
    end

    test "multi-step: intermediate tools called before target tool" do
      search_tool = make_tool("search")
      submit_tool = make_tool("submit")
      agent = make_agent([search_tool, submit_tool])

      stub(ChatAnthropic, :call, fn _model, messages, _tools ->
        non_system = Enum.reject(messages, &(&1.role == :system))

        case length(non_system) do
          # Turn 1: user -> call "search"
          1 ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_search",
                name: "search",
                arguments: %{"q" => "info"},
                status: :complete
              })

            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}

          # Turn 2: user, assistant, tool_result -> call "submit"
          3 ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_submit",
                name: "submit",
                arguments: %{"data" => "found"},
                status: :complete
              })

            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}

          # Should not be reached
          _ ->
            {:ok, [Message.new_assistant!("Unexpected call")]}
        end
      end)

      assert {:ok, state, %ToolResult{name: "submit"}} =
               Agent.execute(agent, initial_state(), until_tool: "submit")

      # Messages: user, assistant(search), tool(search_result), assistant(submit), tool(submit_result)
      assert length(state.messages) == 5
    end

    test "max_runs exceeded returns error" do
      search_tool = make_tool("search")
      submit_tool = make_tool("submit")
      agent = make_agent([search_tool, submit_tool])

      # LLM always calls "search", never "submit"
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_#{:erlang.unique_integer([:positive])}",
            name: "search",
            arguments: %{"q" => "more"},
            status: :complete
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      assert {:error, msg} =
               Agent.execute(agent, initial_state(), until_tool: "submit", max_runs: 2)

      assert msg =~ "max_runs (2) exceeded"
    end

    test "LLM stops without calling target tool returns error" do
      submit_tool = make_tool("submit")
      agent = make_agent([submit_tool])

      # LLM returns plain text (no tool calls)
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("I'm done, no tools needed")]}
      end)

      assert {:error, msg} =
               Agent.execute(agent, initial_state(), until_tool: "submit")

      assert msg =~ "LLM completed without calling target tool"
    end

    test "unknown tool name in until_tool returns error" do
      agent = make_agent([make_tool("search")])

      assert {:error, msg} =
               Agent.execute(agent, initial_state(), until_tool: "nonexistent")

      assert msg =~ "until_tool references unknown tools"
      assert msg =~ "nonexistent"
    end

    test "list of tool names: matches on any" do
      tool_a = make_tool("tool_a")
      tool_b = make_tool("tool_b")
      agent = make_agent([tool_a, tool_b])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_b",
            name: "tool_b",
            arguments: %{},
            status: :complete
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      assert {:ok, _state, %ToolResult{name: "tool_b"}} =
               Agent.execute(agent, initial_state(), until_tool: ["tool_a", "tool_b"])
    end

    test "backward compat: no until_tool returns 2-tuple" do
      agent = make_agent([])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Simple response")]}
      end)

      assert {:ok, %State{}} = Agent.execute(agent, initial_state())
    end

    test "processed_content is preserved on tool_result" do
      submit_tool = make_tool_with_processed("submit")
      agent = make_agent([submit_tool])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_submit",
            name: "submit",
            arguments: %{},
            status: :complete
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      assert {:ok, _state, %ToolResult{} = tool_result} =
               Agent.execute(agent, initial_state(), until_tool: "submit")

      assert [%LangChain.Message.ContentPart{content: "text_result"}] = tool_result.content
      assert tool_result.processed_content == %{structured: true}
    end

    test "multiple tools in one turn: target among them stops loop" do
      helper_tool = make_tool("helper")
      submit_tool = make_tool("submit")
      agent = make_agent([helper_tool, submit_tool])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        # LLM calls both tools in the same turn
        tool_calls = [
          ToolCall.new!(%{
            call_id: "call_helper",
            name: "helper",
            arguments: %{},
            status: :complete
          }),
          ToolCall.new!(%{
            call_id: "call_submit",
            name: "submit",
            arguments: %{"answer" => "42"},
            status: :complete
          })
        ]

        {:ok, [Message.new_assistant!(%{tool_calls: tool_calls})]}
      end)

      assert {:ok, state, %ToolResult{name: "submit"}} =
               Agent.execute(agent, initial_state(), until_tool: "submit")

      # Messages: user, assistant(tool_calls), tool(both results)
      assert length(state.messages) == 3
    end
  end

  describe "execute/3 with until_tool + HITL" do
    test "HITL interrupt fires before target tool, resume completes" do
      # "dangerous" requires approval, "submit" is the target
      dangerous_tool = make_tool("dangerous")
      submit_tool = make_tool("submit")

      agent =
        make_agent_with_hitl(
          [dangerous_tool, submit_tool],
          %{"dangerous" => true}
        )

      stub(ChatAnthropic, :call, fn _model, messages, _tools ->
        non_system = Enum.reject(messages, &(&1.role == :system))

        case length(non_system) do
          # Turn 1: LLM calls "dangerous" (HITL tool)
          1 ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_dangerous",
                name: "dangerous",
                arguments: %{"action" => "go"},
                status: :complete
              })

            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}

          # Turn 2: after resume+tool execution, LLM calls "submit" (target)
          3 ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_submit",
                name: "submit",
                arguments: %{"data" => "done"},
                status: :complete
              })

            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}

          _ ->
            {:ok, [Message.new_assistant!("Unexpected")]}
        end
      end)

      # First execute hits HITL interrupt
      assert {:interrupt, interrupted_state, interrupt_data} =
               Agent.execute(agent, initial_state(), until_tool: "submit")

      assert length(interrupt_data.action_requests) == 1
      assert hd(interrupt_data.action_requests).tool_name == "dangerous"

      # Resume with approval, passing until_tool through
      decisions = [%{type: :approve}]

      assert {:ok, final_state, %ToolResult{name: "submit"}} =
               Agent.resume(agent, interrupted_state, decisions, until_tool: "submit")

      assert %State{} = final_state
    end
  end
end
