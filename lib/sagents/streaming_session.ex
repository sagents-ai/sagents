defmodule Sagents.StreamingSession do
  @moduledoc """
  Host-agnostic helpers for tracking the streaming-tool-call lifecycle on a
  caller's session state.

  Hosts (Phoenix LiveView, plain GenServers, GraphQL bridges) keep a session
  state map that includes a `:streaming_delta` key. This module takes that
  state plus a lifecycle event and returns a *changes map* the host merges
  back in whatever way fits — `assign/3` for LiveView, `Map.merge/2` for
  GenServer state, and so on.

  Two events are supported:

    * **Tool call identified** — fired when the LLM has named a tool it wants
      to invoke but execution hasn't started. Creates a `LangChain.MessageDelta`
      if one isn't already in flight, otherwise upserts the new call into the
      existing delta so multiple tool calls in one assistant turn share one
      delta.

    * **Tool execution update** — fired as a tool moves through
      `:executing → :completed | :failed`, or pauses on `:interrupted`
      (e.g. `ask_user` or a human-in-the-loop approval). Updates the
      call's execution status metadata. The `:streaming_delta` is only
      cleared once every tool call in the delta has reached a terminal
      status (`"completed"` or `"failed"`); `:interrupted` is *not*
      terminal — the call is paused, not finished — so sibling calls
      still in flight (and the interrupted call itself) keep their UI
      state.

  Both functions return an empty map (`%{}`) when the event has no
  `:call_id`, leaving the host's state untouched.

  ## tool_info shape

      %{
        call_id: "call_123",     # required for any state change
        name: "read_file",       # tool name
        display_text: "Reading"  # optional; refines as more info arrives
      }
  """

  alias LangChain.Message.ToolCall
  alias LangChain.MessageDelta

  @type tool_info :: %{
          optional(:call_id) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:display_text) => String.t() | nil
        }

  @type lifecycle_status :: :executing | :completed | :failed | :interrupted

  @doc """
  Apply a "tool call identified" event to the session state. Returns a
  changes map the caller merges into its state.

  Behaviour:

    * If `state.streaming_delta` is nil, builds a fresh
      `LangChain.MessageDelta` containing the new tool call.
    * If a delta is already in flight, upserts the new call into it (by
      `call_id`), then sets the call's execution status to `"identified"`.
    * If `tool_info[:call_id]` is nil, returns `%{}` — there is nothing
      to attach the lifecycle metadata to.
  """
  @spec handle_tool_call_identified(map(), tool_info()) :: map()
  def handle_tool_call_identified(_state, %{call_id: nil}), do: %{}

  def handle_tool_call_identified(_state, tool_info) when not is_map_key(tool_info, :call_id),
    do: %{}

  def handle_tool_call_identified(state, tool_info) do
    call_id = tool_info[:call_id]
    name = tool_info[:name]
    display_text = tool_info[:display_text]

    new_call = %ToolCall{
      call_id: call_id,
      name: name,
      display_text: display_text,
      status: :incomplete,
      metadata: %{"execution_status" => "identified"}
    }

    base =
      Map.get(state, :streaming_delta) || %MessageDelta{role: :assistant, status: :incomplete}

    updated =
      base
      |> MessageDelta.upsert_tool_call(new_call)
      |> MessageDelta.set_tool_execution_status(call_id, "identified")

    %{streaming_delta: updated}
  end

  @doc """
  Apply a tool-execution lifecycle update to the session state. Returns a
  changes map the caller merges into its state.

  Behaviour:

    * If there is no `:streaming_delta` to update, returns `%{}`.
    * Updates the matching call's `"execution_status"` metadata
      (`"executing"`, `"completed"`, `"failed"`, or `"interrupted"`).
    * On `:executing` or `:interrupted`, also forwards
      `tool_info[:display_text]` so callers can refine the UI label as
      the tool collects more context (or surface the paused state). Nil
      `display_text` is a no-op, preserving any prior value.
    * Once every tool call in the delta has reached a terminal status
      (`"completed"` or `"failed"`), returns `%{streaming_delta: nil}` to
      clear the streaming UI. `:interrupted` is treated as paused, not
      terminal, so the delta stays in place until the call resumes and
      eventually completes or fails. Until then the delta also stays so
      sibling tool calls still in flight keep their UI state.
    * If `tool_info[:call_id]` is nil, returns `%{}`.
  """
  @spec handle_tool_execution_update(map(), lifecycle_status(), tool_info()) :: map()
  def handle_tool_execution_update(_state, _status, %{call_id: nil}), do: %{}

  def handle_tool_execution_update(_state, _status, tool_info)
      when not is_map_key(tool_info, :call_id),
      do: %{}

  def handle_tool_execution_update(state, status, tool_info)
      when status in [:executing, :completed, :failed, :interrupted] do
    case Map.get(state, :streaming_delta) do
      nil ->
        %{}

      %MessageDelta{} = delta ->
        call_id = tool_info[:call_id]
        status_string = lifecycle_status_string(status)

        updated =
          delta
          |> maybe_set_display_text(status, call_id, tool_info[:display_text])
          |> MessageDelta.set_tool_execution_status(call_id, status_string)

        if MessageDelta.all_tools_terminal?(updated) do
          %{streaming_delta: nil}
        else
          %{streaming_delta: updated}
        end
    end
  end

  defp maybe_set_display_text(delta, status, call_id, display_text)
       when status in [:executing, :interrupted],
       do: MessageDelta.set_tool_display_text(delta, call_id, display_text)

  defp maybe_set_display_text(delta, _other, _call_id, _display_text), do: delta

  defp lifecycle_status_string(:executing), do: "executing"
  defp lifecycle_status_string(:completed), do: "completed"
  defp lifecycle_status_string(:failed), do: "failed"
  defp lifecycle_status_string(:interrupted), do: "interrupted"
end
