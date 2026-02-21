defmodule Sagents.AgentTest do
  use Sagents.BaseCase, async: true
  use Mimic

  alias Sagents.{Agent, Middleware, State}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias Sagents.MiddlewareEntry

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

      # Now includes custom tool + write_todos (TodoList) + 7 filesystem tools (ls, read_file, write_file, edit_file, search_text, edit_lines, delete_file) + SubAgents
      assert length(agent.tools) == 10
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

      # write_todos + 7 filesystem tools + tool1 + tool2 + SubAgents = 11
      assert length(agent.tools) == 11
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

      # user_tool + write_todos + 7 filesystem tools + tool1 = 10
      assert length(agent.tools) == 11
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
      # calculator + write_todos + 7 filesystem tools + tool1 + tool2 + SubAgents = 12
      assert length(agent.tools) == 12

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

  describe "sub-agent HITL interrupt propagation" do
    @describetag timeout: 15_000

    setup do
      # Mock ChatAnthropic.call - the actual LLM won't be called for these tests
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Mock response")]}
      end)

      :ok
    end

    test "execution loop detects sub-agent interrupt propagated via state" do
      # Create a tool that simulates a sub-agent returning an interrupt via 3-tuple
      # This is what execute_subagent will return after the fix
      interrupt_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            {:ok, "SubAgent paused — awaiting user input.",
             %State{
               interrupt_data: %{
                 type: :subagent_hitl,
                 sub_agent_id: "sub-123",
                 subagent_type: "researcher",
                 interrupt_data: %{
                   action_requests: [
                     %{
                       tool_call_id: "call_1",
                       tool_name: "ask_user",
                       arguments: %{"question" => "Proceed?"}
                     }
                   ],
                   review_configs: %{
                     "ask_user" => %{allowed_decisions: [:approve, :reject]}
                   },
                   hitl_tool_call_ids: ["call_1"]
                 }
               }
             }}
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [interrupt_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      # Mock the LLM to return a tool call for "task"
      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_1",
          name: "task",
          arguments: %{"instructions" => "research", "subagent_type" => "researcher"}
        })

      call_count = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
        else
          # Safety: prevent infinite loop in case fix isn't applied
          {:ok, [Message.new_assistant!("Fallback response")]}
        end
      end)

      state = State.new!(%{messages: [Message.new_user!("Research something")]})

      # After the fix, the execution loop should detect the interrupt_data
      # in the state after tool execution and return {:interrupt, state, interrupt_data}
      result = Agent.execute(agent, state)

      assert {:interrupt, interrupted_state, interrupt_data} = result
      assert interrupt_data.type == :subagent_hitl
      assert interrupt_data.sub_agent_id == "sub-123"
      assert interrupted_state.interrupt_data == interrupt_data
    end

    test "execution loop with HITL middleware detects sub-agent interrupt after tool execution" do
      # Same as above but with HITL middleware active on the parent.
      # The parent's HITL doesn't match "task" tool, but sub-agent propagates interrupt.
      interrupt_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            {:ok, "SubAgent paused — awaiting user input.",
             %State{
               interrupt_data: %{
                 type: :subagent_hitl,
                 sub_agent_id: "sub-456",
                 subagent_type: "coder",
                 interrupt_data: %{
                   action_requests: [
                     %{
                       tool_call_id: "call_x",
                       tool_name: "write_file",
                       arguments: %{"path" => "/tmp/test.txt"}
                     }
                   ],
                   review_configs: %{
                     "write_file" => %{allowed_decisions: [:approve, :reject]}
                   },
                   hitl_tool_call_ids: ["call_x"]
                 }
               }
             }}
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [interrupt_tool],
            middleware: []
          },
          replace_default_middleware: true,
          # HITL on "delete_file" only — "task" is not in interrupt_on
          interrupt_on: %{"delete_file" => true}
        )

      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_2",
          name: "task",
          arguments: %{"instructions" => "write code", "subagent_type" => "coder"}
        })

      call_count = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
        else
          {:ok, [Message.new_assistant!("Fallback response")]}
        end
      end)

      state = State.new!(%{messages: [Message.new_user!("Write some code")]})

      result = Agent.execute(agent, state)

      # The HITL check (pre-tool) passes "task" since it's not in interrupt_on.
      # But after tool execution, check_for_subagent_interrupt should catch it.
      assert {:interrupt, interrupted_state, interrupt_data} = result
      assert interrupt_data.type == :subagent_hitl
      assert interrupt_data.sub_agent_id == "sub-456"
      assert interrupted_state.interrupt_data == interrupt_data
    end

    test "resume routes decisions to sub-agent via direct SubAgentServer.resume call" do
      # This test verifies that when resuming from a sub-agent HITL interrupt,
      # the parent calls SubAgentServer.resume directly with the correct
      # sub_agent_id and decisions, rather than re-executing tool calls.

      subagent_task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            # This function should NOT be called during resume with direct injection.
            {:ok, "should not be called on resume"}
          end
        })

      # The parent needs HITL middleware for resume/4 to work.
      # When using replace_default_middleware, we must add HITL explicitly.
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{"task" => true}]}
            ]
          },
          replace_default_middleware: true
        )

      # Build a state that looks like we were interrupted by a sub-agent HITL
      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_resume",
          name: "task",
          arguments: %{"instructions" => "do work", "subagent_type" => "researcher"}
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do the work"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-789",
            subagent_type: "researcher",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa",
                  tool_name: "ask_user",
                  arguments: %{"question" => "OK?"}
                }
              ],
              review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
              hitl_tool_call_ids: ["call_sa"]
            },
            # This marks the parent's "task" tool call as needing HITL handling
            action_requests: [
              %{
                tool_call_id: "tc_resume",
                tool_name: "task",
                arguments: %{"instructions" => "do work", "subagent_type" => "researcher"}
              }
            ],
            hitl_tool_call_ids: ["tc_resume"]
          }
        })

      decisions = [%{type: :approve}]

      # Mock SubAgentServer.resume to verify it's called with correct args
      expect(Sagents.SubAgentServer, :resume, fn sub_agent_id, received_decisions ->
        assert sub_agent_id == "sub-789"
        assert received_decisions == decisions
        {:ok, "Sub-agent completed the task successfully."}
      end)

      # Mock LLM for the continuation after resume
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Great, the sub-agent finished.")]}
      end)

      result = Agent.resume(agent, interrupted_state, decisions)

      # Should succeed
      assert {:ok, _final_state} = result
    end

    test "parallel tool calls where one returns sub-agent interrupt and one completes normally" do
      # Create a tool that simulates a sub-agent returning an interrupt via 3-tuple
      interrupt_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          async: true,
          function: fn _args, _context ->
            {:ok, "SubAgent paused — awaiting user input.",
             %State{
               interrupt_data: %{
                 type: :subagent_hitl,
                 sub_agent_id: "sub-parallel-1",
                 subagent_type: "researcher",
                 interrupt_data: %{
                   action_requests: [
                     %{
                       tool_call_id: "call_sa_1",
                       tool_name: "ask_user",
                       arguments: %{"question" => "Proceed with research?"}
                     }
                   ],
                   review_configs: %{
                     "ask_user" => %{allowed_decisions: [:approve, :reject]}
                   },
                   hitl_tool_call_ids: ["call_sa_1"]
                 }
               }
             }}
          end
        })

      # A normal tool that completes successfully
      read_file_tool =
        LangChain.Function.new!(%{
          name: "read_file",
          description: "Read a file",
          async: true,
          function: fn _args, _context ->
            {:ok, "file contents: hello world"}
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [interrupt_tool, read_file_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      # Mock the LLM to return both tool calls at once (parallel)
      task_tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_task",
          name: "task",
          arguments: %{"instructions" => "research topic", "subagent_type" => "researcher"}
        })

      read_tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_read",
          name: "read_file",
          arguments: %{"path" => "/tmp/test.txt"}
        })

      call_count = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          {:ok, [Message.new_assistant!(%{tool_calls: [task_tool_call, read_tool_call]})]}
        else
          {:ok, [Message.new_assistant!("Fallback response")]}
        end
      end)

      state = State.new!(%{messages: [Message.new_user!("Research and read")]})

      result = Agent.execute(agent, state)

      # The agent should detect the sub-agent interrupt and return it
      assert {:interrupt, interrupted_state, interrupt_data} = result
      assert interrupt_data.type == :subagent_hitl
      assert interrupt_data.sub_agent_id == "sub-parallel-1"

      # The normal tool's result should also be present in the state messages.
      # After tool execution, a tool result message is added containing results
      # from both tool calls. Look for the read_file result in the messages.
      tool_messages =
        interrupted_state.messages
        |> Enum.filter(&(&1.role == :tool))

      assert length(tool_messages) > 0

      # Find tool results that contain the read_file output
      all_tool_results =
        tool_messages
        |> Enum.flat_map(fn msg -> msg.tool_results || [] end)

      read_file_result =
        Enum.find(all_tool_results, fn tr ->
          tr.name == "read_file"
        end)

      assert read_file_result != nil

      result_content =
        LangChain.Message.ContentPart.content_to_string(read_file_result.content)

      assert result_content =~ "file contents: hello world"
    end

    test "no interrupt when sub-agent completes normally (state has no interrupt_data)" do
      # Verify that normal tool execution (no interrupt_data in state) still works
      normal_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            # Normal completion — no 3-tuple, just {:ok, result}
            {:ok, "Sub-agent completed successfully."}
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [normal_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_normal",
          name: "task",
          arguments: %{"instructions" => "simple task", "subagent_type" => "general-purpose"}
        })

      call_count = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
        else
          {:ok, [Message.new_assistant!("Done!")]}
        end
      end)

      state = State.new!(%{messages: [Message.new_user!("Do a task")]})

      result = Agent.execute(agent, state)

      # Should complete normally, not interrupt
      assert {:ok, final_state} = result
      assert final_state.interrupt_data == nil
    end

    test "resume with subagent_hitl works when parent has empty interrupt_on" do
      # This reproduces the real-world scenario where the bug manifests:
      # - Parent orchestrator has HITL middleware but interrupt_on: %{}
      #   (it doesn't interrupt on "task" — only sub-agents have their own interrupt_on)
      # - Sub-agent triggers an HITL interrupt (e.g., ask_user)
      # - interrupt_data has type: :subagent_hitl with NO parent-level hitl_tool_call_ids
      #
      # BUG: Agent.resume/4 calls process_decisions which extracts
      # hitl_tool_call_ids from the top-level interrupt_data. Since subagent_hitl
      # interrupt_data has no parent-level hitl_tool_call_ids, it defaults to [],
      # and validation fails: "Decision count (1) does not match HITL tool count (0)"

      subagent_task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            # Not called during resume with direct injection
            {:ok, "should not be called on resume"}
          end
        })

      # Empty interrupt_on — parent doesn't interrupt on any tools
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_1",
          name: "task",
          arguments: %{"instructions" => "do work", "subagent_type" => "modeling"}
        })

      # Sub-agent interrupt_data — NO parent-level hitl_tool_call_ids or action_requests.
      # This is what real sub-agent interrupts look like when propagated up.
      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do the work"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-1",
            subagent_type: "modeling",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa",
                  tool_name: "ask_user",
                  arguments: %{"question" => "Is this OK?"}
                }
              ],
              review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
              hitl_tool_call_ids: ["call_sa"]
            }
          }
        })

      # Mock SubAgentServer.resume to return completion
      stub(Sagents.SubAgentServer, :resume, fn _sub_agent_id, _decisions ->
        {:ok, "Sub-agent completed the task successfully."}
      end)

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Great, done.")]}
      end)

      # Without the fix: {:error, "Decision count (1) does not match HITL tool count (0)"}
      # With the fix: {:ok, _final_state}
      result = Agent.resume(agent, interrupted_state, [%{type: :approve}])
      assert {:ok, _final_state} = result
    end

    test "resume with wrong decision count for sub-agent HITL still proceeds (parent skips validation)" do
      # When a sub-agent HITL interrupt has 2 action_requests but the user provides
      # only 1 decision (or 3 decisions), the parent skips process_decisions for
      # subagent_hitl type. The mismatch is between the decisions list and the
      # sub-agent's expectations — the parent doesn't validate this because it
      # calls SubAgentServer.resume directly, forwarding decisions as-is.

      subagent_task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            # Not called during resume with direct injection
            {:ok, "should not be called on resume"}
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_mismatch",
          name: "task",
          arguments: %{"instructions" => "do work", "subagent_type" => "modeling"}
        })

      # Interrupt data with 2 action_requests in the nested sub-agent interrupt_data
      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do the work"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-mismatch",
            subagent_type: "modeling",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa_1",
                  tool_name: "ask_user",
                  arguments: %{"question" => "Q1?"}
                },
                %{
                  tool_call_id: "call_sa_2",
                  tool_name: "write_file",
                  arguments: %{"path" => "/tmp/x"}
                }
              ],
              review_configs: %{
                "ask_user" => %{allowed_decisions: [:approve]},
                "write_file" => %{allowed_decisions: [:approve, :reject]}
              },
              hitl_tool_call_ids: ["call_sa_1", "call_sa_2"]
            }
          }
        })

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Done.")]}
      end)

      # Provide only 1 decision for 2 action_requests — parent doesn't validate this.
      # SubAgentServer.resume receives the decisions directly; the sub-agent is
      # responsible for validating decision count.
      one_decision = [%{type: :approve}]

      expect(Sagents.SubAgentServer, :resume, fn sub_agent_id, received_decisions ->
        assert sub_agent_id == "sub-mismatch"
        assert length(received_decisions) == 1
        {:ok, "Sub-agent completed."}
      end)

      result = Agent.resume(agent, interrupted_state, one_decision)

      # The parent-level resume succeeds because:
      # 1. subagent_hitl type skips process_decisions (no parent-level validation)
      # 2. SubAgentServer.resume is called directly with the decisions
      assert {:ok, _final_state} = result

      # Now test with too many decisions (3 decisions for 2 action_requests)
      three_decisions = [
        %{type: :approve},
        %{type: :reject},
        %{type: :approve}
      ]

      expect(Sagents.SubAgentServer, :resume, fn sub_agent_id, received_decisions ->
        assert sub_agent_id == "sub-mismatch"
        assert length(received_decisions) == 3
        {:ok, "Sub-agent completed."}
      end)

      # Need a fresh agent since Mimic expects are per-call
      {:ok, agent2} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      result2 = Agent.resume(agent2, interrupted_state, three_decisions)

      assert {:ok, _final_state} = result2
    end

    test "resume with subagent_hitl returns error when no assistant message with tool calls exists" do
      # State has interrupt_data with type: :subagent_hitl but no assistant message
      # with tool_calls. The execute_subagent_hitl_resume function searches for the
      # last assistant message with tool_calls and returns an error if none is found.

      subagent_task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context -> {:ok, "done"} end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      # State with interrupt_data but only a user message — no assistant message with tool_calls
      state_no_tool_calls =
        State.new!(%{
          messages: [
            Message.new_user!("Do the work")
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-no-tools",
            subagent_type: "modeling",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa",
                  tool_name: "ask_user",
                  arguments: %{"question" => "OK?"}
                }
              ],
              review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
              hitl_tool_call_ids: ["call_sa"]
            }
          }
        })

      result = Agent.resume(agent, state_no_tool_calls, [%{type: :approve}])
      assert {:error, "No assistant message with tool calls found"} = result

      # Also test with an assistant message that has NO tool_calls (empty list)
      state_empty_tool_calls =
        State.new!(%{
          messages: [
            Message.new_user!("Do the work"),
            Message.new_assistant!("I'll help you with that.")
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-empty-tools",
            subagent_type: "modeling",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa",
                  tool_name: "ask_user",
                  arguments: %{"question" => "OK?"}
                }
              ],
              review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
              hitl_tool_call_ids: ["call_sa"]
            }
          }
        })

      result2 = Agent.resume(agent, state_empty_tool_calls, [%{type: :approve}])
      assert {:error, "No assistant message with tool calls found"} = result2

      # Also test with an assistant message that has tool_calls but none named "task"
      non_task_tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_other",
          name: "read_file",
          arguments: %{"path" => "/tmp/test.txt"}
        })

      state_no_task_tool =
        State.new!(%{
          messages: [
            Message.new_user!("Do the work"),
            Message.new_assistant!(%{tool_calls: [non_task_tool_call]})
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-no-task",
            subagent_type: "researcher",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa",
                  tool_name: "ask_user",
                  arguments: %{"question" => "OK?"}
                }
              ],
              review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
              hitl_tool_call_ids: ["call_sa"]
            }
          }
        })

      result3 = Agent.resume(agent, state_no_task_tool, [%{type: :approve}])
      assert {:error, "No 'task' tool call found in assistant message"} = result3
    end

    test "resume returns error when agent has no HITL middleware configured" do
      # An agent created without any HITL middleware should return a clear error
      # when attempting to resume, because resume/4 requires HumanInTheLoop middleware.

      subagent_task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context -> {:ok, "done"} end
        })

      # Agent with NO middleware at all (replace_default_middleware: true, empty list)
      {:ok, agent_no_middleware} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_no_hitl",
          name: "task",
          arguments: %{"instructions" => "do work", "subagent_type" => "modeling"}
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do the work"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-no-hitl",
            subagent_type: "modeling",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa",
                  tool_name: "ask_user",
                  arguments: %{"question" => "OK?"}
                }
              ],
              review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
              hitl_tool_call_ids: ["call_sa"]
            }
          }
        })

      result = Agent.resume(agent_no_middleware, interrupted_state, [%{type: :approve}])
      assert {:error, "Agent does not have HumanInTheLoop middleware configured"} = result

      # Also test with an agent that has OTHER middleware but not HumanInTheLoop
      {:ok, agent_other_middleware} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [TestMiddleware1]
          },
          replace_default_middleware: true
        )

      result2 = Agent.resume(agent_other_middleware, interrupted_state, [%{type: :approve}])
      assert {:error, "Agent does not have HumanInTheLoop middleware configured"} = result2
    end

    test "resume with nested sub-sub-agent HITL (3-level nesting) routes decisions to level-1 sub-agent" do
      # This test verifies correct behavior when there are 3 levels of nesting:
      #   Parent agent -> Sub-agent (level 1, "researcher") -> Sub-sub-agent (level 2, "analyzer")
      #
      # The innermost sub-sub-agent triggers an HITL interrupt (ask_user). The
      # interrupt_data propagates up through two levels, producing a doubly-nested
      # structure:
      #
      #   %{type: :subagent_hitl,              # outer (level 1)
      #     sub_agent_id: "sub-level1",
      #     subagent_type: "researcher",
      #     interrupt_data: %{
      #       type: :subagent_hitl,             # inner (level 2)
      #       sub_agent_id: "sub-level2",
      #       subagent_type: "analyzer",
      #       interrupt_data: %{                # actual HITL from level 2
      #         action_requests: [...],
      #         ...
      #       }
      #     }}
      #
      # When the parent resumes, execute_subagent_hitl_resume should:
      # 1. Detect type: :subagent_hitl at the top level
      # 2. Call SubAgentServer.resume with the TOP-LEVEL sub_agent_id ("sub-level1")
      # 3. The level-1 sub-agent is then responsible for routing further to level 2

      subagent_task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            # Not called during resume with direct injection
            {:ok, "should not be called on resume"}
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_nested",
          name: "task",
          arguments: %{"instructions" => "research and analyze", "subagent_type" => "researcher"}
        })

      # Build doubly-nested interrupt_data simulating 3-level propagation.
      # Level 2 (innermost) triggered ask_user, which propagated up through
      # level 1 to the parent. Each level wraps the child's interrupt_data
      # in a :subagent_hitl envelope.
      decisions = [%{type: :approve}]

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Research and analyze this topic"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-level1",
            subagent_type: "researcher",
            interrupt_data: %{
              type: :subagent_hitl,
              sub_agent_id: "sub-level2",
              subagent_type: "analyzer",
              interrupt_data: %{
                action_requests: [
                  %{
                    tool_call_id: "call_inner",
                    tool_name: "ask_user",
                    arguments: %{"question" => "Should I proceed with deep analysis?"}
                  }
                ],
                review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
                hitl_tool_call_ids: ["call_inner"]
              }
            }
          }
        })

      # Mock SubAgentServer.resume to verify it's called with the TOP-LEVEL
      # sub-agent ID ("sub-level1"), NOT the inner one ("sub-level2").
      # The level-1 sub-agent is responsible for routing further to level 2.
      expect(Sagents.SubAgentServer, :resume, fn sub_agent_id, received_decisions ->
        assert sub_agent_id == "sub-level1"
        assert received_decisions == decisions
        {:ok, "Sub-agent (level 1) resumed and completed successfully."}
      end)

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Great, the nested sub-agent finished.")]}
      end)

      # Parent resumes. Because interrupt_data.type == :subagent_hitl, the parent
      # skips process_decisions (no parent-level HITL validation) and delegates
      # to execute_subagent_hitl_resume which calls SubAgentServer.resume directly.
      result = Agent.resume(agent, interrupted_state, decisions)

      # Resume should succeed
      assert {:ok, _final_state} = result
    end

    test "parent passes decisions through unvalidated for subagent_hitl, sub-agent validates" do
      # This test verifies the decision validation boundary:
      # 1. The parent does NOT validate decisions for subagent_hitl — even empty
      #    lists or unusual decision types pass through without error.
      # 2. The parent delegates validation responsibility to the sub-agent by
      #    forwarding decisions unmodified via SubAgentServer.resume.

      subagent_task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            # Not called during resume with direct injection
            {:ok, "should not be called on resume"}
          end
        })

      tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_val_1",
          name: "task",
          arguments: %{"instructions" => "validate work", "subagent_type" => "validator"}
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Validate something"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-val-1",
            subagent_type: "validator",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa_v",
                  tool_name: "ask_user",
                  arguments: %{"question" => "Approve?"}
                }
              ],
              review_configs: %{"ask_user" => %{allowed_decisions: [:approve, :reject]}},
              hitl_tool_call_ids: ["call_sa_v"]
            }
          }
        })

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Completed.")]}
      end)

      # --- Scenario 1: empty decisions list [] ---
      # Pass an empty decisions list — parent should NOT reject this.
      # In a normal (non-subagent) HITL resume, empty decisions would fail
      # process_decisions validation. But for subagent_hitl, the parent skips
      # process_decisions entirely and calls SubAgentServer.resume directly.
      expect(Sagents.SubAgentServer, :resume, fn sub_agent_id, received_decisions ->
        assert sub_agent_id == "sub-val-1"
        assert received_decisions == []
        {:ok, "Sub-agent completed."}
      end)

      {:ok, agent_empty} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      result_empty = Agent.resume(agent_empty, interrupted_state, [])
      assert {:ok, _final_state} = result_empty

      # --- Scenario 2: decisions with unusual/custom types ---
      # Pass decisions with unusual types that the parent doesn't understand.
      # A normal HITL resume might reject these, but subagent_hitl skips
      # parent-level validation entirely and forwards to SubAgentServer.resume.
      custom_decisions = [
        %{type: :custom_action, payload: "some_data"},
        %{type: :escalate, reason: "needs manager approval"}
      ]

      expect(Sagents.SubAgentServer, :resume, fn sub_agent_id, received_decisions ->
        assert sub_agent_id == "sub-val-1"
        assert received_decisions == custom_decisions

        # Confirm the decisions were not altered — each decision retains
        # its original keys and values
        [first_decision, second_decision] = received_decisions
        assert first_decision.type == :custom_action
        assert first_decision.payload == "some_data"
        assert second_decision.type == :escalate
        assert second_decision.reason == "needs manager approval"

        {:ok, "Sub-agent completed."}
      end)

      {:ok, agent_custom} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [subagent_task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      result_custom = Agent.resume(agent_custom, interrupted_state, custom_decisions)
      assert {:ok, _final_state} = result_custom
    end

    test "direct injection: resume does NOT re-execute sibling tools" do
      # This test creates a state where the LLM had called TWO tools:
      # "task" (which interrupted for HITL) and "side_effect_tool" (which completed).
      # On resume, the side_effect_tool must NOT be re-executed.

      side_effect_counter = :counters.new(1, [:atomics])

      side_effect_tool =
        LangChain.Function.new!(%{
          name: "side_effect_tool",
          description: "A tool with side effects that should only run once",
          function: fn _args, _context ->
            :counters.add(side_effect_counter, 1, 1)
            {:ok, "side effect executed"}
          end
        })

      task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            {:ok, "should not be called on resume"}
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [task_tool, side_effect_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      task_tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_task_sibling",
          name: "task",
          arguments: %{"instructions" => "do research", "subagent_type" => "researcher"}
        })

      sibling_tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_side_effect",
          name: "side_effect_tool",
          arguments: %{}
        })

      sibling_tool_result_msg =
        Message.new_tool_result!(%{
          tool_results: [
            LangChain.Message.ToolResult.new!(%{
              tool_call_id: "tc_side_effect",
              name: "side_effect_tool",
              content: "side effect executed"
            })
          ]
        })

      # Build interrupted state: assistant made both tool calls,
      # sibling completed, task tool interrupted.
      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do research and run side effect"),
            Message.new_assistant!(%{tool_calls: [task_tool_call, sibling_tool_call]}),
            sibling_tool_result_msg
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-sibling-test",
            subagent_type: "researcher",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "call_sa_sibling",
                  tool_name: "ask_user",
                  arguments: %{"question" => "Proceed with research?"}
                }
              ],
              review_configs: %{
                "ask_user" => %{allowed_decisions: [:approve, :reject]}
              },
              hitl_tool_call_ids: ["call_sa_sibling"]
            }
          }
        })

      # Mock SubAgentServer.resume to return completion
      stub(Sagents.SubAgentServer, :resume, fn _sub_agent_id, _decisions ->
        {:ok, "sub-agent completed after resume"}
      end)

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Great, everything is done.")]}
      end)

      result = Agent.resume(agent, interrupted_state, [%{type: :approve}])

      assert {:ok, final_state} = result

      # CRITICAL: side_effect_tool must NOT have been re-executed
      assert :counters.get(side_effect_counter, 1) == 0,
             "side_effect_tool was re-executed during resume (counter: #{:counters.get(side_effect_counter, 1)})"

      # No duplicate tool_results
      all_tool_results =
        final_state.messages
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.flat_map(fn msg -> msg.tool_results || [] end)

      tool_call_ids = Enum.map(all_tool_results, & &1.tool_call_id)
      assert tool_call_ids == Enum.uniq(tool_call_ids)

      assert final_state.interrupt_data == nil
    end

    test "direct injection: multi-cycle resume clears interrupt_data and has no duplicates" do
      # Exercises: execute -> interrupt -> resume -> interrupt -> resume -> complete
      resume_call_counter = :counters.new(1, [:atomics])

      stub(Sagents.SubAgentServer, :resume, fn _sub_agent_id, _decisions ->
        :counters.add(resume_call_counter, 1, 1)
        count = :counters.get(resume_call_counter, 1)

        if count == 1 do
          {:interrupt,
           %{
             action_requests: [
               %{
                 tool_call_id: "call_q2",
                 tool_name: "ask_user",
                 arguments: %{"question" => "Second question?"}
               }
             ],
             review_configs: %{
               "ask_user" => %{allowed_decisions: [:approve, :reject]}
             },
             hitl_tool_call_ids: ["call_q2"]
           }}
        else
          {:ok, "final result from sub-agent"}
        end
      end)

      task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            {:ok, "SubAgent paused — awaiting user input.",
             %State{
               interrupt_data: %{
                 type: :subagent_hitl,
                 sub_agent_id: "sub-multicycle",
                 subagent_type: "researcher",
                 interrupt_data: %{
                   action_requests: [
                     %{
                       tool_call_id: "call_q1",
                       tool_name: "ask_user",
                       arguments: %{"question" => "First question?"}
                     }
                   ],
                   review_configs: %{
                     "ask_user" => %{allowed_decisions: [:approve, :reject]}
                   },
                   hitl_tool_call_ids: ["call_q1"]
                 }
               }
             }}
          end
        })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      task_tool_call =
        LangChain.Message.ToolCall.new!(%{
          call_id: "tc_multicycle",
          name: "task",
          arguments: %{"instructions" => "multi-step research", "subagent_type" => "researcher"}
        })

      llm_call_counter = :counters.new(1, [:atomics])

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        :counters.add(llm_call_counter, 1, 1)
        count = :counters.get(llm_call_counter, 1)

        if count == 1 do
          {:ok, [Message.new_assistant!(%{tool_calls: [task_tool_call]})]}
        else
          {:ok, [Message.new_assistant!("All done, sub-agent completed.")]}
        end
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Do multi-step research")]})

      # Step 1: Initial execution -> first interrupt
      result1 = Agent.execute(agent, initial_state)
      assert {:interrupt, state_after_int1, interrupt_data_1} = result1
      assert interrupt_data_1.type == :subagent_hitl
      assert interrupt_data_1.sub_agent_id == "sub-multicycle"

      # No duplicate tool_results after first interrupt
      tc_ids_1 =
        state_after_int1.messages
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.flat_map(fn msg -> msg.tool_results || [] end)
        |> Enum.map(& &1.tool_call_id)

      assert tc_ids_1 == Enum.uniq(tc_ids_1)

      # Step 2: First resume -> second interrupt
      result2 = Agent.resume(agent, state_after_int1, [%{type: :approve}])
      assert {:interrupt, state_after_int2, interrupt_data_2} = result2
      assert interrupt_data_2.type == :subagent_hitl

      assert :counters.get(resume_call_counter, 1) >= 1

      tc_ids_2 =
        state_after_int2.messages
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.flat_map(fn msg -> msg.tool_results || [] end)
        |> Enum.map(& &1.tool_call_id)

      assert tc_ids_2 == Enum.uniq(tc_ids_2)

      # Step 3: Second resume -> completion
      result3 = Agent.resume(agent, state_after_int2, [%{type: :approve}])
      assert {:ok, final_state} = result3

      assert :counters.get(resume_call_counter, 1) == 2

      final_tc_ids =
        final_state.messages
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.flat_map(fn msg -> msg.tool_results || [] end)
        |> Enum.map(& &1.tool_call_id)

      assert final_tc_ids == Enum.uniq(final_tc_ids)
      assert final_state.interrupt_data == nil
    end
  end
end
