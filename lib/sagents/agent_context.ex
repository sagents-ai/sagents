defmodule Sagents.AgentContext do
  @moduledoc """
  Process-local context propagation for agent hierarchies.

  Provides a mechanism to propagate application-level context (e.g., OpenTelemetry
  trace IDs, tenant IDs, feature flags) through the agent execution tree.

  Context is stored in the process dictionary for zero-cost reads within a process.
  At process boundaries (e.g., spawning sub-agents), use `fork/1` to snapshot the
  context for explicit passing to the child process.

  ## How it works

  Context flows automatically through the agent hierarchy:

  1. **Your application** passes `:agent_context` when starting an agent
  2. **AgentSupervisor** forwards the context to its child AgentServer
  3. **AgentServer.init/1** calls `AgentContext.init/1` to store it in the process dictionary
  4. **Agent.execute/3** runs in a `Task.async`. Since `Task.async` does NOT
     inherit the caller's process dictionary, AgentServer explicitly forks the
     context via `fork_with_middleware/1` and calls `init/1` in the task,
     so tools and callbacks can read context via `AgentContext.get/0`
  5. **SubAgent middleware** calls `AgentContext.fork_with_middleware/1` to snapshot
     context before spawning a child SubAgentServer. Each middleware's
     `on_fork_context/2` callback can inject process-local state (e.g., OpenTelemetry
     span context) and register restore functions via `add_restore_fn/2`.
  6. **SubAgentServer.init/1** calls `AgentContext.init/1`, which stores the clean
     context and runs any registered restore functions to rebuild process-local state
     in the child process.

  This means context is available everywhere in the hierarchy without passing it
  through every function signature.

  ## Usage

      # At the application boundary (e.g., LiveView or API controller)
      AgentSupervisor.start_link(
        agent: agent,
        agent_context: %{trace_id: "abc123", tenant_id: 42}
      )

      # Inside a tool function
      ctx = AgentContext.get()
      trace_id = AgentContext.fetch(:trace_id)

      # When spawning a sub-agent (cross-process boundary)
      child_context = AgentContext.fork(fn ctx -> Map.put(ctx, :parent_span_id, current_span()) end)
      SubAgentServer.start_link(subagent: subagent, agent_context: child_context)

  ## Reading context in tools

  Tool functions run inside `Task.async` spawned by AgentServer, so they
  inherit the process dictionary. Read context directly:

      defp my_tool_function(_args, context) do
        tenant_id = AgentContext.fetch(:tenant_id)
        trace_id = AgentContext.fetch(:trace_id)

        # Use context to scope operations
        MyApp.Repo.query(data_query, tenant_id: tenant_id)
      end

  ## Common use cases

  - **Tenant isolation** — Pass `tenant_id` so tools scope database queries
    and file operations to the correct tenant.
  - **Distributed tracing** — Propagate `trace_id` and `span_id` so agent
    activity appears in your OpenTelemetry traces.
  - **Feature flags** — Include feature flag state so tool behaviour can vary
    per-user or per-experiment without global lookups.
  - **User info** — Carry `user_id` or `user_email` for audit logging inside
    tool functions.

  ## AgentContext vs State.metadata

  Sagents has two mechanisms for attaching data to agents. Use the right one:

  | | `AgentContext` | `State.metadata` |
  |---|---|---|
  | **Storage** | Process dictionary | Ecto field on `State` |
  | **Persisted to DB?** | No | Yes (serialized to JSONB) |
  | **Survives restart?** | No | Yes |
  | **Propagated to sub-agents?** | Yes (automatic) | No (intentional isolation) |
  | **Access pattern** | `AgentContext.fetch(:key)` | `State.get_metadata(state, key)` |
  | **Requires state param?** | No | Yes |
  | **Use for** | tenant_id, trace_id, user_id, feature flags | conversation_title, middleware working state |

  **Rule of thumb**: If the value must survive after the process dies, use
  `State.metadata`. If the value is ambient context that flows through the
  agent hierarchy, use `AgentContext`.
  """

  require Logger

  @key {Sagents, :agent_context}

  @doc """
  Initialize the agent context for the current process.

  Sets the context map in the process dictionary. Should be called once
  during process initialization (e.g., in `GenServer.init/1`).

  If the context contains `:__context_restore_fns__` (registered via
  `add_restore_fn/2` during `fork_with_middleware/1`), those functions are
  popped from the context, the clean context is stored, and each restore
  function is called with the clean context. Failures in restore functions
  are logged as warnings but do not prevent init from completing.

  Returns `:ok`.
  """
  @spec init(map()) :: :ok
  def init(context) when is_map(context) do
    {restore_fns, clean_context} = Map.pop(context, :__context_restore_fns__, [])
    Process.put(@key, clean_context)

    Enum.each(restore_fns, fn fun ->
      try do
        fun.(clean_context)
      rescue
        e ->
          Logger.warning("AgentContext restore function failed: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  @doc """
  Read the full context map for the current process.

  Returns an empty map if no context has been initialized.
  """
  @spec get() :: map()
  def get do
    Process.get(@key, %{})
  end

  @doc """
  Fetch a single key from the context, returning a default if not found.
  """
  @spec fetch(atom() | term(), term()) :: term()
  def fetch(key, default \\ nil) do
    Map.get(get(), key, default)
  end

  @doc """
  Set a single key in the current process's agent context.

  Updates the process dictionary in-place. Useful for middleware hooks that
  need to add derived values to the context during execution.

  Does NOT persist — this only updates the process dictionary for the
  current process.

  ## Examples

      AgentContext.put(:request_id, "req-123")
      AgentContext.fetch(:request_id)
      #=> "req-123"
  """
  @spec put(atom() | term(), term()) :: :ok
  def put(key, value) do
    ctx = get()
    Process.put(@key, Map.put(ctx, key, value))
    :ok
  end

  @doc """
  Merge a map into the current process's agent context.

  Updates the process dictionary in-place. Useful when middleware needs to
  add multiple derived values at once.

  Does NOT persist — this only updates the process dictionary for the
  current process.

  ## Examples

      AgentContext.merge(%{request_id: "req-123", correlation_id: "corr-456"})
  """
  @spec merge(map()) :: :ok
  def merge(values) when is_map(values) do
    ctx = get()
    Process.put(@key, Map.merge(ctx, values))
    :ok
  end

  @doc """
  Create a copy of the current context suitable for passing to a child process.

  An optional transform function can modify the context before it is handed off.
  This is useful for adding child-specific metadata (e.g., a `parent_span_id`).

  ## Examples

      # Simple copy
      child_ctx = AgentContext.fork()

      # With transform
      child_ctx = AgentContext.fork(fn ctx -> Map.put(ctx, :parent_span_id, span_id) end)
  """
  @spec fork((map() -> map()) | nil) :: map()
  def fork(transform \\ nil) do
    ctx = get()

    case transform do
      nil -> ctx
      fun when is_function(fun, 1) -> fun.(ctx)
    end
  end

  @doc """
  Fork the current context, giving each middleware the opportunity to inject
  process-local state via its `on_fork_context/2` callback.

  Reads the current process context via `get/0`, then reduces over the
  middleware list calling `Middleware.apply_on_fork_context/2` for each entry
  in list order. Returns the transformed context map.

  This is the preferred way to fork context at sub-agent boundaries, as it
  ensures middleware like OpenTelemetry tracers or Logger metadata propagators
  can contribute to the snapshot.

  ## Parameters

  - `middleware_entries` - List of `MiddlewareEntry` structs (in middleware order)

  ## Examples

      child_context = AgentContext.fork_with_middleware(parent_middleware)
      SubAgentServer.start_link(subagent: subagent, agent_context: child_context)
  """
  @spec fork_with_middleware([Sagents.MiddlewareEntry.t()]) :: map()
  def fork_with_middleware(middleware_entries) when is_list(middleware_entries) do
    ctx = get()

    Enum.reduce(middleware_entries, ctx, fn entry, acc ->
      Sagents.Middleware.apply_on_fork_context(acc, entry)
    end)
  end

  @doc """
  Append a restore function to the context map.

  Middleware `on_fork_context/2` implementations use this to register
  side-effect functions that the child process will call during `init/1`
  to rebuild process-local state (e.g., attaching OpenTelemetry span context,
  setting Logger metadata).

  Each restore function is a 1-arity function that receives the clean context
  map (with `:__context_restore_fns__` already removed).

  ## Parameters

  - `context` - The context map being built during fork
  - `fun` - A 1-arity function to call in the child process during `init/1`

  ## Examples

      def on_fork_context(context, _config) do
        otel_ctx = OpenTelemetry.Ctx.get_current()
        context = Map.put(context, :otel_ctx, otel_ctx)

        AgentContext.add_restore_fn(context, fn ctx ->
          OpenTelemetry.Ctx.attach(ctx[:otel_ctx])
        end)
      end
  """
  @spec add_restore_fn(map(), (map() -> any())) :: map()
  def add_restore_fn(context, fun) when is_map(context) and is_function(fun, 1) do
    fns = Map.get(context, :__context_restore_fns__, [])
    Map.put(context, :__context_restore_fns__, fns ++ [fun])
  end
end
