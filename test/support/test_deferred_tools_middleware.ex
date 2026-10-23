defmodule Sagents.TestDeferredToolsMiddleware do
  @moduledoc """
  A middleware whose tools are deferred for tool search and grouped under one
  namespace, the way an app opts a domain into tool search today.

  ## Options

  - `:namespace` - the namespace name (required)
  - `:description` - the namespace description (required)
  - `:tools` - names of the tools it provides (default: `[]`)
  - `:test_pid` - receives `{:tool_ran, name}` when a tool runs
  """

  @behaviour Sagents.Middleware

  alias LangChain.Function

  @impl true
  def init(opts) do
    {:ok,
     %{
       namespace: Keyword.fetch!(opts, :namespace),
       description: Keyword.fetch!(opts, :description),
       tools: Keyword.get(opts, :tools, []),
       test_pid: Keyword.get(opts, :test_pid)
     }}
  end

  @impl true
  def tools(config), do: Enum.map(config.tools, &tool(config, &1))

  defp tool(config, name) do
    Function.new!(%{
      name: name,
      description: "Test tool #{name}",
      parameters_schema: %{type: "object", properties: %{}},
      options: [
        defer_loading: true,
        namespace: config.namespace,
        namespace_description: config.description
      ],
      function: fn _args, _context ->
        if is_pid(config.test_pid), do: send(config.test_pid, {:tool_ran, name})
        {:ok, "#{name} result"}
      end
    })
  end
end
