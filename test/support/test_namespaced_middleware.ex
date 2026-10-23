defmodule Sagents.TestNamespacedMiddleware do
  @moduledoc """
  A configurable middleware for tool search tests. Each instance takes its own
  `:id`, so one module stands in for any number of domain middleware.

  ## Options

  - `:id` - the entry id (default: the module)
  - `:tools` - names of the tools it provides (default: `[]`)
  - `:tool_options` - map of tool name to the `LangChain.Function` options that
    tool sets itself (default: `%{}`)
  - `:tool_search` - what `tool_search/1` returns (default: `nil`)
  - `:prompt` - its system prompt fragment (default: `""`)
  """

  @behaviour Sagents.Middleware

  alias LangChain.Function

  @impl true
  def init(opts) do
    config = %{
      tools: Keyword.get(opts, :tools, []),
      tool_options: Keyword.get(opts, :tool_options, %{}),
      tool_search: Keyword.get(opts, :tool_search),
      prompt: Keyword.get(opts, :prompt, "")
    }

    case Keyword.fetch(opts, :id) do
      {:ok, id} -> {:ok, Map.put(config, :id, id)}
      :error -> {:ok, config}
    end
  end

  @impl true
  def system_prompt(config), do: config.prompt

  @impl true
  def tools(config) do
    Enum.map(config.tools, fn name ->
      Function.new!(%{
        name: name,
        description: "Test tool #{name}",
        parameters_schema: %{type: "object", properties: %{}},
        options: Map.get(config.tool_options, name, []),
        function: fn _args, _context -> {:ok, "#{name} result"} end
      })
    end)
  end

  @impl true
  def tool_search(config), do: config.tool_search
end
