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
| `:on_tool_execution_started` | `fn chain, tool_call, function -> any()` | Tool begins executing |
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
