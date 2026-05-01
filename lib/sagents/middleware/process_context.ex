defmodule Sagents.Middleware.ProcessContext do
  @moduledoc """
  Propagates caller-process state across the three Sagents process boundaries.

  Sagents agents cross three process boundaries during a single invocation:

    1. **Caller → AgentServer GenServer** — when the agent is started under a
       supervisor, lifecycle hooks like `on_server_start/2` run inside the
       GenServer process, not the caller's.
    2. **AgentServer → chain Task** — each turn spawns a `Task` that runs the
       LLM call and synchronous tool execution.
    3. **Chain Task → per-tool async Task** — `LangChain.Function`s declared
       with `async: true` run in a freshly-spawned `Task.async/1`.

  Anything stored in the caller's process dictionary, the OpenTelemetry context
  stash, the APM (Application Performance Monitoring) context, or any similar
  per-process channel is *not* carried across these boundaries automatically.
  This middleware captures that state in the caller's process at `init/1` time
  and re-applies it on the receiving side of each boundary.

  ## Configuration

  Two options, both optional, can be combined freely:

    * `:keys` — a list of process-dictionary keys (atoms). For each key the
      middleware captures `Process.get(key)` in the caller's process and calls
      `Process.put(key, value)` on the receiving side of every boundary.
    * `:propagators` — a list of `{capture_fn, apply_fn}` pairs. `capture_fn` is
      a 0-arity function called once at `init/1` in the caller's process; its
      return value is later passed to `apply_fn`, a 1-arity function called on
      the receiving side of every boundary. Use this for state that lives in
      something other than the process dictionary (OpenTelemetry's context
      stash, ETS-backed contexts, etc.).

  ## Example: Sentry-only

      {:ok, agent} = Sagents.Agent.new(%{
        model: model,
        middleware: [
          {Sagents.Middleware.ProcessContext, keys: [:sentry_context]}
        ]
      })

  ## Example: Sentry + OpenTelemetry + a custom application context

      {:ok, agent} = Sagents.Agent.new(%{
        model: model,
        middleware: [
          {Sagents.Middleware.ProcessContext,
            keys: [:sentry_context],
            propagators: [
              {&OpenTelemetry.get_current/0, &OpenTelemetry.attach/1},
              {&MyApp.Tenancy.get_context/0, &MyApp.Tenancy.set_context/1}
            ]}
        ]
      })

  ## Capture is one-shot at construction time

  `init/1` runs in the caller's process when `Sagents.Agent.new/2` is called
  and captures once. For agents that handle a single request and are then
  discarded that one capture is all you need.

  For long-lived agents that outlive the calling request — a conversation-
  scoped AgentServer reused across many user messages, for example — the
  captured snapshot will go stale.

  Use `update/1` to refresh it. The middleware already has the spec from
  `init/1`, so the caller only supplies the `agent_id`. Capture functions run
  in the *caller of* `update/1`, then the new snapshot replaces the stored
  snapshot in the agent's `state.runtime` and is used for every subsequent
  boundary crossing.

  ## Snapshot lives in `state.runtime`

  The captured snapshot intentionally contains non-serializable values
  (closures, OTel context tokens, PIDs, tuples). It is therefore stored under
  `state.runtime[ProcessContext]`, a virtual field that `StateSerializer`
  never persists. After process restart the snapshot is gone and
  `on_server_start/2` re-captures from the new caller process — which is the
  correct semantic, since a stale OTel/Sentry/tenant token would be wrong to
  re-apply anyway.

      # In a LiveView, before relaying a new user message to the agent:
      Sagents.Middleware.ProcessContext.update(agent_id)
      Sagents.AgentServer.add_message(agent_id, message)

  Both calls go through the same GenServer mailbox in order, so the update takes
  effect before the next execute begins.

  ### Limitation: within-execute consistency

  An execute_loop is a single logical request — one user message resolved by
  potentially many LLM turns and tool calls. Within that loop, the snapshot is
  intentionally frozen: `update/1` arriving mid-execute does not retarget
  in-flight tools. This is the right behavior — a single request should see one
  consistent context for its duration. Refresh between requests, not during one.
  """

  @behaviour Sagents.Middleware

  alias __MODULE__
  alias Sagents.{AgentServer, MiddlewareEntry}

  @impl true
  def init(opts) do
    keys = Keyword.get(opts, :keys, [])
    propagators = Keyword.get(opts, :propagators, [])

    validate_keys!(keys)
    validate_propagators!(propagators)

    {:ok,
     %{
       snapshot: capture_snapshot(keys, propagators),
       keys: keys,
       propagators: propagators
     }}
  end

  @impl true
  def on_server_start(state, config) do
    # One-time bootstrap: copy the init-time capture from config into
    # state.runtime. From here on, state.runtime is the only place the
    # snapshot lives. If state.runtime already has a snapshot (e.g. an
    # update/1 message that landed before on_server_start), preserve it.
    # Note: state.runtime is virtual and never restored from persistence,
    # so a freshly-restored agent always falls through to the config copy.
    state = ensure_snapshot_in_runtime(state, config)
    apply_snapshot(state)
    {:ok, state}
  end

  @impl true
  def before_model(state, _config) do
    apply_snapshot(state)
    {:ok, state}
  end

  @impl true
  def handle_resume(_agent, state, _resume_data, _config, _opts) do
    apply_snapshot(state)
    {:cont, state}
  end

  @impl true
  def handle_message({:update_context, %{keys: _, propagators: _} = snapshot}, state, _config) do
    runtime = Map.put(state.runtime || %{}, ProcessContext, snapshot)
    {:ok, %{state | runtime: runtime}}
  end

  def handle_message(_message, state, _config), do: {:ok, state}

  @impl true
  def callbacks(_config) do
    %{
      on_tool_pre_execution: fn chain, _tool_call, _function ->
        state = chain.custom_context && Map.get(chain.custom_context, :state)
        apply_snapshot(state)
      end
    }
  end

  @doc """
  Refresh the propagated context for a running agent.

  The middleware already knows what to capture — `:keys` and `:propagators`
  were configured at `init/1` time and live in the middleware's stored config.
  `update/1` looks that spec up from the running agent, runs the capture
  functions in the *caller's* process, and ferries the fresh snapshot to the
  agent so it takes effect for every subsequent boundary crossing.

  Call this before sending a new message to a long-lived agent whose ambient
  context has changed since the agent was constructed.

  ## Returns

    * `:ok` — snapshot captured and sent
    * `{:error, :not_found}` — no AgentServer is running for `agent_id`
    * `{:error, :no_process_context_middleware}` — the agent is running but
      does not have `ProcessContext` in its middleware stack

  ## Example

      def handle_event("send_message", %{"text" => text}, socket) do
        Sagents.Middleware.ProcessContext.update(socket.assigns.agent_id)
        Sagents.AgentServer.add_message(socket.assigns.agent_id,
          LangChain.Message.new_user!(text))
        {:noreply, socket}
      end
  """
  @spec update(String.t()) ::
          :ok | {:error, :not_found | :no_process_context_middleware}
  def update(agent_id) when is_binary(agent_id) do
    with {:ok, agent} <- AgentServer.get_agent(agent_id),
         {:ok, %{keys: keys, propagators: propagators}} <- find_own_config(agent) do
      snapshot = capture_snapshot(keys, propagators)
      AgentServer.notify_middleware(agent_id, ProcessContext, {:update_context, snapshot})
    end
  end

  defp find_own_config(agent) do
    case Enum.find(agent.middleware || [], &(&1.module == ProcessContext)) do
      %MiddlewareEntry{config: config} -> {:ok, config}
      nil -> {:error, :no_process_context_middleware}
    end
  end

  # Capture happens in the calling process — Process.get/1 reads that
  # process's dictionary, and capture_fn.() runs there too.
  defp capture_snapshot(keys, propagators) do
    %{
      keys: Enum.map(keys, fn key -> {key, Process.get(key)} end),
      propagators:
        Enum.map(propagators, fn {capture_fn, apply_fn} -> {capture_fn.(), apply_fn} end)
    }
  end

  # state.runtime is the single source of truth for the live snapshot.
  # Bootstrap (`config.snapshot`) is copied in once by `on_server_start/2`;
  # all other reads — including the LangChain callback that fires inside the
  # per-tool Task — go through state.runtime only.
  defp ensure_snapshot_in_runtime(state, config) do
    case state.runtime do
      %{ProcessContext => _} ->
        state

      runtime ->
        %{state | runtime: Map.put(runtime || %{}, ProcessContext, config.snapshot)}
    end
  end

  defp apply_snapshot(nil), do: :ok

  defp apply_snapshot(state) do
    case state.runtime do
      %{ProcessContext => snapshot} -> do_apply(snapshot)
      _ -> :ok
    end
  end

  defp do_apply(%{keys: keys, propagators: propagators}) do
    Enum.each(keys, fn
      {_key, nil} -> :ok
      {key, value} -> Process.put(key, value)
    end)

    Enum.each(propagators, fn {value, apply_fn} -> apply_fn.(value) end)

    :ok
  end

  defp validate_keys!(keys) do
    unless is_list(keys) and Enum.all?(keys, &is_atom/1) do
      raise ArgumentError, ":keys must be a list of atoms, got: #{inspect(keys)}"
    end
  end

  defp validate_propagators!(propagators) do
    unless is_list(propagators) and Enum.all?(propagators, &valid_propagator?/1) do
      raise ArgumentError,
            ":propagators must be a list of {capture_fn, apply_fn} tuples " <>
              "where capture_fn is 0-arity and apply_fn is 1-arity, got: " <>
              inspect(propagators)
    end
  end

  defp valid_propagator?({capture, apply})
       when is_function(capture, 0) and is_function(apply, 1),
       do: true

  defp valid_propagator?(_), do: false
end
