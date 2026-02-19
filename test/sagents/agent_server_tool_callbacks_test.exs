defmodule Sagents.AgentServerToolCallbacksTest do
  @moduledoc """
  Tests for AgentServer tool execution callback functionality.

  This verifies that the consolidated tool execution event is properly broadcast:
  {:tool_execution_update, status, tool_info}

  Where status is :executing, :completed, or :failed
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, AgentSupervisor}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.{Message, Function}
  alias LangChain.Message.ToolCall

  setup :set_mimic_global

  # Helper to start agent with tools
  defp start_agent_with_tools(agent_id, tools) do
    # Subscribe to PubSub first
    Phoenix.PubSub.subscribe(:test_pubsub, "agent_server:#{agent_id}")

    model =
      ChatAnthropic.new!(%{
        model: "claude-3-5-sonnet-20241022",
        api_key: "test_key"
      })

    {:ok, agent} =
      Agent.new(%{
        agent_id: agent_id,
        model: model,
        base_system_prompt: "Test agent",
        replace_default_middleware: true,
        middleware: [],
        tools: tools
      })

    {:ok, _pid} =
      AgentSupervisor.start_link(
        name: AgentSupervisor.get_name(agent_id),
        agent: agent,
        pubsub: {Phoenix.PubSub, :test_pubsub}
      )

    agent_id
  end

  defp stop_agent(agent_id) do
    AgentServer.stop(agent_id)
  end

  describe "tool_execution_update :executing event" do
    test "broadcasts with display_text" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      tool =
        Function.new!(%{
          name: "test_tool",
          description: "A test tool",
          display_text: "Testing something",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:ok, "Success"} end
        })

      # First call: return tool call
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "Using tool",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_123",
                 name: "test_tool",
                 arguments: %{"arg" => "value"}
               })
             ]
           })
         ]}
      end)

      # Second call: return plain message to end the loop
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok, [Message.new_assistant!("Done!")]}
      end)

      start_agent_with_tools(agent_id, [tool])

      AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Verify consolidated tool_execution_update event
      assert_receive {:agent, {:tool_execution_update, :executing, tool_info}}

      assert tool_info.call_id == "call_123"
      assert tool_info.name == "test_tool"
      assert tool_info.display_text == "Testing something"
      assert tool_info.arguments == %{"arg" => "value"}

      # Wait for execution to complete before stopping
      assert_receive {:agent, {:status_changed, :idle, _}}, 5_000

      stop_agent(agent_id)
    end

    test "uses friendly fallback when display_text is nil" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      tool =
        Function.new!(%{
          name: "web_search",
          description: "Search",
          # No display_text
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:ok, "Results"} end
        })

      # First call: return tool call
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "Searching",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_456",
                 name: "web_search",
                 arguments: %{}
               })
             ]
           })
         ]}
      end)

      # Second call: return plain message to end the loop
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok, [Message.new_assistant!("Done!")]}
      end)

      start_agent_with_tools(agent_id, [tool])

      AgentServer.add_message(agent_id, Message.new_user!("Search"))

      assert_receive {:agent, {:tool_execution_update, :executing, tool_info}}

      assert tool_info.name == "web_search"
      # Fallback: "web_search" -> "Web search"
      assert tool_info.display_text == "Web search"

      # Wait for execution to complete before stopping
      assert_receive {:agent, {:status_changed, :idle, _}}, 5_000

      stop_agent(agent_id)
    end
  end

  describe "tool_execution_update :completed event" do
    test "broadcasts when tool succeeds" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      tool =
        Function.new!(%{
          name: "success_tool",
          description: "Succeeds",
          display_text: "Succeeding",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:ok, "Success result"} end
        })

      # First call: return tool call
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "OK",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_789",
                 name: "success_tool",
                 arguments: %{}
               })
             ]
           })
         ]}
      end)

      # Second call: return plain message to end the loop
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok, [Message.new_assistant!("Done!")]}
      end)

      start_agent_with_tools(agent_id, [tool])

      AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Should get both executing and completed
      assert_receive {:agent, {:tool_execution_update, :executing, _}}
      assert_receive {:agent, {:tool_execution_update, :completed, tool_info}}

      assert tool_info.call_id == "call_789"
      assert tool_info.name == "success_tool"
      assert is_binary(tool_info.result)

      # Wait for execution to complete before stopping
      assert_receive {:agent, {:status_changed, :idle, _}}, 5_000

      stop_agent(agent_id)
    end
  end

  describe "tool_execution_update :failed event" do
    test "broadcasts when tool fails" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      tool =
        Function.new!(%{
          name: "failing_tool",
          description: "Fails",
          display_text: "Trying",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:error, "Tool error"} end
        })

      # First call: return tool call
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "Trying",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_fail",
                 name: "failing_tool",
                 arguments: %{}
               })
             ]
           })
         ]}
      end)

      # Second call: return plain message to end the loop
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok, [Message.new_assistant!("Done!")]}
      end)

      start_agent_with_tools(agent_id, [tool])

      AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Should get executing but then failed
      assert_receive {:agent, {:tool_execution_update, :executing, _}}
      assert_receive {:agent, {:tool_execution_update, :failed, tool_info}}

      assert tool_info.call_id == "call_fail"
      assert is_binary(tool_info.error)

      # Wait for execution to complete before stopping
      assert_receive {:agent, {:status_changed, :idle, _}}, 5_000

      stop_agent(agent_id)
    end

    test "broadcasts for non-existent tool" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      # First call: return tool call for non-existent tool
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "Using",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_invalid",
                 name: "nonexistent_tool",
                 arguments: %{}
               })
             ]
           })
         ]}
      end)

      # Second call: return plain message to end the loop
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _callbacks ->
        {:ok, [Message.new_assistant!("Done!")]}
      end)

      # No tools!
      start_agent_with_tools(agent_id, [])

      AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Should get failed event for invalid tool
      assert_receive {:agent, {:tool_execution_update, :failed, tool_info}}

      assert tool_info.call_id == "call_invalid"
      assert tool_info.error =~ "tool not found"

      # Wait for execution to complete before stopping
      assert_receive {:agent, {:status_changed, :idle, _}}, 5_000

      stop_agent(agent_id)
    end
  end
end
