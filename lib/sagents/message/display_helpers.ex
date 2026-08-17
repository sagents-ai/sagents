defmodule Sagents.Message.DisplayHelpers do
  @moduledoc """
  Utilities for extracting displayable content from LangChain Messages.

  These helpers bridge the gap between LangChain Message structs and
  application-specific display schemas. They handle the complexity of:
  - Extracting text, thinking, tool_calls, and tool_results
  - Proper sequencing when a single Message contains multiple display items
  - Converting structs to maps with string keys (JSON-compatible)

  ## Usage in Generated Code

  Mix task templates should demonstrate this pattern:

      # In your LiveView or context module
      def persist_message(%Message{} = message, conversation_id) do
        message
        |> DisplayHelpers.extract_display_items()
        |> Enum.with_index()
        |> Enum.map(fn {item, sequence} ->
          attrs = Map.put(item, "sequence", sequence)
          create_display_message(conversation_id, attrs)
        end)
      end

  This gives users full control over their schema while providing
  library utilities that handle the extraction complexity.
  """

  alias LangChain.LangChainError
  alias LangChain.Message

  @typedoc """
  Why a message stopped, normalized from `LangChain.Message.status`.

  - `nil` - the model finished on its own
  - `:length` - the model hit the output token cap
  - `:cancelled` - the caller stopped the run
  - `:content_filtered` - the provider's content filter stopped the response
  - `:stream_error` - the stream died mid-flight (`overloaded`, an invalid
    request, transport-level filtering)

  Every value other than `nil` means the same thing to a reader ("it stopped
  early"), so a host can treat the classification as one concept and vary the
  wording per value. `:content_filtered` may additionally carry provider detail
  naming the cause; see `stop_details/1`.
  """
  @type stop_reason :: nil | :length | :cancelled | :content_filtered | :stream_error

  @doc """
  Classifies why a message stopped.

  Returns `nil` when the model finished. See `t:stop_reason/0` for the other
  values.

  ## Durability

  The classification survives a state round trip. `Message.status` is
  serialized, and `Sagents.Persistence.StateSerializer` projects the two metadata
  keys this module reads, so a message restored from persisted agent state
  classifies the way it did in the turn that produced it — including where
  metadata is the only discriminator, which is how LangChain releases below
  v0.10.0 record a dead stream.

  The projection is narrower than the live value. `streaming_error/1` returns an
  error carrying the failure's `type` and `message` but not the `:original` term
  behind it, which can be any term and does not belong in a persisted state.

  ## Examples

      iex> Sagents.Message.DisplayHelpers.stop_reason(LangChain.Message.new_assistant!("done"))
      nil

      iex> message = %LangChain.Message{role: :assistant, status: :length}
      iex> Sagents.Message.DisplayHelpers.stop_reason(message)
      :length
  """
  @spec stop_reason(Message.t()) :: stop_reason()
  def stop_reason(%Message{status: :length}), do: :length
  def stop_reason(%Message{status: :content_filtered}), do: :content_filtered
  def stop_reason(%Message{status: :stream_error}), do: :stream_error

  # Part of the supported LangChain range records a dead stream as :cancelled
  # carrying the error, rather than as :stream_error.
  def stop_reason(%Message{status: :cancelled, metadata: %{streaming_error: error}})
      when not is_nil(error),
      do: :stream_error

  def stop_reason(%Message{status: :cancelled}), do: :cancelled
  def stop_reason(%Message{}), do: nil

  @doc """
  Returns the error that killed the stream, or `nil`.

  Keyed on the metadata alone rather than on the status, so it answers the same
  way for either shape the supported LangChain range records a dead stream in.
  Survives a state round trip carrying `type` and `message`; see the durability
  note on `stop_reason/1`.
  """
  @spec streaming_error(Message.t()) :: LangChainError.t() | nil
  def streaming_error(%Message{metadata: %{streaming_error: error}}), do: error
  def streaming_error(%Message{}), do: nil

  @doc """
  Returns the provider's detail about why the response was stopped, or `nil`.

  Populated by providers that name a cause beyond the status itself. Anthropic
  sends it on a refusal as `%{"type" => "refusal", "category" => ...,
  "explanation" => ...}` and omits it for every other stop reason, so a stop can
  carry a reason with no detail.

  Unlike `streaming_error/1` this is plain JSON rather than a struct, so
  `extract_display_items/1` carries it into the item's `content` verbatim and
  agent state stores it as it stands, with no projection.
  """
  @spec stop_details(Message.t()) :: map() | nil
  def stop_details(%Message{metadata: %{stop_details: details}}) when is_map(details), do: details
  def stop_details(%Message{}), do: nil

  @doc """
  Extracts all displayable items from a Message.

  Returns a list of maps, each representing one displayable item.
  A single Message can produce multiple items (e.g., text + tool_calls).

  ## Return Format

  Each map contains atom keys:
  - `:type` - One of: :text, :thinking, :tool_call, :tool_result
  - `:message_type` - Role-based: :user, :assistant, :tool, :system
  - `:content` - Map with type-specific content (string keys for JSONB storage)

  The order of items in the list represents the display order.
  The caller should assign sequence numbers (0, 1, 2, ...) when persisting.

  **Note**: No mixed maps - top-level keys are atoms, content payload uses string keys.

  ## Messages that stopped early

  When `stop_reason/1` classifies the message as unfinished, the **last** item's
  `content` carries a `"stop_reason"` string: `"length"`, `"cancelled"`,
  `"content_filtered"`, or `"stream_error"`. Messages the model finished carry no
  such key, so a host renders the mark on the truthiness of
  `content["stop_reason"]` rather than having to compare against `nil`.

  When the provider named a cause beyond the status, `"stop_details"` sits
  alongside it on the same item, carrying the provider's own map. It is absent
  otherwise, including for stops that carry a reason but no detail.

  Only the last item is marked. A single message can yield several items
  (thinking, then text, then tool calls), and the mark reads as "and then it
  stopped", which is true only of the final thing said. The framework decides
  this so that every host renders it the same way.

  The key rides in `content` rather than alongside it because hosts persist
  `item.content` verbatim into a JSONB column. Nothing has to be mapped, and no
  `content_type` whitelist or migration is involved.

  ## Examples

      # Assistant message with text and tool calls
      message = Message.new_assistant!(%{
        content: [ContentPart.text!("Let me search...")],
        tool_calls: [
          ToolCall.new!(%{call_id: "1", name: "search", arguments: %{q: "elixir"}}),
          ToolCall.new!(%{call_id: "2", name: "weather", arguments: %{city: "NYC"}})
        ]
      })

      DisplayHelpers.extract_display_items(message)
      # => [
      #   %{type: :text, message_type: :assistant, content: %{"text" => "Let me search..."}},
      #   %{type: :tool_call, message_type: :assistant, content: %{"call_id" => "1", "name" => "search", "arguments" => %{q: "elixir"}}},
      #   %{type: :tool_call, message_type: :assistant, content: %{"call_id" => "2", "name" => "weather", "arguments" => %{city: "NYC"}}}
      # ]

      # Tool result message with multiple results
      message = Message.new_tool_result!(%{
        tool_results: [
          ToolResult.new!(%{tool_call_id: "1", name: "search", content: "Found...", is_error: false}),
          ToolResult.new!(%{tool_call_id: "2", name: "weather", content: "Sunny", is_error: false})
        ]
      })

      DisplayHelpers.extract_display_items(message)
      # => [
      #   %{type: :tool_result, message_type: :tool, content: %{"tool_call_id" => "1", "name" => "search", "content" => "Found...", "is_error" => false}},
      #   %{type: :tool_result, message_type: :tool, content: %{"tool_call_id" => "2", "name" => "weather", "content" => "Sunny", "is_error" => false}}
      # ]
  """
  @spec extract_display_items(Message.t()) :: [map()]
  def extract_display_items(%Message{} = message) do
    items = []

    # Extract text/thinking content if present
    items = items ++ extract_content_items(message)

    # Extract tool_calls if present (assistant messages)
    items = items ++ extract_tool_call_items(message)

    # Extract tool_results if present (tool messages)
    items = items ++ extract_tool_result_items(message)

    mark_last_item(items, stop_reason(message), stop_details(message))
  end

  # Stamp the stop reason onto the final item's content. A message that stopped
  # while producing nothing extractable yields no items, and so no place to put
  # the mark.
  defp mark_last_item(items, nil, _stop_details), do: items
  defp mark_last_item([], _stop_reason, _stop_details), do: []

  defp mark_last_item(items, stop_reason, stop_details) do
    {leading, [last]} = Enum.split(items, -1)

    content =
      last.content
      |> Map.put("stop_reason", Atom.to_string(stop_reason))
      |> put_stop_details(stop_details)

    leading ++ [%{last | content: content}]
  end

  # Only providers that name a cause contribute detail, so the key is absent
  # rather than nil when there is none. Hosts match on presence.
  defp put_stop_details(content, details) when is_map(details),
    do: Map.put(content, "stop_details", details)

  defp put_stop_details(content, _details), do: content

  # Extract text and thinking content from message.content
  defp extract_content_items(%Message{content: content, role: role}) do
    message_type = role_to_message_type(role)

    case content do
      # String content (simple text)
      text when is_binary(text) and text != "" ->
        [
          %{
            type: :text,
            message_type: message_type,
            content: %{"text" => text}
          }
        ]

      # List of ContentParts (text, thinking, etc.)
      parts when is_list(parts) ->
        parts
        |> Enum.filter(fn part -> part.type in [:text, :thinking] end)
        |> Enum.reject(fn part -> is_nil(part.content) or part.content == "" end)
        |> Enum.map(fn part ->
          %{
            type: part.type,
            message_type: message_type,
            content: %{"text" => part.content}
          }
        end)

      _other ->
        []
    end
  end

  # Extract tool_calls into display items
  defp extract_tool_call_items(%Message{tool_calls: tool_calls, role: role})
       when is_list(tool_calls) and tool_calls != [] do
    Enum.map(tool_calls, fn tool_call ->
      %{
        type: :tool_call,
        message_type: role_to_message_type(role),
        content: %{
          "call_id" => tool_call.call_id,
          "name" => tool_call.name,
          "arguments" => tool_call.arguments,
          "display_text" => tool_call.display_text
        }
      }
    end)
  end

  defp extract_tool_call_items(_message), do: []

  # Extract tool_results into display items
  defp extract_tool_result_items(%Message{tool_results: tool_results, role: role})
       when is_list(tool_results) and tool_results != [] do
    message_type = role_to_message_type(role)

    Enum.map(tool_results, fn tool_result ->
      # Extract content as string - it may be a list of ContentParts or a string
      content_str = extract_tool_result_content(tool_result.content)

      %{
        type: :tool_result,
        message_type: message_type,
        content: %{
          "tool_call_id" => tool_result.tool_call_id,
          "name" => tool_result.name,
          "content" => content_str,
          "is_error" => tool_result.is_error,
          "is_interrupt" => Map.get(tool_result, :is_interrupt, false)
        }
      }
    end)
  end

  defp extract_tool_result_items(_message), do: []

  # Extract tool result content as a string
  # ToolResult.content can be a string or a list of ContentParts
  defp extract_tool_result_content(content) when is_binary(content), do: content

  defp extract_tool_result_content(content) when is_list(content) do
    # Extract text from ContentParts
    content
    |> Enum.filter(fn part -> part.type == :text end)
    |> Enum.map_join("\n", fn part -> part.content end)
  end

  defp extract_tool_result_content(_other), do: ""

  # Convert Message role to display message_type atom
  defp role_to_message_type(:system), do: :system
  defp role_to_message_type(:user), do: :user
  defp role_to_message_type(:assistant), do: :assistant
  defp role_to_message_type(:tool), do: :tool
end
