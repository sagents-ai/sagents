defmodule Sagents.Fork do
  @moduledoc """
  Build a new conversation that starts from a copy of another conversation's
  history.

  A fork is a separate conversation seeded with the parent's messages. It gets
  its own `agent_id`, its own stored state, its own process, and its own agent
  configuration, so it can be a differently shaped agent that happens to
  remember what the parent knew. The parent keeps running, untouched.

  **A fork carries the messages and nothing else.** Todos and metadata are blank
  by default, and every runtime field starts at its default. See "What a fork
  does not inherit".

  ## The three functions

    * `from_agent/2` — read a base from a running agent. The entry point.
    * `prepare/2` — turn a state or an exported payload into a clean base.
    * `to_stored/1` — turn a base into the payload your persistence layer stores.

  `from_agent/2` is `prepare/2` over a guarded export. The other two are public
  because tests and hosts that already hold a state want them directly.

  ## Typical flow

  Read one base, then fan out. `prepare/2` and `to_stored/1` are pure: no LLM
  call, no process, no I/O, so N forks cost N list appends.

      {:ok, base} = Fork.from_agent(parent_agent_id)

      Enum.each(topics, fn topic ->
        {:ok, stored} =
          base
          |> State.add_message(Message.new_user!(prompt_for(topic)))
          |> Fork.to_stored()

        MyStorage.save_agent_state(scope, new_conversation_id(topic), stored)
      end)

  `base` is an immutable `Sagents.State`, so `Sagents.State.add_message/2`
  returns a new state per topic and the forks cannot interfere with each other.
  Call `from_agent/2` once: the server round trip is the only expensive part.

  Nothing above starts an agent. **A fork is a stored row until someone opens
  it.** The ordinary session-start path finds the row and boots an agent that
  already knows everything the parent knew.

  ## The source must be idle

  `from_agent/2` refuses any status but `:idle`, returning
  `{:error, {:agent_busy, status}}`.

  Messages are appended to a server's rolling state as each one is processed, so
  a snapshot taken mid-run can end on an assistant message whose `tool_calls`
  have no matching results yet. Priming a user message onto that history makes
  the fork's first provider call malformed. The missing results are not
  recoverable — the turn that would produce them is still running — so this is
  prevented rather than repaired.

  The check lives on the server because it cannot live anywhere else: reading a
  status and then exporting is two calls, and a message arriving between them
  starts a run against the very snapshot about to be taken.

  If no agent is running, `from_agent/2` returns `{:error, :not_running}`. Start
  the session first — that loads the persisted state through the ordinary path
  and yields an idle agent holding the freshest history there is — then fork
  from it. There is only ever one source, so a fork cannot be stale.

  Do not fork from inside a tool. The state a tool receives is a build-time
  snapshot that does not include the assistant message carrying the tool's own
  call, and the agent is `:running` by definition, so `from_agent/2` refuses.
  Fork from a completion callback instead.

  ## What a fork does not inherit

  **Agent configuration.** System prompt, tools, model and middleware are code,
  not state, and none of them are serialized. This is what makes forking useful:
  a fork can be re-framed as a narrower agent with no leftover directives in its
  history arguing otherwise.

  **Todos and metadata**, unless asked for. Blanking metadata matters more than
  it looks: middleware keys such as the generated conversation title and its
  "already generated" flag would otherwise make every fork wear the parent's
  name and never produce its own. Use `:todos` and `:metadata` to keep or seed
  what your application owns.

  **A pending interrupt.** A parent paused on a question does not hand that
  question to its forks; `prepare/2` demotes every live interrupt result
  unconditionally.

  **Files.** `Sagents.Middleware.FileSystem` keys its storage by scope, which
  defaults to the agent's own id, and files never live in state. A fork with a
  new `agent_id` therefore starts with an empty filesystem while its inherited
  transcript discusses files by path. See `d:forking.md` for the one lever that
  changes this.

  ## Primed messages are invisible

  Display rows are written by a running `AgentServer`. Messages placed into
  stored state before any server starts produce none, so nothing you prime
  renders in a UI. That is usually right for a priming user message and usually
  wrong for an assistant message meant to open the new thread — write that
  display row yourself.

  See `d:forking.md` for the full flow.
  """

  alias LangChain.Message
  alias LangChain.Message.{ToolCall, ToolResult}
  alias Sagents.AgentServer
  alias Sagents.Persistence.StateSerializer
  alias Sagents.State

  # deserialize_state/2 requires an agent_id because every other caller is
  # restoring into a running server. A fork base belongs to no agent yet, so a
  # placeholder goes in and `build_base/2` drops it along with the other runtime
  # fields.
  @placeholder_agent_id "fork-base"

  @typedoc """
  What a fork base can be built from: a `Sagents.State`, or the string-keyed
  payload `Sagents.AgentServer.export_state/1` produces and persistence stores.
  """
  @type source :: State.t() | map()

  @doc """
  Read a fork base from a running agent.

  Exports and prepares in one server round trip, so no message can arrive
  between reading the agent's status and reading its history. Options are
  forwarded to `prepare/2`.

  ## Returns

    * `{:ok, state}` — a prepared base, ready to prime and store.
    * `{:error, {:agent_busy, status}}` — the agent is not `:idle`.
    * `{:error, :not_running}` — no agent is running under that id.
    * `{:error, {:unanswered_tool_calls, ids}}` — the history is already
      malformed. See `prepare/2`.
    * `{:error, :registry_unavailable}` — this node cannot answer whether the
      agent is running.

  ## Examples

      {:ok, base} = Fork.from_agent("conversation-123")

      {:error, {:agent_busy, :running}} = Fork.from_agent("conversation-456")
  """
  @spec from_agent(String.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def from_agent(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    case AgentServer.export_state_if_idle(agent_id) do
      {:ok, exported} -> prepare(exported, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Turn a state or an exported payload into a clean fork base.

  Accepts a `Sagents.State` held in memory, or the string-keyed payload from
  `Sagents.AgentServer.export_state/1` or storage. Both forms yield the same
  base.

  ## What it does

  Keeps the messages. Blanks the todos and the metadata. Demotes any live
  interrupt through `Sagents.State.cancel_pending_interrupts/1`, so a fork of a
  parent that was mid-question does not boot paused on that question. Leaves
  every runtime field at its default, so the returned state means the same thing
  whether you use it live or store it first.

  Idempotent: preparing an already-prepared base changes nothing.

  ## Options

    * `:todos` — `[]` (default) blanks them, `:inherit` keeps the parent's, an
      explicit list seeds new ones.
    * `:metadata` — `%{}` (default) blanks it, `:inherit` keeps the parent's, an
      explicit map replaces it, `{:keep, keys}` retains just those keys.

  Both run once on the shared base. Anything that differs per fork belongs in
  the per-fork transform instead, applied after this returns.

  ## Unanswered tool calls

  Returns `{:error, {:unanswered_tool_calls, ids}}` when the history contains a
  tool call with no matching result. Such a history is already unusable — the
  parent hits the same provider rejection on its own next turn — and the missing
  results cannot be invented, because doing so would fabricate an outcome the
  parent still intends to produce. Reporting it here costs one pass over the
  messages and turns a provider error on the fork's first message into a clear
  answer at fork time.

  ## Examples

      {:ok, base} = Fork.prepare(state)

      {:ok, base} = Fork.prepare(stored_payload, metadata: {:keep, ["tenant_id"]})
  """
  @spec prepare(source(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def prepare(source, opts \\ [])

  def prepare(%State{} = state, opts) when is_list(opts) do
    case unanswered_tool_calls(state.messages) do
      [] -> {:ok, build_base(state, opts)}
      ids -> {:error, {:unanswered_tool_calls, ids}}
    end
  end

  def prepare(payload, opts) when is_map(payload) and is_list(opts) do
    case StateSerializer.deserialize_state(@placeholder_agent_id, inner_state(payload)) do
      {:ok, state} -> prepare(state, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Turn a fork base into the payload your persistence layer stores.

  Produces the same string-keyed envelope `Sagents.AgentServer.export_state/1`
  returns, so anything that reads a stored conversation reads a fork without
  knowing it is one.

  Write it with your application's own state-saving function. The
  `Sagents.AgentPersistence` behaviour exists for a running agent to persist
  itself and its lifecycle values have no member meaning "created by forking";
  here there is no agent and no lifecycle event.

  ## Examples

      {:ok, stored} = Fork.to_stored(base)
  """
  @spec to_stored(State.t()) :: {:ok, map()}
  def to_stored(%State{} = state) do
    {:ok, StateSerializer.serialize_server_state(nil, state)}
  end

  # Constructed field by field rather than by updating the source, so every
  # field this does not name — `runtime`, `interrupt_data`, `pause_reason`,
  # `conversation_id`, `agent_id` — starts at its default by construction. None
  # of them survive serialization, so leaving one populated would produce a base
  # that behaves one way passed to a server directly and another way after a
  # round trip through storage.
  defp build_base(%State{} = state, opts) do
    %State{
      messages: state.messages,
      todos: resolve_todos(state.todos, Keyword.get(opts, :todos, [])),
      metadata: resolve_metadata(state.metadata, Keyword.get(opts, :metadata, %{}))
    }
    |> State.cancel_pending_interrupts()
  end

  defp resolve_todos(parent_todos, :inherit), do: parent_todos
  defp resolve_todos(_parent_todos, todos) when is_list(todos), do: todos

  defp resolve_todos(_parent_todos, other) do
    raise ArgumentError,
          ":todos accepts a list or :inherit, got: #{inspect(other)}"
  end

  defp resolve_metadata(parent_metadata, :inherit), do: parent_metadata
  defp resolve_metadata(_parent_metadata, metadata) when is_map(metadata), do: metadata

  defp resolve_metadata(parent_metadata, {:keep, keys}) when is_list(keys) do
    Map.take(parent_metadata, keys)
  end

  defp resolve_metadata(_parent_metadata, other) do
    raise ArgumentError,
          ":metadata accepts a map, :inherit, or {:keep, keys}, got: #{inspect(other)}"
  end

  # Accepts the full envelope and, for a caller that already unwrapped it, the
  # inner state map on its own.
  defp inner_state(%{"state" => inner}) when is_map(inner), do: inner
  defp inner_state(payload), do: payload

  # Every call a provider expects to see answered, in the order it was made,
  # minus the ones that were. Scans the whole history rather than only its tail:
  # a gap anywhere is rejected by the provider, and a tail-only check would miss
  # one parallel call out of several.
  defp unanswered_tool_calls(messages) do
    answered =
      for %Message{role: :tool, tool_results: results} <- messages,
          is_list(results),
          %ToolResult{tool_call_id: id} <- results,
          into: MapSet.new(),
          do: id

    for %Message{role: :assistant, tool_calls: calls} <- messages,
        is_list(calls),
        %ToolCall{call_id: id} <- calls,
        not MapSet.member?(answered, id),
        do: id
  end
end
