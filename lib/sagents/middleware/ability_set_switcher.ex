defmodule Sagents.Middleware.AbilitySetSwitcher do
  @moduledoc """
  Lets an agent work in one of several modes, each a named set of middleware.

  An **ability set** is a curated set of middleware with a short "when to use".
  Only the rails (every middleware outside a set) plus the active set's
  middleware contribute their system prompt fragments, their tools and their
  model hooks to an LLM call. The model moves between sets with a `switch_mode`
  tool, and the new set's tools are sent on the next LLM call of the same run.

  Switching needs nothing from the provider beyond ordinary function calling, so
  it shrinks the tool list on every chat model, including OpenAI-compatible
  services that have no tool search.

  The model and the end user see the word "mode". Developer-facing and
  persisted names say "ability set".

  ## Declaring sets

      Agent.new(
        %{
          model: model,
          middleware: [
            MyApp.Middleware.UserContext,
            {Sagents.Middleware.AbilitySetSwitcher,
             sets: %{
               "devices" => %{
                 name: "Devices",
                 when_to_use: "Device inventory, packages, and deployments to devices.",
                 middleware: [MyApp.Middleware.Devices, MyApp.Middleware.Deployments]
               },
               "billing" => %{
                 name: "Billing",
                 when_to_use: "Invoices, balances, and payment status.",
                 middleware: [MyApp.Middleware.Billing]
               }
             },
             default: nil}
          ]
        },
        interrupt_on: %{"deploy_package" => true, "issue_refund" => true}
      )

  `Sagents.Agent.new/2` initializes every set's middleware once, at the
  switcher's position in the stack, and tags each entry with the sets it
  belongs to (`Sagents.MiddlewareEntry.ability_sets`). A middleware listed in
  two sets is initialized once. `interrupt_on` may name tools from any set.

  ## Options

  - `:sets` - Map of set name to set definition (required). A name matches
    `^[a-z][a-z0-9_]{0,63}$`. A definition holds:
    - `:when_to_use` - One line telling the model when the set applies (required)
    - `:name` - Display name, used in tool results and hints (default: the
      capitalized set name)
    - `:middleware` - The set's middleware specs (default: `[]`)
  - `:default` - The set active when the state names none. `nil` (the default)
    means rails only.
  - `:max_switches_per_run` - Switches the model may make within one
    `Sagents.Agent.execute/3` call (default: `1`).
  - `:state_key` - The `State.metadata` key holding the active set (default:
    `"active_ability_set"`).
  - `:tool_name` - Name of the switching tool (default: `"switch_mode"`).

  ## The active set

  The active set is `state.metadata["active_ability_set"]`, so it persists and
  restores with the conversation. A value naming no declared set (a set
  removed or renamed by a deploy) falls back to `:default` with a warning. See
  `Sagents.AbilitySets.active/2`.

  ## Callbacks of inactive middleware

  An entry outside the active set contributes no prompt fragment and no tools,
  and its `before_model/2` and `after_model/2` do not run. Everything else
  about it is unchanged: `init/1` and `on_server_start/2` run for every entry,
  `handle_message/3`, `handle_resume/5` and `transform_display_message/2` still
  reach it, its `state_schema/0` still applies, and its LangChain callbacks
  stay registered. A callback that fires while its set is inactive must not
  assume its tools are visible to the model.

  Within one `execute`, the entries active at the start run `before_model/2`.
  At a switch, the entries the new set adds run it before the next LLM call. An
  entry never runs it twice in one `execute`. At the end, the entries of the
  set active then run `after_model/2`. An entry active only between two
  switches runs `before_model/2` but not `after_model/2` for that call.
  """

  @behaviour Sagents.Middleware

  alias LangChain.Function
  alias Sagents.State

  @set_name_pattern ~r/^[a-z][a-z0-9_]{0,63}$/

  @default_state_key "active_ability_set"
  @default_tool_name "switch_mode"

  @impl true
  def init(opts) do
    with {:ok, sets} <- validate_sets(Keyword.get(opts, :sets)),
         {:ok, default} <- validate_default(Keyword.get(opts, :default), sets),
         {:ok, max_switches} <-
           validate_max_switches(Keyword.get(opts, :max_switches_per_run, 1)),
         {:ok, state_key} <-
           validate_string(:state_key, Keyword.get(opts, :state_key, @default_state_key)),
         {:ok, tool_name} <-
           validate_string(:tool_name, Keyword.get(opts, :tool_name, @default_tool_name)) do
      config = %{
        sets: sets,
        default: default,
        max_switches_per_run: max_switches,
        state_key: state_key,
        tool_name: tool_name
      }

      config =
        case Keyword.fetch(opts, :id) do
          {:ok, id} -> Map.put(config, :id, id)
          :error -> config
        end

      {:ok, config}
    end
  end

  @impl true
  def system_prompt(config), do: catalog_prompt(config, config.default)

  @impl true
  def tools(config), do: [switch_tool(config)]

  @doc """
  The switcher's prompt fragment for the given active set (`nil` for rails
  only).

  The fragment lists every set with its "when to use" and names the current
  mode. It is rebuilt with the rest of the system prompt whenever the active set
  changes.
  """
  @spec catalog_prompt(map(), String.t() | nil) :: String.t()
  def catalog_prompt(config, active) do
    catalog =
      config
      |> set_names()
      |> Enum.map_join("\n", fn name -> "- #{name}: #{config.sets[name].when_to_use}" end)

    current =
      case active do
        nil -> "Current mode: none. No mode is active, so only the general tools are available."
        name -> "Current mode: #{name}."
      end

    """
    You work in modes. Each mode gives you the tools for one kind of task.
    #{catalog}

    #{current}

    Call #{config.tool_name} only when the request needs tools the current mode lacks. \
    Do not switch to look around. After switching, the new mode's tools are available \
    on your next step.\
    """
  end

  @doc """
  The tool result text for a call to `tool_name`, a tool in the inactive set
  `set`.
  """
  @spec inactive_tool_hint(map(), String.t(), String.t()) :: String.t()
  def inactive_tool_hint(config, tool_name, set) do
    "#{tool_name} is in the #{display_name(config, set)} mode. " <>
      "Call #{config.tool_name} with \"#{set}\" first, then retry."
  end

  @doc """
  The declared set names, in the order the catalog lists them.
  """
  @spec set_names(map()) :: [String.t()]
  def set_names(config), do: config.sets |> Map.keys() |> Enum.sort()

  @doc """
  Normalize a set name given as an atom or a string.
  """
  @spec set_name(atom() | String.t()) :: String.t()
  def set_name(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  def set_name(name) when is_binary(name), do: name

  # ── switch_mode ────────────────────────────────────────────────

  defp switch_tool(config) do
    Function.new!(%{
      name: config.tool_name,
      description:
        "Switch to another mode to get the tools for a different kind of task. " <>
          "Call it alone, not together with other tools: the new mode's tools are only " <>
          "available on your next step.",
      display_text: "Switching mode",
      parameters_schema: %{
        type: "object",
        properties: %{
          mode: %{
            type: "string",
            enum: set_names(config),
            description: "The mode to switch to."
          }
        },
        required: ["mode"]
      },
      function: fn args, context -> switch(config, args, context) end
    })
  end

  defp switch(config, %{"mode" => mode}, context) when is_binary(mode) do
    {current, switches} = run_position(config, context)

    cond do
      not Map.has_key?(config.sets, mode) ->
        {:error,
         "Unknown mode #{inspect(mode)}. Available modes: #{Enum.join(set_names(config), ", ")}."}

      mode == current ->
        {:error, "Already in the #{display_name(config, mode)} mode."}

      switches >= config.max_switches_per_run ->
        {:error,
         "Mode already switched in this turn. Continue with the current tools or answer the user."}

      true ->
        {:ok, "Switched to the #{display_name(config, mode)} mode. Its tools are available now.",
         State.delta(%{metadata: %{config.state_key => mode}})}
    end
  end

  defp switch(config, _args, _context) do
    {:error, "Missing mode. Available modes: #{Enum.join(set_names(config), ", ")}."}
  end

  # The chain records the set it was built for and the switches made so far in
  # this `execute`. Outside an agent chain the state is all there is.
  defp run_position(_config, %{ability_sets: %{active: active, switches: switches}}),
    do: {active, switches}

  defp run_position(config, %{state: %State{metadata: metadata}}),
    do: {Sagents.AbilitySets.resolve(config, metadata), 0}

  defp run_position(config, _context), do: {config.default, 0}

  defp display_name(config, set), do: config.sets[set].name

  # ── Validation ─────────────────────────────────────────────────

  defp validate_sets(sets) when is_map(sets) and map_size(sets) > 0 do
    Enum.reduce_while(sets, {:ok, %{}}, fn {name, definition}, {:ok, acc} ->
      case validate_set(name, definition) do
        {:ok, set_name, set} -> {:cont, {:ok, Map.put(acc, set_name, set)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_sets(other),
    do:
      {:error, ":sets must be a non-empty map of set name to definition, got: #{inspect(other)}"}

  defp validate_set(name, definition) when is_list(definition),
    do: validate_set(name, Map.new(definition))

  defp validate_set(name, definition)
       when is_map(definition) and (is_atom(name) or is_binary(name)) do
    set_name = set_name(name)

    cond do
      not Regex.match?(@set_name_pattern, set_name) ->
        {:error,
         "ability set name #{inspect(set_name)} must match #{inspect(Regex.source(@set_name_pattern))}"}

      not non_empty_string?(Map.get(definition, :when_to_use)) ->
        {:error, "ability set #{inspect(set_name)} needs a :when_to_use description"}

      not (is_nil(Map.get(definition, :name)) or non_empty_string?(Map.get(definition, :name))) ->
        {:error, "ability set #{inspect(set_name)} has an invalid :name"}

      true ->
        {:ok, set_name,
         %{
           name: Map.get(definition, :name) || String.capitalize(set_name),
           when_to_use: definition.when_to_use
         }}
    end
  end

  defp validate_set(name, definition),
    do: {:error, "invalid ability set #{inspect(name)}: #{inspect(definition)}"}

  defp validate_default(nil, _sets), do: {:ok, nil}

  defp validate_default(default, sets) when is_atom(default) or is_binary(default) do
    name = set_name(default)

    if Map.has_key?(sets, name) do
      {:ok, name}
    else
      {:error, ":default names an ability set that does not exist: #{inspect(name)}"}
    end
  end

  defp validate_default(other, _sets), do: {:error, "invalid :default #{inspect(other)}"}

  defp validate_max_switches(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp validate_max_switches(other),
    do: {:error, ":max_switches_per_run must be a non-negative integer, got: #{inspect(other)}"}

  defp validate_string(key, value) do
    if non_empty_string?(value),
      do: {:ok, value},
      else: {:error, "#{inspect(key)} must be a non-empty string, got: #{inspect(value)}"}
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""
end
