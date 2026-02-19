defmodule Sagents.AgentPersistence do
  @moduledoc """
  Behaviour for persisting agent state snapshots.

  Implement this behaviour in your application to enable automatic
  state persistence at key lifecycle points. If no persistence module
  is configured, AgentServer operates entirely in-memory.

  ## Lifecycle Contexts

  The `context` parameter indicates why persistence was triggered:

  | Context | When | Notes |
  |---------|------|-------|
  | `:on_completion` | Agent execution completes successfully (status → :idle) | Most common persistence point |
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

  @type context ::
          :on_completion
          | :on_error
          | :on_interrupt
          | :on_title_generated
          | :on_shutdown

  @doc """
  Called when the agent should persist its current state.

  `agent_id` is the agent's identifier.
  `state_data` is the serialized state map (string keys, JSON-compatible)
    as returned by `StateSerializer.serialize_server_state/2`.
  `context` indicates why persistence was triggered.

  Return `:ok` on success. Errors are logged but do not affect agent operation.
  """
  @callback persist_state(agent_id :: String.t(), state_data :: map(), context :: context()) ::
              :ok | {:error, term()}

  @doc """
  Called to load a previously persisted state when starting an agent.

  Returns the serialized state map, or `{:error, :not_found}` if no
  saved state exists (normal for first-time agents).
  """
  @callback load_state(agent_id :: String.t()) ::
              {:ok, map()} | {:error, :not_found | term()}
end
