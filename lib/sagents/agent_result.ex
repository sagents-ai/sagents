defmodule Sagents.AgentResult do
  @moduledoc """
  Helpers for reading structured results out of an `Sagents.Agent.execute/3`
  return value.

  `Sagents.Agent.execute/3` can return any of:

    * `{:ok, %State{}}` — normal completion. Last message may be assistant prose
      or an assistant tool call followed by tool results.
    * `{:ok, %State{}, %ToolResult{}}` — `until_tool` completion. The third
      element is the `LangChain.Message.ToolResult` produced by the target tool.
    * `{:interrupt, %State{}, interrupt_data}` — paused for HITL/ask-user.
    * `{:pause, %State{}}` — infrastructure pause.
    * `{:error, term()}` — execution failed.

  This module's job is to translate those shapes into a focused payload for
  callers doing structured-extraction or single-invocation workflows. It is
  intentionally a thin read layer — it does not validate, retry, or coerce. It
  mirrors
  `LangChain.Utils.ChainResult`, which serves the same role for `LLMChain`.

  ## Functions

    * `tool_result/1` — pull the `%ToolResult{}` out of a 3-tuple, or find the
      last tool result in `state.messages` for the 2-tuple case.
    * `tool_arguments/1` — the LLM-supplied arguments map. This is what
      structured-extraction callers want 95% of the time.
    * `processed_content/1` — the native-Elixir payload, when the tool's body
      returned `{:ok, "string", native_term}`.
    * `to_string/1` — extract a final assistant text response (for executions
      that ended in prose rather than a tool call). Mirrors
      `LangChain.Utils.ChainResult.to_string/1`.

  All functions accept either an `execute/3` return value or a bare `%State{}`.
  Error tuples pass straight through unchanged so callers can pipe.

  ## Examples

      iex> {:ok, _state, _tool_result} = result =
      ...>   Sagents.Agent.execute(agent, state, until_tool: "submit")
      iex> {:ok, args} = Sagents.AgentResult.tool_arguments(result)

      iex> {:ok, state} = Sagents.Agent.execute(agent, state)
      iex> {:ok, text} = Sagents.AgentResult.to_string({:ok, state})
  """

  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias Sagents.State

  @typedoc "Anything `Sagents.Agent.execute/3` can return, or a bare State."
  @type execute_return ::
          State.t()
          | {:ok, State.t()}
          | {:ok, State.t(), ToolResult.t()}
          | {:interrupt, State.t(), any()}
          | {:pause, State.t()}
          | {:error, any()}

  @doc """
  Return the `%ToolResult{}` carried by an `until_tool` 3-tuple.

  For a 2-tuple or bare `%State{}`, walks back through `state.messages` and
  returns the most recent successful (non-error) tool result, if any. Returns
  `{:error, %LangChainError{}}` when no usable tool result is present.
  """
  @spec tool_result(execute_return()) ::
          {:ok, ToolResult.t()} | {:error, LangChainError.t()} | {:error, any()}
  def tool_result({:ok, %State{}, %ToolResult{} = tr}), do: {:ok, tr}

  def tool_result({:ok, %State{} = state}), do: tool_result(state)

  def tool_result(%State{messages: messages}) do
    case last_tool_result(messages) do
      nil ->
        {:error,
         LangChainError.exception(
           type: "no_tool_result",
           message: "No tool result found in state.messages"
         )}

      %ToolResult{} = tr ->
        {:ok, tr}
    end
  end

  def tool_result({:interrupt, _state, _data} = passthrough), do: passthrough_error(passthrough)
  def tool_result({:pause, _state} = passthrough), do: passthrough_error(passthrough)
  def tool_result({:error, _reason} = err), do: err

  @doc """
  Return the LLM-supplied arguments map from the result tool call.

  Prefers `tool_call.arguments` from the assistant message that produced the
  tool result (this is what the LLM actually emitted, already parsed from JSON
  by LangChain). Falls back to the 3-tuple's `%ToolResult{}` when the matching
  tool call can't be located.

  This is the right call for structured-extraction workflows where the schema
  *is* the tool's `parameters_schema`.
  """
  @spec tool_arguments(execute_return()) ::
          {:ok, map()} | {:error, LangChainError.t()} | {:error, any()}
  def tool_arguments({:ok, %State{} = state, %ToolResult{tool_call_id: id}}) do
    case find_tool_call(state.messages, id) do
      %ToolCall{arguments: args} when is_map(args) -> {:ok, args}
      _other -> {:error, no_arguments_error()}
    end
  end

  def tool_arguments({:ok, %State{} = state}), do: tool_arguments(state)

  def tool_arguments(%State{messages: messages}) do
    case last_assistant_tool_call(messages) do
      %ToolCall{arguments: args} when is_map(args) -> {:ok, args}
      _other -> {:error, no_arguments_error()}
    end
  end

  def tool_arguments({:interrupt, _state, _data} = passthrough),
    do: passthrough_error(passthrough)

  def tool_arguments({:pause, _state} = passthrough), do: passthrough_error(passthrough)
  def tool_arguments({:error, _reason} = err), do: err

  @doc """
  Return the `processed_content` of the result tool — the native Elixir term a
  tool body can attach by returning `{:ok, "string for LLM", native_term}`.

  Useful when the tool wants to hand back something richer than a JSON-parseable
  argument map (a struct, a tuple, etc.).
  """
  @spec processed_content(execute_return()) ::
          {:ok, any()} | {:error, LangChainError.t()} | {:error, any()}
  def processed_content(input) do
    case tool_result(input) do
      {:ok, %ToolResult{processed_content: nil}} ->
        {:error,
         LangChainError.exception(
           type: "no_processed_content",
           message: "Tool result has no processed_content set"
         )}

      {:ok, %ToolResult{processed_content: content}} ->
        {:ok, content}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Return the final assistant message content as a string.

  Mirrors `LangChain.Utils.ChainResult.to_string/1`. For executions that ended
  with prose rather than a tool call.

  Returns `{:error, %LangChainError{}}` if the last message is not a complete
  assistant message.
  """
  @spec to_string(execute_return()) ::
          {:ok, String.t()} | {:error, LangChainError.t()} | {:error, any()}
  def to_string({:ok, %State{} = state}), do: __MODULE__.to_string(state)
  def to_string({:ok, %State{} = state, _extra}), do: __MODULE__.to_string(state)

  def to_string(%State{messages: messages}) do
    case List.last(messages) do
      %Message{role: :assistant, status: :complete, content: content} ->
        {:ok, content_to_string(content)}

      %Message{role: :assistant, status: status} ->
        {:error,
         LangChainError.exception(
           type: "to_string",
           message: "Assistant message is incomplete (status: #{inspect(status)})"
         )}

      %Message{role: role} ->
        {:error,
         LangChainError.exception(
           type: "to_string",
           message: "Last message is not from assistant (role: #{inspect(role)})"
         )}

      nil ->
        {:error, LangChainError.exception(type: "to_string", message: "No messages in state")}
    end
  end

  def to_string({:interrupt, _state, _data} = passthrough), do: passthrough_error(passthrough)
  def to_string({:pause, _state} = passthrough), do: passthrough_error(passthrough)
  def to_string({:error, _reason} = err), do: err

  # ── Private ──────────────────────────────────────────────────────

  defp last_tool_result(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :tool, tool_results: results} when is_list(results) ->
        Enum.find(results, fn r -> not r.is_error end) || List.last(results)

      _other ->
        nil
    end)
  end

  defp last_assistant_tool_call(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, tool_calls: [_head | _rest] = calls} -> List.last(calls)
      _other -> nil
    end)
  end

  defp find_tool_call(messages, tool_call_id) do
    messages
    |> Enum.find_value(fn
      %Message{role: :assistant, tool_calls: calls} when is_list(calls) ->
        Enum.find(calls, &(&1.call_id == tool_call_id))

      _other ->
        nil
    end)
  end

  defp content_to_string(content) when is_binary(content), do: content
  defp content_to_string(content) when is_list(content), do: ContentPart.parts_to_string(content)
  defp content_to_string(nil), do: ""

  defp no_arguments_error do
    LangChainError.exception(
      type: "no_tool_arguments",
      message: "No assistant tool call with arguments found"
    )
  end

  defp passthrough_error({:interrupt, _state, _data}) do
    {:error,
     LangChainError.exception(
       type: "interrupted",
       message: "Agent was interrupted; cannot extract result"
     )}
  end

  defp passthrough_error({:pause, _state}) do
    {:error,
     LangChainError.exception(
       type: "paused",
       message: "Agent was paused; cannot extract result"
     )}
  end
end
