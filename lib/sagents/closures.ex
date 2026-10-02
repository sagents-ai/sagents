defmodule Sagents.Closures do
  @moduledoc """
  Finds anonymous functions that the local node cannot call.

  An anonymous function is a reference to a compiled module, not a copy of its
  code. It carries the MD5 of the module version that created it, and it can
  only be called on a node that has that exact version loaded. A function built
  on one node and sent to a node running a different build of the module raises
  `BadFunctionError` when called.

  An agent's configuration carries such functions (tool functions, callbacks,
  middleware config), and under the `:horde` distribution it crosses nodes: a
  start may be placed on another member, and a departed node's agents are
  restarted on a survivor from the arguments of the original start. During a
  rolling deploy those nodes run different builds.

  Captures of named functions (`&Mod.fun/2`) are resolved by name when called,
  so they are callable on any node that has the module and are never reported.
  """

  @doc """
  Returns the modules whose anonymous functions inside `term` cannot be called
  on this node, or `[]` when every function in `term` is callable.

  Walks lists, tuples, maps, structs, and the values each function closes over.

  ## Examples

      iex> Sagents.Closures.stale_modules(%{tools: [&String.upcase/1], name: "agent"})
      []
  """
  @spec stale_modules(term()) :: [module()]
  def stale_modules(term) do
    term
    |> collect(MapSet.new())
    |> Enum.sort()
  end

  defp collect(fun, acc) when is_function(fun) do
    case :erlang.fun_info(fun, :type) do
      {:type, :external} ->
        acc

      {:type, :local} ->
        {:module, module} = :erlang.fun_info(fun, :module)
        {:new_uniq, uniq} = :erlang.fun_info(fun, :new_uniq)
        {:env, env} = :erlang.fun_info(fun, :env)

        acc = if current?(module, uniq), do: acc, else: MapSet.put(acc, module)
        collect(env, acc)
    end
  end

  defp collect([head | tail], acc), do: collect(tail, collect(head, acc))

  defp collect(tuple, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> collect(acc)
  end

  defp collect(map, acc) when is_map(map) do
    :maps.fold(fn key, value, acc -> collect(value, collect(key, acc)) end, acc, map)
  end

  defp collect(_other, acc), do: acc

  defp current?(module, uniq) do
    Code.ensure_loaded?(module) and module.module_info(:md5) == uniq
  end
end
