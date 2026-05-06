defmodule Sagents.State do
  @moduledoc """
  Agent state structure for managing agent execution context.

  The state holds the complete context for an agent execution including:
  - Message history (list of `LangChain.Message` structs)
  - TODO list
  - Metadata

  **Note**: Files are managed separately by `FileSystemServer` and are not part of
  the agent's internal state. The FileSystemServer provides persistent storage with
  ETS and optional backend persistence (disk, database, S3, etc.).

  ## agent_id Management (Automatic)

  The `agent_id` field is a **runtime identifier** used for process registration and
  coordination. You don't need to set it when creating states—the library
  automatically injects it when you call `Sagents.Agent.execute/2`, `Sagents.Agent.resume/3`, or
  start an `AgentServer`.

  ### Why it's automatic

  The `agent_id` flows from the Agent struct (which is configuration) to the State
  (which is data). Making you synchronize them manually could be error-prone.

  ### For middleware developers

  When middleware receives state in hooks (`before_model`, `after_model`), the
  `agent_id` will already be set. If you create new state structs in middleware,
  copy the `agent_id` from the incoming state:

      def after_model(state, config) do
        updated_state = State.new!(%{
          agent_id: state.agent_id,  # Copy from incoming state
          messages: new_messages
        })
        {:ok, updated_state}
      end

  ## State Merging

  State merging follows specific rules:

  - **messages**: Appends new messages to existing list
  - **todos**: Replaces with new todos (merge handled by TodoList middleware)
  - **metadata**: Deep merges metadata maps
  - **agent_id**: Uses right if present, otherwise left (runtime identifier, not data)
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger
  alias __MODULE__

  @primary_key false
  embedded_schema do
    # Agent identifier (set automatically by AgentServer during initialization)
    field :agent_id, :string
    # List of LangChain.Message structs
    field :messages, {:array, :any}, default: [], virtual: true
    field :todos, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    # Runtime-only middleware state. Virtual: never persisted, never JSON-encoded.
    # Use this for values that are inherently process-local or non-serializable —
    # captured closures, OTel/Sentry context tokens, PIDs, refs, tuples — that
    # only make sense within the lifetime of a single OS process.
    field :runtime, :map, default: %{}, virtual: true
    # Interrupt data for HumanInTheLoop middleware
    field :interrupt_data, :map, default: nil, virtual: true
  end

  @type t :: %State{}

  @doc """
  Create a new agent state.

  Note: The `agent_id` field is optional when creating a state. The library
  automatically injects it when the state is passed to Agent.execute or
  AgentServer. This eliminates the need for manual agent_id synchronization.

  ## Examples

      # Create state without agent_id (recommended)
      state = State.new!(%{messages: [message]})

      # Library injects agent_id automatically
      {:ok, result_state} = Agent.execute(agent, state)
  """
  def new(attrs \\ %{}) do
    %State{}
    |> cast(attrs, [:agent_id, :messages, :todos, :metadata, :runtime, :interrupt_data])
    |> apply_action(:insert)
  end

  @doc """
  Create a new agent state, raising on error.
  """
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, state} -> state
      {:error, changeset} -> raise LangChain.LangChainError, changeset
    end
  end

  @doc """
  Deserializes state data from export_state/1.

  This is a convenience wrapper around StateSerializer.deserialize_state/2.

  **Important**: The `agent_id` is NOT serialized (it's a runtime identifier),
  so you MUST provide it when deserializing. This ensures the state can properly
  interact with AgentServer and middleware that rely on the agent_id.

  ## Examples

      # Load from database
      {:ok, state_data} = load_from_db(conversation_id)

      # Deserialize with agent_id
      {:ok, state} = State.from_serialized("my-agent-123", state_data["state"])

  ## Parameters

    - `agent_id` - The agent_id to use for this state (required)
    - `data` - The serialized state map (the "state" field from export_state)

  ## Returns

    - `{:ok, state}` - Successfully deserialized with agent_id set
    - `{:error, reason}` - Deserialization failed
  """
  def from_serialized(agent_id, data) when is_binary(agent_id) and is_map(data) do
    # No agent in scope here, so we can't consult middleware on restoring serialized interrupt_data. Fall back to the default of demoting every interrupted tool result.
    case Sagents.Persistence.StateSerializer.deserialize_state(agent_id, data) do
      {:ok, state} -> {:ok, clean_stale_interrupts(state, [])}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load an agent's persisted state via an `Sagents.AgentPersistence`
  implementation, or return a fresh empty state if nothing is saved or the
  saved data is unusable.

  Always returns `{:ok, state}` so callers can pattern-match without
  fallback branches. Failure modes (missing envelope key, malformed
  serialized data) are logged at warning level and degrade gracefully to a
  fresh state — restoring a partial conversation is worse than starting
  fresh, since the user can re-prompt but cannot recover from a server
  that won't boot.

  ## Parameters

  - `persistence_module` — module implementing `Sagents.AgentPersistence`
  - `scope` — integrator-defined scope struct (forwarded to `load_state/2`)
  - `context` — map with `:agent_id` (required) and `:conversation_id`
    (optional; useful for log lines and is included in the load context)

  ## Examples

      Sagents.State.load_or_new(MyApp.AgentPersistence, scope, %{
        agent_id: "conversation-123",
        conversation_id: 123
      })
      # => {:ok, %Sagents.State{...}}

  """
  @spec load_or_new(module(), term() | nil, %{
          required(:agent_id) => String.t(),
          optional(:conversation_id) => term()
        }) :: {:ok, t()}
  def load_or_new(persistence_module, scope, %{agent_id: agent_id} = context)
      when is_atom(persistence_module) and is_binary(agent_id) do
    load_context = %{
      agent_id: agent_id,
      conversation_id: Map.get(context, :conversation_id)
    }

    case persistence_module.load_state(scope, load_context) do
      {:ok, exported_state} ->
        Logger.info("Found saved state for agent #{agent_id}, attempting to restore...")
        restore_or_fresh(agent_id, exported_state)

      {:error, :not_found} ->
        Logger.info("No saved state found for agent #{agent_id}, creating fresh state")
        {:ok, new!(%{})}
    end
  end

  defp restore_or_fresh(agent_id, exported_state) do
    case Map.get(exported_state, "state") do
      nil ->
        Logger.warning(
          "Exported state for agent #{agent_id} has no 'state' field, using fresh state"
        )

        {:ok, new!(%{})}

      nested_state ->
        case from_serialized(agent_id, nested_state) do
          {:ok, state} ->
            Logger.info(
              "Successfully restored agent state for #{agent_id} with #{length(state.messages)} messages"
            )

            {:ok, state}

          {:error, reason} ->
            Logger.warning(
              "Failed to deserialize agent state for #{agent_id}: #{inspect(reason)}, using fresh state"
            )

            {:ok, new!(%{})}
        end
    end
  end

  @doc """
  Merge two states together.

  This is used when combining state updates from tools, middleware, or subagents.

  ## Merge Rules

  - **messages**: Concatenates lists (left + right)
  - **todos**: Uses right if present, otherwise left
  - **metadata**: Deep merges maps

  ## Examples

      left = State.new!(%{messages: [%{role: "user", content: "hi"}]})
      right = State.new!(%{messages: [%{role: "assistant", content: "hello"}]})
      merged = State.merge_states(left, right)
      # merged now has both messages
  """
  def merge_states(left, right)

  def merge_states(%State{} = left, %State{} = right) do
    %State{
      agent_id: left.agent_id || right.agent_id,
      messages: merge_messages(left.messages, right.messages),
      todos: merge_todos(left.todos, right.todos),
      metadata: deep_merge_maps(left.metadata, right.metadata),
      runtime: merge_runtime(left.runtime, right.runtime),
      interrupt_data: right.interrupt_data || left.interrupt_data
    }
  end

  def merge_states(%State{} = state, updates) when is_map(updates) do
    right = struct(State, updates)
    merge_states(state, right)
  end

  # Private merge functions

  defp merge_messages(left, right) when is_list(left) and is_list(right) do
    left ++ right
  end

  defp merge_messages(left, _right) when is_list(left), do: left
  defp merge_messages(_left, right) when is_list(right), do: right
  defp merge_messages(_left, _right), do: []

  # Replace todos with right if right is a list (even if empty - allows clearing)
  defp merge_todos(_left, right) when is_list(right), do: right
  defp merge_todos(left, _right) when is_list(left), do: left
  defp merge_todos(_left, _right), do: []

  defp deep_merge_maps(left, right) when is_nil(left), do: right
  defp deep_merge_maps(left, right) when is_nil(right), do: left

  defp deep_merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      if is_map(left_val) and is_map(right_val) do
        deep_merge_maps(left_val, right_val)
      else
        right_val
      end
    end)
  end

  defp deep_merge_maps(left, _right) when is_map(left), do: left
  defp deep_merge_maps(_left, right) when is_map(right), do: right
  defp deep_merge_maps(_left, _right), do: %{}

  # Runtime entries are shallow merged. A namespacing strategy used by
  # ProcessContext is to store the data under the module as the key.
  defp merge_runtime(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right)
  end

  defp merge_runtime(left, _right) when is_map(left), do: left
  defp merge_runtime(_left, right) when is_map(right), do: right
  defp merge_runtime(_left, _right), do: %{}

  @doc """
  Add a message to the state.

  Message must be a `LangChain.Message` struct.
  """
  def add_message(%State{} = state, %LangChain.Message{} = message) do
    add_messages(state, [message])
  end

  @doc """
  Add multiple messages to the state.

  Messages must be `LangChain.Message` structs.
  """
  def add_messages(%State{} = state, messages) when is_list(messages) do
    %{state | messages: state.messages ++ messages}
  end

  @doc """
  Replace a tool result in the state's messages by `tool_call_id`.

  Delegates to `LangChain.Message.replace_tool_result/3`.
  """
  def replace_tool_result(
        %State{} = state,
        tool_call_id,
        %LangChain.Message.ToolResult{} = new_result
      ) do
    updated_messages =
      LangChain.Message.replace_tool_result(state.messages, tool_call_id, new_result)

    %{state | messages: updated_messages}
  end

  @doc """
  Set metadata value.
  """
  def put_metadata(%State{} = state, key, value) do
    %{state | metadata: Map.put(state.metadata, key, value)}
  end

  @doc """
  Get metadata value.
  """
  def get_metadata(%State{} = state, key, default \\ nil) do
    Map.get(state.metadata, key, default)
  end

  @doc """
  Add or update a TODO item.

  If a TODO with the same ID exists, it will be replaced at its current position.
  If the TODO ID doesn't exist, it will be appended to the end of the list.
  """
  def put_todo(%State{} = state, %Sagents.Todo{} = todo) do
    # Find the index of the existing TODO with the same ID
    existing_index =
      Enum.find_index(state.todos, fn
        %{id: id} -> id == todo.id
        _other -> false
      end)

    updated_todos =
      case existing_index do
        nil ->
          # Not found, append to the end
          state.todos ++ [todo]

        index ->
          # Found, replace at the same index position
          List.replace_at(state.todos, index, todo)
      end

    %{state | todos: updated_todos}
  end

  @doc """
  Get a TODO by ID.
  """
  def get_todo(%State{} = state, todo_id) when is_binary(todo_id) do
    Enum.find(state.todos, fn
      %{id: ^todo_id} -> true
      _other -> false
    end)
  end

  @doc """
  Remove a TODO by ID.
  """
  def delete_todo(%State{} = state, todo_id) when is_binary(todo_id) do
    updated_todos =
      Enum.reject(state.todos, fn
        %{id: ^todo_id} -> true
        _other -> false
      end)

    %{state | todos: updated_todos}
  end

  @doc """
  Get all TODOs with a specific status.
  """
  def get_todos_by_status(%State{} = state, status) when is_atom(status) do
    Enum.filter(state.todos, fn
      %{status: ^status} -> true
      _other -> false
    end)
  end

  @doc """
  Replace all TODOs.
  """
  def set_todos(%State{} = state, todos) when is_list(todos) do
    %{state | todos: todos}
  end

  @doc """
  Replace all messages.

  Useful for:
  - Thread restoration (restoring persisted messages)
  - Testing scenarios (setting sample messages)
  - Bulk message updates

  ## Parameters

  - `state` - The current State struct
  - `messages` - List of Message structs

  ## Examples

      messages = [
        Message.new_user!("Hello")
      ]
      state = State.set_messages(state, messages)
  """
  def set_messages(%State{} = state, messages) when is_list(messages) do
    %{state | messages: messages}
  end

  @doc """
  Reset the state to a clean slate.

  Clears:
  - All messages
  - All TODOs
  - All metadata

  **Note**: This function only resets the Agent's state structure. File state is managed
  separately by FileSystemServer and must be reset through AgentServer.reset/1 which
  coordinates the full reset process.

  ## Examples

      state = State.new!(%{
        messages: [msg1, msg2],
        todos: [todo1],
        metadata: %{config: "value"}
      })

      reset_state = State.reset(state)
      # reset_state has:
      # - messages: []
      # - todos: []
      # - metadata: %{} (cleared)
  """
  @spec reset(t()) :: t()
  def reset(%State{} = state) do
    %State{
      agent_id: state.agent_id,
      messages: [],
      todos: [],
      metadata: %{},
      runtime: %{}
    }
  end

  @doc """
  Replace stale interrupt placeholder tool results with error messages,
  consulting the agent's middleware to decide which interrupts can be
  restored from cold start.

  Called after loading state from the database. For each interrupted tool
  result the decision is:

  - `interrupt_data == nil` (decode failed, never persisted, or written by
    older code) → demote to error result.
  - `interrupt_data` shape is `:multiple_interrupts` → demote *unless* every
    sub-interrupt is itself claimed by some middleware. Partial restore is a
    footgun: a resumed agent would dispatch responses that don't all have
    valid targets.
  - No middleware in `middleware_entries` says `restorable_interrupt?` for
    the data → demote.
  - Otherwise → keep `is_interrupt: true` and `interrupt_data` intact.

  Demoted results carry a clear message so the LLM can see the call failed
  on the next turn and recover gracefully. Two messages are used to
  distinguish the failure modes (process-bound vs incompatible data) for
  debugging. Both are equivalent to the model.

  An empty `middleware_entries` list demotes every interrupt — preserving
  pre-restorable behaviour for callers that don't have an agent in scope
  (e.g. `from_serialized/2`).

  Idempotent: a state with no interrupted tool results is unchanged.
  """
  @spec clean_stale_interrupts(t(), [Sagents.MiddlewareEntry.t()]) :: t()
  def clean_stale_interrupts(%State{} = state, middleware_entries \\ [])
      when is_list(middleware_entries) do
    cleaned_messages =
      Enum.map(state.messages, fn message ->
        case message do
          %LangChain.Message{role: :tool, tool_results: results} when is_list(results) ->
            cleaned_results = Enum.map(results, &maybe_demote(&1, middleware_entries))
            %{message | tool_results: cleaned_results}

          other ->
            other
        end
      end)

    %{state | messages: cleaned_messages}
  end

  defp maybe_demote(
         %LangChain.Message.ToolResult{is_interrupt: true, interrupt_data: nil} = tr,
         _middleware
       ) do
    demote(tr, :incompatible)
  end

  defp maybe_demote(
         %LangChain.Message.ToolResult{is_interrupt: true, interrupt_data: data} = tr,
         middleware
       )
       when is_map(data) do
    if interrupt_restorable?(data, middleware) do
      tr
    else
      demote(tr, :process_bound)
    end
  end

  defp maybe_demote(other, _middleware), do: other

  # `:multiple_interrupts` is restorable if *every* sub-interrupt is
  # claimed by some middleware. Sub-agents and ask_user questions can mix in
  # the same wrapper, so partial restore would silently drop some questions.
  defp interrupt_restorable?(%{type: :multiple_interrupts, interrupts: subs}, middleware)
       when is_list(subs) do
    Enum.all?(subs, &any_middleware_claims?(&1, middleware))
  end

  defp interrupt_restorable?(data, middleware) when is_map(data) do
    any_middleware_claims?(data, middleware)
  end

  defp any_middleware_claims?(data, middleware) when is_map(data) do
    Enum.any?(middleware, &Sagents.Middleware.apply_restorable_interrupt?(&1, data))
  end

  defp any_middleware_claims?(_data, _middleware), do: false

  defp demote(tr, :process_bound) do
    %{
      tr
      | content:
          "Tool execution was interrupted and could not be resumed " <>
            "(agent was restarted). The sub-agent's work was lost.",
        is_interrupt: false,
        is_error: true,
        interrupt_data: nil
    }
  end

  defp demote(tr, :incompatible) do
    %{
      tr
      | content:
          "Tool execution was interrupted and could not be resumed " <>
            "(saved data was incompatible with current code).",
        is_interrupt: false,
        is_error: true,
        interrupt_data: nil
    }
  end

  defp demote(tr, :user_cancelled) do
    %{
      tr
      | content:
          "Tool execution was interrupted and the user did not respond. " <>
            "They sent a new message instead — proceed with their new request.",
        is_interrupt: false,
        is_error: true,
        interrupt_data: nil
    }
  end

  @doc """
  Demote every `is_interrupt: true` tool result in the message log to an
  error result, signaling to the LLM that the user abandoned the pending
  interrupt and that a new user message follows.

  Used when a user sends a free-text message instead of resuming an
  interrupted tool call (e.g. ignoring an `ask_user` question and asking
  something different). Without this demotion the trailing interrupt
  placeholder would remain in the conversation, causing the next LLM call
  to be malformed (Anthropic rejects with "must end with a user message").

  Also clears `state.interrupt_data` (the virtual field).

  Idempotent: a state with no interrupts is unchanged.
  """
  @spec cancel_pending_interrupts(t()) :: t()
  def cancel_pending_interrupts(%State{} = state) do
    cancelled_messages =
      Enum.map(state.messages, fn message ->
        case message do
          %LangChain.Message{role: :tool, tool_results: results} when is_list(results) ->
            cancelled_results =
              Enum.map(results, fn
                %LangChain.Message.ToolResult{is_interrupt: true} = tr ->
                  demote(tr, :user_cancelled)

                other ->
                  other
              end)

            %{message | tool_results: cancelled_results}

          other ->
            other
        end
      end)

    %{state | messages: cancelled_messages, interrupt_data: nil}
  end
end
