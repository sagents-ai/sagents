# Observability & Custom Telemetry

This guide shows how to build custom observability middleware that emits telemetry events, OpenTelemetry spans, or any other instrumentation from your agent's LLM and tool execution lifecycle.

## Why Middleware?

Sagents provides a `callbacks/1` middleware callback that lets you hook into every LLM event — token usage, tool execution, message processing, errors, and more. Rather than building a one-size-fits-all telemetry integration, Sagents leaves this to you as a custom middleware because:

- **Your telemetry metadata is unique** — customer IDs, tenant context, billing tiers, feature flags
- **Your instrumentation stack is unique** — `:telemetry`, OpenTelemetry, StatsD, Prometheus, Datadog
- **Your event shapes are unique** — what you measure and how you label it depends on your domain

The `callbacks/1` callback gives you direct access to LLM lifecycle events, and your middleware's `init/1` config is the natural place to carry your application-specific context.

## Quick Start

Here's a minimal observability middleware that emits `:telemetry` events for token usage:

```elixir
defmodule MyApp.Middleware.Observability do
  @behaviour Sagents.Middleware

  @impl true
  def init(opts) do
    {:ok, %{service_name: Keyword.get(opts, :service_name, "agent")}}
  end

  @impl true
  def callbacks(config) do
    %{
      on_llm_token_usage: fn chain, usage ->
        %{model: model_name} = chain.llm

        :telemetry.execute(
          [:myapp, :llm, :token_usage],
          %{input: usage.input, output: usage.output},
          %{service: config.service_name, model: model_name}
        )
      end
    }
  end
end
```

Add it to your agent:

```elixir
{:ok, agent} = Sagents.Agent.new(%{
  model: model,
  middleware: [{MyApp.Middleware.Observability, service_name: "support-agent"}]
})
```

That's it. Every LLM call made by this agent will now emit a `[:myapp, :llm, :token_usage]` telemetry event with your service name attached.

## Passing Application-Specific Context

The real power of middleware-based observability is that `init/1` receives your application context and `callbacks/1` closes over it. This means every event you emit can carry metadata that is specific to your system — customer IDs, user IDs, billing tiers, or anything else.

```elixir
defmodule MyApp.Middleware.Observability do
  @behaviour Sagents.Middleware

  @impl true
  def init(opts) do
    {:ok, %{
      service_name: Keyword.get(opts, :service_name, "agent"),
      customer_id: Keyword.fetch!(opts, :customer_id),
      user_id: Keyword.fetch!(opts, :user_id)
    }}
  end

  @impl true
  def callbacks(config) do
    %{
      on_llm_token_usage: fn chain, usage ->
        %{model: model_name} = chain.llm

        :telemetry.execute(
          [:myapp, :llm, :token_usage],
          %{input: usage.input, output: usage.output},
          %{
            service: config.service_name,
            model: model_name,
            customer_id: config.customer_id,
            user_id: config.user_id
          }
        )
      end,

      on_tool_execution_started: fn _chain, tool_call, _function ->
        :telemetry.execute(
          [:myapp, :tool, :started],
          %{system_time: System.system_time()},
          %{
            tool: tool_call.name,
            customer_id: config.customer_id,
            user_id: config.user_id
          }
        )
      end,

      on_tool_execution_completed: fn _chain, tool_call, _tool_result ->
        :telemetry.execute(
          [:myapp, :tool, :completed],
          %{system_time: System.system_time()},
          %{
            tool: tool_call.name,
            customer_id: config.customer_id,
            user_id: config.user_id
          }
        )
      end,

      on_tool_execution_failed: fn _chain, tool_call, error ->
        :telemetry.execute(
          [:myapp, :tool, :failed],
          %{system_time: System.system_time()},
          %{
            tool: tool_call.name,
            error: inspect(error),
            customer_id: config.customer_id,
            user_id: config.user_id
          }
        )
      end
    }
  end
end
```

When creating the agent, pass the context from your application:

```elixir
# In your Coordinator, Factory, or wherever agents are created
{:ok, agent} = Sagents.Agent.new(%{
  model: model,
  middleware: [
    {MyApp.Middleware.Observability,
      service_name: "support-agent",
      customer_id: customer.id,
      user_id: current_user.id},
    # ... other middleware
  ]
})
```

Now every telemetry event carries the customer and user context, so you can slice metrics by customer, track per-user usage for billing, or correlate tool failures with specific accounts.

## Available Callback Keys

The `callbacks/1` function returns a map of callback keys to handler functions. Here is the complete list of available keys with their signatures:

### Model-Level Callbacks

| Key | Signature | When it fires |
|-----|-----------|---------------|
| `:on_llm_new_delta` | `fn chain, [delta] -> any()` | Each streaming token/delta received |
| `:on_llm_new_message` | `fn chain, message -> any()` | Complete message from LLM (non-streaming) |
| `:on_llm_ratelimit_info` | `fn chain, info_map -> any()` | Rate limit headers from provider |
| `:on_llm_token_usage` | `fn chain, token_usage -> any()` | Token usage for the request |
| `:on_llm_response_headers` | `fn chain, headers_map -> any()` | Raw HTTP response headers |

### Chain-Level Callbacks

| Key | Signature | When it fires |
|-----|-----------|---------------|
| `:on_message_processed` | `fn chain, message -> any()` | Message fully processed (streaming or not) |
| `:on_message_processing_error` | `fn chain, message -> any()` | Error while processing a message |
| `:on_error_message_created` | `fn chain, message -> any()` | Automated error response message created |
| `:on_tool_call_identified` | `fn chain, tool_call, function -> any()` | Tool call detected during streaming |
| `:on_tool_execution_started` | `fn chain, tool_call, function -> any()` | Tool begins executing (fires in the parent chain process, before any per-tool async Task is spawned) |
| `:on_tool_pre_execution` | `fn chain, tool_call, function -> any()` | Fires inside the process that runs the tool, immediately before invocation. For `async: true` tools this is the spawned `Task.async/1`; for sync tools and HITL-resumed tools it is the chain's own process. Use this for code that depends on per-process state (OpenTelemetry context, Sentry scope, tenancy, Logger metadata) |
| `:on_tool_execution_completed` | `fn chain, tool_call, tool_result -> any()` | Tool finished successfully |
| `:on_tool_execution_failed` | `fn chain, tool_call, error -> any()` | Tool execution errored |
| `:on_tool_response_created` | `fn chain, message -> any()` | Tool response message created |
| `:on_retries_exceeded` | `fn chain -> any()` | Max retries exhausted |

All handler return values are discarded. Callbacks are for observation only — they cannot modify the chain or its state.

> **Tip: Extracting the model name.** The `chain` argument is an `LLMChain` struct. You can extract the model name with `%{model: model_name} = chain.llm`. This works regardless of which chat model provider is being used (Anthropic, OpenAI, etc.), since they all have a `:model` field. This is especially useful in token usage callbacks for cost tracking across different models.

## Fan-Out Behavior

When multiple middleware declare callbacks, all handlers fire for each event. If two middleware both define `on_llm_token_usage`, both handlers execute. This means you can have separate middleware for metrics, logging, and tracing without them interfering with each other.

```elixir
{:ok, agent} = Sagents.Agent.new(%{
  model: model,
  middleware: [
    {MyApp.Middleware.Metrics, customer_id: customer.id},
    {MyApp.Middleware.AuditLog, user_id: user.id},
    # ... other middleware
  ]
})
```

Both `Metrics` and `AuditLog` can declare `callbacks/1` and both will fire.

## Sub-Agent Propagation

By default, an agent's middleware stack is passed down to any sub-agents it spawns. This means your observability middleware automatically covers the entire agent tree — the parent agent and all of its sub-agents — without any extra configuration.

If your parent agent is configured with:

```elixir
{:ok, agent} = Sagents.Agent.new(%{
  model: model,
  middleware: [
    {MyApp.Middleware.Observability,
      service_name: "support-agent",
      customer_id: customer.id,
      user_id: current_user.id},
    Sagents.Middleware.SubAgent,
    # ... other middleware
  ]
})
```

When this agent spawns sub-agents, those sub-agents inherit the same middleware stack including your observability middleware. Token usage, tool execution, and errors from sub-agents all emit the same telemetry events with the same customer and user context as the parent. You get full visibility across the entire agent interaction without any additional wiring.

## Full Example: Comprehensive Observability

Here's a more complete example that covers the most useful events for production observability:

```elixir
defmodule MyApp.Middleware.Observability do
  @behaviour Sagents.Middleware
  require Logger

  @impl true
  def init(opts) do
    {:ok, %{
      service_name: Keyword.get(opts, :service_name, "agent"),
      customer_id: Keyword.get(opts, :customer_id),
      user_id: Keyword.get(opts, :user_id)
    }}
  end

  @impl true
  def callbacks(config) do
    metadata = %{
      service: config.service_name,
      customer_id: config.customer_id,
      user_id: config.user_id
    }

    %{
      # Track token usage for cost monitoring and billing
      on_llm_token_usage: fn chain, usage ->
        %{model: model_name} = chain.llm

        :telemetry.execute(
          [:myapp, :llm, :token_usage],
          %{input: usage.input, output: usage.output},
          Map.put(metadata, :model, model_name)
        )
      end,

      # Track rate limits to detect throttling
      on_llm_ratelimit_info: fn _chain, info ->
        :telemetry.execute(
          [:myapp, :llm, :ratelimit],
          info,
          metadata
        )
      end,

      # Track tool execution lifecycle
      on_tool_execution_started: fn _chain, tool_call, _function ->
        :telemetry.execute(
          [:myapp, :tool, :started],
          %{system_time: System.system_time()},
          Map.put(metadata, :tool, tool_call.name)
        )
      end,

      on_tool_execution_completed: fn _chain, tool_call, _tool_result ->
        :telemetry.execute(
          [:myapp, :tool, :completed],
          %{system_time: System.system_time()},
          Map.put(metadata, :tool, tool_call.name)
        )
      end,

      on_tool_execution_failed: fn _chain, tool_call, error ->
        Logger.warning("Tool #{tool_call.name} failed: #{inspect(error)}",
          customer_id: config.customer_id
        )

        :telemetry.execute(
          [:myapp, :tool, :failed],
          %{system_time: System.system_time()},
          Map.merge(metadata, %{tool: tool_call.name, error: inspect(error)})
        )
      end,

      # Track when retries are exhausted (potential reliability issue)
      on_retries_exceeded: fn _chain ->
        :telemetry.execute(
          [:myapp, :llm, :retries_exceeded],
          %{count: 1},
          metadata
        )
      end
    }
  end
end
```

### Attaching Telemetry Handlers

Wire up the telemetry events in your application startup:

```elixir
# In your Application.start/2 or a dedicated Telemetry module
:telemetry.attach_many(
  "myapp-agent-metrics",
  [
    [:myapp, :llm, :token_usage],
    [:myapp, :tool, :started],
    [:myapp, :tool, :completed],
    [:myapp, :tool, :failed],
    [:myapp, :llm, :retries_exceeded]
  ],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

## Testing Your Observability Middleware

Test that your callbacks fire and emit the expected telemetry events:

```elixir
defmodule MyApp.Middleware.ObservabilityTest do
  use ExUnit.Case
  alias MyApp.Middleware.Observability

  test "callbacks/1 returns expected callback keys" do
    {:ok, config} = Observability.init(
      service_name: "test",
      customer_id: "cust-1",
      user_id: "user-1"
    )

    callbacks = Observability.callbacks(config)

    assert is_function(callbacks[:on_llm_token_usage], 2)
    assert is_function(callbacks[:on_tool_execution_started], 3)
    assert is_function(callbacks[:on_tool_execution_completed], 3)
    assert is_function(callbacks[:on_tool_execution_failed], 3)
  end

  test "on_llm_token_usage emits telemetry event" do
    {:ok, config} = Observability.init(
      service_name: "test",
      customer_id: "cust-1",
      user_id: "user-1"
    )

    ref = :telemetry_test.attach_event_handlers(self(), [
      [:myapp, :llm, :token_usage]
    ])

    callbacks = Observability.callbacks(config)
    usage = %LangChain.TokenUsage{input: 100, output: 50}
    callbacks.on_llm_token_usage.(nil, usage)

    assert_received {[:myapp, :llm, :token_usage], ^ref,
      %{input: 100, output: 50},
      %{service: "test", customer_id: "cust-1", user_id: "user-1"}}
  end
end
```

## Propagating Caller Context Across Process Boundaries

Observability that depends on per-process state — OpenTelemetry trace context, Sentry context, request-scoped logger metadata, multi-tenant context — runs into a structural problem: a Sagents agent crosses three process boundaries during a single invocation, and per-process state does not cross any of them automatically.

The boundaries:

1. **Caller → AgentServer GenServer.** The agent's lifecycle hooks run inside a supervised GenServer, not the process that created the agent.
2. **AgentServer → chain Task.** Each LLM turn spawns a `Task` for the chain run.
3. **Chain Task → per-tool async Task.** `LangChain.Function`s declared with `async: true` run in fresh `Task.async/1` processes.

Without explicit propagation, an OpenTelemetry span started by your tool runs detached from the parent trace, a Sentry exception captured during tool execution arrives without user/request context, and a tenant-scoped DB query in a tool raises because `Process.get(:org_id)` returns `nil`.

### `Sagents.Middleware.ProcessContext`

The built-in `Sagents.Middleware.ProcessContext` middleware closes all three boundaries with one configuration block. Add it as the **first** middleware in your stack so its `before_model/2` runs before any other middleware that might query the Repo or open a span.

```elixir
{:ok, agent} = Sagents.Agent.new(%{
  model: model,
  middleware: [
    {Sagents.Middleware.ProcessContext,
      keys: [:sentry_context],
      propagators: [
        {&OpenTelemetry.get_current/0, &OpenTelemetry.attach/1},
        {&MyApp.Tenancy.get_context/0, &MyApp.Tenancy.set_context/1}
      ]},
    # ... your other middleware (Observability, TodoList, etc.)
  ]
})
```

Two configuration options, both optional, freely combined:

- **`:keys`** — list of process-dictionary keys (atoms). Each key has its value captured via `Process.get/1` in the caller's process at `init/1` time, then re-applied with `Process.put/2` on the receiving side of every boundary. Use for state that genuinely lives in the process dict, like `:sentry_context`.
- **`:propagators`** — list of `{capture_fn, apply_fn}` pairs. `capture_fn` is 0-arity, called once at `init/1` in the caller's process. `apply_fn` is 1-arity, called on the receiving side of each boundary with the captured value. Use for state that lives somewhere other than the process dict — OpenTelemetry's context stash, ETS-backed contexts, application-specific tenancy modules.

The propagator pairs are read like English at the call site: `{&OpenTelemetry.get_current/0, &OpenTelemetry.attach/1}` says "capture the current OTel context, re-apply it on the other side." There is no hidden behavior — the middleware does exactly what the pair specifies.

### Refreshing the snapshot for long-lived agents

`init/1` captures once, at agent construction time. For agents that handle a single request and are then discarded — a fresh agent per LiveView mount, per Coordinator session, per Oban job — that one capture is the only one you need.

For long-lived agents that handle many user messages over time — a conversation-scoped `AgentServer` reused across hours of user interaction, for example — the captured snapshot goes stale. The OTel trace ID, the Sentry context, the active tenant might all be different by the time message #50 arrives.

`update/1` refreshes it. The middleware already has the spec from `init/1`, so the caller only supplies the `agent_id`. Capture functions run in the *caller of* `update/1` against its current process dictionary, then the new snapshot replaces the stored snapshot in the agent's `state.metadata`:

```elixir
# In a LiveView handle_event, an Oban worker, a Phoenix controller — anywhere
# a new request boundary is crossed before relaying a message to the agent:
def handle_event("send_message", %{"text" => text}, socket) do
  Sagents.Middleware.ProcessContext.update(socket.assigns.agent_id)
  Sagents.AgentServer.add_message(socket.assigns.agent_id, Message.new_user!(text))
  {:noreply, socket}
end
```

Both the `update/1` call and the `add_message/2` call go through the same AgentServer mailbox in order, so the refresh always lands before the next execute begins.

`update/1` returns:

- `:ok` on success
- `{:error, :not_found}` if no AgentServer is running for that `agent_id`
- `{:error, :no_process_context_middleware}` if the agent is running but doesn't have `ProcessContext` in its middleware stack

### Important: within-execute consistency

A single execute_loop is one logical request — one user message resolved by potentially many LLM turns and tool calls. **Within that loop, the snapshot is intentionally frozen.** An `update/1` call arriving mid-execute does not retarget in-flight tools; the chain captured its `custom_context` snapshot when the loop began, and per-tool callbacks see *that* snapshot.

This is the right behavior. A single request should see one consistent context for its duration — interleaving partial OTel contexts or two different tenant scopes inside one logical operation would be a correctness disaster, not a feature. Refresh between requests, not during one.

If you genuinely need to retarget mid-flight (rare), the right tool is to interrupt the agent (`Sagents.Agent.resume/3` after an interrupt), update the context, and resume.

### Sub-agent propagation

`ProcessContext` is just another middleware, and middleware stacks are inherited by sub-agents by default (see *Sub-Agent Propagation* above). Configure it once at the top-level agent and every sub-agent spawned by `Sagents.Middleware.SubAgent` inherits the same propagation behaviour and the same `update/1` plumbing automatically.
