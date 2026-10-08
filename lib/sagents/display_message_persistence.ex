defmodule Sagents.DisplayMessagePersistence do
  @moduledoc """
  Behaviour for persisting display messages (user-facing message representations).

  Display messages are the UI-friendly representations of conversation turns:
  text messages, tool call cards, thinking blocks, error notifications, etc.
  They are separate from the agent's internal state and optimized for rendering.

  ## Scope-first contract

  Every callback takes the integrator's scope struct as its first positional argument.

  ## When callbacks are invoked

  All callbacks are invoked from within the AgentServer process, ensuring
  exactly-once semantics regardless of how many LiveViews are connected.

  ### Message saving

  `save_message/3` is called when a new LangChain Message is processed.
  A single Message can produce multiple display messages (e.g., text + tool_calls).
  The implementation should return the saved records so AgentServer can
  broadcast `{:display_message_saved, msg}` events to connected LiveViews.

  ### Tool execution lifecycle

  Tool execution status updates reflect the lifecycle of tool calls:

  1. Tool call identified → message saved with status "pending" (via `save_message/3`)
  2. Tool execution starts → `update_tool_status/4` with status `:executing`
  3. Tool execution ends → `update_tool_status/4` with status `:completed` or `:failed`

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

  ## Narration

  Some models label an utterance as narration: the model saying what it is
  about to do, rather than its reply. An implementation that stores
  `Sagents.Message.DisplayHelpers.extract_display_items/1` output keeps the
  label without doing anything, because it rides inside each item's `content`
  under `"utterance"` and that map is stored verbatim.

  An implementation that builds its own content map instead should carry the
  key across, or a reloaded conversation renders every preamble as a reply.
  `Sagents.Message.DisplayHelpers.narration?/1` answers the same question for a
  whole message.

  Rendering is the host's call. The label is there so a host that wants to show
  narration as a status line rather than a chat bubble can, and one that does
  not care can ignore it.
  """

  @typedoc """
  Context map passed to every callback. Carries cross-cutting identifiers that
  every implementation needs but don't benefit from positional visibility.

  - `:agent_id` - the agent's identifier
  - `:conversation_id` - the conversation the rows belong to, or `nil`
  - `:user_request_seq` - the user request the row belongs to (see
    `Sagents.UserRequest`); 0 before the first human message. Store it on the
    row to group the transcript by user request.
  """
  @type callback_context :: %{
          required(:agent_id) => String.t(),
          required(:conversation_id) => String.t() | nil,
          required(:user_request_seq) => non_neg_integer()
        }

  @type tool_status :: :executing | :completed | :failed | :interrupted | :cancelled

  @doc """
  Save a LangChain Message as one or more display messages.

  A single `LangChain.Message` may produce multiple display messages
  (e.g., an assistant message with text content + tool calls produces
  a text display message and one or more tool_call display messages).

  The implementation should:
  1. Convert the Message into display message records
  2. Persist them to the database (scoped via `scope`)
  3. Return the list of saved records

  Use `Sagents.Message.DisplayHelpers.extract_display_items/1` to do the
  conversion, and store each item's `content` map **verbatim**. Beyond the keys
  a given `content_type` needs for rendering, the framework writes keys of its
  own — `"stop_reason"` and `"stop_details"` on a message the model did not
  finish, `"display_text"` on a tool call. An implementation that rebuilds
  `content` key by key silently drops them. `extract_display_items/1` documents
  the full inventory.

  AgentServer broadcasts `{:display_message_saved, msg}` for each
  returned record, so connected LiveViews can update their UI.

  ## Parameters

  - `scope` — Integrator-defined scope struct (or `nil`). Use to filter DB writes.
  - `message` — The `LangChain.Message` struct to persist
  - `context` — Map with `:agent_id`, `:conversation_id`, and `:user_request_seq`

  ## Returns

  - `{:ok, [saved_messages]}` — List of persisted display message records
  - `{:error, reason}` — Persistence failed (logged, does not affect agent)
  """
  @callback save_message(
              scope :: term() | nil,
              message :: LangChain.Message.t(),
              context :: callback_context()
            ) :: {:ok, list()} | {:error, term()}

  @doc """
  Update the status of a persisted tool call display message.

  Called at each stage of the tool execution lifecycle. The `tool_info`
  map contains the tool call identifier and any status-specific metadata.

  ## Parameters

  - `scope` — Integrator-defined scope struct (or `nil`). Use to filter DB writes.
  - `status` — The new status: `:executing`, `:completed`, `:failed`, `:interrupted`, or `:cancelled`
  - `tool_info` — Map with at minimum `:call_id`, plus status-specific fields:

    | Status | Fields |
    |--------|--------|
    | `:executing` | `%{call_id: "...", name: "...", display_text: "..."}` |
    | `:completed` | `%{call_id: "...", name: "...", result: "..."}` |
    | `:failed` | `%{call_id: "...", name: "...", error: "..."}` |
    | `:interrupted` | `%{call_id: "...", display_text: "..."}` |
    | `:cancelled` | `%{call_id: "...", name: "..."}` |

  - `context` — Map with `:agent_id`, `:conversation_id`, and `:user_request_seq`

  ## Returns

  - `{:ok, updated_message}` — Updated record, broadcast to LiveViews as `{:display_message_updated, msg}`
  - `{:error, :not_found}` — No matching tool call exists (normal if persistence wasn't configured when call was saved)
  """
  @callback update_tool_status(
              scope :: term() | nil,
              status :: tool_status(),
              tool_info :: map(),
              context :: callback_context()
            ) :: {:ok, term()} | {:error, :not_found | term()}

  @doc """
  Resolve an interrupted tool result display message with actual result content.

  Called after a sub-agent resumes and completes. Updates the persisted tool result
  display message to clear the interrupt flag and replace placeholder content with
  the actual result.

  Optional callback — implementations that don't need this can skip it.

  ## Parameters

  - `scope` — Integrator-defined scope struct (or `nil`). Use to filter DB writes.
  - `tool_call_id` — The tool call ID matching the interrupted tool result
  - `result_content` — The actual result content string
  - `context` — Map with `:agent_id`, `:conversation_id`, and `:user_request_seq`

  ## Returns

  - `{:ok, updated_message}` — Updated record, broadcast to LiveViews
  - `{:error, :not_found}` — No matching interrupted tool result exists
  """
  @callback resolve_tool_result(
              scope :: term() | nil,
              tool_call_id :: String.t(),
              result_content :: String.t(),
              context :: callback_context()
            ) :: {:ok, term()} | {:error, :not_found | term()}

  @typedoc """
  Attributes for a synthetic display message produced by middleware (not by an
  LLM). The shape mirrors the fields a typical implementation will write to
  its display-message store.
  """
  @type synthetic_message_attrs :: %{
          required(:message_type) => String.t(),
          required(:content_type) => String.t(),
          required(:content) => map(),
          optional(:metadata) => map()
        }

  @doc """
  Persist a synthetic display message originated by middleware.

  Used for transcript entries that should appear in the conversation but do
  not correspond to a `LangChain.Message` — for example, the user's answer
  to an `ask_user` question, or a "user cancelled" notification.

  AgentServer invokes this callback in response to
  `Sagents.AgentServer.save_synthetic_message_from/2` and broadcasts the
  saved record as `{:display_message_saved, msg}` so LiveViews stream it in
  via the same path used for LLM-generated display messages.

  Optional callback — middleware that uses this feature is responsible for
  ensuring the configured persistence module implements it.

  ## Parameters

  - `scope` — Integrator-defined scope struct (or `nil`). Use to filter DB writes.
  - `attrs` — Map with `:message_type`, `:content_type`, `:content` (and optionally `:metadata`).
  - `context` — Map with `:agent_id`, `:conversation_id`, and `:user_request_seq`.

  ## Returns

  - `{:ok, display_message}` — Persisted record, broadcast as `{:display_message_saved, msg}`.
  - `{:error, reason}` — Persistence failed (logged, does not affect agent).
  """
  @callback save_synthetic_message(
              scope :: term() | nil,
              attrs :: synthetic_message_attrs(),
              context :: callback_context()
            ) :: {:ok, term()} | {:error, term()}

  @typedoc """
  The report for a finished user request. The summary fields come from
  `Sagents.UserRequest.summarize/2`, without the message list.

  - `:status` - `:completed`, `:error`, `:cancelled`, or `:superseded` (an
    interrupt the user abandoned by sending a new message)
  - `:final_rows` - the rows `save_message/3` returned for the final answer,
    or `nil` when they are not known (no final answer, or the server
    restarted during the user request). An implementation chooses which of
    them to mark; a thinking row usually stays with the collapsed work.
  - `:token_usage` - the user request's total usage, including sub-agent work
    and summarization it triggered
  """
  @type user_request_report :: %{
          seq: pos_integer(),
          status: :completed | :error | :cancelled | :superseded,
          completed_at: DateTime.t(),
          final_message: LangChain.Message.t() | nil,
          final_rows: list() | nil,
          assistant_message_count: non_neg_integer(),
          tool_calls: %{String.t() => pos_integer()},
          token_usage: LangChain.TokenUsage.t() | nil
        }

  @doc """
  Called when a user request ends. Use it to record per-request work (for
  billing) and to mark the final answer's rows.

  AgentServer calls it before broadcasting the status change that ends the
  user request, and broadcasts the same report as
  `{:user_request_completed, report}`.

  A user request ends when its last run finishes cleanly, errors, or is
  cancelled; when a halt interrupt is dismissed; or when the user sends a new
  message instead of answering an interrupt. Interrupts and pauses do not end
  it: a resume continues the same user request.

  The same `seq` can be reported more than once. A run started without a new
  human message, after `Sagents.AgentServer.reset/1` or
  `Sagents.AgentServer.restore_state/2`, continues the current user request,
  and it is reported again when that run ends. Implementations should upsert
  by conversation and `seq`; the last report is the current one.

  Optional callback. A module that does not implement it still receives every
  other callback, and subscribers still receive the broadcast.

  ## Returns

  - `:ok`
  - `{:error, reason}`: logged, does not affect the agent
  """
  @callback complete_user_request(
              scope :: term() | nil,
              report :: user_request_report(),
              context :: callback_context()
            ) :: :ok | {:error, term()}

  @optional_callbacks [
    resolve_tool_result: 4,
    save_synthetic_message: 3,
    complete_user_request: 3
  ]
end
