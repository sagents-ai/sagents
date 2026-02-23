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
  4. **Agent.execute/3** runs in a `Task.async`, which inherits the caller's process dictionary,
     so tools and callbacks can read context via `AgentContext.get/0`
  5. **SubAgent middleware** calls `AgentContext.fork/1` to snapshot context before
     spawning a child SubAgentServer, which calls `AgentContext.init/1` in its own process

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
  """

  @key {Sagents, :agent_context}

  @doc """
  Initialize the agent context for the current process.

  Sets the context map in the process dictionary. Should be called once
  during process initialization (e.g., in `GenServer.init/1`).

  Returns `:ok`.
  """
  @spec init(map()) :: :ok
  def init(context) when is_map(context) do
    Process.put(@key, context)
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
end
