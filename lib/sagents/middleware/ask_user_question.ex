defmodule Sagents.Middleware.AskUserQuestion do
  @moduledoc """
  Middleware that gives agents a structured way to ask the user questions.

  Provides an `ask_user` tool that triggers the existing interrupt/resume lifecycle
  with typed question and response data. This enables UIs to render appropriate
  controls (radio buttons, checkboxes, text inputs) based on the question type.

  ## Configuration

      # All response types (default)
      Sagents.Middleware.AskUserQuestion

      # Restricted to specific types
      {Sagents.Middleware.AskUserQuestion, response_types: [:single_select, :multi_select]}

  ## Response Types

  - `:single_select` - User picks one option from a list (radio buttons)
  - `:multi_select` - User picks one or more options (checkboxes)
  - `:freeform` - User provides free-form text input

  ## Interrupt Data

  When the agent calls `ask_user`, execution returns:

      {:interrupt, state, %{
        type: :ask_user_question,
        question: "Which database should we use?",
        response_type: :single_select,
        options: [
          %{label: "PostgreSQL", value: "postgresql", description: "Relational DB"},
          %{label: "MongoDB", value: "mongodb", description: "Document store"}
        ],
        allow_other: false,
        allow_cancel: true,
        context: "We need a primary data store for the user service.",
        tool_call_id: "call_123"
      }}

  ## Resume Data

  Resume with a response map:

      # Answer
      AgentServer.resume(agent_id, %{type: :answer, selected: ["postgresql"]})

      # Answer with additional text
      AgentServer.resume(agent_id, %{
        type: :answer,
        selected: ["postgresql"],
        other_text: "Use jsonb columns"
      })

      # Cancel
      AgentServer.resume(agent_id, %{type: :cancel})
  """

  @behaviour Sagents.Middleware

  alias Sagents.State
  alias LangChain.Function
  alias LangChain.Message.ToolResult

  @all_response_types [:single_select, :multi_select, :freeform]

  @impl true
  def init(opts) do
    response_types = Keyword.get(opts, :response_types, @all_response_types)

    invalid = response_types -- @all_response_types

    if invalid != [] do
      {:error, "Invalid response types: #{inspect(invalid)}"}
    else
      {:ok, %{response_types: response_types}}
    end
  end

  @impl true
  def system_prompt(config) do
    build_system_prompt(config.response_types)
  end

  @impl true
  def tools(config) do
    [build_ask_user_tool(config)]
  end

  # Claim: resume_data is nil (re-scan from HITL handoff). Surface the interrupt
  # so the user sees it. Don't try to resolve -- there's no answer yet.
  @impl true
  def handle_resume(
        _agent,
        %State{interrupt_data: %{type: :ask_user_question} = interrupt_data} = state,
        nil,
        _config,
        _opts
      ) do
    {:interrupt, state, interrupt_data}
  end

  # Resolve: resume_data is a response map. Process the user's answer.
  def handle_resume(
        _agent,
        %State{interrupt_data: %{type: :ask_user_question}} = state,
        response,
        _config,
        _opts
      ) do
    resolve_single_question(state, state.interrupt_data, response)
  end

  # Multiple interrupts where ALL are ask_user questions.
  # Claim if resume_data is nil; resolve if resume_data is a list of responses.
  def handle_resume(
        _agent,
        %State{interrupt_data: %{type: :multiple_interrupts, interrupts: interrupts}} = state,
        nil,
        _config,
        _opts
      ) do
    if Enum.all?(interrupts, &(&1.type == :ask_user_question)) do
      {:interrupt, state, state.interrupt_data}
    else
      {:cont, state}
    end
  end

  def handle_resume(
        _agent,
        %State{interrupt_data: %{type: :multiple_interrupts, interrupts: interrupts}} = state,
        responses,
        _config,
        _opts
      )
      when is_list(responses) do
    if Enum.all?(interrupts, &(&1.type == :ask_user_question)) do
      resolve_multiple_questions(state, interrupts, responses)
    else
      {:cont, state}
    end
  end

  def handle_resume(_agent, state, _resume_data, _config, _opts), do: {:cont, state}

  defp resolve_single_question(state, question_data, response) do
    case process_response(response, question_data) do
      {:ok, tool_result_content} ->
        new_tool_result =
          ToolResult.new!(%{
            tool_call_id: question_data.tool_call_id,
            content: tool_result_content,
            name: "ask_user",
            is_interrupt: false
          })

        {:ok, State.replace_tool_result(state, question_data.tool_call_id, new_tool_result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_multiple_questions(state, interrupts, responses) do
    # Build a map of tool_call_id -> response for lookup
    responses_by_id = Map.new(responses, fn r -> {r.tool_call_id, r} end)

    Enum.reduce_while(interrupts, {:ok, state}, fn question_data, {:ok, acc_state} ->
      response = Map.get(responses_by_id, question_data.tool_call_id)

      if response == nil do
        {:halt,
         {:error, "Missing response for question tool_call_id: #{question_data.tool_call_id}"}}
      else
        case process_response(response, question_data) do
          {:ok, tool_result_content} ->
            new_tool_result =
              ToolResult.new!(%{
                tool_call_id: question_data.tool_call_id,
                content: tool_result_content,
                name: "ask_user",
                is_interrupt: false
              })

            {:cont,
             {:ok,
              State.replace_tool_result(acc_state, question_data.tool_call_id, new_tool_result)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
  end

  # -- Tool definition --

  defp build_ask_user_tool(config) do
    Function.new!(%{
      name: "ask_user",
      description:
        "Ask the user a structured question when you need their input to make a decision. " <>
          "Use this for significant choices where multiple valid approaches exist.",
      display_text: "Asking a question",
      parameters_schema: build_parameters_schema(config.response_types),
      function: fn args, _context ->
        execute_ask_user(args, config)
      end
    })
  end

  defp build_parameters_schema(response_types) do
    %{
      type: "object",
      properties: %{
        question: %{type: "string", description: "The question to ask the user"},
        response_type: %{
          type: "string",
          enum: Enum.map(response_types, &Atom.to_string/1),
          description:
            "The type of response expected: " <>
              Enum.map_join(response_types, ", ", fn
                :single_select -> "single_select (pick one)"
                :multi_select -> "multi_select (pick one or more)"
                :freeform -> "freeform (open text)"
              end)
        },
        options: %{
          type: "array",
          description:
            "Options for single_select or multi_select. Must have 2-10 items. Not used for freeform.",
          items: %{
            type: "object",
            properties: %{
              label: %{type: "string", description: "Display label for the option"},
              value: %{type: "string", description: "Machine-readable value"},
              description: %{
                type: "string",
                description: "Optional description with tradeoffs or details"
              }
            },
            required: ["label", "value"]
          }
        },
        context: %{
          type: "string",
          description: "Additional context to help the user understand the decision"
        },
        allow_other: %{
          type: "boolean",
          description: "Whether to allow a freeform 'other' option alongside selections"
        },
        allow_cancel: %{
          type: "boolean",
          description: "Whether the user can cancel/dismiss this question"
        }
      },
      required: ["question", "response_type"]
    }
  end

  # -- Tool execution (validation + interrupt) --

  defp execute_ask_user(args, config) do
    with {:ok, question} <- validate_question(args),
         {:ok, response_type} <- validate_response_type(args, config.response_types),
         {:ok, options} <- validate_options(args, response_type) do
      question_data = %{
        type: :ask_user_question,
        question: question,
        response_type: response_type,
        options: options,
        allow_other: get_boolean_arg(args, "allow_other", false),
        allow_cancel: get_boolean_arg(args, "allow_cancel", true),
        context: Map.get(args, "context")
      }

      {:interrupt, "Waiting for user response...", question_data}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_question(args) do
    case Map.get(args, "question") do
      nil -> {:error, "Missing required field: question"}
      q when is_binary(q) and byte_size(q) > 0 -> {:ok, q}
      "" -> {:error, "Question must be a non-empty string"}
      _ -> {:error, "Question must be a string"}
    end
  end

  defp validate_response_type(args, enabled_types) do
    case Map.get(args, "response_type") do
      nil ->
        {:error, "Missing required field: response_type"}

      type_str when is_binary(type_str) ->
        type_atom =
          try do
            String.to_existing_atom(type_str)
          rescue
            ArgumentError -> nil
          end

        cond do
          type_atom == nil ->
            {:error, "Invalid response_type: #{type_str}"}

          type_atom not in @all_response_types ->
            {:error, "Invalid response_type: #{type_str}"}

          type_atom not in enabled_types ->
            {:error,
             "Response type '#{type_str}' is not enabled. Enabled types: #{inspect(enabled_types)}"}

          true ->
            {:ok, type_atom}
        end

      _ ->
        {:error, "response_type must be a string"}
    end
  end

  defp validate_options(args, response_type) do
    options = Map.get(args, "options", [])

    case response_type do
      type when type in [:single_select, :multi_select] ->
        cond do
          not is_list(options) ->
            {:error, "Options must be an array for #{type}"}

          length(options) < 2 ->
            {:error, "#{type} requires at least 2 options, got #{length(options)}"}

          length(options) > 10 ->
            {:error, "#{type} allows at most 10 options, got #{length(options)}"}

          true ->
            validate_option_items(options)
        end

      :freeform ->
        if options != [] and options != nil do
          {:error, "freeform questions must not have options"}
        else
          {:ok, []}
        end
    end
  end

  defp validate_option_items(options) do
    # Validate each option has non-empty label and value, and values are unique
    result =
      Enum.reduce_while(options, {:ok, MapSet.new()}, fn opt, {:ok, seen_values} ->
        label = Map.get(opt, "label", "")
        value = Map.get(opt, "value", "")

        cond do
          not is_binary(label) or byte_size(label) == 0 ->
            {:halt, {:error, "Each option must have a non-empty 'label'"}}

          not is_binary(value) or byte_size(value) == 0 ->
            {:halt, {:error, "Each option must have a non-empty 'value'"}}

          MapSet.member?(seen_values, value) ->
            {:halt, {:error, "Duplicate option value: #{value}"}}

          true ->
            {:cont, {:ok, MapSet.put(seen_values, value)}}
        end
      end)

    case result do
      {:ok, _seen} ->
        {:ok,
         Enum.map(options, fn opt ->
           %{
             label: Map.fetch!(opt, "label"),
             value: Map.fetch!(opt, "value"),
             description: Map.get(opt, "description")
           }
         end)}

      {:error, _} = error ->
        error
    end
  end

  defp get_boolean_arg(args, key, default) do
    case Map.get(args, key) do
      val when is_boolean(val) -> val
      _ -> default
    end
  end

  # -- Response processing --

  @doc """
  Process a user's response to a question.

  Called by `handle_resume/4` to validate the response and format it as
  human-readable text for the LLM.

  ## Returns

  - `{:ok, formatted_text}` - Valid response, formatted for the LLM
  - `{:error, reason}` - Invalid response
  """
  def process_response(response, question_data) do
    case response do
      %{type: :answer} ->
        validate_and_format_answer(response, question_data)

      %{type: :cancel} ->
        if question_data.allow_cancel do
          {:ok,
           "User cancelled this question. They do not want you to proceed with this direction. Stop what you are doing and wait for further instructions from the user."}
        else
          {:error, "Cancellation is not allowed for this question"}
        end

      _ ->
        {:error, "Invalid response format. Expected %{type: :answer, ...} or %{type: :cancel}"}
    end
  end

  defp validate_and_format_answer(response, question_data) do
    case question_data.response_type do
      :single_select -> validate_single_select(response, question_data)
      :multi_select -> validate_multi_select(response, question_data)
      :freeform -> validate_freeform(response)
    end
  end

  defp validate_single_select(response, question_data) do
    selected = Map.get(response, :selected, [])
    valid_values = Enum.map(question_data.options, & &1.value)
    # "other" is only the special allow_other value when it's NOT a regular option
    special_other? = hd(selected) == "other" and "other" not in valid_values

    cond do
      not is_list(selected) or length(selected) != 1 ->
        {:error, "single_select requires exactly one selection"}

      special_other? and not question_data.allow_other ->
        {:error, "'other' is not allowed for this question"}

      special_other? ->
        other_text = Map.get(response, :other_text, "")
        {:ok, "User selected: other\nAdditional input: \"#{other_text}\""}

      hd(selected) not in valid_values ->
        {:error,
         "Selected value '#{hd(selected)}' is not a valid option. Valid: #{inspect(valid_values)}"}

      true ->
        text = "User selected: #{hd(selected)}"

        case Map.get(response, :other_text) do
          nil -> {:ok, text}
          "" -> {:ok, text}
          other -> {:ok, text <> "\nAdditional input: \"#{other}\""}
        end
    end
  end

  defp validate_multi_select(response, question_data) do
    selected = Map.get(response, :selected, [])
    valid_values = Enum.map(question_data.options, & &1.value)
    # "other" is only the special allow_other value when it's NOT a regular option
    has_special_other? = "other" in selected and "other" not in valid_values

    non_special_other =
      if has_special_other?, do: Enum.reject(selected, &(&1 == "other")), else: selected

    cond do
      not is_list(selected) or length(selected) == 0 ->
        {:error, "multi_select requires at least one selection"}

      has_special_other? and not question_data.allow_other ->
        {:error, "'other' is not allowed for this question"}

      Enum.any?(non_special_other, fn v -> v not in valid_values end) ->
        invalid = Enum.reject(non_special_other, fn v -> v in valid_values end)
        {:error, "Invalid selections: #{inspect(invalid)}. Valid: #{inspect(valid_values)}"}

      true ->
        text = "User selected: #{Enum.join(selected, ", ")}"

        case Map.get(response, :other_text) do
          nil -> {:ok, text}
          "" -> {:ok, text}
          other -> {:ok, text <> "\nAdditional input: \"#{other}\""}
        end
    end
  end

  defp validate_freeform(response) do
    case Map.get(response, :other_text) do
      nil ->
        {:error, "freeform response requires 'other_text' field"}

      text when is_binary(text) and byte_size(text) > 0 ->
        {:ok, "User responded: \"#{text}\""}

      "" ->
        {:error, "freeform response text must not be empty"}

      _ ->
        {:error, "freeform 'other_text' must be a string"}
    end
  end

  # -- System prompt --

  defp build_system_prompt(response_types) do
    type_instructions =
      response_types
      |> Enum.map(fn
        :single_select ->
          """
          - **single_select**: Use when the user should pick exactly one option from a list.
            Provide 2-5 clear, distinct options with brief descriptions explaining tradeoffs.
          """

        :multi_select ->
          """
          - **multi_select**: Use when the user can pick one or more options from a list.
            Provide 2-5 options. Good for feature selections, technology stacks, etc.
          """

        :freeform ->
          """
          - **freeform**: Use when you need open-ended text input.
            Good for naming things, getting specific requirements, or open feedback.
            Do NOT provide options for freeform questions.
          """
      end)
      |> Enum.join("\n")

    """
    ## ask_user Tool

    You have an `ask_user` tool for asking the user structured questions.

    ### When to use ask_user:
    - Multiple valid approaches exist and the choice significantly affects the outcome
    - You need the user's preference on a subjective decision
    - Requirements are ambiguous and you need clarification before proceeding
    - A decision would be difficult or costly to reverse

    ### When NOT to use ask_user:
    - You have enough context to make a reasonable decision
    - The choice is minor and easily reversible
    - You can infer the answer from prior conversation context

    ### Response types:
    #{type_instructions}
    ### Best practices:
    - Keep questions concise and focused on the decision at hand
    - Provide 2-5 distinct options with brief descriptions of tradeoffs
    - Include relevant context to help the user make an informed decision
    - Set allow_cancel to true unless the question blocks critical progress
    """
  end
end
