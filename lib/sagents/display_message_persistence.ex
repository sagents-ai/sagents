defmodule Sagents.DisplayMessagePersistence do
  @moduledoc """
  Behaviour for persisting display messages (user-facing message representations).

  Display messages are the UI-friendly representations of conversation turns:
  text messages, tool call cards, thinking blocks, error notifications, etc.
  They are separate from the agent's internal state and optimized for rendering.

  ## When callbacks are invoked

  All callbacks are invoked from within the AgentServer process, ensuring
  exactly-once semantics regardless of how many LiveViews are connected.

  ### Message saving

  `save_message/2` is called when a new LangChain Message is processed.
  A single Message can produce multiple display messages (e.g., text + tool_calls).
  The implementation should return the saved records so AgentServer can
  broadcast `{:display_message_saved, msg}` events to connected LiveViews.

  ### Tool execution lifecycle

  Tool execution status updates reflect the lifecycle of tool calls:

  1. Tool call identified → message saved with status "pending" (via `save_message/2`)
  2. Tool execution starts → `update_tool_status/2` with status `:executing`
  3. Tool execution ends → `update_tool_status/2` with status `:completed` or `:failed`

  ## Configuration

  Per-agent via AgentServer start options:

      supervisor_config = [
        agent_id: agent_id,
        conversation_id: conversation_id,
        display_message_persistence: MyApp.DisplayMessagePersistence,
        # ... other config
      ]

  If not configured, no display messages are persisted. The agent still
  broadcasts PubSub events for real-time streaming — LiveViews can render
  messages from events alone without persistence.
  """

  @doc """
  Save a LangChain Message as one or more display messages.

  A single `LangChain.Message` may produce multiple display messages
  (e.g., an assistant message with text content + tool calls produces
  a text display message and one or more tool_call display messages).

  The implementation should:
  1. Convert the Message into display message records
  2. Persist them to the database
  3. Return the list of saved records

  AgentServer broadcasts `{:display_message_saved, msg}` for each
  returned record, so connected LiveViews can update their UI.

  ## Parameters

  - `conversation_id` — Identifier for the conversation
  - `message` — The `LangChain.Message` struct to persist

  ## Returns

  - `{:ok, [saved_messages]}` — List of persisted display message records
  - `{:error, reason}` — Persistence failed (logged, does not affect agent)
  """
  @callback save_message(conversation_id :: String.t(), message :: LangChain.Message.t()) ::
              {:ok, list()} | {:error, term()}

  @type tool_status :: :executing | :completed | :failed

  @doc """
  Update the status of a persisted tool call display message.

  Called at each stage of the tool execution lifecycle. The `tool_info`
  map contains the tool call identifier and any status-specific metadata.

  ## Parameters

  - `status` — The new status: `:executing`, `:completed`, or `:failed`
  - `tool_info` — Map with at minimum `:call_id`, plus status-specific fields:

    | Status | Fields |
    |--------|--------|
    | `:executing` | `%{call_id: "...", name: "...", display_text: "..."}` |
    | `:completed` | `%{call_id: "...", name: "...", result: "..."}` |
    | `:failed` | `%{call_id: "...", name: "...", error: "..."}` |

  ## Returns

  - `{:ok, updated_message}` — Updated record, broadcast to LiveViews as `{:display_message_updated, msg}`
  - `{:error, :not_found}` — No matching tool call exists (normal if persistence wasn't configured when call was saved)
  """
  @callback update_tool_status(status :: tool_status(), tool_info :: map()) ::
              {:ok, term()} | {:error, :not_found | term()}
end
