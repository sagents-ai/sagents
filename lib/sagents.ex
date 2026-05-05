defmodule Sagents do
  @moduledoc """
  Sagents provides hierarchical agent capabilities with composable middleware.

  Sagents extends LangChain with powerful features:

  - **Middleware System**: Composable components for agent capabilities
  - **TODO Management**: Task planning and progress tracking
  - **Virtual Filesystem**: File operations for agent workflows
  - **Task Delegation**: Hierarchical sub-agents for complex tasks
  - **Context Management**: Automatic summarization and optimization
  - **Observability**: Custom telemetry and tracing via middleware callbacks (see [Observability Guide](docs/observability.md))

  ## Quick Start

      alias Sagents.{Agent, State}
      alias LangChain.ChatModels.ChatAnthropic

      # Create an agent
      {:ok, agent} = Agent.new(%{
        model: ChatAnthropic.new!(%{model: "claude-sonnet-4-6"}),
        system_prompt: "You are a helpful assistant."
      })

      # Execute with a State
      state = State.new!(%{messages: [%{role: "user", content: "Hello!"}]})
      {:ok, result} = Agent.execute(agent, state)

  ## Middleware Composition

  Sagents uses a middleware pattern for extensibility:

      # Use default middleware (TODO, Filesystem, SubAgent, etc.)
      {:ok, agent} = Agent.new(%{
        model: model,
        middleware: [MyCustomMiddleware]
      })

      # Customize default middleware
      {:ok, agent} = Agent.new(%{
        model: model,
        filesystem_opts: [long_term_memory: true]
      })

      # Provide complete middleware stack
      {:ok, agent} = Agent.new(%{
        model: model,
        replace_default_middleware: true,
        middleware: [MyMiddleware1, MyMiddleware2]
      })

  ## Creating Custom Middleware

      defmodule MyMiddleware do
        @behaviour Sagents.Middleware

        @impl true
        def init(opts) do
          {:ok, %{enabled: Keyword.get(opts, :enabled, true)}}
        end

        @impl true
        def system_prompt(_config) do
          "Custom instructions for the agent."
        end

        @impl true
        def tools(_config) do
          [my_custom_tool()]
        end

        @impl true
        def before_model(state, _config) do
          # Preprocess state before LLM
          {:ok, state}
        end

        @impl true
        def after_model(state, _config) do
          # Postprocess after LLM response
          {:ok, state}
        end
      end

  ## State Management

  Agent state flows through middleware and execution:

      state = Sagents.State.new!(%{
        messages: [%{role: "user", content: "Hello"}],
        files: %{"/notes.txt" => "content"},
        metadata: %{session_id: "123"}
      })

      {:ok, result_state} = Sagents.Agent.execute(agent, state)

  See `Sagents.Agent` for agent creation and execution, and `Sagents.State` for
  state management functions.
  """
end
