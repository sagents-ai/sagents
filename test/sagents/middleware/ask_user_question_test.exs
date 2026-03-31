defmodule Sagents.Middleware.AskUserQuestionTest do
  use ExUnit.Case, async: true

  alias Sagents.Middleware.AskUserQuestion
  alias Sagents.Middleware
  alias Sagents.State
  alias Sagents.Agent

  # ToolResult.content may be a string or a list of ContentParts
  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{content: text} -> text
      text when is_binary(text) -> text
    end)
  end

  describe "init/1" do
    test "defaults to all response types" do
      {:ok, config} = AskUserQuestion.init([])
      assert config.response_types == [:single_select, :multi_select, :freeform]
    end

    test "accepts restricted response types" do
      {:ok, config} = AskUserQuestion.init(response_types: [:single_select])
      assert config.response_types == [:single_select]
    end

    test "returns error for invalid response types" do
      assert {:error, msg} = AskUserQuestion.init(response_types: [:invalid_type])
      assert msg =~ "Invalid response types"
    end
  end

  describe "system_prompt/1" do
    test "includes only enabled response types" do
      {:ok, config} = AskUserQuestion.init(response_types: [:single_select, :multi_select])
      prompt = AskUserQuestion.system_prompt(config)

      assert prompt =~ "single_select"
      assert prompt =~ "multi_select"
      refute prompt =~ "freeform"
    end

    test "includes all types when all enabled" do
      {:ok, config} = AskUserQuestion.init([])
      prompt = AskUserQuestion.system_prompt(config)

      assert prompt =~ "single_select"
      assert prompt =~ "multi_select"
      assert prompt =~ "freeform"
    end
  end

  describe "tools/1" do
    test "returns single ask_user function" do
      {:ok, config} = AskUserQuestion.init([])
      tools = AskUserQuestion.tools(config)

      assert length(tools) == 1
      assert hd(tools).name == "ask_user"
    end

    test "tool schema response_type enum matches enabled types" do
      {:ok, config} = AskUserQuestion.init(response_types: [:single_select, :freeform])
      [tool] = AskUserQuestion.tools(config)

      enum = tool.parameters_schema.properties.response_type.enum
      assert enum == ["single_select", "freeform"]
    end
  end

  describe "tool execution - valid questions" do
    setup do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)
      %{tool: tool, config: config}
    end

    test "valid single_select returns interrupt", %{tool: tool} do
      args = %{
        "question" => "Which database?",
        "response_type" => "single_select",
        "options" => [
          %{"label" => "PostgreSQL", "value" => "postgresql"},
          %{"label" => "MongoDB", "value" => "mongodb"}
        ]
      }

      assert {:interrupt, "Waiting for user response...", question_data} =
               tool.function.(args, %{})

      assert question_data.type == :ask_user_question
      assert question_data.question == "Which database?"
      assert question_data.response_type == :single_select
      assert length(question_data.options) == 2
      assert question_data.allow_cancel == true
      assert question_data.allow_other == false
    end

    test "valid multi_select returns interrupt", %{tool: tool} do
      args = %{
        "question" => "Which features?",
        "response_type" => "multi_select",
        "options" => [
          %{"label" => "Auth", "value" => "auth"},
          %{"label" => "Logging", "value" => "logging"},
          %{"label" => "Caching", "value" => "caching"}
        ]
      }

      assert {:interrupt, _, question_data} = tool.function.(args, %{})
      assert question_data.response_type == :multi_select
    end

    test "valid freeform returns interrupt (no options)", %{tool: tool} do
      args = %{
        "question" => "What should we call this service?",
        "response_type" => "freeform"
      }

      assert {:interrupt, _, question_data} = tool.function.(args, %{})
      assert question_data.response_type == :freeform
      assert question_data.options == []
    end

    test "options with descriptions are preserved", %{tool: tool} do
      args = %{
        "question" => "Which database?",
        "response_type" => "single_select",
        "options" => [
          %{"label" => "PostgreSQL", "value" => "pg", "description" => "Relational"},
          %{"label" => "MongoDB", "value" => "mongo", "description" => "Document store"}
        ]
      }

      assert {:interrupt, _, question_data} = tool.function.(args, %{})
      assert hd(question_data.options).description == "Relational"
    end

    test "allow_other and allow_cancel are respected", %{tool: tool} do
      args = %{
        "question" => "Pick one",
        "response_type" => "single_select",
        "options" => [
          %{"label" => "A", "value" => "a"},
          %{"label" => "B", "value" => "b"}
        ],
        "allow_other" => true,
        "allow_cancel" => false
      }

      assert {:interrupt, _, question_data} = tool.function.(args, %{})
      assert question_data.allow_other == true
      assert question_data.allow_cancel == false
    end
  end

  describe "tool execution - validation errors" do
    setup do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)
      %{tool: tool}
    end

    test "missing question returns error", %{tool: tool} do
      args = %{"response_type" => "single_select", "options" => []}
      assert {:error, msg} = tool.function.(args, %{})
      assert msg =~ "question"
    end

    test "empty question returns error", %{tool: tool} do
      args = %{"question" => "", "response_type" => "single_select"}
      assert {:error, _} = tool.function.(args, %{})
    end

    test "invalid response_type returns error", %{tool: tool} do
      args = %{"question" => "Q?", "response_type" => "invalid"}
      assert {:error, msg} = tool.function.(args, %{})
      assert msg =~ "Invalid response_type"
    end

    test "disabled response_type returns error" do
      {:ok, config} = AskUserQuestion.init(response_types: [:single_select])
      [tool] = AskUserQuestion.tools(config)

      args = %{
        "question" => "Q?",
        "response_type" => "freeform"
      }

      assert {:error, msg} = tool.function.(args, %{})
      assert msg =~ "not enabled"
    end

    test "single_select with < 2 options returns error", %{tool: tool} do
      args = %{
        "question" => "Q?",
        "response_type" => "single_select",
        "options" => [%{"label" => "Only one", "value" => "one"}]
      }

      assert {:error, msg} = tool.function.(args, %{})
      assert msg =~ "at least 2"
    end

    test "single_select with > 10 options returns error", %{tool: tool} do
      options = Enum.map(1..11, &%{"label" => "Opt #{&1}", "value" => "opt_#{&1}"})

      args = %{
        "question" => "Q?",
        "response_type" => "single_select",
        "options" => options
      }

      assert {:error, msg} = tool.function.(args, %{})
      assert msg =~ "at most 10"
    end

    test "options with duplicate values returns error", %{tool: tool} do
      args = %{
        "question" => "Q?",
        "response_type" => "single_select",
        "options" => [
          %{"label" => "A", "value" => "same"},
          %{"label" => "B", "value" => "same"}
        ]
      }

      assert {:error, msg} = tool.function.(args, %{})
      assert msg =~ "Duplicate"
    end

    test "options with empty label returns error", %{tool: tool} do
      args = %{
        "question" => "Q?",
        "response_type" => "single_select",
        "options" => [
          %{"label" => "", "value" => "a"},
          %{"label" => "B", "value" => "b"}
        ]
      }

      assert {:error, _} = tool.function.(args, %{})
    end

    test "freeform with options returns error", %{tool: tool} do
      args = %{
        "question" => "Q?",
        "response_type" => "freeform",
        "options" => [%{"label" => "A", "value" => "a"}, %{"label" => "B", "value" => "b"}]
      }

      assert {:error, msg} = tool.function.(args, %{})
      assert msg =~ "must not have options"
    end
  end

  describe "process_response/2" do
    test "valid single_select answer formats correctly" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [
          %{label: "PostgreSQL", value: "postgresql"},
          %{label: "MongoDB", value: "mongodb"}
        ],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, selected: ["postgresql"]}
      assert {:ok, text} = AskUserQuestion.process_response(response, question_data)
      assert text == "User selected: postgresql"
    end

    test "single_select with other_text" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, selected: ["a"], other_text: "Use jsonb columns"}
      assert {:ok, text} = AskUserQuestion.process_response(response, question_data)
      assert text =~ "User selected: a"
      assert text =~ "Additional input: \"Use jsonb columns\""
    end

    test "valid multi_select answer formats correctly" do
      question_data = %{
        type: :ask_user_question,
        response_type: :multi_select,
        options: [
          %{label: "PostgreSQL", value: "postgresql"},
          %{label: "Redis", value: "redis"}
        ],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, selected: ["postgresql", "redis"]}
      assert {:ok, text} = AskUserQuestion.process_response(response, question_data)
      assert text == "User selected: postgresql, redis"
    end

    test "valid freeform answer formats correctly" do
      question_data = %{
        type: :ask_user_question,
        response_type: :freeform,
        options: [],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, other_text: "Call it UserProfileCache"}
      assert {:ok, text} = AskUserQuestion.process_response(response, question_data)
      assert text == "User responded: \"Call it UserProfileCache\""
    end

    test "cancel when allowed" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :cancel}
      assert {:ok, text} = AskUserQuestion.process_response(response, question_data)
      assert text =~ "cancelled"
    end

    test "cancel when not allowed returns error" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: false
      }

      response = %{type: :cancel}
      assert {:error, msg} = AskUserQuestion.process_response(response, question_data)
      assert msg =~ "not allowed"
    end

    test "single_select with multiple selections returns error" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, selected: ["a", "b"]}
      assert {:error, msg} = AskUserQuestion.process_response(response, question_data)
      assert msg =~ "exactly one"
    end

    test "multi_select with zero selections returns error" do
      question_data = %{
        type: :ask_user_question,
        response_type: :multi_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, selected: []}
      assert {:error, msg} = AskUserQuestion.process_response(response, question_data)
      assert msg =~ "at least one"
    end

    test "selected value not in options returns error" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, selected: ["c"]}
      assert {:error, msg} = AskUserQuestion.process_response(response, question_data)
      assert msg =~ "not a valid option"
    end

    test "'other' selected without allow_other returns error" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, selected: ["other"]}
      assert {:error, msg} = AskUserQuestion.process_response(response, question_data)
      assert msg =~ "not allowed"
    end

    test "'other' as a regular option value succeeds even when allow_other is false" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [
          %{label: "A", value: "a"},
          %{label: "Something else", value: "other"}
        ],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, selected: ["other"]}
      assert {:ok, text} = AskUserQuestion.process_response(response, question_data)
      assert text =~ "other"
    end

    test "'other' selected with allow_other succeeds" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: true,
        allow_cancel: true
      }

      response = %{type: :answer, selected: ["other"], other_text: "Custom choice"}
      assert {:ok, text} = AskUserQuestion.process_response(response, question_data)
      assert text =~ "other"
    end

    test "freeform with empty other_text returns error" do
      question_data = %{
        type: :ask_user_question,
        response_type: :freeform,
        options: [],
        allow_other: false,
        allow_cancel: true
      }

      response = %{type: :answer, other_text: ""}
      assert {:error, _} = AskUserQuestion.process_response(response, question_data)
    end

    test "invalid response format returns error" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true
      }

      assert {:error, _} = AskUserQuestion.process_response(%{invalid: true}, question_data)
    end
  end

  describe "handle_resume/4" do
    setup do
      {:ok, config} = AskUserQuestion.init([])

      question_data = %{
        type: :ask_user_question,
        question: "Which database?",
        response_type: :single_select,
        options: [
          %{label: "PostgreSQL", value: "postgresql"},
          %{label: "MongoDB", value: "mongodb"}
        ],
        allow_other: false,
        allow_cancel: true,
        context: nil,
        tool_call_id: "call_123"
      }

      # Build a state that already has the interrupt placeholder tool result
      # (this is what LLMChain creates when the tool returns {:interrupt, ...})
      interrupt_tool_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_123",
          content: "Waiting for user response...",
          name: "ask_user",
          is_interrupt: true
        })

      tool_msg =
        LangChain.Message.new_tool_result!(%{
          content: nil,
          tool_results: [interrupt_tool_result]
        })

      state =
        State.new!(%{
          messages: [tool_msg],
          interrupt_data: question_data
        })

      %{config: config, state: state, question_data: question_data}
    end

    test "valid answer returns {:ok, state} with replaced tool result", %{
      config: config,
      state: state
    } do
      response = %{type: :answer, selected: ["postgresql"]}

      assert {:ok, updated_state} =
               AskUserQuestion.handle_resume(nil, state, response, config, [])

      # The interrupt placeholder should be replaced, not a new message added
      assert length(updated_state.messages) == 1
      last_msg = List.last(updated_state.messages)
      assert last_msg.role == :tool
      [tool_result] = last_msg.tool_results
      assert tool_result.tool_call_id == "call_123"
      assert content_text(tool_result.content) =~ "postgresql"
      refute tool_result.is_interrupt
    end

    test "cancel response returns {:ok, state} with cancellation message", %{
      config: config,
      state: state
    } do
      response = %{type: :cancel}

      assert {:ok, updated_state} =
               AskUserQuestion.handle_resume(nil, state, response, config, [])

      last_msg = List.last(updated_state.messages)
      [tool_result] = last_msg.tool_results
      assert content_text(tool_result.content) =~ "cancelled"
      refute tool_result.is_interrupt
    end

    test "returns {:cont, state} for non-ask_user interrupts", %{config: config} do
      state = State.new!(%{interrupt_data: %{action_requests: []}})

      assert {:cont, ^state} =
               AskUserQuestion.handle_resume(nil, state, %{type: :answer}, config, [])
    end

    test "invalid response returns error", %{config: config, state: state} do
      response = %{type: :answer, selected: ["nonexistent"]}

      assert {:error, _} =
               AskUserQuestion.handle_resume(nil, state, response, config, [])
    end
  end

  describe "middleware integration" do
    test "can be initialized via Middleware.init_middleware/1" do
      entry = Middleware.init_middleware(AskUserQuestion)
      assert entry.module == AskUserQuestion
      assert entry.config.response_types == [:single_select, :multi_select, :freeform]
    end

    test "can be initialized with options" do
      entry =
        Middleware.init_middleware({AskUserQuestion, response_types: [:single_select]})

      assert entry.config.response_types == [:single_select]
    end

    test "system prompt is returned via Middleware.get_system_prompt/1" do
      entry = Middleware.init_middleware(AskUserQuestion)
      prompt = Middleware.get_system_prompt(entry)
      assert prompt =~ "ask_user"
    end

    test "tools are returned via Middleware.get_tools/1" do
      entry = Middleware.init_middleware(AskUserQuestion)
      tools = Middleware.get_tools(entry)
      assert length(tools) == 1
      assert hd(tools).name == "ask_user"
    end
  end

  describe "generic resume dispatch" do
    test "middleware without handle_resume passes through" do
      # TodoList doesn't implement handle_resume
      entry = Middleware.init_middleware(Sagents.Middleware.TodoList)
      state = State.new!()

      assert {:cont, ^state} =
               Middleware.apply_handle_resume(nil, state, %{}, entry)
    end

    test "AskUserQuestion claims its own interrupt type" do
      entry = Middleware.init_middleware(AskUserQuestion)

      question_data = %{
        type: :ask_user_question,
        question: "Q?",
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true,
        tool_call_id: "call_1"
      }

      # Include the interrupt placeholder tool result
      interrupt_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_1",
          content: "Waiting for user response...",
          name: "ask_user",
          is_interrupt: true
        })

      tool_msg =
        LangChain.Message.new_tool_result!(%{
          content: nil,
          tool_results: [interrupt_result]
        })

      state = State.new!(%{messages: [tool_msg], interrupt_data: question_data})
      response = %{type: :answer, selected: ["a"]}

      assert {:ok, _updated} =
               Middleware.apply_handle_resume(nil, state, response, entry)
    end

    test "no middleware claims unknown interrupt returns error" do
      {:ok, agent} =
        Agent.new(%{
          model: LangChain.ChatModels.ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"})
        })

      state = State.new!(%{interrupt_data: %{type: :completely_unknown}})

      assert {:error, "No middleware handled the resume for this interrupt"} =
               Agent.resume(agent, state, %{})
    end
  end

  describe "multiple_interrupts handling" do
    setup do
      {:ok, config} = AskUserQuestion.init([])

      q1 = %{
        type: :ask_user_question,
        question: "Question 1?",
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true,
        context: nil,
        tool_call_id: "call_1"
      }

      q2 = %{
        type: :ask_user_question,
        question: "Question 2?",
        response_type: :single_select,
        options: [%{label: "X", value: "x"}, %{label: "Y", value: "y"}],
        allow_other: false,
        allow_cancel: true,
        context: nil,
        tool_call_id: "call_2"
      }

      # Build state with two interrupt placeholder tool results
      interrupt_result_1 =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_1",
          content: "Waiting for user response...",
          name: "ask_user",
          is_interrupt: true
        })

      interrupt_result_2 =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_2",
          content: "Waiting for user response...",
          name: "ask_user",
          is_interrupt: true
        })

      tool_msg =
        LangChain.Message.new_tool_result!(%{
          content: nil,
          tool_results: [interrupt_result_1, interrupt_result_2]
        })

      multiple_interrupt = %{
        type: :multiple_interrupts,
        interrupts: [q1, q2]
      }

      state = State.new!(%{messages: [tool_msg], interrupt_data: multiple_interrupt})

      %{config: config, state: state, q1: q1, q2: q2}
    end

    test "handles multiple ask_user questions with list of responses", %{
      config: config,
      state: state
    } do
      responses = [
        %{type: :answer, selected: ["a"], tool_call_id: "call_1"},
        %{type: :answer, selected: ["x"], tool_call_id: "call_2"}
      ]

      assert {:ok, updated_state} =
               AskUserQuestion.handle_resume(nil, state, responses, config, [])

      # Both tool results should be replaced
      tool_msg = List.last(updated_state.messages)
      assert length(tool_msg.tool_results) == 2

      result_1 = Enum.find(tool_msg.tool_results, &(&1.tool_call_id == "call_1"))
      result_2 = Enum.find(tool_msg.tool_results, &(&1.tool_call_id == "call_2"))

      refute result_1.is_interrupt
      refute result_2.is_interrupt
      assert content_text(result_1.content) =~ "a"
      assert content_text(result_2.content) =~ "x"
    end

    test "returns error when response missing for a question", %{
      config: config,
      state: state
    } do
      # Only provide response for call_1, not call_2
      responses = [
        %{type: :answer, selected: ["a"], tool_call_id: "call_1"}
      ]

      assert {:error, msg} =
               AskUserQuestion.handle_resume(nil, state, responses, config, [])

      assert msg =~ "Missing response"
      assert msg =~ "call_2"
    end

    test "returns error when one response is invalid", %{
      config: config,
      state: state
    } do
      responses = [
        %{type: :answer, selected: ["a"], tool_call_id: "call_1"},
        %{type: :answer, selected: ["invalid_value"], tool_call_id: "call_2"}
      ]

      assert {:error, msg} =
               AskUserQuestion.handle_resume(nil, state, responses, config, [])

      assert msg =~ "not a valid option"
    end

    test "passes through when not all interrupts are ask_user", %{config: config} do
      mixed_interrupt = %{
        type: :multiple_interrupts,
        interrupts: [
          %{type: :ask_user_question, tool_call_id: "call_1"},
          %{type: :subagent_hitl, tool_call_id: "call_2"}
        ]
      }

      state = State.new!(%{interrupt_data: mixed_interrupt})

      assert {:cont, ^state} =
               AskUserQuestion.handle_resume(nil, state, [], config, [])
    end

    test "handles cancel in multi-question response", %{config: config, state: state} do
      responses = [
        %{type: :answer, selected: ["a"], tool_call_id: "call_1"},
        %{type: :cancel, tool_call_id: "call_2"}
      ]

      assert {:ok, updated_state} =
               AskUserQuestion.handle_resume(nil, state, responses, config, [])

      tool_msg = List.last(updated_state.messages)
      result_2 = Enum.find(tool_msg.tool_results, &(&1.tool_call_id == "call_2"))
      assert content_text(result_2.content) =~ "cancelled"
    end
  end
end
