defmodule Sagents.SubAgentUntilToolTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Sagents.SubAgent
  alias Sagents.Agent
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult

  defp test_model do
    ChatAnthropic.new!(%{
      model: "claude-3-5-sonnet-20241022",
      api_key: "test_key"
    })
  end

  defp make_tool(name, result \\ nil) do
    result = result || "#{name}_result"

    LangChain.Function.new!(%{
      name: name,
      description: "Test tool: #{name}",
      function: fn _args, _context -> {:ok, result} end
    })
  end

  defp make_agent(tools) do
    Agent.new!(
      %{
        model: test_model(),
        tools: tools,
        middleware: []
      },
      replace_default_middleware: true
    )
  end

  defp make_subagent(tools) do
    agent_config = make_agent(tools)

    SubAgent.new_from_config(
      parent_agent_id: "test-parent",
      instructions: "Do the thing",
      agent_config: agent_config,
      parent_state: %{messages: []}
    )
  end

  describe "execute/2 with struct-based until_tool (no opts)" do
    test "uses until_tool_names from struct when no opts provided" do
      submit_tool = make_tool("submit")

      # Create subagent with until_tool set via new_from_config
      agent_config = make_agent([submit_tool])

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "test-parent",
          instructions: "Do the thing",
          agent_config: agent_config,
          parent_state: %{messages: []},
          until_tool: "submit"
        )

      assert subagent.until_tool_names == ["submit"]

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_1",
            name: "submit",
            arguments: %{"data" => "result"},
            status: :complete
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      # Execute WITHOUT passing until_tool opt — should use struct fields
      assert {:ok, %SubAgent{status: :completed}, %ToolResult{name: "submit"}} =
               SubAgent.execute(subagent)
    end

    test "opts override struct-based until_tool" do
      submit_tool = make_tool("submit")
      other_tool = make_tool("other")

      agent_config = make_agent([submit_tool, other_tool])

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "test-parent",
          instructions: "Do the thing",
          agent_config: agent_config,
          parent_state: %{messages: []},
          until_tool: "submit"
        )

      assert subagent.until_tool_names == ["submit"]

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_1",
            name: "other",
            arguments: %{},
            status: :complete
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      # Execute with different until_tool opt — should override struct
      assert {:ok, %SubAgent{status: :completed}, %ToolResult{name: "other"}} =
               SubAgent.execute(subagent, until_tool: "other")
    end

    test "struct-based max_runs is used when no opts provided" do
      search_tool = make_tool("search")
      submit_tool = make_tool("submit")

      agent_config = make_agent([search_tool, submit_tool])

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "test-parent",
          instructions: "Do the thing",
          agent_config: agent_config,
          parent_state: %{messages: []},
          until_tool: "submit",
          until_tool_max_runs: 2
        )

      assert subagent.until_tool_max_runs == 2

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

      # Should hit struct's max_runs of 2
      assert {:error, %SubAgent{status: :error} = error_subagent} = SubAgent.execute(subagent)
      assert error_subagent.error =~ "max_runs (2) exceeded"
    end
  end

  describe "execute/2 with until_tool option" do
    test "returns 3-tuple when target tool is called" do
      submit_tool = make_tool("submit")
      subagent = make_subagent([submit_tool])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_1",
            name: "submit",
            arguments: %{"data" => "result"},
            status: :complete
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      assert {:ok, %SubAgent{status: :completed}, %ToolResult{name: "submit"} = tool_result} =
               SubAgent.execute(subagent, until_tool: "submit")

      assert [%LangChain.Message.ContentPart{content: "submit_result"}] = tool_result.content
    end

    test "unknown tool name returns error" do
      subagent = make_subagent([make_tool("search")])

      assert {:error, %SubAgent{status: :error} = error_subagent} =
               SubAgent.execute(subagent, until_tool: "nonexistent")

      assert error_subagent.error =~ "until_tool references unknown tools"
    end

    test "max_runs exceeded returns error" do
      search_tool = make_tool("search")
      submit_tool = make_tool("submit")
      subagent = make_subagent([search_tool, submit_tool])

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

      assert {:error, %SubAgent{status: :error} = error_subagent} =
               SubAgent.execute(subagent, until_tool: "submit", max_runs: 2)

      assert error_subagent.error =~ "max_runs (2) exceeded"
    end

    test "backward compat: no until_tool returns 2-tuple" do
      subagent = make_subagent([])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Done")]}
      end)

      assert {:ok, %SubAgent{status: :completed}} = SubAgent.execute(subagent)
    end

    test "LLM stops without calling target tool returns error" do
      submit_tool = make_tool("submit")
      subagent = make_subagent([submit_tool])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("I'm done")]}
      end)

      assert {:error, %SubAgent{status: :error} = error_subagent} =
               SubAgent.execute(subagent, until_tool: "submit")

      assert error_subagent.error =~ "LLM completed without calling target tool"
    end

    test "multi-step: intermediate tools before target" do
      search_tool = make_tool("search")
      submit_tool = make_tool("submit")
      subagent = make_subagent([search_tool, submit_tool])

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
            {:ok, [Message.new_assistant!("Unexpected")]}
        end
      end)

      assert {:ok, %SubAgent{status: :completed}, %ToolResult{name: "submit"}} =
               SubAgent.execute(subagent, until_tool: "submit")
    end

    test "list of tool names: matches on any" do
      tool_a = make_tool("tool_a")
      tool_b = make_tool("tool_b")
      subagent = make_subagent([tool_a, tool_b])

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

      assert {:ok, %SubAgent{status: :completed}, %ToolResult{name: "tool_b"}} =
               SubAgent.execute(subagent, until_tool: ["tool_a", "tool_b"])
    end

    test "stores until_tool_names on struct for resume" do
      submit_tool = make_tool("submit")
      subagent = make_subagent([submit_tool])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_1",
            name: "submit",
            arguments: %{},
            status: :complete
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      {:ok, completed_subagent, _tool_result} =
        SubAgent.execute(subagent, until_tool: "submit")

      assert completed_subagent.until_tool_names == ["submit"]
      assert completed_subagent.until_tool_max_runs == 25
    end
  end
end
