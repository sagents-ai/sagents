defmodule Sagents.ToolSearchUserlandTest do
  @moduledoc """
  An app can use provider tool search with no framework support: a middleware
  marks its tools deferred and namespaced, and the search tool is passed in
  `tools:`. Both reach the chat model unchanged, in order, and the rest of the
  agent treats the search tool as an ordinary named tool.
  """
  use Sagents.BaseCase, async: true
  use Mimic

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.NativeTool
  alias Sagents.{Agent, State}

  defp agent(test_pid, extra_middleware \\ []) do
    {:ok, agent} =
      Agent.new(
        %{
          model: mock_model(),
          tools: [NativeTool.tool_search()],
          middleware:
            [
              {Sagents.TestDeferredToolsMiddleware,
               namespace: "devices",
               description: "Find and restart managed devices.",
               tools: ["devices_list", "devices_restart"],
               test_pid: test_pid}
            ] ++ extra_middleware
        },
        replace_default_middleware: true
      )

    agent
  end

  defp capture_tools(test_pid) do
    stub(ChatAnthropic, :call, fn _model, _messages, tools ->
      send(test_pid, {:tools, tools})
      {:ok, [Message.new_assistant!("Done.")]}
    end)
  end

  test "the search tool and the deferred, namespaced functions reach the chat model in order" do
    test_pid = self()
    capture_tools(test_pid)

    state = State.new!(%{messages: [Message.new_user!("List the devices")]})
    assert {:ok, _state} = Agent.execute(agent(test_pid), state)

    assert_received {:tools, tools}

    assert [
             %NativeTool{name: "tool_search"},
             %Function{name: "devices_list"} = list,
             %Function{name: "devices_restart"} = restart
           ] = tools

    for function <- [list, restart] do
      assert Function.deferred?(function)
      assert Function.namespace(function) == "devices"
      assert Function.namespace_description(function) == "Find and restart managed devices."
    end
  end

  test "until_tool accepts a deferred tool alongside the search tool" do
    test_pid = self()

    stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
      {:ok,
       [
         Message.new_assistant!(%{
           tool_calls: [
             ToolCall.new!(%{call_id: "call_1", name: "devices_list", arguments: %{}})
           ]
         })
       ]}
    end)

    state = State.new!(%{messages: [Message.new_user!("List the devices")]})

    assert {:ok, _state, %{name: "devices_list"}} =
             Agent.execute(agent(test_pid), state, until_tool: "devices_list")

    assert_received {:tool_ran, "devices_list"}
  end

  test "until_tool naming the search tool validates, because it has a name" do
    capture_tools(self())
    state = State.new!(%{messages: [Message.new_user!("Hi")]})

    # The search tool runs on the provider and is never called locally, so the
    # run ends without it; what matters is that validation accepts the name.
    assert {:error, %{message: message}} =
             Agent.execute(agent(self()), state, until_tool: "tool_search")

    refute message =~ "not found"
  end

  test "interrupt_on for a deferred tool pauses the call for approval" do
    stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
      {:ok,
       [
         Message.new_assistant!(%{
           tool_calls: [
             ToolCall.new!(%{call_id: "call_1", name: "devices_restart", arguments: %{}})
           ]
         })
       ]}
    end)

    state = State.new!(%{messages: [Message.new_user!("Restart device 7")]})

    agent =
      agent(self(), [
        {Sagents.Middleware.HumanInTheLoop, interrupt_on: %{"devices_restart" => true}}
      ])

    assert {:interrupt, _state, interrupt_data} = Agent.execute(agent, state)
    assert inspect(interrupt_data) =~ "devices_restart"
    refute_received {:tool_ran, "devices_restart"}
  end
end
