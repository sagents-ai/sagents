defmodule Sagents.AgentPersistence do
  @moduledoc """
  Behaviour for persisting agent state snapshots.

  Implement this behaviour in your application to enable automatic
  state persistence at key lifecycle points. If no persistence module
  is configured, AgentServer operates entirely in-memory.

  ## Scope-first contract

  Every callback takes the integrator's scope struct as its first positional argument.

  Scope is opaque to sagents (`term() | nil`). Implementations can pattern-match on
  their own Scope struct (`%MyApp.Accounts.Scope{} = scope`) in the callback head.

  ## Lifecycle Contexts

  The `context.lifecycle` key indicates why persistence was triggered:

  | Lifecycle | When | Notes |
  |-----------|------|-------|
  | `:on_completion` | Agent execution completes successfully (status → :idle) | Most common persistence point |
  | `:on_cancel` | Execution cancelled by user | Preserves rolling state up to cancel point |
  | `:on_error` | Agent execution fails (status → :error) | Preserves state up to the error |
  | `:on_interrupt` | Execution paused for HITL approval (status → :interrupted) | Preserves interrupt context |
  | `:on_title_generated` | Conversation title auto-generated | State includes updated metadata |
  | `:on_shutdown` | Agent process terminating (inactivity timeout, node shutdown) | Best-effort — DB may also be shutting down |

  ## Configuration

  Per-agent via AgentServer start options (passed through AgentSupervisor):

      supervisor_config = [
        agent_id: agent_id,
        agent_persistence: MyApp.AgentPersistence,
        # ... other config
      ]

  No configuration = no persistence. AgentServer works fine without it.
  """

  @type lifecycle ::
          :on_completion
          | :on_cancel
          | :on_error
          | :on_interrupt
          | :on_title_generated
          | :on_shutdown

  @typedoc """
  Context map passed to `persist_state/3`. Contains the agent and conversation
  identifiers plus the lifecycle reason for this persistence call.
  """
  @type persist_context :: %{
          required(:agent_id) => String.t(),
          required(:conversation_id) => String.t() | nil,
          required(:lifecycle) => lifecycle()
        }

  @typedoc """
  Context map passed to `load_state/2`. Contains the agent and conversation
  identifiers.
  """
  @type load_context :: %{
          required(:agent_id) => String.t(),
          required(:conversation_id) => String.t() | nil
        }

  @doc """
  Called when the agent should persist its current state.

  `scope` is the integrator-defined scope struct (or `nil` for unscoped callers
  like admin tools). Use it to filter tenant-isolated DB writes.

  `state_data` is the serialized state map (string keys, JSON-compatible)
  as returned by `StateSerializer.serialize_server_state/2`.

  `context` carries `:agent_id`, `:conversation_id`, and `:lifecycle` (why
  persistence was triggered).

  Return `:ok` on success. Errors are logged but do not affect agent operation.
  """
  @callback persist_state(
              scope :: term() | nil,
              state_data :: map(),
              context :: persist_context()
            ) :: :ok | {:error, term()}

  @doc """
  Called to load a previously persisted state when starting an agent.

  `scope` is the integrator-defined scope struct. Use it to verify that the
  requested conversation belongs to the caller before returning state.

  `context` carries `:agent_id` and `:conversation_id`.

  Returns the serialized state map, or `{:error, :not_found}` if no
  saved state exists (normal for first-time agents).
  """
  @callback load_state(scope :: term() | nil, context :: load_context()) ::
              {:ok, map()} | {:error, :not_found | term()}
end
