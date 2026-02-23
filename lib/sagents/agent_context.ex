defmodule Sagents.AgentContext do
  @moduledoc """
  Process-local context propagation for agent hierarchies.

  Provides a mechanism to propagate application-level context (e.g., OpenTelemetry
  trace IDs, tenant IDs, feature flags) through the agent execution tree.

  Context is stored in the process dictionary for zero-cost reads within a process.
  At process boundaries (e.g., spawning sub-agents), use `fork/1` to snapshot the
  context for explicit passing to the child process.

  ## Usage

      # At the application boundary (e.g., LiveView or API controller)
      AgentSupervisor.start_link(
        agent: agent,
        agent_context: %{trace_id: "abc123", tenant_id: 42}
      )

      # Inside a tool function (reads from chain's custom_context or PD)
      ctx = AgentContext.get()
      trace_id = AgentContext.fetch(:trace_id)

      # When spawning a sub-agent (cross-process boundary)
      child_context = AgentContext.fork(fn ctx -> Map.put(ctx, :parent_span_id, current_span()) end)
      SubAgentServer.start_link(subagent: subagent, agent_context: child_context)
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
