defmodule Sagents.MessagePreprocessor do
  @moduledoc """
  Behaviour for transforming user-submitted messages into separate display and LLM representations.

  When a user sends a message, the system may need to produce two different versions:

  1. **Display message** — The user-facing representation persisted for UI rendering.
     For example, `@ProjectBrief` might render as a styled link/chip.

  2. **LLM message** — The message added to the model's conversation history.
     For example, `@ProjectBrief` might be expanded to include the full document content
     so the model can reason over it.

  ## When this runs

  Called inside `AgentServer.handle_call({:add_message, ...})` **before** the message
  is added to state or persisted as a display message. Only called for messages submitted
  via `AgentServer.add_message/2` — NOT for messages generated during LLM execution
  (assistant responses, tool results).

  ## Content representation

  Both the display message and the LLM message are regular `LangChain.Message` structs.
  The behaviour only constrains the return shape — not what's inside the messages.
  Implementations are free to use whatever content representation makes sense:

  - Plain text with HTML snippets for display rendering
  - XML-tagged metadata for structured LLM context
  - Structured content maps for richer UI rendering

  ## Configuration

  Per-agent via AgentServer/AgentSupervisor start options:

      AgentSupervisor.start_link(
        agent: agent,
        conversation_id: conversation_id,
        message_preprocessor: MyApp.MentionPreprocessor,
        # ...
      )

  If not configured, messages flow through unchanged to both paths.
  """

  @doc """
  Transform a user-submitted message into separate display and LLM representations.

  ## Context

  The `context` map provides:

  - `:agent_id` — The agent identifier string
  - `:conversation_id` — The conversation identifier (may be nil)
  - `:tool_context` — The caller-supplied context map from the Agent struct.
    Contains `:current_scope` (the Phoenix Scope with the current user),
    injected by the Coordinator at session start. Use this to scope document
    lookups, permission checks, etc.
  - `:state` — The current `Sagents.State` (messages, metadata). Useful for
    context-aware preprocessing (e.g., referencing prior messages).

  ## Returns

  - `{:ok, display_message, llm_message}` — Use different messages for each path.
    For passthrough, return the same message for both.
  - `{:error, reason}` — Reject the message. AgentServer replies with `{:error, reason}`.
  """
  @callback preprocess(message :: LangChain.Message.t(), context :: map()) ::
              {:ok, display_message :: LangChain.Message.t(),
               llm_message :: LangChain.Message.t()}
              | {:error, term()}
end
