defmodule Sagents.Middleware.AskUserQuestionTest do
  use ExUnit.Case, async: true

  alias Sagents.Middleware.AskUserQuestion
  alias Sagents.Middleware
  alias Sagents.State
  alias Sagents.Agent

  # Answered tool results carry a list of ContentParts. There is deliberately
  # no clause for a bare string: chat model encoders reject one, so a string
  # reaching here fails every test that reads the result.
  defp content_text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{content: text} -> text
      text when is_binary(text) -> text
    end)
  end

  defp single_select_args(extra) do
    Map.merge(
      %{
        "question" => "Which database?",
        "response_type" => "single_select",
        "options" => [
          %{"label" => "PostgreSQL", "value" => "postgresql"},
          %{"label" => "MongoDB", "value" => "mongodb"}
        ]
      },
      extra
    )
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

    test "forced flags default to nil" do
      {:ok, config} = AskUserQuestion.init([])
      assert config.forced_allow_cancel == nil
      assert config.forced_allow_other == nil
    end

    test "forces allow_cancel when a boolean is given" do
      {:ok, config} = AskUserQuestion.init(allow_cancel: false)
      assert config.forced_allow_cancel == false
      assert config.forced_allow_other == nil
    end

    test "forces allow_other when a boolean is given" do
      {:ok, config} = AskUserQuestion.init(allow_other: true)
      assert config.forced_allow_other == true
      assert config.forced_allow_cancel == nil
    end

    test "returns error when allow_cancel is not a boolean" do
      assert {:error, msg} = AskUserQuestion.init(allow_cancel: "yes")
      assert msg =~ "allow_cancel must be a boolean"
    end

    test "returns error when allow_other is not a boolean" do
      assert {:error, msg} = AskUserQuestion.init(allow_other: 1)
      assert msg =~ "allow_other must be a boolean"
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

    test "includes allow_cancel guidance when not forced" do
      {:ok, config} = AskUserQuestion.init([])
      assert AskUserQuestion.system_prompt(config) =~ "Set allow_cancel"
    end

    test "omits allow_cancel guidance when forced" do
      {:ok, config} = AskUserQuestion.init(allow_cancel: false)
      refute AskUserQuestion.system_prompt(config) =~ "Set allow_cancel"
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

    test "exposes both flags in schema when neither is forced" do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)

      props = tool.parameters_schema.properties
      assert Map.has_key?(props, :allow_other)
      assert Map.has_key?(props, :allow_cancel)
    end

    test "omits allow_cancel from schema when forced" do
      {:ok, config} = AskUserQuestion.init(allow_cancel: false)
      [tool] = AskUserQuestion.tools(config)

      props = tool.parameters_schema.properties
      refute Map.has_key?(props, :allow_cancel)
      assert Map.has_key?(props, :allow_other)
    end

    test "omits allow_other from schema when forced" do
      {:ok, config} = AskUserQuestion.init(allow_other: true)
      [tool] = AskUserQuestion.tools(config)

      props = tool.parameters_schema.properties
      refute Map.has_key?(props, :allow_other)
      assert Map.has_key?(props, :allow_cancel)
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

      assert {:interrupt, _msg, question_data} = tool.function.(args, %{})
      assert question_data.response_type == :multi_select
    end

    test "valid freeform returns interrupt (no options)", %{tool: tool} do
      args = %{
        "question" => "What should we call this service?",
        "response_type" => "freeform"
      }

      assert {:interrupt, _msg, question_data} = tool.function.(args, %{})
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

      assert {:interrupt, _msg, question_data} = tool.function.(args, %{})
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

      assert {:interrupt, _msg, question_data} = tool.function.(args, %{})
      assert question_data.allow_other == true
      assert question_data.allow_cancel == false
    end
  end

  # These tests build config inline (the shared setup uses default config) so
  # each can force a specific flag.
  describe "tool execution - forced flags" do
    test "forced allow_cancel overrides the LLM-provided arg" do
      {:ok, config} = AskUserQuestion.init(allow_cancel: false)
      [tool] = AskUserQuestion.tools(config)

      # LLM tries to set true; the forced false must win.
      args = single_select_args(%{"allow_cancel" => true})

      assert {:interrupt, _msg, question_data} = tool.function.(args, %{})
      assert question_data.allow_cancel == false
    end

    test "forced allow_other overrides the LLM-provided arg" do
      {:ok, config} = AskUserQuestion.init(allow_other: true)
      [tool] = AskUserQuestion.tools(config)

      args = single_select_args(%{"allow_other" => false})

      assert {:interrupt, _msg, question_data} = tool.function.(args, %{})
      assert question_data.allow_other == true
    end

    test "uses LLM-provided flags when neither is forced" do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)

      args = single_select_args(%{"allow_cancel" => false, "allow_other" => true})

      assert {:interrupt, _msg, question_data} = tool.function.(args, %{})
      assert question_data.allow_cancel == false
      assert question_data.allow_other == true
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
      assert {:error, _reason} = tool.function.(args, %{})
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

      assert {:error, _reason} = tool.function.(args, %{})
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
      assert text == "User selected:\n- postgresql\n- redis"
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
      assert {:error, _reason} = AskUserQuestion.process_response(response, question_data)
    end

    test "invalid response format returns error" do
      question_data = %{
        type: :ask_user_question,
        response_type: :single_select,
        options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}],
        allow_other: false,
        allow_cancel: true
      }

      assert {:error, _reason} = AskUserQuestion.process_response(%{invalid: true}, question_data)
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

    test "the answer is content parts, which every chat model can encode", %{
      config: config,
      state: state
    } do
      response = %{type: :answer, selected: ["postgresql"]}

      assert {:ok, updated_state} =
               AskUserQuestion.handle_resume(nil, state, response, config, [])

      [tool_result] = List.last(updated_state.messages).tool_results
      assert [%LangChain.Message.ContentPart{type: :text}] = tool_result.content

      # The Chat Completions encoder accepts only content parts. A bare string
      # here raises a FunctionClauseError when the conversation is next sent.
      message = List.last(updated_state.messages)

      assert [%{"role" => :tool, "content" => [%{"type" => "text"}]}] =
               LangChain.ChatModels.ChatCompletionsFormat.messages_for_api([message], [])
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

    test "the answered result keeps the placeholder's name and display text", %{
      config: config,
      question_data: question_data
    } do
      # The interrupt map has no tool name; the placeholder is the only record
      # of which tool asked.
      placeholder =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_123",
          content: "Waiting for user response...",
          name: "request_user_choice",
          display_text: "Choosing",
          is_interrupt: true,
          interrupt_data: question_data
        })

      state =
        State.new!(%{
          messages: [
            LangChain.Message.new_tool_result!(%{content: nil, tool_results: [placeholder]})
          ],
          interrupt_data: question_data
        })

      response = %{type: :answer, selected: ["postgresql"]}

      assert {:ok, updated_state} =
               AskUserQuestion.handle_resume(nil, state, response, config, [])

      assert [%{tool_results: [tool_result]}] = updated_state.messages
      assert tool_result.name == "request_user_choice"
      assert tool_result.display_text == "Choosing"
      assert tool_result.is_interrupt == false
      assert tool_result.interrupt_data == nil
      assert content_text(tool_result.content) =~ "postgresql"

      assert tool_result.processed_content == %{
               type: :answer,
               selected: [%{label: "PostgreSQL", value: "postgresql"}],
               other_text: nil
             }
    end

    test "each answered result of a multiple interrupt keeps its own placeholder's name", %{
      config: config,
      question_data: question_data
    } do
      q1 = %{question_data | tool_call_id: "call_a"}
      q2 = %{question_data | tool_call_id: "call_b"}

      placeholders =
        Enum.map([{"call_a", "ask_user", q1}, {"call_b", "request_user_choice", q2}], fn
          {id, name, data} ->
            LangChain.Message.ToolResult.new!(%{
              tool_call_id: id,
              content: "Waiting for user response...",
              name: name,
              is_interrupt: true,
              interrupt_data: data
            })
        end)

      state =
        State.new!(%{
          messages: [
            LangChain.Message.new_tool_result!(%{content: nil, tool_results: placeholders})
          ],
          interrupt_data: %{type: :multiple_interrupts, interrupts: [q1, q2]}
        })

      responses = [
        %{tool_call_id: "call_a", type: :answer, selected: ["postgresql"]},
        %{tool_call_id: "call_b", type: :answer, selected: ["mongodb"]}
      ]

      assert {:ok, updated_state} =
               AskUserQuestion.handle_resume(nil, state, responses, config, [])

      assert [%{tool_results: [first, second]}] = updated_state.messages
      assert %{name: "ask_user", is_interrupt: false} = first
      assert %{name: "request_user_choice", is_interrupt: false} = second
    end

    test "returns {:cont, state} for non-ask_user interrupts", %{config: config} do
      state = State.new!(%{interrupt_data: %{action_requests: []}})

      assert {:cont, ^state} =
               AskUserQuestion.handle_resume(nil, state, %{type: :answer}, config, [])
    end

    test "invalid response returns error", %{config: config, state: state} do
      response = %{type: :answer, selected: ["nonexistent"]}

      assert {:error, _reason} =
               AskUserQuestion.handle_resume(nil, state, response, config, [])
    end
  end

  describe "init/1 tool surface options" do
    test "defaults reproduce the ask_user tool" do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)

      assert tool.name == "ask_user"
      assert tool.display_text == "Asking a question"
      assert tool.description =~ "Ask the user a structured question"
      assert AskUserQuestion.system_prompt(config) =~ "## ask_user Tool"
    end

    test "tool_name, description and display_text configure the tool" do
      {:ok, config} =
        AskUserQuestion.init(
          tool_name: "request_user_choice",
          description: "Offer the user a choice.",
          display_text: "Choosing"
        )

      [tool] = AskUserQuestion.tools(config)
      assert tool.name == "request_user_choice"
      assert tool.description == "Offer the user a choice."
      assert tool.display_text == "Choosing"
    end

    test "the built-in prompt names the configured tool" do
      {:ok, config} = AskUserQuestion.init(tool_name: "request_user_choice")
      prompt = AskUserQuestion.system_prompt(config)

      assert prompt =~ "## request_user_choice Tool"
      assert prompt =~ "You have an `request_user_choice` tool"
      assert prompt =~ "### When to use request_user_choice:"
      assert prompt =~ "### When NOT to use request_user_choice:"
      refute prompt =~ "ask_user"
    end

    test "a system_prompt string is used verbatim" do
      contract = "<user_choice>\nUse request_user_choice to offer choices.\n</user_choice>"
      {:ok, config} = AskUserQuestion.init(system_prompt: contract)

      assert AskUserQuestion.system_prompt(config) == contract
    end

    test "system_prompt false or empty contributes nothing" do
      for value <- [false, ""] do
        {:ok, config} = AskUserQuestion.init(system_prompt: value)
        assert AskUserQuestion.system_prompt(config) == ""
      end
    end

    test "rejects an invalid tool_name" do
      for name <- ["has space", String.duplicate("a", 65), "", :ask, nil] do
        assert {:error, message} = AskUserQuestion.init(tool_name: name)
        assert message =~ "tool_name"
      end
    end

    test "rejects a non-string description or display_text" do
      assert {:error, message} = AskUserQuestion.init(description: nil)
      assert message =~ "description"

      assert {:error, message} = AskUserQuestion.init(display_text: "")
      assert message =~ "display_text"
    end

    test "rejects a system_prompt that is not a string or false" do
      assert {:error, message} = AskUserQuestion.init(system_prompt: true)
      assert message =~ "system_prompt"
    end

    test "rejects unknown option keys" do
      assert {:error, message} = AskUserQuestion.init(max_option: 4)
      assert message =~ "max_option"
    end

    test "accepts :id and the keys the agent injects" do
      assert {:ok, _config} =
               AskUserQuestion.init(
                 id: "choice",
                 agent_id: "agent-1",
                 model: nil,
                 filesystem_scope: nil
               )
    end

    test "two instances with their own ids and names give distinct tools and prompts" do
      {:ok, agent} =
        Agent.new(
          %{
            model: Sagents.TestingHelpers.mock_model(),
            middleware: [
              {AskUserQuestion, id: "ask", response_types: [:freeform]},
              {AskUserQuestion,
               id: "choice", tool_name: "request_user_choice", response_types: [:single_select]}
            ]
          },
          replace_default_middleware: true
        )

      entries = Enum.filter(agent.middleware, &(&1.module == AskUserQuestion))
      tool_names = entries |> Enum.flat_map(&Middleware.get_tools/1) |> Enum.map(& &1.name)
      prompts = Enum.map(entries, &Middleware.get_system_prompt/1)

      assert Enum.sort(tool_names) == ["ask_user", "request_user_choice"]
      assert Enum.any?(prompts, &(&1 =~ "## ask_user Tool"))
      assert Enum.any?(prompts, &(&1 =~ "## request_user_choice Tool"))
    end
  end

  describe "option count bounds" do
    defp options_args(count) do
      %{
        "question" => "Which one?",
        "response_type" => "single_select",
        "options" => Enum.map(1..count, &%{"label" => "Option #{&1}"})
      }
    end

    defp run_tool(config, args) do
      [tool] = AskUserQuestion.tools(config)
      tool.function.(args, %{})
    end

    test "defaults put 2 and 10 in the schema and suggest 2-5 in the prompt" do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)
      options = tool.parameters_schema.properties.options

      assert options.minItems == 2
      assert options.maxItems == 10
      assert options.description =~ "Must have 2-10 items"
      assert AskUserQuestion.system_prompt(config) =~ "Provide 2-5"
    end

    test "configured bounds reach the schema, the validator and the prompt" do
      {:ok, config} = AskUserQuestion.init(min_options: 2, max_options: 4)
      [tool] = AskUserQuestion.tools(config)
      options = tool.parameters_schema.properties.options

      assert options.minItems == 2
      assert options.maxItems == 4
      assert options.description =~ "Must have 2-4 items"

      prompt = AskUserQuestion.system_prompt(config)
      assert prompt =~ "Provide 2-4"
      refute prompt =~ "2-5"

      assert {:interrupt, _message, %{options: options}} = run_tool(config, options_args(4))
      assert length(options) == 4

      assert {:error, message} = run_tool(config, options_args(5))
      assert message =~ "at most 4 options"
    end

    test "a minimum above the suggested count is suggested as is" do
      {:ok, config} = AskUserQuestion.init(min_options: 6, max_options: 6)
      prompt = AskUserQuestion.system_prompt(config)

      assert prompt =~ "Provide 6 clear, distinct options"
      assert {:error, message} = run_tool(config, options_args(5))
      assert message =~ "at least 6 options"
    end

    test "rejects invalid bounds" do
      for opts <- [
            [min_options: 1],
            [min_options: 5, max_options: 4],
            [max_options: "4"],
            [min_options: 2.0]
          ] do
        assert {:error, message} = AskUserQuestion.init(opts)
        assert message =~ "min_options and max_options"
      end
    end
  end

  describe "slim schema options" do
    defp pick_one_config(extra \\ []) do
      {:ok, config} =
        AskUserQuestion.init(
          [
            tool_name: "request_user_choice",
            response_types: [:single_select],
            min_options: 2,
            max_options: 4,
            option_values: false,
            context_field: false,
            allow_other: true,
            allow_cancel: true
          ] ++ extra
        )

      config
    end

    defp call_tool(config, args) do
      [tool] = AskUserQuestion.tools(config)
      tool.function.(args, %{})
    end

    test "option_values: false drops value from the schema and ignores a sent value" do
      {:ok, config} = AskUserQuestion.init(option_values: false)
      [tool] = AskUserQuestion.tools(config)
      item = tool.parameters_schema.properties.options.items

      assert Map.keys(item.properties) |> Enum.sort() == [:description, :label]

      args = single_select_args(%{})

      assert {:interrupt, _message, %{options: options}} = call_tool(config, args)

      assert [
               %{label: "PostgreSQL", value: "PostgreSQL"},
               %{label: "MongoDB", value: "MongoDB"}
             ] = options
    end

    test "option_values: false resumes with the label as the answer" do
      config = pick_one_config()

      {:interrupt, _message, question_data} =
        call_tool(config, %{
          "question" => "Which database?",
          "options" => [
            %{"label" => "PostgreSQL", "value" => "pg"},
            %{"label" => "MongoDB"}
          ]
        })

      assert {:ok, "User selected: PostgreSQL"} =
               AskUserQuestion.process_response(
                 %{type: :answer, selected: ["PostgreSQL"]},
                 question_data
               )
    end

    test "context_field: false drops context from the schema, the data and the prompt" do
      {:ok, config} = AskUserQuestion.init(context_field: false)
      [tool] = AskUserQuestion.tools(config)

      refute Map.has_key?(tool.parameters_schema.properties, :context)
      refute AskUserQuestion.system_prompt(config) =~ "Include relevant context"

      assert {:interrupt, _message, %{context: nil}} =
               call_tool(config, single_select_args(%{"context" => "Background"}))
    end

    test "context is kept by default" do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)

      assert Map.has_key?(tool.parameters_schema.properties, :context)
      assert AskUserQuestion.system_prompt(config) =~ "Include relevant context"

      assert {:interrupt, _message, %{context: "Background"}} =
               call_tool(config, single_select_args(%{"context" => "Background"}))
    end

    test "rejects non-boolean option_values and context_field" do
      assert {:error, message} = AskUserQuestion.init(option_values: nil)
      assert message =~ "option_values"

      assert {:error, message} = AskUserQuestion.init(context_field: "no")
      assert message =~ "context_field"
    end

    test "a single response type is inferred and left out of the schema" do
      {:ok, config} = AskUserQuestion.init(response_types: [:single_select])
      [tool] = AskUserQuestion.tools(config)

      refute Map.has_key?(tool.parameters_schema.properties, :response_type)
      assert tool.parameters_schema.required == ["question"]

      args = Map.delete(single_select_args(%{}), "response_type")

      assert {:interrupt, _message, %{response_type: :single_select}} = call_tool(config, args)
    end

    test "a sent response_type is still accepted when it names the single type" do
      {:ok, config} = AskUserQuestion.init(response_types: [:single_select])

      assert {:interrupt, _message, %{response_type: :single_select}} =
               call_tool(config, single_select_args(%{}))

      assert {:error, message} =
               call_tool(config, single_select_args(%{"response_type" => "multi_select"}))

      assert message =~ "not enabled"
    end

    test "the prompt for a single type does not name response types" do
      {:ok, config} = AskUserQuestion.init(response_types: [:single_select])
      prompt = AskUserQuestion.system_prompt(config)

      refute prompt =~ "Response types"
      refute prompt =~ "single_select"
      assert prompt =~ "Use when the user should pick exactly one option from a list."
    end

    test "with two response types the field stays required" do
      {:ok, config} = AskUserQuestion.init(response_types: [:single_select, :freeform])
      [tool] = AskUserQuestion.tools(config)

      assert Map.has_key?(tool.parameters_schema.properties, :response_type)
      assert tool.parameters_schema.required == ["question", "response_type"]

      args = Map.delete(single_select_args(%{}), "response_type")
      assert {:error, "Missing required field: response_type"} = call_tool(config, args)
    end

    test "a full pick-one configuration has only question and options" do
      config = pick_one_config()
      [tool] = AskUserQuestion.tools(config)
      schema = tool.parameters_schema

      assert tool.name == "request_user_choice"
      assert Map.keys(schema.properties) |> Enum.sort() == [:options, :question]
      assert schema.required == ["question"]

      assert Map.keys(schema.properties.options.items.properties) |> Enum.sort() ==
               [:description, :label]

      assert schema.properties.options.maxItems == 4
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

  describe "user_facing_attrs/2" do
    defp question(overrides) do
      Map.merge(
        %{
          type: :ask_user_question,
          response_type: :single_select,
          options: [
            %{label: "PostgreSQL", value: "postgresql"},
            %{label: "MongoDB", value: "mongodb"}
          ],
          allow_other: false,
          allow_cancel: true,
          context: nil,
          tool_call_id: "call_1"
        },
        overrides
      )
    end

    test "single_select renders the chosen option's label" do
      response = %{type: :answer, selected: ["postgresql"]}

      assert {:ok, attrs} = AskUserQuestion.user_facing_attrs(response, question(%{}))

      assert attrs == %{
               message_type: "user",
               content_type: "text",
               content: %{"text" => "PostgreSQL"}
             }
    end

    test "single_select with special 'other' renders 'Other' + typed text" do
      q = question(%{allow_other: true})
      response = %{type: :answer, selected: ["other"], other_text: "DuckDB please"}

      assert {:ok, attrs} = AskUserQuestion.user_facing_attrs(response, q)
      assert attrs.content == %{"text" => "Other:  \nDuckDB please"}
      assert attrs.message_type == "user"
    end

    test "single_select 'other' is rejected when allow_other is false" do
      response = %{type: :answer, selected: ["other"], other_text: "x"}

      assert {:error, :other_not_allowed} =
               AskUserQuestion.user_facing_attrs(response, question(%{allow_other: false}))
    end

    test "single_select treats 'other' as a regular value when it's a real option" do
      q =
        question(%{
          options: [
            %{label: "Yes", value: "yes"},
            %{label: "Other Brand", value: "other"}
          ]
        })

      response = %{type: :answer, selected: ["other"]}

      assert {:ok, attrs} = AskUserQuestion.user_facing_attrs(response, q)
      assert attrs.content == %{"text" => "Other Brand"}
    end

    test "multi_select renders labels as a bullet list" do
      q =
        question(%{
          response_type: :multi_select,
          options: [
            %{label: "Auth", value: "auth"},
            %{label: "Billing", value: "billing"},
            %{label: "Notifications", value: "notif"}
          ]
        })

      response = %{type: :answer, selected: ["auth", "notif"]}

      assert {:ok, attrs} = AskUserQuestion.user_facing_attrs(response, q)
      assert attrs.content == %{"text" => "- Auth\n- Notifications"}
    end

    test "multi_select with 'other' appends a new line + typed text" do
      q =
        question(%{
          response_type: :multi_select,
          allow_other: true,
          options: [
            %{label: "Auth", value: "auth"},
            %{label: "Billing", value: "billing"}
          ]
        })

      response = %{
        type: :answer,
        selected: ["auth", "other"],
        other_text: "audit logging"
      }

      assert {:ok, attrs} = AskUserQuestion.user_facing_attrs(response, q)
      assert attrs.content == %{"text" => "- Auth\n\nOther:  \naudit logging"}
    end

    test "multi_select 'other' alone (no regular selections) renders without leading CSV" do
      q =
        question(%{
          response_type: :multi_select,
          allow_other: true,
          options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}]
        })

      response = %{type: :answer, selected: ["other"], other_text: "neither"}

      assert {:ok, attrs} = AskUserQuestion.user_facing_attrs(response, q)
      assert attrs.content == %{"text" => "Other:  \nneither"}
    end

    test "multi_select rejects 'other' when allow_other is false" do
      q =
        question(%{
          response_type: :multi_select,
          allow_other: false,
          options: [%{label: "A", value: "a"}]
        })

      response = %{type: :answer, selected: ["a", "other"], other_text: "x"}

      assert {:error, :other_not_allowed} = AskUserQuestion.user_facing_attrs(response, q)
    end

    test "freeform renders the user's typed text" do
      q = question(%{response_type: :freeform, options: []})
      response = %{type: :answer, other_text: "Use jsonb columns."}

      assert {:ok, attrs} = AskUserQuestion.user_facing_attrs(response, q)
      assert attrs.content == %{"text" => "Use jsonb columns."}
      assert attrs.message_type == "user"
    end

    test "freeform with empty text errors" do
      q = question(%{response_type: :freeform, options: []})

      assert {:error, :empty_freeform} =
               AskUserQuestion.user_facing_attrs(%{type: :answer, other_text: ""}, q)
    end

    test "cancel produces a notification message" do
      assert {:ok, attrs} =
               AskUserQuestion.user_facing_attrs(%{type: :cancel}, question(%{}))

      assert attrs == %{
               message_type: "system",
               content_type: "notification",
               content: %{"text" => "User cancelled"}
             }
    end

    test "cancel is rejected when allow_cancel is false" do
      assert {:error, :cancellation_not_allowed} =
               AskUserQuestion.user_facing_attrs(
                 %{type: :cancel},
                 question(%{allow_cancel: false})
               )
    end
  end

  describe "restorable_interrupt?/1" do
    alias Sagents.Middleware.AskUserQuestion

    test "returns true for :ask_user_question type" do
      assert AskUserQuestion.restorable_interrupt?(%{type: :ask_user_question, question: "hi"})
    end

    test "returns false for unrelated types" do
      refute AskUserQuestion.restorable_interrupt?(%{type: :subagent_hitl})
      refute AskUserQuestion.restorable_interrupt?(%{type: :multiple_interrupts, interrupts: []})
      refute AskUserQuestion.restorable_interrupt?(%{})
    end
  end

  describe "options without a value" do
    setup do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)
      %{tool: tool, config: config}
    end

    defp ask(tool, response_type, options, extra \\ %{}) do
      args =
        Map.merge(
          %{"question" => "Q?", "response_type" => response_type, "options" => options},
          extra
        )

      tool.function.(args, %{})
    end

    # Questions from `ask/4` have no tool_call_id until the framework adds one.
    defp resolve(config, question_data, response) do
      resolved_result(config, Map.put(question_data, :tool_call_id, "call_1"), response)
    end

    test "an option with no value uses its label as the value", %{tool: tool} do
      assert {:interrupt, _msg, q} =
               ask(tool, "single_select", [%{"label" => "Yes"}, %{"label" => "No"}])

      assert Enum.map(q.options, & &1.value) == ["Yes", "No"]
      assert Enum.all?(q.options, &(&1.value == &1.label))
    end

    test "nil, empty, and non-string values fall back to the label", %{tool: tool} do
      options = [
        %{"label" => "A", "value" => nil},
        %{"label" => "B", "value" => ""},
        %{"label" => "C", "value" => 3},
        %{"label" => "D", "value" => %{"x" => 1}}
      ]

      assert {:interrupt, _msg, q} = ask(tool, "single_select", options)
      assert Enum.map(q.options, & &1.value) == ["A", "B", "C", "D"]
    end

    test "mixed options keep supplied values", %{tool: tool} do
      options = [%{"label" => "PostgreSQL", "value" => "pg"}, %{"label" => "MongoDB"}]

      assert {:interrupt, _msg, q} = ask(tool, "single_select", options)
      assert Enum.map(q.options, & &1.value) == ["pg", "MongoDB"]
    end

    test "a label equal to another option's explicit value is a duplicate", %{tool: tool} do
      options = [%{"label" => "Yes"}, %{"label" => "Sure", "value" => "Yes"}]

      assert {:error, msg} = ask(tool, "single_select", options)
      assert msg =~ ~s|Duplicate option value: "Yes"|
    end

    test "duplicate labels are refused and named", %{tool: tool} do
      options = [%{"label" => "Same", "value" => "a"}, %{"label" => "Same", "value" => "b"}]

      assert {:error, msg} = ask(tool, "single_select", options)
      assert msg =~ ~s|Duplicate option label: "Same"|
    end

    test "labels differing only in line breaks are duplicates", %{tool: tool} do
      options = [%{"label" => "Use the\nloan"}, %{"label" => "Use the loan"}]

      assert {:error, msg} = ask(tool, "single_select", options)
      assert msg =~ ~s|Duplicate option label: "Use the loan"|
    end

    test "line breaks in a label collapse to a single space", %{tool: tool} do
      options = [%{"label" => "  First line\r\n   second line \n"}, %{"label" => "Other choice"}]

      assert {:interrupt, _msg, q} = ask(tool, "single_select", options)
      assert hd(q.options).label == "First line second line"
      assert hd(q.options).value == "First line second line"
    end

    test "option-shape refusals include an example", %{tool: tool} do
      assert {:error, missing} =
               ask(tool, "single_select", [%{"value" => "a"}, %{"label" => "B"}])

      assert missing =~ "non-empty 'label'"
      assert missing =~ ~s|{"label": "Yes"|

      assert {:error, blank} =
               ask(tool, "single_select", [%{"label" => " \n "}, %{"label" => "B"}])

      assert blank =~ "non-empty 'label'"

      assert {:error, not_object} = ask(tool, "single_select", ["Yes", "No"])
      assert not_object =~ "must be an object"
      assert not_object =~ ~s|{"label": "Yes"|
    end

    test "single_select result names the chosen label", %{tool: tool, config: config} do
      label = "$170 is the loan, the other $28 is something else"

      {:interrupt, _msg, q} =
        ask(tool, "single_select", [%{"label" => label}, %{"label" => "All $198 is the loan"}])

      tool_result = resolve(config, q, %{type: :answer, selected: [label]})
      assert content_text(tool_result.content) == "User selected: #{label}"
    end

    test "multi_select result keeps labels with commas intact", %{tool: tool, config: config} do
      {:interrupt, _msg, q} =
        ask(tool, "multi_select", [
          %{"label" => "Yellow, Red, and Blue"},
          %{"label" => "Blue, Purple, and Green"},
          %{"label" => "Black"}
        ])

      response = %{
        type: :answer,
        selected: ["Yellow, Red, and Blue", "Blue, Purple, and Green"]
      }

      tool_result = resolve(config, q, response)

      assert content_text(tool_result.content) ==
               "User selected:\n- Yellow, Red, and Blue\n- Blue, Purple, and Green"
    end

    test "user_facing_attrs renders labels for options with no supplied value", %{tool: tool} do
      {:interrupt, _msg, q} =
        ask(tool, "multi_select", [%{"label" => "Auth"}, %{"label" => "Billing, invoices"}])

      response = %{type: :answer, selected: ["Billing, invoices", "Auth"]}

      assert {:ok, attrs} = AskUserQuestion.user_facing_attrs(response, q)
      assert attrs.content == %{"text" => "- Billing, invoices\n- Auth"}
    end

    test "a label of exactly 'other' is a regular option", %{tool: tool, config: config} do
      {:interrupt, _msg, q} =
        ask(tool, "single_select", [%{"label" => "yes"}, %{"label" => "other"}])

      tool_result = resolve(config, q, %{type: :answer, selected: ["other"]})
      assert content_text(tool_result.content) == "User selected: other"
      refute content_text(tool_result.content) =~ "Additional input"
      assert tool_result.processed_content.selected == [%{label: "other", value: "other"}]
    end

    test "a label of 'Other' leaves the special other selection working", %{
      tool: tool,
      config: config
    } do
      {:interrupt, _msg, q} =
        ask(tool, "single_select", [%{"label" => "Yes"}, %{"label" => "Other"}], %{
          "allow_other" => true
        })

      response = %{type: :answer, selected: ["other"], other_text: "Something custom"}
      tool_result = resolve(config, q, response)

      assert content_text(tool_result.content) ==
               "User selected: other\nAdditional input: \"Something custom\""

      assert tool_result.processed_content == %{
               type: :answer,
               selected: [],
               other_text: "Something custom"
             }
    end
  end

  describe "processed_content on the resolved tool result" do
    setup do
      {:ok, config} = AskUserQuestion.init([])
      %{config: config}
    end

    defp resolved_result(config, question_data, response) do
      tool_msg =
        LangChain.Message.new_tool_result!(%{
          content: nil,
          tool_results: [
            LangChain.Message.ToolResult.new!(%{
              tool_call_id: "call_1",
              content: "Waiting for user response...",
              name: "ask_user",
              is_interrupt: true
            })
          ]
        })

      state = State.new!(%{messages: [tool_msg], interrupt_data: question_data})
      {:ok, updated} = AskUserQuestion.handle_resume(nil, state, response, config, [])
      [tool_result] = List.last(updated.messages).tool_results
      tool_result
    end

    # The shape of a question persisted from an LLM that supplied slug values.
    defp slug_question(response_type) do
      %{
        type: :ask_user_question,
        question: "Which stores?",
        response_type: response_type,
        options: [
          %{label: "PostgreSQL", value: "postgresql", description: nil},
          %{label: "Redis", value: "redis", description: nil}
        ],
        allow_other: true,
        allow_cancel: true,
        context: nil,
        tool_call_id: "call_1"
      }
    end

    test "single_select with slug values reports as before", %{config: config} do
      response = %{type: :answer, selected: ["postgresql"]}
      tool_result = resolved_result(config, slug_question(:single_select), response)

      assert content_text(tool_result.content) == "User selected: postgresql"

      assert tool_result.processed_content == %{
               type: :answer,
               selected: [%{label: "PostgreSQL", value: "postgresql"}],
               other_text: nil
             }
    end

    test "multi_select lists labels and values, with other_text", %{config: config} do
      response = %{type: :answer, selected: ["redis", "other"], other_text: "SQLite"}
      tool_result = resolved_result(config, slug_question(:multi_select), response)

      assert tool_result.processed_content == %{
               type: :answer,
               selected: [%{label: "Redis", value: "redis"}],
               other_text: "SQLite"
             }
    end

    test "freeform carries the text with no selections", %{config: config} do
      q = %{slug_question(:freeform) | options: []}
      response = %{type: :answer, other_text: "Call it Cache"}
      tool_result = resolved_result(config, q, response)

      assert tool_result.processed_content == %{
               type: :answer,
               selected: [],
               other_text: "Call it Cache"
             }
    end

    test "cancel is recorded", %{config: config} do
      tool_result = resolved_result(config, slug_question(:single_select), %{type: :cancel})
      assert tool_result.processed_content == %{type: :cancel}
    end

    test "each question in a multiple_interrupts resume gets its own answer", %{config: config} do
      q1 = %{slug_question(:single_select) | tool_call_id: "call_a"}
      q2 = %{slug_question(:single_select) | tool_call_id: "call_b"}

      tool_results =
        Enum.map(["call_a", "call_b"], fn id ->
          LangChain.Message.ToolResult.new!(%{
            tool_call_id: id,
            content: "Waiting for user response...",
            name: "ask_user",
            is_interrupt: true
          })
        end)

      tool_msg = LangChain.Message.new_tool_result!(%{content: nil, tool_results: tool_results})

      state =
        State.new!(%{
          messages: [tool_msg],
          interrupt_data: %{type: :multiple_interrupts, interrupts: [q1, q2]}
        })

      responses = [
        %{type: :answer, tool_call_id: "call_a", selected: ["postgresql"]},
        %{type: :answer, tool_call_id: "call_b", selected: ["redis"]}
      ]

      assert {:ok, updated} = AskUserQuestion.handle_resume(nil, state, responses, config, [])

      selected_by_id =
        Map.new(List.last(updated.messages).tool_results, fn r ->
          {r.tool_call_id, r.processed_content.selected}
        end)

      assert selected_by_id == %{
               "call_a" => [%{label: "PostgreSQL", value: "postgresql"}],
               "call_b" => [%{label: "Redis", value: "redis"}]
             }
    end
  end

  describe "model-facing instructions" do
    test "option schema requires only label and describes value as optional" do
      {:ok, config} = AskUserQuestion.init([])
      [tool] = AskUserQuestion.tools(config)
      items = tool.parameters_schema.properties.options.items

      assert items.required == ["label"]
      assert Map.has_key?(items.properties, :value)
      assert items.properties.label.description =~ "single line"
      assert items.properties.label.description =~ "returned to you"
      assert items.properties.value.description =~ "Optional"
      assert items.properties.value.description =~ "the label is used"
    end

    test "system prompt guides option labels for select types without naming value" do
      {:ok, config} = AskUserQuestion.init([])
      prompt = AskUserQuestion.system_prompt(config)

      assert prompt =~ "Write each option label as the answer itself, on one line"
      refute prompt =~ "value"
    end

    test "system prompt omits option guidance when only freeform is enabled" do
      {:ok, config} = AskUserQuestion.init(response_types: [:freeform])
      prompt = AskUserQuestion.system_prompt(config)

      refute prompt =~ "option label"
    end
  end
end
