defmodule Sagents.Middleware.Haltable do
  @moduledoc """
  Adds the ability for an agent's tools to *halt* the agent's workflow.

  Adding `Sagents.Middleware.Haltable` to a middleware stack expresses
  "this agent is haltable" — any tool the agent can invoke is then
  allowed to emit a `:halt` interrupt, which terminates the agent loop
  inside the framework (no further LLM call) and surfaces a user-facing
  message. This middleware claims those interrupts so they survive
  cold start and are re-surfaced to integrators on AgentServer reboot.

  ## What a halt is

  A `:halt` interrupt is a *terminal* interrupt: a tool has decided the
  enclosing workflow should stop, and the framework should NOT invoke the
  LLM again. There is no "next turn" for the orchestrator to weigh the
  halt against — it is a structural gate, not a persuasive one.

  Contrast with `Sagents.Middleware.AskUserQuestion`:

  | | `:ask_user_question` | `:halt` |
  | --- | --- | --- |
  | Intent | Pause for a typed response | Terminate the workflow |
  | Resume payload | A response slotted back into the halted tool call | None |
  | `handle_resume/5` behavior | Process the answer, continue the tool call | None — the tool call is dead |
  | User's next message | Slotted in as a tool result | A new turn; the halted call is demoted |

  ## How resume works (and where `Halt` is NOT involved)

  When a user sends a new free-text message after a halt,
  `Sagents.AgentServer.handle_call({:add_message, _})` calls
  `Sagents.State.cancel_pending_interrupts/1`, which demotes every
  `is_interrupt: true` tool result in the log to an error result and
  clears `state.interrupt_data`. The agent transitions back to `:idle`
  and the new message proceeds as a fresh turn.

  **This means `Halt.handle_resume/5` is never called for the "user moved
  on" leg.** This middleware only handles cold-start re-surface: when an
  AgentServer boots from persisted state that has a surviving `:halt`
  interrupt, `handle_resume/5` is called with `resume_data: nil`, and
  this middleware re-emits the interrupt so UIs can re-render the halt
  message.

  ## Emitting a halt

  Tool authors emit a halt via the standard `{:interrupt, msg, data}`
  return tuple, with `type: :halt` in the data:

      def execute(args, _ctx) do
        case gate_check(args) do
          :ok ->
            {:ok, result}

          {:gate_failed, reason} ->
            {:interrupt, "Workflow halted: \#{reason}",
             %{
               type: :halt,
               source_tool: "scout_outline",
               message: "Author-facing explanation of what to fix."
             }}
        end
      end

  ## Required keys in interrupt_data

  - `:type` — must be `:halt`
  - `:message` — `String.t()`, the user-facing reason for the halt
  - `:source_tool` — `String.t()` identifying which tool emitted the halt
    (or `:source` if the emitter is not a tool)

  The framework also fills in `:tool_call_id` when the halt comes from
  inside a tool execution (set by LangChain when it normalizes the tool
  function's return value).

  ## Adoption

  Add this middleware to your agent's middleware stack:

      middleware: [
        # ... existing middleware ...
        Sagents.Middleware.Haltable,
        # ... rest of stack ...
      ]

  Any tool that returns `{:interrupt, _, %{type: :halt, ...}}` will then
  produce a restorable halt interrupt.

  ## "Halt wins" in `:multiple_interrupts`

  When multiple parallel tools emit interrupts in the same turn and at
  least one is `:halt`, the workflow is over — there is no point asking
  the user to answer the sibling `ask_user` questions or approve the
  sibling HITL action requests. This middleware enforces that at
  cold-start time by claiming `:multiple_interrupts` wrappers that
  contain any `:halt` sub-interrupt. The UI layer (see
  `Sagents.AgentUtils.interrupt_session_changes/1`) enforces it at
  render time.

  ## Transcript persistence

  When a halt fires and the AgentServer is configured with a
  `DisplayMessagePersistence` module and a `conversation_id`, the
  halt's `:message` field is automatically persisted as a synthetic
  assistant display message in the conversation transcript. This means
  the halt's recommended-actions text survives:

  - the user dismissing the halt display,
  - the user sending a follow-up message (which clears `:pending_halt`
    via `Sagents.State.cancel_pending_interrupts/1`),
  - page reload — the message is in the persisted display-message log
    just like any other assistant turn.

  Persistence fires *once*, at the original halt-emit moment. Cold-start
  re-surface (this middleware's `handle_resume/5` re-emitting the
  interrupt when an AgentServer reboots from persisted state) does NOT
  re-persist — the transcript message is already there from the
  original emit.

  Halts with no `:message` (or an empty string) are skipped. So is the
  case where the AgentServer has no persistence configured — no error,
  just a silent no-op.
  """

  @behaviour Sagents.Middleware

  alias Sagents.State

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def system_prompt(_config), do: ""

  @impl true
  def tools(_config), do: []

  # A halt is pure data: a message, a source, and (optionally) a tool_call_id.
  # Nothing process-bound. Safe to restore from cold start.
  @impl true
  def restorable_interrupt?(%{type: :halt}), do: true

  # Claim `:multiple_interrupts` wrappers IFF they contain a :halt
  # sub-interrupt. Halt wins: if even one sibling is a halt, the workflow
  # is terminating and the whole batch should survive cold start so the
  # UI can render the halt message.
  def restorable_interrupt?(%{type: :multiple_interrupts, interrupts: subs})
      when is_list(subs) do
    Enum.any?(subs, fn
      %{type: :halt} -> true
      _other -> false
    end)
  end

  def restorable_interrupt?(_other), do: false

  # Cold-start re-surface: AgentServer is booting from persisted state with
  # a surviving halt. Hand the interrupt back out so the integrator's UI
  # can re-render the halt message. There is no resume_data because the
  # user hasn't acted yet — the agent is just back in the :interrupted
  # state it was in before the process restart.
  @impl true
  def handle_resume(
        _agent,
        %State{interrupt_data: %{type: :halt} = data} = state,
        nil,
        _config,
        _opts
      ) do
    {:interrupt, state, data}
  end

  # `:multiple_interrupts` cold-start re-surface, with the "halt wins"
  # policy: if any sub-interrupt is a halt, the whole batch re-surfaces as
  # the interrupt. The sibling questions/HITL approvals are moot because
  # the workflow is over.
  def handle_resume(
        _agent,
        %State{interrupt_data: %{type: :multiple_interrupts, interrupts: subs}} = state,
        nil,
        _config,
        _opts
      )
      when is_list(subs) do
    if Enum.any?(subs, &(&1.type == :halt)) do
      {:interrupt, state, state.interrupt_data}
    else
      {:cont, state}
    end
  end

  # There is no "user supplied resume_data" clause. A halt is terminal —
  # the user's next message goes through AgentServer's add_message path,
  # which demotes the interrupt via State.cancel_pending_interrupts/1
  # without calling handle_resume/5. If an integrator does call
  # Agent.resume/3 on a halted state with a payload, falling through to
  # {:cont, state} is the right behaviour: no middleware will claim the
  # resume and Agent.resume/3 returns an error from its no-handler path.
  def handle_resume(_agent, state, _resume_data, _config, _opts), do: {:cont, state}
end
