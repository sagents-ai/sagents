defmodule Sagents.InterruptSignal do
  @moduledoc """
  Marker struct carried via `ToolResult.processed_content` to propagate
  SubAgent HITL interrupts through the LangChain pipeline.

  When a SubAgent hits an HITL interrupt, the `task` tool returns
  `{:ok, message, %InterruptSignal{}}`. LangChain's `normalize_execution_result`
  handles this 3-tuple natively, storing the signal in `ToolResult.processed_content`.
  The `check_post_tool_interrupt` pipeline step then detects it and converts
  the pipeline to `{:interrupt, chain, interrupt_data}`.
  """

  @enforce_keys [:type, :sub_agent_id, :subagent_type, :interrupt_data]
  defstruct [:type, :sub_agent_id, :subagent_type, :interrupt_data, :tool_call_id]

  @type t :: %__MODULE__{
          type: :subagent_hitl,
          sub_agent_id: String.t(),
          subagent_type: String.t(),
          interrupt_data: map(),
          tool_call_id: String.t() | nil
        }
end
