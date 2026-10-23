defmodule Sagents.Middleware.ToolSearch do
  @moduledoc """
  Turns on provider tool search for an agent.

  With this middleware in the stack, a middleware that declares a tool search
  namespace (`c:Sagents.Middleware.tool_search/1`) has its tools declared on
  every request but kept out of the model's context. The model loads them with
  the provider's search tool, which this middleware adds. The tool list and the
  system prompt stay the same for the life of a conversation, so the prompt
  cache and replayed reasoning survive a load.

      Agent.new(%{
        model: model,
        middleware: [
          {Sagents.Middleware.ToolSearch,
           namespaces: %{
             ThirdParty.Middleware.Billing => [
               namespace: "billing",
               description: "Invoices and balances."
             ]
           }},
          MyApp.Middleware.Devices,
          ThirdParty.Middleware.Billing
        ]
      })

  Each namespace's tools are grouped as one OpenAI `namespace` and are found by
  one search. On Anthropic, the namespace has no provider form and the tools
  are deferred individually. A chat model without tool search leaves the
  search tool out and sends every tool normally, so the same agent runs on any
  chat model. See `LangChain.NativeTool` for the chat models that search.

  Deferral hides tool definitions; it does not unmount a middleware. A
  namespaced middleware's model hooks, callbacks, state and messages all work
  as they do without tool search.

  Tool search is independent of `Sagents.Middleware.AbilitySetSwitcher`. A
  middleware in an ability set may also declare a namespace, and its tools are
  then deferred whenever its set is active. This middleware itself must be a
  rail (outside every set), so the search tool goes out with every set.

  ## Options

  - `:variant` - `:bm25` (default) or `:regex`, how the model writes its
    search on providers that offer a choice (see
    `LangChain.NativeTool.tool_search/1`).
  - `:namespaces` - Map of middleware entry id to a namespace declaration,
    which overrides or supplies the middleware's own `tool_search/1`. A
    declaration takes the keys `tool_search/1` returns. Keys it leaves out are
    taken from the middleware's own declaration. `false` keeps an entry's
    tools visible even though its middleware declares a namespace. An override
    for a middleware without `tool_search/1` keeps that middleware's system
    prompt fragment unless it sets `system_prompt: :omit`, since its author
    did not write the fragment for deferred tools. Default: `%{}`.

  An option the middleware does not know is an error, so a misspelled key
  fails `Sagents.Agent.new/2` instead of being ignored.

  ## Validation

  `Sagents.Agent.new/2` fails when a namespace has no description, when its
  name does not match `^[a-z][a-z0-9_]{0,63}$`, when two declarations give one
  namespace different descriptions, or when a `:namespaces` key names no entry
  in the stack. A namespace holding ten or more functions logs a warning:
  OpenAI recommends fewer than ten.
  """

  @behaviour Sagents.Middleware

  alias LangChain.NativeTool

  @variants [:bm25, :regex]
  @option_keys [:id, :variant, :namespaces] ++ Sagents.Agent.injected_context_keys()

  @impl true
  def init(opts) do
    with :ok <- validate_option_keys(opts),
         {:ok, variant} <- validate_variant(Keyword.get(opts, :variant, :bm25)),
         {:ok, namespaces} <- validate_namespaces(Keyword.get(opts, :namespaces, %{})) do
      config = %{variant: variant, namespaces: namespaces}

      config =
        case Keyword.fetch(opts, :id) do
          {:ok, id} -> Map.put(config, :id, id)
          :error -> config
        end

      {:ok, config}
    end
  end

  @impl true
  def tools(config), do: [NativeTool.tool_search(variant: config.variant)]

  defp validate_option_keys(opts) do
    case Keyword.keys(opts) -- @option_keys do
      [] ->
        :ok

      unknown ->
        {:error,
         "unknown option(s) #{inspect(unknown)}; expected #{inspect([:variant, :namespaces])}"}
    end
  end

  defp validate_variant(variant) when variant in @variants, do: {:ok, variant}

  defp validate_variant(other),
    do: {:error, ":variant must be one of #{inspect(@variants)}, got: #{inspect(other)}"}

  defp validate_namespaces(namespaces) when is_map(namespaces) do
    Enum.reduce_while(namespaces, {:ok, %{}}, fn
      {id, false}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, id, false)}}

      {id, declaration}, {:ok, acc} when is_list(declaration) ->
        if Keyword.keyword?(declaration),
          do: {:cont, {:ok, Map.put(acc, id, declaration)}},
          else: {:halt, invalid_namespace(id, declaration)}

      {id, declaration}, _acc ->
        {:halt, invalid_namespace(id, declaration)}
    end)
  end

  defp validate_namespaces(other),
    do: {:error, ":namespaces must be a map of entry id to keyword list, got: #{inspect(other)}"}

  defp invalid_namespace(id, declaration) do
    {:error,
     ":namespaces entry for #{inspect(id)} must be a keyword list or false, " <>
       "got: #{inspect(declaration)}"}
  end
end
