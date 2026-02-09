# Middleware Development

This document covers how to build custom middleware for Sagents.

## Overview

Middleware is the primary extension mechanism in Sagents. Each middleware can:
- Add tools to the agent
- Contribute to the system prompt
- Process state before/after LLM calls
- Handle async messages
- Trigger HITL interrupts

## The Middleware Behaviour

```elixir
@callback init(opts :: keyword()) :: {:ok, config :: map()} | {:error, reason}
@callback system_prompt(config :: map()) :: String.t() | [String.t()]
@callback tools(config :: map()) :: [LangChain.Function.t()]
@callback before_model(state :: State.t(), config :: map()) ::
  {:ok, State.t()} | {:interrupt, State.t(), interrupt_data :: map()} | {:error, reason}
@callback after_model(state :: State.t(), config :: map()) ::
  {:ok, State.t()} | {:interrupt, State.t(), interrupt_data :: map()} | {:error, reason}
@callback handle_message(message :: term(), state :: State.t(), config :: map()) ::
  {:ok, State.t()} | {:error, reason}
@callback on_server_start(state :: State.t(), config :: map()) ::
  {:ok, State.t()} | {:error, reason}
@callback state_schema() :: module() | nil
```

All callbacks are optional with default implementations that pass through unchanged.

## Basic Middleware

### Minimal Example

```elixir
defmodule MyApp.Middleware.Greeting do
  @behaviour Sagents.Middleware

  @impl true
  def system_prompt(_config) do
    "Always greet the user warmly before responding."
  end
end
```

### With Configuration

```elixir
defmodule MyApp.Middleware.RateLimit do
  @behaviour Sagents.Middleware

  @impl true
  def init(opts) do
    config = %{
      max_calls_per_minute: Keyword.get(opts, :max_calls, 10),
      window_ms: Keyword.get(opts, :window, 60_000)
    }
    {:ok, config}
  end

  @impl true
  def before_model(state, config) do
    if rate_limited?(state, config) do
      {:error, "Rate limit exceeded"}
    else
      {:ok, track_call(state)}
    end
  end

  defp rate_limited?(state, config) do
    # Implementation...
  end

  defp track_call(state) do
    # Implementation...
  end
end

# Usage
{:ok, agent} = Agent.new(%{
  middleware: [
    {MyApp.Middleware.RateLimit, max_calls: 20, window: 30_000}
  ]
})
```

## Adding Tools

### Simple Tool

```elixir
defmodule MyApp.Middleware.Calculator do
  @behaviour Sagents.Middleware
  alias LangChain.Function

  @impl true
  def system_prompt(_config) do
    "You have access to a calculator for mathematical operations."
  end

  @impl true
  def tools(_config) do
    [
      Function.new!(%{
        name: "calculate",
        description: "Perform a mathematical calculation",
        parameters_schema: %{
          type: "object",
          properties: %{
            expression: %{
              type: "string",
              description: "Mathematical expression to evaluate (e.g., '2 + 2 * 3')"
            }
          },
          required: ["expression"]
        },
        function: &execute_calculate/2
      })
    ]
  end

  defp execute_calculate(%{"expression" => expr}, _context) do
    case safe_eval(expr) do
      {:ok, result} -> {:ok, "Result: #{result}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_eval(expr) do
    # Safe expression evaluation...
  end
end
```

### Tool with State Updates

Tools can modify the agent state:

```elixir
defmodule MyApp.Middleware.Counter do
  @behaviour Sagents.Middleware
  alias Sagents.State
  alias LangChain.Function

  @impl true
  def tools(_config) do
    [
      Function.new!(%{
        name: "increment_counter",
        description: "Increment the conversation counter",
        parameters_schema: %{type: "object", properties: %{}},
        function: &execute_increment/2
      })
    ]
  end

  defp execute_increment(_args, context) do
    state = context.state
    current = State.get_metadata(state, :counter, 0)
    new_count = current + 1

    # Return updated state as third element
    updated_state = State.put_metadata(state, :counter, new_count)

    {:ok, "Counter is now #{new_count}", updated_state}
  end
end
```

The state delta is automatically merged back into the main state.

### Configurable Tools

```elixir
defmodule MyApp.Middleware.WebSearch do
  @behaviour Sagents.Middleware

  @impl true
  def init(opts) do
    {:ok, %{
      api_key: Keyword.fetch!(opts, :api_key),
      max_results: Keyword.get(opts, :max_results, 5),
      enabled: Keyword.get(opts, :enabled, true)
    }}
  end

  @impl true
  def tools(config) do
    if config.enabled do
      [build_search_tool(config)]
    else
      []
    end
  end

  defp build_search_tool(config) do
    Function.new!(%{
      name: "web_search",
      description: "Search the web for information",
      parameters_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query"}
        },
        required: ["query"]
      },
      function: fn args, _ctx -> execute_search(args, config) end
    })
  end

  defp execute_search(%{"query" => query}, config) do
    # Use config.api_key, config.max_results
  end
end
```

## Processing State

### before_model

Called before each LLM call. Use for:
- Validating/transforming messages
- Adding context
- Rate limiting
- Token management

```elixir
defmodule MyApp.Middleware.ContextInjector do
  @behaviour Sagents.Middleware
  alias Sagents.State
  alias LangChain.Message

  @impl true
  def before_model(state, config) do
    # Add current time to context
    context_msg = Message.new_system!(
      "Current time: #{DateTime.utc_now()}"
    )

    # Insert after system message, before conversation
    messages = inject_context(state.messages, context_msg)

    {:ok, %{state | messages: messages}}
  end

  defp inject_context([system | rest], context) do
    [system, context | rest]
  end

  defp inject_context(messages, context) do
    [context | messages]
  end
end
```

### after_model

Called after LLM responds. Use for:
- Post-processing responses
- Triggering HITL interrupts
- Logging/telemetry

```elixir
defmodule MyApp.Middleware.ResponseFilter do
  @behaviour Sagents.Middleware

  @impl true
  def after_model(state, config) do
    # Get the last assistant message
    case find_last_assistant_message(state.messages) do
      nil ->
        {:ok, state}

      message ->
        if contains_forbidden_content?(message.content) do
          # Replace with filtered content
          filtered = filter_content(message.content)
          updated_messages = replace_last_assistant(state.messages, filtered)
          {:ok, %{state | messages: updated_messages}}
        else
          {:ok, state}
        end
    end
  end
end
```

## Triggering Interrupts

Middleware can pause execution for human approval:

```elixir
defmodule MyApp.Middleware.SensitiveTopicReview do
  @behaviour Sagents.Middleware

  @impl true
  def after_model(state, config) do
    last_message = List.last(state.messages)

    if requires_review?(last_message) do
      interrupt_data = %{
        reason: :sensitive_topic,
        message: last_message,
        suggested_action: "Please review this response before sending."
      }

      {:interrupt, state, interrupt_data}
    else
      {:ok, state}
    end
  end

  defp requires_review?(message) do
    # Check for sensitive topics...
  end
end
```

The interrupt pauses execution and broadcasts to subscribers. Resume with:

```elixir
# User approves
AgentServer.resume(agent_id, %{approved: true})

# User rejects - execution continues but message is removed
AgentServer.resume(agent_id, %{approved: false})
```

## Async Operations

Sometimes middleware needs to perform slow operations (API calls, LLM requests, database queries) without blocking the main agent execution. The `handle_message` callback enables this pattern by allowing middleware to:

1. Spawn an async task during a hook (like `after_model`)
2. Return immediately so the agent can continue
3. Receive the async result later via `handle_message`
4. Update state persistently when the result arrives

This is powerful because the state update in `handle_message` is durable—it gets persisted just like any other state change, and the middleware can broadcast events to notify subscribers (like LiveViews) of the update.

### Real-World Example: Conversation Title Generation

A concrete use case is the `ConversationTitle` middleware. When a user sends their first message, we want to generate a descriptive title for the conversation. However, calling an LLM to generate the title would block the agent's response. Instead:

1. `before_model` spawns an async task to generate the title (runs in parallel with the main LLM call and any tool execution)
2. The agent immediately proceeds to the LLM call (no delay)
3. When the title is ready, `handle_message` stores it in metadata
4. A PubSub event notifies the UI to update the conversation title

The user sees the title appear quickly, even if the agent triggers long-running tools.

### handle_message Callback

For middleware that spawns async tasks:

```elixir
defmodule MyApp.Middleware.AsyncEnrichment do
  @behaviour Sagents.Middleware
  alias Sagents.AgentServer
  alias Sagents.State

  @impl true
  def after_model(state, _config) do
    # Spawn async task - don't block the agent
    spawn_enrichment_task(state)
    # Return immediately so agent execution continues
    {:ok, state}
  end

  defp spawn_enrichment_task(state) do
    agent_id = state.agent_id
    middleware_id = __MODULE__

    Task.start(fn ->
      # Do slow work (API call, LLM request, etc.)
      result = fetch_enrichment_data()

      # Route the result back to THIS middleware via AgentServer
      # The AgentServer will call our handle_message/3 with this data
      AgentServer.send_middleware_message(agent_id, middleware_id, {:enrichment_ready, result})
    end)
  end

  @impl true
  def handle_message({:enrichment_ready, result}, state, _config) do
    # This runs later, when the async task completes
    # State updates here are persisted just like in other callbacks
    updated_state = State.put_metadata(state, :enrichment, result)

    # Broadcast to subscribers (LiveViews, etc.) so they can react
    AgentServer.publish_event_from(state.agent_id, {:enrichment_updated, result})

    {:ok, updated_state}
  end
end
```

### Key Points

- **Message Routing**: `AgentServer.send_middleware_message/3` routes the message to the specific middleware that sent it, using the `middleware_id` (typically `__MODULE__`)
- **Persistent State**: Updates in `handle_message` are persisted to the agent's state, surviving process restarts if auto-save is configured
- **Non-Blocking**: The agent doesn't wait for async work—it continues executing and responding to users
- **Event Broadcasting**: Use `publish_event_from/2` to notify external subscribers (like LiveViews) when async work completes

### on_server_start Callback

Called when AgentServer starts (including restarts):

```elixir
defmodule MyApp.Middleware.InitialBroadcast do
  @behaviour Sagents.Middleware
  alias Sagents.AgentServer

  @impl true
  def on_server_start(state, _config) do
    # Broadcast initial state to any subscribers
    if state.todos != [] do
      AgentServer.publish_event_from(state.agent_id, {:todos_updated, state.todos})
    end

    {:ok, state}
  end
end
```

## State Schema

Define what metadata your middleware stores for serialization by returning a schema module:

```elixir
defmodule MyApp.Middleware.Preferences do
  @behaviour Sagents.Middleware

  @impl true
  def state_schema do
    # Return a module that defines the schema, or nil if no custom serialization needed
    MyApp.Middleware.Preferences.Schema
  end

  @impl true
  def tools(_config) do
    [
      Function.new!(%{
        name: "set_preference",
        description: "Set a user preference",
        parameters_schema: %{
          type: "object",
          properties: %{
            key: %{type: "string"},
            value: %{type: "string"}
          },
          required: ["key", "value"]
        },
        function: &execute_set_preference/2
      })
    ]
  end

  defp execute_set_preference(%{"key" => key, "value" => value}, context) do
    prefs = State.get_metadata(context.state, :preferences, %{})
    new_prefs = Map.put(prefs, key, value)
    updated_state = State.put_metadata(context.state, :preferences, new_prefs)

    {:ok, "Preference '#{key}' set to '#{value}'", updated_state}
  end
end
```

## Middleware Ordering

Middleware order matters:

```elixir
middleware: [
  TodoList,           # 1. Runs first in before_model, last in after_model
  FileSystem,         # 2.
  Summarization,      # 3. Should run before PatchToolCalls
  PatchToolCalls,     # 4. Fixes dangling calls
  HumanInTheLoop,     # 5. Runs last in before_model, first in after_model
]
```

### before_model Order

```
User message → TodoList → FileSystem → Summarization → PatchToolCalls → HITL → LLM
```

### after_model Order (Reversed)

```
LLM response → HITL → PatchToolCalls → Summarization → FileSystem → TodoList → Done
```

This "sandwich" pattern means:
- Early middleware can set up context for later middleware
- Early middleware sees the final processed result

## Broadcasting Events

### Standard Events

```elixir
# Broadcast to main topic
AgentServer.publish_event_from(state.agent_id, {:my_event, data})

# Subscribers receive:
{:agent, {:my_event, data}}
```

### Debug Events

```elixir
# Broadcast to debug topic
AgentServer.publish_debug_event_from(
  state.agent_id,
  {:middleware_action, __MODULE__, {:action_name, details}}
)

# Subscribers to debug topic receive:
{:agent, {:debug, {:middleware_action, MyMiddleware, {:action_name, details}}}}
```

## Testing Middleware

### Unit Testing

```elixir
defmodule MyApp.Middleware.CalculatorTest do
  use ExUnit.Case
  alias MyApp.Middleware.Calculator
  alias Sagents.State

  describe "tools/1" do
    test "returns calculate tool" do
      {:ok, config} = Calculator.init([])
      tools = Calculator.tools(config)

      assert length(tools) == 1
      assert hd(tools).name == "calculate"
    end
  end

  describe "calculate execution" do
    test "evaluates expression" do
      {:ok, config} = Calculator.init([])
      [tool] = Calculator.tools(config)

      context = %{state: State.new!()}
      result = tool.function.(%{"expression" => "2 + 3"}, context)

      assert {:ok, "Result: 5"} = result
    end
  end
end
```

### Integration Testing

```elixir
defmodule MyApp.Middleware.CalculatorIntegrationTest do
  use ExUnit.Case
  alias Sagents.{Agent, State}
  alias LangChain.Message

  @tag :live_call
  test "agent can use calculator tool" do
    {:ok, agent} = Agent.new(%{
      model: test_model(),
      middleware: [MyApp.Middleware.Calculator]
    })

    state = State.new!(%{
      messages: [Message.new_user!("What is 15 * 23?")]
    })

    {:ok, result_state} = Agent.execute(agent, state)

    # Verify tool was called and result included
    assert Enum.any?(result_state.messages, fn msg ->
      msg.role == :tool && String.contains?(msg.content, "345")
    end)
  end
end
```

## Common Patterns

### Read-Only Middleware

```elixir
defmodule MyApp.Middleware.Logging do
  @behaviour Sagents.Middleware
  require Logger

  @impl true
  def before_model(state, _config) do
    Logger.info("Agent #{state.agent_id}: #{length(state.messages)} messages")
    {:ok, state}  # Return unchanged
  end

  @impl true
  def after_model(state, _config) do
    Logger.info("Agent #{state.agent_id}: LLM responded")
    {:ok, state}  # Return unchanged
  end
end
```

### Conditional Middleware

```elixir
defmodule MyApp.Middleware.FeatureFlag do
  @behaviour Sagents.Middleware

  @impl true
  def init(opts) do
    {:ok, %{
      flag_name: Keyword.fetch!(opts, :flag),
      wrapped_middleware: Keyword.fetch!(opts, :middleware)
    }}
  end

  @impl true
  def tools(config) do
    if feature_enabled?(config.flag_name) do
      {mod, opts} = config.wrapped_middleware
      {:ok, inner_config} = mod.init(opts)
      mod.tools(inner_config)
    else
      []
    end
  end

  # Delegate other callbacks similarly...
end

# Usage
{MyApp.Middleware.FeatureFlag, [
  flag: :advanced_search,
  middleware: {MyApp.Middleware.WebSearch, [api_key: key]}
]}
```

### Dynamic Middleware Configuration

One of the key benefits of middleware is that the stack can be assembled programmatically at runtime. This allows you to customize agent capabilities based on account tier, user permissions, project settings, or any other context.

```elixir
defmodule MyApp.AgentFactory do
  @moduledoc """
  Builds agents with middleware tailored to the user's context.
  """

  alias Sagents.Agent
  alias Sagents.Middleware.{TodoList, FileSystem, Summarization, SubAgent}

  def create_agent(user, project) do
    middleware = build_middleware_stack(user, project)

    Agent.new(%{
      agent_id: "project-#{project.id}",
      model: select_model(user),
      middleware: middleware
    })
  end

  defp build_middleware_stack(user, project) do
    base = [
      {TodoList, []},
      {Summarization, [max_tokens: token_limit(user)]}
    ]

    # Add filesystem access based on project settings
    base = if project.filesystem_enabled do
      base ++ [{FileSystem, [
        enabled_tools: filesystem_tools(user),
        filesystem_scope: {:project, project.id}
      ]}]
    else
      base
    end

    # Add sub-agents for premium users
    base = if user.plan == :premium do
      base ++ [{SubAgent, [max_concurrent: 3]}]
    else
      base
    end

    # Add custom middleware from project config
    base ++ project.custom_middleware
  end

  defp filesystem_tools(user) do
    case user.role do
      :admin -> ["ls", "read_file", "write_file", "delete_file"]
      :developer -> ["ls", "read_file", "write_file"]
      :viewer -> ["ls", "read_file"]
    end
  end

  defp token_limit(user) do
    case user.plan do
      :enterprise -> 500_000
      :premium -> 200_000
      :free -> 50_000
    end
  end

  defp select_model(user) do
    # Different models based on user tier
    case user.plan do
      :enterprise -> ChatAnthropic.new!(%{model: "claude-sonnet-4-20250514"})
      _ -> ChatAnthropic.new!(%{model: "claude-3-5-haiku-latest"})
    end
  end
end
```

This pattern keeps middleware modular and reusable while allowing fine-grained control over what capabilities each agent receives. The middleware themselves don't need to know about user tiers or permissions—that logic lives in the factory that assembles the stack.
