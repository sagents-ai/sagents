defmodule Sagents.SubAgentUntilToolResultTest do
  @moduledoc """
  End-to-end coverage for result extraction on an `until_tool` termination.

  These tests deliberately drive the real mode pipeline with a scripted model
  rather than stubbing `LLMChain.run/2`. An `until_tool` run terminates the
  instant the target tool's result lands, so the chain's `last_message` is a
  *tool* message — never the assistant message that a stubbed chain returns.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias Sagents.Agent
  alias Sagents.SubAgent
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  setup :verify_on_exit!

  defp test_model do
    ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"})
  end

  defp submit_tool(fun) do
    Function.new!(%{
      name: "submit_report",
      description: "Submit the final report",
      parameters_schema: %{
        type: "object",
        properties: %{"summary" => %{type: "string"}}
      },
      function: fun
    })
  end

  defp build_subagent(tool, until_opts) do
    agent =
      Agent.new!(
        %{
          model: test_model(),
          base_system_prompt: "Confined agent",
          tools: [tool],
          middleware: []
        },
        replace_default_middleware: true
      )

    SubAgent.new_from_config(
      [
        parent_agent_id: "parent-1",
        instructions: "produce a report",
        agent_config: agent
      ] ++ until_opts
    )
  end

  # Scripts the model to emit a single call to the until-tool.
  defp script_submit_call(args) do
    ChatAnthropic
    |> expect(:call, fn _model, _messages, _tools ->
      {:ok,
       Message.new_assistant!(%{
         tool_calls: [
           ToolCall.new!(%{call_id: "call_1", name: "submit_report", arguments: args})
         ]
       })}
    end)
  end

  describe "extract_result/1 on an until_tool termination" do
    test "returns the matched tool's result rather than failing on the tool message" do
      payload = ~s({"summary":"widget X is safe"})

      subagent =
        build_subagent(submit_tool(fn _args, _ctx -> {:ok, payload} end),
          until_tool: "submit_report"
        )

      script_submit_call(%{"summary" => "widget X is safe"})

      assert {:ok, %SubAgent{status: :completed} = completed, _extra} = SubAgent.execute(subagent)

      # The run genuinely ended on the tool message, which is what makes
      # ChainResult.to_string/1 the wrong extractor here.
      assert %Message{role: :tool} = completed.chain.last_message

      assert {:ok, ^payload} = SubAgent.extract_result(completed)
    end

    test "surfaces a failing until-tool result as an error" do
      subagent =
        build_subagent(submit_tool(fn _args, _ctx -> {:error, "schema violation"} end),
          until_tool: "submit_report"
        )

      script_submit_call(%{"summary" => "bad"})

      assert {:ok, %SubAgent{status: :completed} = completed, _extra} = SubAgent.execute(subagent)

      assert {:error, reason} = SubAgent.extract_result(completed)
      assert reason =~ "schema violation"
    end

    test "extracts the result of an until_tool_success termination" do
      payload = ~s({"summary":"validated"})

      subagent =
        build_subagent(submit_tool(fn _args, _ctx -> {:ok, payload} end),
          until_tool: "submit_report",
          require_tool_success: true
        )

      script_submit_call(%{"summary" => "validated"})

      assert {:ok, %SubAgent{status: :completed} = completed, _extra} = SubAgent.execute(subagent)
      assert {:ok, ^payload} = SubAgent.extract_result(completed)
    end

    test "still reads assistant prose when no until_tool is configured" do
      subagent = build_subagent(submit_tool(fn _args, _ctx -> {:ok, "unused"} end), [])

      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, Message.new_assistant!(%{content: "all done"})}
      end)

      assert {:ok, %SubAgent{status: :completed} = completed} = SubAgent.execute(subagent)
      assert {:ok, "all done"} = SubAgent.extract_result(completed)
    end
  end
end
