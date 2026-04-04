defmodule Sagents.AgentTest do
  use Sagents.BaseCase, async: true
  use Mimic

  import ExUnit.CaptureLog
  require Logger

  alias Sagents.{Agent, Middleware, State}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias Sagents.MiddlewareEntry
  alias LangChain.LangChainError

  # Test middleware for composition testing

  defmodule TestMiddleware1 do
    @behaviour Middleware

    @impl true
    def init(opts) do
      {:ok, %{name: Keyword.get(opts, :name, "test1")}}
    end

    @impl true
    def system_prompt(config) do
      "Prompt from #{config.name}"
    end

    @impl true
    def tools(_config) do
      [
        LangChain.Function.new!(%{
          name: "tool1",
          description: "Test tool 1",
          function: fn _args, _params -> {:ok, "result1"} end
        })
      ]
    end

    @impl true
    def before_model(state, config) do
      calls = Map.get(state, :before_calls, [])
      {:ok, Map.put(state, :before_calls, calls ++ [config.name])}
    end

    @impl true
    def after_model(state, config) do
      calls = Map.get(state, :after_calls, [])
      {:ok, Map.put(state, :after_calls, calls ++ [config.name])}
    end
  end

  defmodule TestMiddleware2 do
    @behaviour Middleware

    @impl true
    def init(opts) do
      {:ok, %{name: Keyword.get(opts, :name, "test2")}}
    end

    @impl true
    def system_prompt(config) do
      "Another prompt from #{config.name}"
    end

    @impl true
    def tools(_config) do
      [
        LangChain.Function.new!(%{
          name: "tool2",
          description: "Test tool 2",
          function: fn _args, _params -> {:ok, "result2"} end
        })
      ]
    end

    @impl true
    def before_model(state, config) do
      calls = Map.get(state, :before_calls, [])
      {:ok, Map.put(state, :before_calls, calls ++ [config.name])}
    end

    @impl true
    def after_model(state, config) do
      calls = Map.get(state, :after_calls, [])
      {:ok, Map.put(state, :after_calls, calls ++ [config.name])}
    end
  end

  defmodule ErrorMiddleware do
    @behaviour Middleware

    @impl true
    def before_model(_state, _config) do
      {:error, "before_model failed"}
    end
  end

  describe "new/1" do
    test "creates agent with required model" do
      assert {:ok, agent} = Agent.new(%{model: mock_model()})
      assert %Agent{} = agent
      assert agent.model != nil
      # System prompt now includes TodoList middleware prompt
      assert agent.assembled_system_prompt =~ "write_todos"
    end

    test "requires model parameter" do
      {:error, changeset} = Agent.new(%{})
      assert {"can't be blank", _} = changeset.errors[:model]
    end

    test "creates agent with system prompt" do
      {:ok, agent} = Agent.new(%{model: mock_model(), base_system_prompt: "You are helpful."})
      # System prompt includes user prompt + TodoList middleware
      assert agent.assembled_system_prompt =~ "You are helpful"
      assert agent.assembled_system_prompt =~ "write_todos"
    end

    test "creates agent with custom name" do
      {:ok, agent} = Agent.new(%{model: mock_model(), name: "my-agent"})
      assert agent.name == "my-agent"
    end

    test "creates agent with tools" do
      tool =
        LangChain.Function.new!(%{
          name: "custom_tool",
          description: "A custom tool",
          function: fn _args, _params -> {:ok, "result"} end
        })

      {:ok, agent} = Agent.new(%{model: mock_model(), tools: [tool]})

      # Now includes custom tool + write_todos (TodoList) + 8 filesystem tools (ls, read_file, write_file, edit_file, search_text, edit_lines, delete_file, move_file) + SubAgents
      assert length(agent.tools) == 11
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "custom_tool" in tool_names
      assert "write_todos" in tool_names
      assert "ls" in tool_names
      assert "read_file" in tool_names
      assert "task" in tool_names
    end
  end

  describe "new!/1" do
    test "creates agent successfully" do
      agent = Agent.new!(%{model: mock_model()})
      assert %Agent{} = agent
    end

    test "raises on error" do
      assert_raise LangChain.LangChainError, fn ->
        Agent.new!(%{})
      end
    end
  end

  describe "middleware composition - default behavior" do
    test "appends user middleware to defaults" do
      # Defaults include TodoList, Filesystem, Summarization, and PatchToolCalls
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          middleware: [TestMiddleware1]
        })

      # Default middleware (TodoList + Filesystem + SubAgents + Summarization + PatchToolCalls) + TestMiddleware1 = 6
      assert length(agent.middleware) == 6
    end

    test "collects system prompts from middleware" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          base_system_prompt: "Base prompt",
          middleware: [
            {TestMiddleware1, [name: "first"]},
            {TestMiddleware2, [name: "second"]}
          ]
        })

      assert agent.assembled_system_prompt =~ "Base prompt"
      assert agent.assembled_system_prompt =~ "Prompt from first"
      assert agent.assembled_system_prompt =~ "Another prompt from second"
    end

    test "collects tools from middleware" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          middleware: [TestMiddleware1, TestMiddleware2]
        })

      # write_todos + 8 filesystem tools + tool1 + tool2 + SubAgents = 12
      assert length(agent.tools) == 12
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "write_todos" in tool_names
      assert "ls" in tool_names
      assert "tool1" in tool_names
      assert "tool2" in tool_names
      assert "task" in tool_names
    end

    test "combines user tools with middleware tools" do
      user_tool =
        LangChain.Function.new!(%{
          name: "user_tool",
          description: "User tool",
          function: fn _args, _params -> {:ok, "result"} end
        })

      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          tools: [user_tool],
          middleware: [TestMiddleware1]
        })

      # user_tool + write_todos + 8 filesystem tools + tool1 = 12
      assert length(agent.tools) == 12
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "write_todos" in tool_names
      assert "user_tool" in tool_names
      assert "tool1" in tool_names
      assert "ls" in tool_names
      assert "delete_file" in tool_names
      assert "task" in tool_names
    end
  end

  describe "middleware composition - replace defaults" do
    test "uses only provided middleware when replace_default_middleware is true" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            middleware: [TestMiddleware1]
          },
          replace_default_middleware: true
        )

      assert length(agent.middleware) == 1
      %MiddlewareEntry{module: module} = hd(agent.middleware)
      assert module == TestMiddleware1
    end

    test "empty middleware when replace_default_middleware is true and no middleware provided" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            middleware: []
          },
          replace_default_middleware: true
        )

      assert agent.middleware == []
      assert agent.tools == []
      assert agent.assembled_system_prompt == ""
    end
  end

  describe "execute/2" do
    setup do
      # Mock ChatAnthropic.call to return a simple response
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Mock response")]}
      end)

      :ok
    end

    test "executes with empty middleware" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          replace_default_middleware: true
        })

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})

      assert {:ok, result_state} = Agent.execute(agent, initial_state)
      assert %State{} = result_state
      # Mock execution adds an assistant message
      assert length(result_state.messages) == 2
      assert Enum.at(result_state.messages, 1).role == :assistant
    end

    test "applies before_model hooks in order" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          middleware: [
            {TestMiddleware1, [name: "first"]},
            {TestMiddleware2, [name: "second"]}
          ]
        })

      initial_state = State.new!(%{messages: [Message.new_user!("Test")]})

      assert {:ok, result_state} = Agent.execute(agent, initial_state)
      assert result_state.before_calls == ["first", "second"]
    end

    test "applies after_model hooks in reverse order" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          middleware: [
            {TestMiddleware1, [name: "first"]},
            {TestMiddleware2, [name: "second"]}
          ]
        })

      initial_state = State.new!(%{messages: [Message.new_user!("Test")]})

      assert {:ok, result_state} = Agent.execute(agent, initial_state)
      # After hooks applied in reverse
      assert result_state.after_calls == ["second", "first"]
    end

    test "returns error if before_model hook fails" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          middleware: [ErrorMiddleware]
        })

      initial_state = State.new!(%{messages: [Message.new_user!("Test")]})

      assert {:error, "before_model failed"} = Agent.execute(agent, initial_state)
    end

    test "state flows through all hooks" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          middleware: [
            {TestMiddleware1, [name: "mw1"]},
            {TestMiddleware2, [name: "mw2"]}
          ]
        })

      initial_state = State.new!(%{messages: [Message.new_user!("Test")]})

      assert {:ok, result_state} = Agent.execute(agent, initial_state)

      # Verify hooks were called
      assert result_state.before_calls == ["mw1", "mw2"]
      assert result_state.after_calls == ["mw2", "mw1"]

      # Verify original messages preserved
      first_message = Enum.at(result_state.messages, 0)
      assert first_message.role == :user
      assert Message.ContentPart.content_to_string(first_message.content) == "Test"

      # Verify mock response added
      assert Enum.at(result_state.messages, 1).role == :assistant
    end

    test "propagates {:pause, state} from mode" do
      # Use a mode that always returns {:pause, chain} to simulate
      # infrastructure pause (e.g., node draining)
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          mode: Sagents.Test.PauseMode,
          replace_default_middleware: true
        })

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})

      assert {:pause, paused_state} = Agent.execute(agent, initial_state)
      assert %State{} = paused_state
      # Original message preserved, no assistant response added (paused before completion)
      assert [%{role: :user}] = paused_state.messages
    end
  end

  describe "execute/2 with callbacks as list" do
    setup do
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Mock response")]}
      end)

      :ok
    end

    test "accepts callbacks as a list of maps" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            middleware: [{TestMiddleware1, [name: "mw1"]}]
          },
          replace_default_middleware: true
        )

      test_pid = self()

      callback1 = %{
        on_after_middleware: fn _state ->
          send(test_pid, :callback1_fired)
        end
      }

      callback2 = %{
        on_after_middleware: fn _state ->
          send(test_pid, :callback2_fired)
        end
      }

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})

      assert {:ok, _result_state} =
               Agent.execute(agent, initial_state, callbacks: [callback1, callback2])

      # Both callbacks should fire (fan-out)
      assert_received :callback1_fired
      assert_received :callback2_fired
    end

    test "accepts empty list of callbacks" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            middleware: [{TestMiddleware1, [name: "mw1"]}]
          },
          replace_default_middleware: true
        )

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})
      assert {:ok, _result_state} = Agent.execute(agent, initial_state, callbacks: [])
    end
  end

  describe "integration tests" do
    setup do
      # Mock ChatAnthropic.call to return a simple response
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Mock response")]}
      end)

      :ok
    end

    test "complete workflow with system prompt, tools, and middleware" do
      custom_tool =
        LangChain.Function.new!(%{
          name: "calculator",
          description: "Calculate things",
          function: fn _args, _params -> {:ok, "42"} end
        })

      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          name: "math-agent",
          base_system_prompt: "You are a math assistant.",
          tools: [custom_tool],
          middleware: [
            {TestMiddleware1, [name: "logging"]},
            {TestMiddleware2, [name: "validation"]}
          ]
        })

      # Verify agent structure
      assert agent.name == "math-agent"
      assert agent.assembled_system_prompt =~ "math assistant"
      assert agent.assembled_system_prompt =~ "logging"
      assert agent.assembled_system_prompt =~ "validation"
      # calculator + write_todos + 8 filesystem tools + tool1 + tool2 + SubAgents = 13
      assert length(agent.tools) == 13

      # Execute
      initial_state = State.new!(%{messages: [Message.new_user!("What is 2+2?")]})
      assert {:ok, result_state} = Agent.execute(agent, initial_state)

      # Verify execution
      assert length(result_state.messages) == 2
      assert result_state.before_calls == ["logging", "validation"]
      assert result_state.after_calls == ["validation", "logging"]
    end

    test "agent with no middleware works correctly" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          base_system_prompt: "Simple agent",
          replace_default_middleware: true
        })

      initial_state = State.new!(%{messages: [Message.new_user!("Hi")]})
      assert {:ok, result_state} = Agent.execute(agent, initial_state)

      assert length(result_state.messages) == 2
      # No middleware hooks were called, so these keys don't exist
      assert Map.get(result_state, :before_calls) == nil
      assert Map.get(result_state, :after_calls) == nil
    end
  end

  describe "TodoList middleware integration" do
    test "agents include TodoList middleware by default" do
      {:ok, agent} = Agent.new(%{model: mock_model()})

      # Should have TodoList middleware in the stack
      assert length(agent.middleware) > 0

      # Should have write_todos tool
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "write_todos" in tool_names
    end

    test "TodoList middleware can be excluded" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            middleware: []
          },
          replace_default_middleware: true
        )

      # No middleware
      assert agent.middleware == []
      assert agent.tools == []
    end

    test "system prompt includes TODO instructions" do
      {:ok, agent} = Agent.new(%{model: mock_model()})

      assert agent.assembled_system_prompt =~ "write_todos"
    end
  end

  describe "fallback models" do
    test "accepts fallback_models field" do
      fallback_model = mock_model()

      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          fallback_models: [fallback_model]
        })

      assert agent.fallback_models == [fallback_model]
    end

    test "defaults to empty list when not provided" do
      {:ok, agent} = Agent.new(%{model: mock_model()})

      assert agent.fallback_models == []
    end

    test "accepts before_fallback function" do
      before_fallback_fn = fn chain -> chain end

      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          before_fallback: before_fallback_fn
        })

      assert agent.before_fallback == before_fallback_fn
    end

    test "defaults to nil when before_fallback not provided" do
      {:ok, agent} = Agent.new(%{model: mock_model()})

      assert agent.before_fallback == nil
    end
  end

  describe "custom execution mode" do
    setup do
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Mock response")]}
      end)

      :ok
    end

    test "accepts mode field" do
      {:ok, agent} =
        Agent.new(%{
          model: mock_model(),
          mode: Sagents.Modes.AgentExecution
        })

      assert agent.mode == Sagents.Modes.AgentExecution
    end

    test "defaults to nil when not provided" do
      {:ok, agent} = Agent.new(%{model: mock_model()})

      assert agent.mode == nil
    end

    test "custom mode is invoked during execute" do
      test_pid = self()

      # Define a custom mode inline via a module attribute trick:
      # We use a real module defined below (TestMode) that sends a message
      # to the test process.
      #
      # TestMode is defined at the bottom of this describe block.
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            mode: __MODULE__.TestMode
          },
          replace_default_middleware: true
        )

      # Store the test pid so TestMode can notify us
      Process.put(:test_mode_pid, test_pid)

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})
      assert {:ok, _result_state} = Agent.execute(agent, initial_state)

      # Verify our custom mode was called, not the default AgentExecution
      assert_received {:custom_mode_called, opts}
      assert Keyword.get(opts, :middleware) != nil
    end

    test "nil mode falls back to default AgentExecution" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            mode: nil
          },
          replace_default_middleware: true
        )

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})

      # Should work normally using the default AgentExecution mode
      assert {:ok, result_state} = Agent.execute(agent, initial_state)
      assert length(result_state.messages) == 2
      assert Enum.at(result_state.messages, 1).role == :assistant
    end

    test "custom mode receives middleware in opts" do
      test_pid = self()
      Process.put(:test_mode_pid, test_pid)

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            mode: __MODULE__.TestMode,
            middleware: [{TestMiddleware1, [name: "mw1"]}]
          },
          replace_default_middleware: true
        )

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})
      assert {:ok, _result_state} = Agent.execute(agent, initial_state)

      assert_received {:custom_mode_called, opts}
      middleware = Keyword.get(opts, :middleware)
      assert length(middleware) == 1
    end
  end

  describe "until_tool execution" do
    setup do
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Mock response")]}
      end)

      :ok
    end

    test "until_tool validation: valid tool name passes" do
      search_tool =
        LangChain.Function.new!(%{
          name: "search",
          description: "Search for information",
          function: fn _args, _params -> {:ok, "result"} end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [search_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})

      # Should not return a validation error - the tool name is valid
      result = Agent.execute(agent, initial_state, until_tool: "search")
      # It may return an error about the tool not being called (since mock just returns text),
      # but NOT a validation error
      case result do
        {:error, %LangChainError{} = err} -> refute err.message =~ "not found"
        {:error, msg} when is_binary(msg) -> refute msg =~ "not found"
        _ -> :ok
      end
    end

    test "until_tool validation: invalid tool name returns error" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [],
            middleware: []
          },
          replace_default_middleware: true
        )

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})

      assert {:error, msg} = Agent.execute(agent, initial_state, until_tool: "nonexistent")
      assert msg =~ "until_tool"
      assert msg =~ "nonexistent"
      assert msg =~ "not found"
    end

    test "until_tool validation: multiple tools, one invalid" do
      search_tool =
        LangChain.Function.new!(%{
          name: "search",
          description: "Search",
          function: fn _args, _params -> {:ok, "result"} end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [search_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})

      assert {:error, msg} =
               Agent.execute(agent, initial_state, until_tool: ["search", "nonexistent"])

      assert msg =~ "nonexistent"
      assert msg =~ "not found"
      # Only "nonexistent" should be in the missing list, not "search"
      assert msg =~ ~s|tool(s) ["nonexistent"] not found|
    end

    test "until_tool: returns 3-tuple when target tool called" do
      submit_tool =
        LangChain.Function.new!(%{
          name: "submit_report",
          description: "Submit a report",
          parameters_schema: %{
            type: "object",
            properties: %{"title" => %{type: "string"}}
          },
          function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [submit_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      # LLM calls the target tool
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_1",
            name: "submit_report",
            arguments: %{"title" => "Test Report"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Write a report")]})

      assert {:ok, result_state, %ToolResult{name: "submit_report"}} =
               Agent.execute(agent, initial_state, until_tool: "submit_report")

      assert %State{} = result_state
    end

    test "until_tool: returns error when LLM stops without calling tool" do
      submit_tool =
        LangChain.Function.new!(%{
          name: "submit_report",
          description: "Submit a report",
          function: fn _args, _ctx -> {:ok, "done"} end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [submit_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      # LLM returns a plain text response without calling any tool
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("I'm done talking.")]}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Do something")]})

      assert {:error, %LangChainError{type: "until_tool_not_called"} = err} =
               Agent.execute(agent, initial_state, until_tool: "submit_report")

      assert err.message =~ "submit_report"
      assert err.message =~ "without calling target tool"
    end

    test "3-tuple propagation: execute_chain passes extra through" do
      submit_tool =
        LangChain.Function.new!(%{
          name: "submit_report",
          description: "Submit a report",
          parameters_schema: %{
            type: "object",
            properties: %{"title" => %{type: "string"}}
          },
          function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
        })

      search_tool =
        LangChain.Function.new!(%{
          name: "search",
          description: "Search",
          function: fn _args, _ctx -> {:ok, "found something"} end
        })

      # Agent with both tools so LLM can call search first, then submit_report
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [submit_tool, search_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_1",
            name: "search",
            arguments: %{"query" => "test"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)
      |> expect(:call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_2",
            name: "submit_report",
            arguments: %{"title" => "Found it"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Research and report")]})

      assert {:ok, result_state, %ToolResult{name: "submit_report"}} =
               Agent.execute(agent, initial_state, until_tool: "submit_report")

      assert %State{} = result_state
      # Should have multiple messages from the multi-step execution
      assert length(result_state.messages) > 2
    end

    test "resume after HITL interrupt completes with until_tool 3-tuple" do
      write_file_tool =
        LangChain.Function.new!(%{
          name: "write_file",
          description: "Write content to a file",
          parameters_schema: %{
            type: "object",
            properties: %{
              "path" => %{type: "string"},
              "content" => %{type: "string"}
            },
            required: ["path", "content"]
          },
          function: fn args, _ctx -> {:ok, "File written: #{args["path"]}"} end
        })

      submit_report_tool =
        LangChain.Function.new!(%{
          name: "submit_report",
          description: "Submit a report",
          parameters_schema: %{
            type: "object",
            properties: %{
              "title" => %{type: "string"}
            }
          },
          function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
        })

      # Call 1 (during execute): LLM returns a write_file tool call (HITL protected)
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_1",
            name: "write_file",
            arguments: %{"path" => "report.txt", "content" => "data"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)
      # Call 2 (during resume, after write_file executes): LLM returns submit_report
      |> expect(:call, fn _model, _messages, _tools ->
        tool_call =
          ToolCall.new!(%{
            call_id: "call_2",
            name: "submit_report",
            arguments: %{"title" => "Final Report"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
      end)

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [write_file_tool, submit_report_tool],
            base_system_prompt: "Test agent",
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{"write_file" => true}]}
            ]
          },
          replace_default_middleware: true,
          interrupt_on: %{"write_file" => true}
        )

      initial_state = State.new!(%{messages: [Message.new_user!("Write a report")]})

      # Step 1: Execute should return HITL interrupt because write_file is protected
      assert {:interrupt, interrupted_state, interrupt_data} =
               Agent.execute(agent, initial_state, until_tool: "submit_report")

      # Verify interrupt data
      assert %{action_requests: [action_request]} = interrupt_data
      assert action_request.tool_name == "write_file"
      assert action_request.arguments == %{"path" => "report.txt", "content" => "data"}

      # Step 2: Resume with approval decision for the write_file tool call
      decisions = [%{type: :approve}]

      assert {:ok, final_state, %ToolResult{name: "submit_report"} = tool_result} =
               Agent.resume(agent, interrupted_state, decisions, until_tool: "submit_report")

      assert %State{} = final_state
      # The tool result should contain the submit_report result
      assert tool_result.name == "submit_report"
    end

    test "raw LangChain mode warning" do
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            mode: LangChain.Chains.LLMChain.Modes.WhileNeedsResponse,
            middleware: []
          },
          replace_default_middleware: true
        )

      initial_state = State.new!(%{messages: [Message.new_user!("Hello")]})

      log =
        capture_log(fn ->
          Agent.execute(agent, initial_state)
        end)

      assert log =~ "raw LangChain mode"
      assert log =~ "HITL interrupts and state propagation will NOT be applied"
      assert log =~ "WhileNeedsResponse"
    end
  end

  describe "resume/4 classify_interrupt dispatch" do
    setup :verify_on_exit!

    test "returns error for unknown interrupt type" do
      {:ok, agent} =
        Agent.new(%{
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"})
        })

      state = State.new!(%{interrupt_data: %{type: :unknown_type}})

      assert {:error, "No middleware handled the resume for this interrupt"} =
               Agent.resume(agent, state, [])
    end

    test "returns error for nil interrupt_data" do
      {:ok, agent} =
        Agent.new(%{
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"})
        })

      state = State.new!()

      assert {:error, "No middleware handled the resume for this interrupt"} =
               Agent.resume(agent, state, [])
    end

    test "dispatches to subagent resume when interrupt_data.type is :subagent_hitl" do
      {:ok, agent} =
        Agent.new(%{
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"})
        })

      # Mock SubAgentServer.resume to return success
      expect(Sagents.SubAgentServer, :resume, fn "sub-agent-1", [%{type: :approve}] ->
        {:ok, "Sub-agent completed successfully."}
      end)

      # Mock the ChatAnthropic call for the continue execution after sub-agent completes
      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Done!")]}
      end)

      # Create a state with sub-agent interrupt data and a tool message with interrupt placeholder
      tool_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_task_1",
          name: "task",
          content: "SubAgent 'researcher' requires human approval.",
          is_interrupt: true,
          interrupt_data: %{type: :subagent_hitl, sub_agent_id: "sub-agent-1"}
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [tool_result]})

      assistant_msg =
        Message.new_assistant!(%{
          tool_calls: [
            LangChain.Message.ToolCall.new!(%{
              call_id: "call_task_1",
              name: "task",
              arguments: %{}
            })
          ]
        })

      state =
        State.new!(%{
          messages: [Message.new_user!("Do research"), assistant_msg, tool_msg],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-agent-1",
            subagent_type: "researcher",
            tool_call_id: "call_task_1",
            interrupt_data: %{action_requests: []}
          }
        })

      decisions = [%{type: :approve}]

      result = Agent.resume(agent, state, decisions)
      assert {:ok, final_state} = result

      # The placeholder tool result should have been replaced
      tool_message = Enum.find(final_state.messages, &(&1.role == :tool))
      [replaced_result] = tool_message.tool_results
      assert replaced_result.is_interrupt == false
    end

    test "sub-agent re-interrupts during resume" do
      {:ok, agent} =
        Agent.new(%{
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"})
        })

      new_inner_data = %{action_requests: [%{tool_name: "file_write"}]}

      expect(Sagents.SubAgentServer, :resume, fn "sub-agent-1", [%{type: :approve}] ->
        {:interrupt, new_inner_data}
      end)

      tool_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_task_1",
          name: "task",
          content: "placeholder",
          is_interrupt: true,
          interrupt_data: %{type: :subagent_hitl}
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [tool_result]})

      state =
        State.new!(%{
          messages: [Message.new_user!("Do research"), tool_msg],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-agent-1",
            subagent_type: "researcher",
            tool_call_id: "call_task_1",
            interrupt_data: %{action_requests: [%{tool_name: "web_search"}]}
          }
        })

      result = Agent.resume(agent, state, [%{type: :approve}])

      assert {:interrupt, updated_state, updated_interrupt} = result
      assert updated_interrupt.type == :subagent_hitl
      assert updated_interrupt.sub_agent_id == "sub-agent-1"
      assert updated_interrupt.interrupt_data == new_inner_data
      assert updated_state.interrupt_data == updated_interrupt
    end

    test "sub-agent error during resume creates error tool result and continues" do
      {:ok, agent} =
        Agent.new(%{
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"})
        })

      expect(Sagents.SubAgentServer, :resume, fn "sub-agent-1", [%{type: :approve}] ->
        {:error, :process_not_found}
      end)

      # The agent will continue execution after patching error — mock the LLM
      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("The sub-agent failed, sorry.")]}
      end)

      tool_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_task_1",
          name: "task",
          content: "placeholder",
          is_interrupt: true,
          interrupt_data: %{type: :subagent_hitl}
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [tool_result]})

      state =
        State.new!(%{
          messages: [Message.new_user!("Do research"), tool_msg],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-agent-1",
            subagent_type: "researcher",
            tool_call_id: "call_task_1",
            interrupt_data: %{}
          }
        })

      result = Agent.resume(agent, state, [%{type: :approve}])
      assert {:ok, final_state} = result

      # The error tool result should be in the messages
      tool_message = Enum.find(final_state.messages, &(&1.role == :tool))
      [error_result] = tool_message.tool_results
      assert error_result.is_error == true
      assert error_result.is_interrupt == false
    end

    test "dispatches to direct HITL when interrupt_data has action_requests" do
      {:ok, agent} =
        Agent.new(%{
          model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
          interrupt_on: %{"tool1" => :always}
        })

      state =
        State.new!(%{
          messages: [Message.new_user!("hi")],
          interrupt_data: %{
            action_requests: [%{tool_call_id: "call_1", tool_name: "tool1"}],
            hitl_tool_call_ids: ["call_1"]
          }
        })

      # direct_hitl path requires HITL middleware validation + chain rebuild
      # For this test, we just verify it takes the right path (not :unknown)
      result = Agent.resume(agent, state, [%{type: :approve}])
      refute match?({:error, "Unknown interrupt type" <> _}, result)
    end

    test "ask_user interrupt is claimed by AskUserQuestion middleware, not HITL" do
      {:ok, agent} =
        Agent.new(
          %{
            model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
            middleware: [
              Sagents.Middleware.AskUserQuestion,
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{"write_file" => true}]}
            ]
          },
          replace_default_middleware: true
        )

      # Mock the LLM for the re-execution after resume
      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Great choice!")]}
      end)

      # Build state with ask_user interrupt placeholder
      interrupt_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_ask",
          content: "Waiting for user response...",
          name: "ask_user",
          is_interrupt: true
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [interrupt_result]})

      question_data = %{
        type: :ask_user_question,
        question: "Which DB?",
        response_type: :single_select,
        options: [%{label: "PG", value: "pg"}, %{label: "Mongo", value: "mongo"}],
        allow_other: false,
        allow_cancel: true,
        tool_call_id: "call_ask"
      }

      state =
        State.new!(%{
          messages: [Message.new_user!("hi"), tool_msg],
          interrupt_data: question_data
        })

      response = %{type: :answer, selected: ["pg"], tool_call_id: "call_ask"}
      result = Agent.resume(agent, state, response)

      assert {:ok, final_state} = result
      # The tool result should be replaced with the answer
      tool_message = Enum.find(final_state.messages, &(&1.role == :tool))
      [resolved] = tool_message.tool_results
      refute resolved.is_interrupt
    end

    test "HITL resume surfaces ask_user interrupt when both tools in same turn" do
      # When the LLM calls both delete_file (HITL) and ask_user in one turn:
      # 1. HITL fires pre-tool, interrupts for delete_file approval
      # 2. User approves -> HITL executes ALL tools via execute_tool_calls_with_decisions
      # 3. delete_file runs (approved), ask_user runs (auto-approved) -> interrupt ToolResult
      # 4. HITL detects the interrupt ToolResult, returns {:cont, state} with ask_user interrupt_data
      # 5. apply_handle_resume_hooks re-scans -> AskUserQuestion claims it with {:interrupt}
      # 6. Agent.resume returns {:interrupt, state, %{type: :ask_user_question}}

      # Standalone delete_file tool (HITL middleware doesn't provide tools, just gates them)
      delete_tool =
        LangChain.Function.new!(%{
          name: "delete_file",
          description: "Delete a file",
          parameters_schema: %{
            type: "object",
            properties: %{file_path: %{type: "string"}},
            required: ["file_path"]
          },
          function: fn _args, _ctx -> {:ok, "File deleted"} end
        })

      # AskUserQuestion middleware provides the ask_user tool via tools/1.
      # No standalone ask_user tool needed.
      {:ok, agent} =
        Agent.new(
          %{
            model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
            middleware: [
              Sagents.Middleware.AskUserQuestion,
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{"delete_file" => true}]}
            ],
            tools: [delete_tool]
          },
          replace_default_middleware: true
        )

      # No LLM call should happen -- HITL detects the secondary interrupt and
      # returns {:cont}, which re-scans to AskUserQuestion returning
      # {:interrupt}. Agent.resume never calls execute(). Stub to catch any
      # unexpected calls.
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        flunk("LLM should not be called -- the interrupt should be caught before execute()")
      end)

      # The assistant called both tools with proper arguments
      ask_user_args = %{
        "question" => "Which DB?",
        "response_type" => "single_select",
        "options" => [
          %{"label" => "PG", "value" => "pg"},
          %{"label" => "Mongo", "value" => "mongo"}
        ]
      }

      assistant_msg =
        Message.new_assistant!(%{
          tool_calls: [
            LangChain.Message.ToolCall.new!(%{
              call_id: "call_delete",
              name: "delete_file",
              arguments: %{"file_path" => "/tmp/test.txt"}
            }),
            LangChain.Message.ToolCall.new!(%{
              call_id: "call_ask",
              name: "ask_user",
              arguments: ask_user_args
            })
          ]
        })

      state =
        State.new!(%{
          messages: [Message.new_user!("Delete and ask"), assistant_msg],
          interrupt_data: %{
            action_requests: [
              %{
                tool_call_id: "call_delete",
                tool_name: "delete_file",
                arguments: %{"file_path" => "/tmp/test.txt"}
              }
            ],
            review_configs: %{
              "delete_file" => %{allowed_decisions: [:approve, :edit, :reject]}
            },
            hitl_tool_call_ids: ["call_delete"]
          }
        })

      result = Agent.resume(agent, state, [%{type: :approve}])

      assert {:interrupt, interrupted_state, interrupt_data} = result
      assert interrupt_data.type == :ask_user_question
      assert interrupt_data.question == "Which DB?"

      # The delete_file tool result should also be in messages (it executed successfully)
      tool_msg = Enum.find(interrupted_state.messages, &(&1.role == :tool))
      delete_result = Enum.find(tool_msg.tool_results, &(&1.name == "delete_file"))
      refute delete_result.is_interrupt
    end

    test "ask_user works without HITL middleware in the stack" do
      # When HITL is not in the middleware stack, ask_user interrupts flow
      # through the normal mode pipeline (execute_tools ->
      # check_tool_interrupts). No HITL pre-tool gate, no
      # execute_tool_calls_with_decisions.

      {:ok, agent} =
        Agent.new(
          %{
            model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
            middleware: [Sagents.Middleware.AskUserQuestion],
            tools: []
          },
          replace_default_middleware: true
        )

      # Mock LLM to return an ask_user tool call
      ask_user_args = %{
        "question" => "What's your name?",
        "response_type" => "freeform"
      }

      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok,
         [
           Message.new_assistant!(%{
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_ask",
                 name: "ask_user",
                 arguments: ask_user_args
               })
             ]
           })
         ]}
      end)

      state = State.new!(%{messages: [Message.new_user!("Ask me something")]})
      result = Agent.execute(agent, state)

      # Should interrupt for the question (no HITL involved)
      assert {:interrupt, interrupted_state, interrupt_data} = result
      assert interrupt_data.type == :ask_user_question
      assert interrupt_data.question == "What's your name?"

      # Now resume with an answer
      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Nice to meet you, Mark!")]}
      end)

      response = %{type: :answer, other_text: "Mark", tool_call_id: "call_ask"}
      assert {:ok, final_state} = Agent.resume(agent, interrupted_state, response)
      last_msg = List.last(final_state.messages)
      assert last_msg.role == :assistant
    end

    test "HITL resume with no secondary interrupts still works (regression)" do
      # When HITL resumes and all tools complete normally (no interrupt
      # ToolResults), behavior must be identical to before: {:ok, state} ->
      # Agent.execute continues.

      delete_tool =
        LangChain.Function.new!(%{
          name: "delete_file",
          description: "Delete a file",
          parameters_schema: %{
            type: "object",
            properties: %{file_path: %{type: "string"}},
            required: ["file_path"]
          },
          function: fn _args, _ctx -> {:ok, "File deleted"} end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
            middleware: [
              Sagents.Middleware.AskUserQuestion,
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{"delete_file" => true}]}
            ],
            tools: [delete_tool]
          },
          replace_default_middleware: true
        )

      # After HITL resume + tool execution, Agent.execute calls the LLM
      expect(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("File has been deleted.")]}
      end)

      assistant_msg =
        Message.new_assistant!(%{
          tool_calls: [
            ToolCall.new!(%{
              call_id: "call_delete",
              name: "delete_file",
              arguments: %{"file_path" => "/tmp/test.txt"}
            })
          ]
        })

      state =
        State.new!(%{
          messages: [Message.new_user!("Delete the file"), assistant_msg],
          interrupt_data: %{
            action_requests: [
              %{
                tool_call_id: "call_delete",
                tool_name: "delete_file",
                arguments: %{"file_path" => "/tmp/test.txt"}
              }
            ],
            review_configs: %{
              "delete_file" => %{allowed_decisions: [:approve, :edit, :reject]}
            },
            hitl_tool_call_ids: ["call_delete"]
          }
        })

      # Resume with approve -- no secondary interrupts, should complete normally
      result = Agent.resume(agent, state, [%{type: :approve}])
      assert {:ok, final_state} = result
      last_msg = List.last(final_state.messages)
      assert last_msg.role == :assistant
    end
  end

  # A test mode module that implements the Mode behaviour.
  # It notifies the test process that it was called, then delegates
  # to the default AgentExecution so the rest of execution completes normally.
  defmodule TestMode do
    @behaviour LangChain.Chains.LLMChain.Mode

    @impl true
    def run(chain, opts) do
      # Notify the test process
      if pid = Process.get(:test_mode_pid) do
        send(pid, {:custom_mode_called, opts})
      end

      # Delegate to the real mode so execution completes
      Sagents.Modes.AgentExecution.run(chain, opts)
    end
  end
end
