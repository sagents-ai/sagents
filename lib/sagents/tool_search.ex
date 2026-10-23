defmodule Sagents.ToolSearch do
  @moduledoc """
  Pure functions behind `Sagents.Middleware.ToolSearch`: resolving which
  middleware entries are tool search namespaces, stamping their tools, and
  indexing the namespaces an agent declares.

  `Sagents.Agent.new/2` resolves every entry once and stores the result on
  `Sagents.MiddlewareEntry.tool_search`. `Sagents.Middleware.get_tools/1` then
  stamps that entry's functions wherever its tools are collected: the agent's
  own tool list and each ability set's. The stamp is fixed at construction, so
  the tools sent are identical on every request.

  An agent without `Sagents.Middleware.ToolSearch` takes a fast path through
  every function here: nothing is resolved, stamped or indexed.
  """

  require Logger

  alias LangChain.Function
  alias Sagents.Middleware
  alias Sagents.Middleware.ToolSearch, as: Switch
  alias Sagents.MiddlewareEntry

  @namespace_pattern ~r/^[a-z][a-z0-9_]{0,63}$/
  @declaration_keys [:namespace, :description]
  @recommended_max_functions 10

  @typedoc """
  One namespace in an agent's index: its description, the names of the tools
  in it, in stack order, and the ids of the entries that contribute them (`nil`
  for a base tool that set its own namespace).
  """
  @type namespace_info :: %{
          description: String.t(),
          tools: [String.t()],
          entry_ids: [term()]
        }

  @typedoc "Namespace name to its `t:namespace_info/0`."
  @type index :: %{String.t() => namespace_info()}

  @doc """
  Stamp `tools` with an entry's tool search namespace.

  Each `LangChain.Function` gets `defer_loading: true`, `namespace:` and
  `namespace_description:` in its options. Options the function already sets
  win. Other tools, and every tool when `tool_search` is `nil`, are returned
  unchanged.
  """
  @spec stamp([term()], map() | nil) :: [term()]
  def stamp(tools, nil), do: tools

  def stamp(tools, %{namespace: namespace, description: description}) do
    stamp_options = [
      defer_loading: true,
      namespace: namespace,
      namespace_description: description
    ]

    Enum.map(tools, fn
      %Function{} = function ->
        %Function{function | options: Keyword.merge(stamp_options, function.options || [])}

      other ->
        other
    end)
  end

  @doc """
  True when `entries` hold a `Sagents.Middleware.ToolSearch` entry.
  """
  @spec enabled?([MiddlewareEntry.t()]) :: boolean()
  def enabled?(entries), do: Enum.any?(entries, &switch?/1)

  @doc """
  True when `entry` is the `Sagents.Middleware.ToolSearch` entry.
  """
  @spec switch?(term()) :: boolean()
  def switch?(%MiddlewareEntry{module: Switch}), do: true
  def switch?(_entry), do: false

  @doc """
  The `Sagents.Middleware.ToolSearch` entry's system prompt fragment for a
  chain that sends `tools`: the catalog (see `catalog_prompt/1`), or `""` when
  the switch is configured with `catalog: false`.

  The fragment is rendered where prompts are assembled, from the tools each
  prompt goes out with, so an ability set's prompt lists only its own
  namespaces.
  """
  @spec switch_prompt(MiddlewareEntry.t(), [term()]) :: String.t()
  def switch_prompt(%MiddlewareEntry{config: %{catalog: false}}, _tools), do: ""
  def switch_prompt(%MiddlewareEntry{}, tools), do: catalog_prompt(tools)

  @doc """
  The catalog of tool search namespaces among `tools`, for the system prompt.

  Lists each namespace with at least one deferred function in `tools`, with
  its description, in the order the namespaces first appear. A namespace
  whose functions are all visible is not listed. Returns `""` when nothing is
  deferred into a namespace.

  Anthropic's models see nothing about a deferred tool until they search, so
  the catalog is how they learn what is worth searching for. OpenAI shows a
  namespace's name and description itself; there the catalog repeats it.
  """
  @spec catalog_prompt([term()]) :: String.t()
  def catalog_prompt(tools) do
    namespaced = Enum.filter(tools, &(match?(%Function{}, &1) and Function.namespace(&1)))
    groups = Enum.group_by(namespaced, &Function.namespace/1)

    listed =
      namespaced
      |> Enum.map(&Function.namespace/1)
      |> Enum.uniq()
      |> Enum.filter(fn name -> Enum.any?(groups[name], &Function.deferred?/1) end)

    case listed do
      [] ->
        ""

      names ->
        lines =
          Enum.map_join(names, "\n", fn name ->
            "- #{name}: #{Enum.find_value(groups[name], &Function.namespace_description/1)}"
          end)

        "Some tools load on demand. Search for tools when you need one of these:\n" <> lines
    end
  end

  @doc """
  Resolve each entry's tool search namespace and store it on the entry.

  An entry's declaration is its `:namespaces` override in the
  `Sagents.Middleware.ToolSearch` config, merged over its middleware's
  `tool_search/1`. Returns the entries unchanged when the stack holds no
  `Sagents.Middleware.ToolSearch`.
  """
  @spec resolve([MiddlewareEntry.t()]) :: {:ok, [MiddlewareEntry.t()]} | {:error, String.t()}
  def resolve(entries) do
    case Enum.find(entries, &switch?/1) do
      nil -> {:ok, entries}
      switch -> resolve_with(entries, switch)
    end
  end

  defp resolve_with(entries, %MiddlewareEntry{config: config} = switch) do
    overrides = config.namespaces
    ids = MapSet.new(entries, & &1.id)

    with :ok <- validate_switch_is_rail(switch),
         :ok <- validate_override_ids(overrides, ids) do
      Enum.reduce_while(entries, {:ok, []}, fn %MiddlewareEntry{} = entry, {:ok, acc} ->
        case resolve_entry(entry, overrides) do
          {:ok, tool_search} ->
            {:cont, {:ok, [%MiddlewareEntry{entry | tool_search: tool_search} | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
        error -> error
      end
    end
  end

  # The search tool must reach every chain the agent builds. An ability set
  # sends only the rails plus its own entries, so a switch inside a set would
  # leave the other sets sending deferred tools with no search tool, which the
  # provider rejects.
  defp validate_switch_is_rail(%MiddlewareEntry{ability_sets: nil}), do: :ok

  defp validate_switch_is_rail(%MiddlewareEntry{}),
    do: {:error, "Sagents.Middleware.ToolSearch must not be in an ability set"}

  defp validate_override_ids(overrides, ids) do
    case Enum.reject(Map.keys(overrides), &MapSet.member?(ids, &1)) do
      [] ->
        :ok

      unknown ->
        {:error,
         "tool search :namespaces names no middleware entry: #{inspect(unknown)}. " <>
           "Entry ids: #{inspect(MapSet.to_list(ids))}"}
    end
  end

  defp resolve_entry(entry, overrides) do
    if switch?(entry) do
      {:ok, nil}
    else
      entry
      |> declaration(Map.get(overrides, entry.id))
      |> validate_declaration(entry.id)
    end
  end

  # An override's keys replace the middleware's own; `false` keeps the entry's
  # tools visible.
  defp declaration(_entry, false), do: nil

  defp declaration(entry, override) do
    case {Middleware.get_tool_search(entry), override} do
      {own, nil} -> own
      {nil, override} -> override
      {own, _override} when not is_list(own) -> own
      {own, override} -> Keyword.merge(own, override)
    end
  end

  defp validate_declaration(nil, _id), do: {:ok, nil}

  defp validate_declaration(declaration, id) when is_list(declaration) do
    namespace = Keyword.get(declaration, :namespace)
    description = Keyword.get(declaration, :description)

    cond do
      not Keyword.keyword?(declaration) ->
        {:error, "tool search declaration for #{inspect(id)} must be a keyword list"}

      (unknown = Keyword.keys(declaration) -- @declaration_keys) != [] ->
        {:error,
         "tool search declaration for #{inspect(id)} has unknown key(s) #{inspect(unknown)}; " <>
           "expected #{inspect(@declaration_keys)}"}

      not (is_binary(namespace) and Regex.match?(@namespace_pattern, namespace)) ->
        {:error,
         "tool search namespace for #{inspect(id)} must match " <>
           "#{inspect(Regex.source(@namespace_pattern))}, got: #{inspect(namespace)}"}

      not (is_binary(description) and String.trim(description) != "") ->
        {:error, "tool search namespace #{inspect(namespace)} needs a :description"}

      true ->
        {:ok, %{namespace: namespace, description: description}}
    end
  end

  defp validate_declaration(other, id),
    do:
      {:error,
       "tool search declaration for #{inspect(id)} must be a keyword list, got: #{inspect(other)}"}

  @doc """
  Index the namespaces of an agent's tools, and validate them.

  Reads every function's own `:namespace` option, so a namespace a middleware
  or base tool set itself is indexed beside the declared ones. Returns
  `{:ok, nil}` when the stack holds no `Sagents.Middleware.ToolSearch`.

  Fails when a namespace has no description, or when its functions give it
  different descriptions. Logs a warning for a namespace with
  #{@recommended_max_functions} or more functions, and a debug message when
  the switch is present but nothing is deferred.
  """
  @spec build_index([MiddlewareEntry.t()], [term()]) ::
          {:ok, index() | nil} | {:error, String.t()}
  def build_index(entries, base_tools) do
    if enabled?(entries) do
      contributions =
        Enum.map(base_tools, &{nil, &1}) ++
          for entry <- entries, tool <- Middleware.get_tools(entry), do: {entry.id, tool}

      functions = for {id, %Function{} = function} <- contributions, do: {id, function}

      with {:ok, index} <- index_namespaces(functions) do
        log_index(index, functions)
        {:ok, index}
      end
    else
      {:ok, nil}
    end
  end

  defp index_namespaces(functions) do
    functions
    |> Enum.filter(fn {_id, function} -> Function.namespace(function) end)
    |> Enum.group_by(fn {_id, function} -> Function.namespace(function) end)
    |> Enum.reduce_while({:ok, %{}}, fn {namespace, members}, {:ok, acc} ->
      case namespace_description(namespace, members) do
        {:ok, description} ->
          info = %{
            description: description,
            tools: Enum.map(members, fn {_id, function} -> function.name end),
            entry_ids: members |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
          }

          {:cont, {:ok, Map.put(acc, namespace, info)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp namespace_description(namespace, members) do
    descriptions =
      members
      |> Enum.map(fn {_id, function} -> Function.namespace_description(function) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case descriptions do
      [description] ->
        {:ok, description}

      [] ->
        {:error, "tool search namespace #{inspect(namespace)} has no description"}

      several ->
        {:error,
         "tool search namespace #{inspect(namespace)} has different descriptions: " <>
           inspect(several)}
    end
  end

  defp log_index(index, functions) do
    for {namespace, %{tools: tools}} <- index,
        length(tools) >= @recommended_max_functions do
      Logger.warning(
        "Tool search namespace #{inspect(namespace)} holds #{length(tools)} functions. " <>
          "OpenAI recommends fewer than #{@recommended_max_functions} per namespace."
      )
    end

    unless Enum.any?(functions, fn {_id, function} -> Function.deferred?(function) end) do
      Logger.debug("Sagents.Middleware.ToolSearch is in the stack, but no tool is deferred")
    end

    :ok
  end
end
