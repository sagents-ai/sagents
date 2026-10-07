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

  ### Forcing allow_other / allow_cancel

  By default the LLM chooses `allow_other` and `allow_cancel` per question. Set
  either to a fixed boolean in the init config to force it for every question
  and remove it from the LLM's control. Omit a key to leave it LLM-decided.

      # User must always answer (never cancel); always offer an "Other" input
      {Sagents.Middleware.AskUserQuestion, allow_cancel: false, allow_other: true}

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
          %{label: "PostgreSQL", value: "PostgreSQL", description: "Relational DB"},
          %{label: "MongoDB", value: "MongoDB", description: "Document store"}
        ],
        allow_other: false,
        allow_cancel: true,
        context: "We need a primary data store for the user service.",
        tool_call_id: "call_123"
      }}

  Every option has a `:value`. The LLM may supply one, but usually omits it, and
  then the value is the option's label. Labels are single-line: line breaks
  inside a label are collapsed to a space.

  ## Resume Data

  Resume with a response map. `selected` holds option values, posted back
  unchanged from the interrupt's `options`:

      # Answer
      AgentServer.resume(agent_id, %{type: :answer, selected: ["PostgreSQL"]})

      # Answer with additional text
      AgentServer.resume(agent_id, %{
        type: :answer,
        selected: ["PostgreSQL"],
        other_text: "Use jsonb columns"
      })

      # Cancel
      AgentServer.resume(agent_id, %{type: :cancel})

  ## Result

  The LLM receives the selected option values as text: one line for
  `:single_select`, a Markdown bullet list for `:multi_select`. When the LLM
  omitted `value`, that text is the label the user chose.

  The resolved tool result also carries the answer in `processed_content`,
  which is not sent to the LLM:

      %{type: :answer, selected: [%{label: "PostgreSQL", value: "PostgreSQL"}], other_text: nil}
      %{type: :cancel}

  `selected` lists the chosen regular options. The special `"other"` selection
  is not included; its typed text is in `other_text`. A `:freeform` answer has
  `selected: []` and the text in `other_text`. `processed_content` is a virtual
  field and is not persisted with the state.
  """

  @behaviour Sagents.Middleware

  alias Sagents.AgentServer
  alias Sagents.State
  alias LangChain.Function
  alias LangChain.Message.ToolResult

  @all_response_types [:single_select, :multi_select, :freeform]

  @impl true
  def init(opts) do
    response_types = Keyword.get(opts, :response_types, @all_response_types)
    invalid = response_types -- @all_response_types

    with [] <- invalid,
         {:ok, forced_allow_other} <- validate_forced_flag(opts, :allow_other),
         {:ok, forced_allow_cancel} <- validate_forced_flag(opts, :allow_cancel) do
      {:ok,
       %{
         response_types: response_types,
         forced_allow_other: forced_allow_other,
         forced_allow_cancel: forced_allow_cancel
       }}
    else
      invalid when is_list(invalid) ->
        {:error, "Invalid response types: #{inspect(invalid)}"}

      {:error, _reason} = error ->
        error
    end
  end

  # A forced flag (`allow_other` / `allow_cancel`) fixes the value for every
  # question and removes it from the LLM's control. Absent -> nil (LLM decides).
  # Boolean -> forced. Anything else -> error.
  defp validate_forced_flag(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, nil}
      {:ok, val} when is_boolean(val) -> {:ok, val}
      {:ok, other} -> {:error, "#{key} must be a boolean when set, got: #{inspect(other)}"}
    end
  end

  @impl true
  def system_prompt(config) do
    build_system_prompt(config)
  end

  @impl true
  def tools(config) do
    [build_ask_user_tool(config)]
  end

  # An ask_user interrupt is fully self-contained: the question, options, and
  # tool_call_id are everything `handle_resume/5` needs. No PIDs, no monitors,
  # no external state. So this middleware opts in to cold-start restoration.
  # `:multiple_interrupts` is decomposed by the framework — each sub-interrupt
  # is checked individually against the middleware list, and the wrapper is
  # restored only if every sub-interrupt is claimed.
  @impl true
  def restorable_interrupt?(%{type: :ask_user_question}), do: true
  def restorable_interrupt?(_other), do: false

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
        agent,
        %State{interrupt_data: %{type: :ask_user_question}} = state,
        response,
        _config,
        _opts
      ) do
    resolve_single_question(agent, state, state.interrupt_data, response)
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
        agent,
        %State{interrupt_data: %{type: :multiple_interrupts, interrupts: interrupts}} = state,
        responses,
        _config,
        _opts
      )
      when is_list(responses) do
    if Enum.all?(interrupts, &(&1.type == :ask_user_question)) do
      resolve_multiple_questions(agent, state, interrupts, responses)
    else
      {:cont, state}
    end
  end

  def handle_resume(_agent, state, _resume_data, _config, _opts), do: {:cont, state}

  defp resolve_single_question(agent, state, question_data, response) do
    case process_response(response, question_data) do
      {:ok, tool_result_content} ->
        new_tool_result = answered_tool_result(question_data, response, tool_result_content)
        save_user_facing_message(agent, question_data, response)

        {:ok, State.replace_tool_result(state, question_data.tool_call_id, new_tool_result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_multiple_questions(agent, state, interrupts, responses) do
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
            new_tool_result = answered_tool_result(question_data, response, tool_result_content)
            save_user_facing_message(agent, question_data, response)

            {:cont,
             {:ok,
              State.replace_tool_result(acc_state, question_data.tool_call_id, new_tool_result)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp answered_tool_result(question_data, response, content) do
    ToolResult.new!(%{
      tool_call_id: question_data.tool_call_id,
      content: content,
      processed_content: answer_data(response, question_data),
      name: "ask_user",
      is_interrupt: false
    })
  end

  # The structured answer carried in the tool result's `processed_content`.
  # Only called after `process_response/2` accepted the response.
  defp answer_data(%{type: :cancel}, _question_data), do: %{type: :cancel}

  defp answer_data(%{type: :answer} = response, question_data) do
    selected =
      response
      |> Map.get(:selected, [])
      |> Enum.reject(&special_other?(&1, question_data.options))
      |> Enum.map(fn value ->
        %{label: lookup_label(question_data.options, value), value: value}
      end)

    other_text =
      case Map.get(response, :other_text) do
        text when is_binary(text) and text != "" -> text
        _other -> nil
      end

    %{type: :answer, selected: selected, other_text: other_text}
  end

  # Fire a synthetic display message so the user's answer (or cancellation)
  # appears in the conversation transcript. Skipped when called outside a live
  # AgentServer context (nil agent in unit tests, missing agent_id, or a cast
  # to a registered name that isn't currently alive).
  defp save_user_facing_message(nil, _question_data, _response), do: :ok

  defp save_user_facing_message(%{agent_id: agent_id}, question_data, response)
       when is_binary(agent_id) do
    case user_facing_attrs(response, question_data) do
      {:ok, attrs} ->
        try do
          AgentServer.save_synthetic_message_from(agent_id, attrs)
        catch
          :exit, _reason -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp save_user_facing_message(_agent, _question_data, _response), do: :ok

  # -- Tool definition --

  defp build_ask_user_tool(config) do
    Function.new!(%{
      name: "ask_user",
      description:
        "Ask the user a structured question when you need their input to make a decision. " <>
          "Use this for significant choices where multiple valid approaches exist.",
      display_text: "Asking a question",
      parameters_schema: build_parameters_schema(config),
      function: fn args, _context ->
        execute_ask_user(args, config)
      end
    })
  end

  defp build_parameters_schema(config) do
    response_types = config.response_types

    base_properties = %{
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
            label: %{
              type: "string",
              description:
                "The answer as the user would say it, on a single line. If the user picks " <>
                  "this option, this text is returned to you as their answer, unless you set value."
            },
            value: %{
              type: "string",
              description:
                "Optional. Omit it unless you need a clear, short key for this option. " <>
                  "When omitted, the label is used."
            },
            description: %{
              type: "string",
              description: "Optional description with tradeoffs or details"
            }
          },
          required: ["label"]
        }
      },
      context: %{
        type: "string",
        description: "Additional context to help the user understand the decision"
      }
    }

    # A forced flag is dropped from the schema so the LLM can't (and isn't asked
    # to) set it. An unforced flag (nil) is exposed as today.
    properties =
      base_properties
      |> maybe_put_flag_property(:allow_other, config.forced_allow_other, %{
        type: "boolean",
        description: "Whether to allow a freeform 'other' option alongside selections"
      })
      |> maybe_put_flag_property(:allow_cancel, config.forced_allow_cancel, %{
        type: "boolean",
        description: "Whether the user can cancel/dismiss this question"
      })

    %{
      type: "object",
      properties: properties,
      required: ["question", "response_type"]
    }
  end

  defp maybe_put_flag_property(properties, _key, forced, _schema) when is_boolean(forced),
    do: properties

  defp maybe_put_flag_property(properties, key, nil, schema),
    do: Map.put(properties, key, schema)

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
        allow_other: resolve_flag(config.forced_allow_other, args, "allow_other", false),
        allow_cancel: resolve_flag(config.forced_allow_cancel, args, "allow_cancel", true),
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
      _other -> {:error, "Question must be a string"}
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

      _other ->
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

  @option_example ~s|{"label": "Yes", "description": "Optional details"}|

  # Normalizes each option and checks that labels and values are unique. Both
  # checks run on the normalized form, so labels that differ only in line
  # breaks, or a label that equals another option's explicit value, collide.
  defp validate_option_items(options) do
    result =
      Enum.reduce_while(options, {:ok, [], MapSet.new(), MapSet.new()}, fn opt,
                                                                           {:ok, acc, labels,
                                                                            values} ->
        with {:ok, option} <- normalize_option(opt),
             :ok <- check_unique(labels, option.label, "label"),
             :ok <- check_unique(values, option.value, "value") do
          {:cont,
           {:ok, [option | acc], MapSet.put(labels, option.label),
            MapSet.put(values, option.value)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, normalized, _labels, _values} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_option(%{} = opt) do
    case normalize_label(Map.get(opt, "label")) do
      "" ->
        {:error, "Each option needs a non-empty 'label', e.g. #{@option_example}"}

      label ->
        {:ok,
         %{
           label: label,
           value: option_value(Map.get(opt, "value"), label),
           description: Map.get(opt, "description")
         }}
    end
  end

  defp normalize_option(_opt) do
    {:error, "Each option must be an object, e.g. #{@option_example}"}
  end

  # A label is one line. A line break and the whitespace around it become a
  # single space, so the label stays one line in the result text and the UI.
  defp normalize_label(label) when is_binary(label) do
    label
    |> String.replace(~r/\s*[\r\n]+\s*/, " ")
    |> String.trim()
  end

  defp normalize_label(_label), do: ""

  # The LLM's value is used when it is a non-empty string. Otherwise the label
  # is the value, so the label is what the LLM gets back as the answer.
  defp option_value(value, _label) when is_binary(value) and value != "", do: value
  defp option_value(_value, label), do: label

  defp check_unique(seen, item, field) do
    if MapSet.member?(seen, item) do
      {:error,
       "Duplicate option #{field}: #{inspect(item)}. Each option needs a distinct #{field}."}
    else
      :ok
    end
  end

  defp get_boolean_arg(args, key, default) do
    case Map.get(args, key) do
      val when is_boolean(val) -> val
      _other -> default
    end
  end

  # A forced config value wins and the LLM-provided arg is ignored. When not
  # forced (nil), fall back to the LLM arg with its existing default.
  defp resolve_flag(forced, _args, _key, _default) when is_boolean(forced), do: forced
  defp resolve_flag(nil, args, key, default), do: get_boolean_arg(args, key, default)

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

      _other ->
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
    case Map.get(response, :selected, []) do
      [value] ->
        valid_values = Enum.map(question_data.options, & &1.value)
        validate_single_value(value, response, question_data, valid_values)

      _multiples ->
        {:error, "single_select requires exactly one selection"}
    end
  end

  defp validate_single_value(value, response, question_data, valid_values) do
    # "other" is only the special allow_other value when it's NOT a regular option
    special_other? = value == "other" and "other" not in valid_values

    cond do
      special_other? and not question_data.allow_other ->
        {:error, "'other' is not allowed for this question"}

      special_other? ->
        other_text = Map.get(response, :other_text, "")
        {:ok, "User selected: other\nAdditional input: \"#{other_text}\""}

      value not in valid_values ->
        {:error,
         "Selected value '#{value}' is not a valid option. Valid: #{inspect(valid_values)}"}

      true ->
        text = "User selected: #{value}"

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
      not is_list(selected) or selected == [] ->
        {:error, "multi_select requires at least one selection"}

      has_special_other? and not question_data.allow_other ->
        {:error, "'other' is not allowed for this question"}

      Enum.any?(non_special_other, fn v -> v not in valid_values end) ->
        invalid = Enum.reject(non_special_other, fn v -> v in valid_values end)
        {:error, "Invalid selections: #{inspect(invalid)}. Valid: #{inspect(valid_values)}"}

      true ->
        text = "User selected:\n" <> Enum.map_join(selected, "\n", &"- #{&1}")

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

      _other ->
        {:error, "freeform 'other_text' must be a string"}
    end
  end

  # -- User-facing display formatting --
  #
  # Produces synthetic display message attrs from a user response. Uses option
  # *labels* (what the user saw). `process_response/2` builds the LLM-facing
  # text from option *values*, which are the labels unless the LLM supplied its
  # own.

  @doc false
  @spec user_facing_attrs(map(), map()) :: {:ok, map()} | {:error, term()}
  def user_facing_attrs(%{type: :cancel}, %{allow_cancel: true}) do
    {:ok, notification_attrs("User cancelled")}
  end

  def user_facing_attrs(%{type: :cancel}, _question_data) do
    {:error, :cancellation_not_allowed}
  end

  def user_facing_attrs(%{type: :answer} = response, %{response_type: :freeform}) do
    case Map.get(response, :other_text) do
      text when is_binary(text) and byte_size(text) > 0 -> {:ok, user_text_attrs(text)}
      _other -> {:error, :empty_freeform}
    end
  end

  def user_facing_attrs(%{type: :answer} = response, %{response_type: :single_select} = q) do
    case Map.get(response, :selected, []) do
      [value] when is_binary(value) ->
        cond do
          special_other?(value, q.options) and not Map.get(q, :allow_other, false) ->
            {:error, :other_not_allowed}

          special_other?(value, q.options) ->
            other_text = Map.get(response, :other_text, "")
            {:ok, user_text_attrs("Other:  \n#{other_text}")}

          true ->
            {:ok, user_text_attrs(lookup_label(q.options, value))}
        end

      _other ->
        {:error, :invalid_single_select}
    end
  end

  def user_facing_attrs(%{type: :answer} = response, %{response_type: :multi_select} = q) do
    case Map.get(response, :selected, []) do
      selected when is_list(selected) and selected != [] ->
        build_multi_select_attrs(response, q, selected)

      _other ->
        {:error, :invalid_multi_select}
    end
  end

  def user_facing_attrs(_response, _question_data), do: {:error, :invalid_response}

  defp build_multi_select_attrs(response, q, selected) do
    has_other? = Enum.any?(selected, &special_other?(&1, q.options))

    if has_other? and not Map.get(q, :allow_other, false) do
      {:error, :other_not_allowed}
    else
      regular = Enum.reject(selected, &special_other?(&1, q.options))
      labels_list = Enum.map_join(regular, "\n", &"- #{lookup_label(q.options, &1)}")
      other_text = if has_other?, do: Map.get(response, :other_text, ""), else: nil
      {:ok, user_text_attrs(format_multi_select(labels_list, other_text))}
    end
  end

  # A blank line ends the Markdown list, so "Other:" renders as its own
  # paragraph rather than continuing the last list item.
  defp format_multi_select(labels_list, nil), do: labels_list
  defp format_multi_select("", other_text), do: "Other:  \n#{other_text}"
  defp format_multi_select(list, other_text), do: "#{list}\n\nOther:  \n#{other_text}"

  defp lookup_label(options, value) do
    case Enum.find(options, &(&1.value == value)) do
      %{label: label} when is_binary(label) -> label
      _other -> value
    end
  end

  # The special "Other" sentinel only applies when "other" is NOT a regular
  # option value -- otherwise the LLM provided "other" as a real choice.
  defp special_other?(value, options) do
    value == "other" and not Enum.any?(options, &(&1.value == "other"))
  end

  defp user_text_attrs(text) do
    %{
      message_type: "user",
      content_type: "text",
      content: %{"text" => text}
    }
  end

  defp notification_attrs(text) do
    %{
      message_type: "system",
      content_type: "notification",
      content: %{"text" => text}
    }
  end

  # -- System prompt --

  defp build_system_prompt(config) do
    response_types = config.response_types

    type_instructions =
      Enum.map_join(response_types, "\n", fn
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
    #{option_guidance(config)}#{flag_guidance(config)}
    """
  end

  # Option-label guidance applies only when a select type is enabled. A
  # freeform-only configuration has no options.
  defp option_guidance(config) do
    if Enum.any?(config.response_types, &(&1 in [:single_select, :multi_select])) do
      "- Write each option label as the answer itself, on one line, the way the user would say it\n"
    else
      ""
    end
  end

  # Only guide the LLM about a flag it actually controls. A forced flag is
  # absent from the tool schema, so mentioning it here would be misleading.
  defp flag_guidance(config) do
    [
      if(is_nil(config.forced_allow_cancel),
        do: "- Set allow_cancel to true unless the question blocks critical progress"
      ),
      if(is_nil(config.forced_allow_other),
        do: "- Set allow_other to true only when a custom 'Other' answer would genuinely help"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
