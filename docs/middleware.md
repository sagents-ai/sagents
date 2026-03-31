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
@callback handle_resume(agent :: Agent.t(), state :: State.t(), resume_data :: term(),
  config :: map(), opts :: keyword()) ::
  {:ok, State.t()} | {:cont, State.t()} | {:interrupt, State.t(), map()} | {:error, reason}
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
AgentServer.resume(agent_id, resume_data)
```

### Tool-Level Interrupts

Tools can also trigger interrupts by returning `{:interrupt, display_message, interrupt_data}` from their function. This is how `AskUserQuestion` works -- the `ask_user` tool returns an interrupt, which the mode pipeline detects via `check_tool_interrupts` and surfaces to the caller.

```elixir
Function.new!(%{
  name: "confirm_action",
  description: "Ask the user to confirm before proceeding",
  parameters_schema: %{...},
  function: fn args, _ctx ->
    {:interrupt, "Waiting for confirmation...", %{
      type: :my_custom_confirmation,
      action: args["action"],
      details: args["details"]
    }}
  end
})
```

### Handling Resume with `handle_resume/5`

When `Agent.resume/4` is called, the middleware stack is cycled in order. Each middleware's `handle_resume/5` gets a chance to claim the interrupt by pattern-matching on `state.interrupt_data`.

```elixir
@callback handle_resume(agent, state, resume_data, config, opts) ::
  {:ok, State.t()}              # Handled, ready for re-execution
  | {:cont, State.t()}          # Not mine (or handled, pass along)
  | {:interrupt, State.t(), map()} # Handled, but needs another round
  | {:error, reason}            # Handled, but invalid
```

The default (when not implemented) is `{:cont, state}` -- pass through to the next middleware.

**Return values explained:**

- **`{:cont, state}`** -- "Not my interrupt" or "I handled my part, let the next middleware look." If no middleware claims the interrupt, `Agent.resume` returns an error.

- **`{:ok, state}`** -- "Fully handled. The state is ready for the agent to continue execution." `Agent.resume` calls `Agent.execute` with the updated state.

- **`{:interrupt, state, new_interrupt_data}`** -- "I recognize this, and it needs to go back to the user." `Agent.resume` returns the interrupt to the caller without calling `execute`.

- **`{:error, reason}`** -- "I recognize this interrupt but the resume_data is invalid."

### Claim vs Resolve

When `resume_data` is `nil`, the middleware is being asked to **claim** an interrupt (identify it as its own type and surface it). When `resume_data` is non-nil, the middleware is being asked to **resolve** it (process the user's response).

This distinction matters when interrupts are discovered during another middleware's `handle_resume`. For example, when HumanInTheLoop executes tools and one of them produces a new interrupt, HITL sets the new `interrupt_data` on state and returns `{:cont}`. The resume cycle re-scans the middleware stack with `resume_data = nil`, and the owning middleware claims it:

```elixir
defmodule MyApp.Middleware.CustomConfirmation do
  @behaviour Sagents.Middleware

  # Claim: resume_data is nil, just surface the interrupt to the user
  @impl true
  def handle_resume(_agent, %State{interrupt_data: %{type: :my_confirmation}} = state,
                    nil, _config, _opts) do
    {:interrupt, state, state.interrupt_data}
  end

  # Resolve: resume_data has the user's response
  def handle_resume(_agent, %State{interrupt_data: %{type: :my_confirmation}} = state,
                    %{confirmed: confirmed}, _config, _opts) do
    if confirmed do
      # Build tool result, replace the interrupt placeholder
      result = ToolResult.new!(%{
        tool_call_id: state.interrupt_data.tool_call_id,
        content: "User confirmed the action.",
        name: "confirm_action",
        is_interrupt: false
      })
      {:ok, State.replace_tool_result(state, state.interrupt_data.tool_call_id, result)}
    else
      result = ToolResult.new!(%{
        tool_call_id: state.interrupt_data.tool_call_id,
        content: "User declined. Do not proceed with this action.",
        name: "confirm_action",
        is_interrupt: false
      })
      {:ok, State.replace_tool_result(state, state.interrupt_data.tool_call_id, result)}
    end
  end

  # Not our interrupt type
  def handle_resume(_agent, state, _resume_data, _config, _opts), do: {:cont, state}
end
```

### Re-scan Mechanism

When a middleware returns `{:cont, state}` with new `interrupt_data` on state (different from what the cycle started with), `Agent.resume` automatically re-scans the middleware stack from the beginning with `resume_data = nil`. This allows the owning middleware to claim the interrupt regardless of its position in the stack.

This is how HumanInTheLoop and AskUserQuestion interact when the LLM calls both a gated tool and `ask_user` in the same turn: HITL executes all tools, discovers the ask_user interrupt in the results, sets it on state, and returns `{:cont}`. The re-scan lets AskUserQuestion claim it.

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

Middleware order matters for `before_model` (runs in list order) and `after_model` (runs in reverse). The `handle_resume` cycle runs in list order.

```elixir
middleware: [
  TodoList,           # 1. Task management
  FileSystem,         # 2. File operations
  SubAgent,           # 3. Child agent delegation
  Summarization,      # 4. Conversation compression
  PatchToolCalls,     # 5. Fix dangling tool calls
  AskUserQuestion,    # 6. Structured questions (interrupt-producing)
  HumanInTheLoop,     # 7. MUST BE LAST - human approval gate
]
```

### before_model Order

```
User message → TodoList → FileSystem → ... → PatchToolCalls → AskUserQuestion → HITL → LLM
```

### after_model Order (Reversed)

```
LLM response → HITL → AskUserQuestion → PatchToolCalls → ... → FileSystem → TodoList → Done
```

This "sandwich" pattern means:
- Early middleware can set up context for later middleware
- Early middleware sees the final processed result

### Why HumanInTheLoop Must Be Last

During `handle_resume`, HITL executes all tool calls from the interrupted assistant message -- including auto-approved tools from other middleware. If an auto-approved tool produces its own interrupt (e.g., `ask_user`), HITL detects it and returns `{:cont}` with the new interrupt_data on state. The resume cycle then re-scans the middleware stack so the owning middleware can claim it.

`HumanInTheLoop.maybe_append/2` enforces this by always appending to the end of the middleware list. All interrupt-producing middleware (like AskUserQuestion or custom interrupt middleware) should be positioned before HITL in the stack.

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

## System Prompt: Static vs Dynamic Content

The `system_prompt(config)` callback is called **once during `Agent.new`**, not on every execution. The result is cached in `agent.assembled_system_prompt` and reused for every LLM call. This is important for prompt caching—a stable system prompt means the LLM provider can cache and reuse it across requests.

### What `config` Contains

The `config` map is whatever your `init/1` returned. Since `system_prompt/1` receives this config, you can interpolate **session-scoped values** that were set at agent creation time:

```elixir
defmodule MyApp.Middleware.InjectCurrentDate do
  @behaviour Sagents.Middleware

  @impl true
  def init(opts) do
    timezone = Keyword.get(opts, :timezone, "UTC")
    {:ok, %{timezone: timezone}}
  end

  @impl true
  def system_prompt(config) do
    # Compute the date once at agent creation time
    date =
      DateTime.utc_now()
      |> DateTime.shift_zone!(config.timezone)
      |> Calendar.strftime("%a, %Y-%m-%d %Z")

    "Today's date is #{date}. The user's timezone is #{config.timezone}."
  end
end
```

This works well for data that is stable for the agent's lifetime: timezone, feature flags, configuration values, etc.

### User Context via `before_model` (Recommended)

User-controlled content (names, preferences, etc.) should be injected into **user messages**, not the system prompt. Putting user-controlled strings in the system prompt creates a prompt injection vector — a user could set their name to something like `"Ignore all previous instructions..."` and hijack the agent's behavior.

Instead, use `before_model/2` to prepend user context to the first user message:

```elixir
defmodule MyApp.Middleware.UserContext do
  @behaviour Sagents.Middleware

  alias LangChain.Message.ContentPart

  @impl true
  def init(opts) do
    scope = Keyword.get(opts, :scope)
    first_name = get_in(scope, [Access.key(:user), Access.key(:first_name)])
    {:ok, %{first_name: first_name}}
  end

  @impl true
  def before_model(state, config) do
    if config.first_name do
      {:ok, maybe_prepend_user_context(state, config.first_name)}
    else
      {:ok, state}
    end
  end

  # Only prepend to the first user message, and only when it's the last
  # message (just added). On subsequent turns the first user message is
  # no longer last, so it won't be modified again — preserving prompt caching.
  defp maybe_prepend_user_context(state, first_name) do
    last = List.last(state.messages)

    if last && last.role == :user && !has_prior_user_message?(state.messages) do
      context = "<user_information>The user's first name is #{first_name}.</user_information>\n\n"
      updated = %{last | content: prepend_context(last.content, context)}
      %{state | messages: List.replace_at(state.messages, -1, updated)}
    else
      state
    end
  end

  # Message content can be a string or a list of ContentPart structs.
  # For lists, insert a new text part rather than mutating an existing one.
  defp prepend_context(content, text) when is_binary(content), do: text <> content
  defp prepend_context(parts, text) when is_list(parts),
    do: [ContentPart.text!(text) | parts]
  defp prepend_context(nil, text), do: text

  defp has_prior_user_message?(messages) do
    messages |> Enum.drop(-1) |> Enum.any?(&(&1.role == :user))
  end
end

# In your Factory:
{MyApp.Middleware.UserContext, [scope: current_scope]}
```

This approach keeps user-controlled content in a clearly delimited XML tag within the user message, where the model can distinguish it from instructions.

### Per-Request Dynamic Content

For truly per-request data (data that changes on every LLM call), use `before_model/2` to modify the most recent user message. Note that modifying older user messages breaks prompt caching for those messages, so only modify the latest message when possible.

```elixir
@impl true
def before_model(state, config) do
  # Prepend dynamic data to the last user message
  updated_messages =
    List.update_at(state.messages, -1, fn msg ->
      price = fetch_price()
      %{msg | content: "<stock_price>$#{price}</stock_price>\n\n" <> msg.content}
    end)

  {:ok, %{state | messages: updated_messages}}
end
```

## Tool Function Context

When a tool function executes, it receives two arguments: the parsed arguments from the LLM and a `context` map.

### What's in `context`

```elixir
function: fn args, context ->
  # context.state             - Current Sagents.State (messages, todos, metadata)
  # context.parent_middleware - Parent agent's middleware entries (used by SubAgent)
  # context.parent_tools      - Parent agent's tools (used by SubAgent)
end
```

The `state` key is the most commonly used—it gives tools access to the full agent state including metadata.

### Accessing Middleware Config in Tools

Middleware config is **not** included in the tool context. Instead, middleware captures its own config via closure when defining tools in `tools/1`:

```elixir
@impl true
def tools(config) do
  [
    Function.new!(%{
      name: "my_tool",
      description: "Does something",
      parameters_schema: %{type: "object", properties: %{}},
      # config is captured via closure—available inside the function
      function: fn args, context -> execute(args, context, config) end
    })
  ]
end

defp execute(_args, context, config) do
  # config.api_key is from this middleware's init
  # context.state is the current agent state
  {:ok, "result"}
end
```

This means one middleware's tools **cannot** directly access another middleware's config. See the next section for how to share data across middleware boundaries.

## Cross-Middleware Data Sharing via State Metadata

To share data between middleware, use `State.put_metadata/3` to publish and `State.get_metadata/3` to read.

### Publishing Stable Data via `on_server_start`

For data that is known at init time (timezone, user info, feature flags), publish it in `on_server_start` so it's available from the very first execution, regardless of middleware ordering:

```elixir
defmodule MyApp.Middleware.InjectCurrentDate do
  @behaviour Sagents.Middleware
  alias Sagents.State

  @impl true
  def init(opts) do
    {:ok, %{timezone: Keyword.get(opts, :timezone, "UTC")}}
  end

  @impl true
  def on_server_start(state, config) do
    # Store timezone in metadata at startup, before any execution happens.
    # This ensures all middleware tools can read it from the first request.
    {:ok, State.put_metadata(state, "timezone", config.timezone)}
  end
end
```

### Reading Shared Data in Tools

Any middleware's tools can read shared metadata via the state in context:

```elixir
defmodule MyApp.Middleware.Scheduler do
  @behaviour Sagents.Middleware
  alias Sagents.State

  @impl true
  def tools(_config) do
    [
      Function.new!(%{
        name: "schedule_event",
        description: "Schedule an event",
        parameters_schema: %{
          type: "object",
          properties: %{time: %{type: "string"}},
          required: ["time"]
        },
        function: fn args, context ->
          # Read timezone published by InjectCurrentDate middleware
          timezone = State.get_metadata(context.state, "timezone") || "UTC"
          schedule_in_timezone(args["time"], timezone)
        end
      })
    ]
  end
end
```

### Middleware Ordering and `before_model`

If you publish metadata in `before_model` instead of `on_server_start`, be aware that middleware ordering affects visibility. `before_model` hooks run in list order, so a middleware can only see metadata set by middleware listed **before** it:

```elixir
middleware: [
  InjectCurrentDate,  # before_model sets "timezone" in metadata
  Scheduler,          # before_model CAN read "timezone" (runs second)
]

# But if reversed:
middleware: [
  Scheduler,          # before_model CANNOT read "timezone" yet (runs first)
  InjectCurrentDate,  # before_model sets "timezone" (runs second)
]
```

Tool functions are not affected by this — they execute later during the LLM response, after all `before_model` hooks have run. So a tool defined by Scheduler can always read `"timezone"` regardless of middleware order. The ordering concern only applies to `before_model` hooks reading metadata set by other `before_model` hooks.

For stable config data, prefer `on_server_start` to avoid ordering issues entirely.

### String Keys Required

Metadata is persisted to the database as PostgreSQL JSONB. The `StateSerializer` converts all keys to strings on write, and after a database round-trip keys come back as strings. This means **you must use string keys** for metadata—atom keys will silently break after a restore because `get_metadata(state, :timezone)` won't match `"timezone"`.

```elixir
# Correct - survives database round-trip
State.put_metadata(state, "timezone", "America/Denver")
State.get_metadata(state, "timezone")

# Broken after restore - atom key won't match string key from DB
State.put_metadata(state, :timezone, "America/Denver")
State.get_metadata(state, :timezone)  # => nil after DB restore
```
