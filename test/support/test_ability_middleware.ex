defmodule Sagents.TestAbilityMiddleware do
  @moduledoc """
  A configurable middleware for ability set tests. Each instance takes its own
  `:id`, so one module stands in for any number of domain middleware.

  ## Options

  - `:id` - the entry id (required)
  - `:agent_id` - kept in the config, so a test can see the agent context
    `Sagents.Agent.new/2` injected
  - `:tools` - names of the tools it provides (default: `[]`)
  - `:prompt` - its system prompt fragment (default: `""`)
  - `:test_pid` - receives `{:before_model, id}`, `{:after_model, id}` and
    `{:tool_ran, name, context}` messages
  - `:interrupting_tools` - tool names that return an interrupt instead of a
    result
  """

  @behaviour Sagents.Middleware

  alias LangChain.Function

  @impl true
  def init(opts) do
    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       agent_id: Keyword.get(opts, :agent_id),
       tools: Keyword.get(opts, :tools, []),
       prompt: Keyword.get(opts, :prompt, ""),
       test_pid: Keyword.get(opts, :test_pid),
       interrupting_tools: Keyword.get(opts, :interrupting_tools, [])
     }}
  end

  @impl true
  def system_prompt(config), do: config.prompt

  @impl true
  def tools(config), do: Enum.map(config.tools, &tool(config, &1))

  @impl true
  def before_model(state, config) do
    notify(config, {:before_model, config.id})
    {:ok, state}
  end

  @impl true
  def after_model(state, config) do
    notify(config, {:after_model, config.id})
    {:ok, state}
  end

  defp tool(config, name) do
    Function.new!(%{
      name: name,
      description: "Test tool #{name}",
      parameters_schema: %{type: "object", properties: %{}},
      function: fn _args, context ->
        notify(config, {:tool_ran, name, context})

        if name in config.interrupting_tools,
          do: {:interrupt, "Waiting on #{name}", %{type: :test_interrupt, tool: name}},
          else: {:ok, "#{name} result"}
      end
    })
  end

  defp notify(%{test_pid: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_config, _message), do: :ok
end
