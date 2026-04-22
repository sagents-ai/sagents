defmodule Sagents.MessagePreprocessor do
  @moduledoc """
  Behaviour for transforming user-submitted messages into separate display and LLM representations.

  When a user sends a message, the system may need to produce two different versions:

  1. **Display message** — The user-facing representation persisted for UI rendering.
     For example, `@ProjectBrief` might render as a styled link/chip.

  2. **LLM message** — The message added to the model's conversation history.
     For example, `@ProjectBrief` might be expanded to include the full document content
     so the model can reason over it.

  ## Scope-first contract

  The `preprocess/3` callback takes the integrator's scope struct as its first positional argument.

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

  @typedoc """
  Context map passed to `preprocess/3`. Contains identifiers plus the caller's
  `tool_context` (for integrator-defined tool-parameter data, no longer a transport
  for scope) and the current agent state.
  """
  @type preprocessor_context :: %{
          required(:agent_id) => String.t(),
          required(:conversation_id) => String.t() | nil,
          required(:tool_context) => map(),
          required(:state) => Sagents.State.t()
        }

  @doc """
  Transform a user-submitted message into separate display and LLM representations.

  ## Parameters

  - `scope` — Integrator-defined scope struct (or `nil`). Use for document lookups,
    permission checks, etc.
  - `message` — The `LangChain.Message` being submitted
  - `context` — Map with `:agent_id`, `:conversation_id`, `:tool_context`
    (integrator's non-scope tool-parameter data), and `:state` (current `Sagents.State`).

  ## Returns

  - `{:ok, display_message, llm_message}` — Use different messages for each path.
    For passthrough, return the same message for both.
  - `{:error, reason}` — Reject the message. AgentServer replies with `{:error, reason}`.
  """
  @callback preprocess(
              scope :: term() | nil,
              message :: LangChain.Message.t(),
              context :: preprocessor_context()
            ) ::
              {:ok, display_message :: LangChain.Message.t(),
               llm_message :: LangChain.Message.t()}
              | {:error, term()}
end
