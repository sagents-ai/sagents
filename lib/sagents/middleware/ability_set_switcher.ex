defmodule Sagents.Middleware.AbilitySetSwitcher do
  @moduledoc ~S"""
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
               "devices" =>
                 AbilitySet.new!(%{
                   name: "Devices",
                   when_to_use: "Device inventory, packages, and deployments to devices.",
                   middleware: [MyApp.Middleware.Devices, MyApp.Middleware.Deployments]
                 }),
               "billing" =>
                 AbilitySet.new!(%{
                   name: "Billing",
                   when_to_use: "Invoices, balances, and payment status.",
                   middleware: [MyApp.Middleware.Billing]
                 })
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

  - `:sets` - Map of set name to `Sagents.AbilitySet` (required). A name
    matches `^[a-z][a-z0-9_]{0,63}$`. A set may also be given as a plain map or
    keyword list of the struct's fields, and is validated the same way. A set's
    `:switch_message` defaults to `"Switched to the <name> mode."` followed by
    the tools the switch makes available (see "Switch messages").
  - `:default` - The set active when the state names none. `nil` (the default)
    means rails only.
  - `:max_switches_per_run` - Switches the model may make within one
    `Sagents.Agent.execute/3` call (default: `1`).
  - `:state_key` - The `State.metadata` key holding the active set (default:
    `"active_ability_set"`).
  - `:tool_name` - Name of the switching tool (default: `"switch_mode"`).
  - `:on_switch` - A callback run once for each switch (see "Reacting to a
    switch") (default: `nil`).

  An option or set field the switcher does not know is an error, so a
  misspelled key fails `Sagents.Agent.new/2` instead of being ignored.

  A callback is a 1-arity function or a `{module, function, args}` tuple. A
  tuple is called as `apply(module, function, [info | args])`. Prefer the tuple
  under Horde: an agent's options travel between nodes, and an anonymous
  function can only be called by the build that created it.

  ## Switch messages

  A successful `switch_mode` call returns the target set's `:switch_message`
  to the model. The default names the mode and lists the tools that became
  available, the target set's tools that the previous set did not have:

      Switched to the Billing mode. Tools now available: get_invoice, list_invoices.

  A callback receives a map and returns the text:

  - `:from` - the set switched from (`nil` for rails only)
  - `:to` - the set switched to
  - `:name` - the target set's display name
  - `:tools` - the names of the tools that became available, sorted

  ```elixir
  switch_message: fn %{name: name, tools: tools} ->
    "Switching to focus on #{name}. You can now use #{Enum.join(tools, ", ")}."
  end
  ```

  A callback that raises or returns anything but a non-empty string falls back
  to the default message, with a warning.

  ## Reacting to a switch

  `:on_switch` runs once for every switch, in the process executing the agent,
  when the switch is announced with `{:agent, {:ability_set_changed, from, to}}`.
  That covers a switch that continues the run on a new chain and a switch
  recorded in the same tool batch as an interrupt, an `until_tool` hit or a
  pause. It receives a map with `:agent_id`, `:from`, `:to` and `:mid_run`.

  It suits work that must happen once per switch whatever is watching, such as
  adding a message to the conversation's transcript:

  ```elixir
  on_switch: {MyApp.Modes, :announce, []}

  # in MyApp.Modes
  def announce(%{agent_id: agent_id, to: to}) do
    Sagents.AgentServer.save_synthetic_message_from(agent_id, %{
      message_type: "assistant",
      content_type: "text",
      content: %{"text" => announcement(to)}
    })
  end
  ```

  Its return value is ignored. An exception is logged and does not affect the
  run. Keep it quick: the next LLM call waits for it.

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

  ## Sub-agents

  A dynamic sub-agent started with `Sagents.Middleware.SubAgent` inherits the
  parent's middleware for the set active when it starts: the rails plus that
  set's members. Members of other sets are not inherited, and neither is the
  switcher. The sub-agent therefore works in the parent's current mode for its
  whole task, with that mode's prompt fragments and tools as ordinary
  middleware, and has no `switch_mode` tool. With no set active, it inherits
  the rails only.

  `:block_middleware` on the SubAgent middleware applies as usual, so listing a
  set member there keeps it out of sub-agents even while its set is active.
  """

  @behaviour Sagents.Middleware

  require Logger

  alias LangChain.Function
  alias Sagents.AbilitySet
  alias Sagents.State

  @typedoc "A 1-arity function or a `{module, function, args}` tuple."
  @type callback :: (map() -> term()) | {module(), atom(), list()}

  @set_name_pattern ~r/^[a-z][a-z0-9_]{0,63}$/

  @default_state_key "active_ability_set"
  @default_tool_name "switch_mode"

  @option_keys [:sets, :default, :max_switches_per_run, :state_key, :tool_name, :on_switch, :id]

  @impl true
  def init(opts) do
    with :ok <- validate_option_keys(opts),
         {:ok, sets} <- validate_sets(Keyword.get(opts, :sets)),
         {:ok, default} <- validate_default(Keyword.get(opts, :default), sets),
         {:ok, max_switches} <-
           validate_max_switches(Keyword.get(opts, :max_switches_per_run, 1)),
         {:ok, state_key} <-
           validate_string(:state_key, Keyword.get(opts, :state_key, @default_state_key)),
         {:ok, tool_name} <-
           validate_string(:tool_name, Keyword.get(opts, :tool_name, @default_tool_name)),
         {:ok, on_switch} <- validate_on_switch(Keyword.get(opts, :on_switch)) do
      config = %{
        sets: sets,
        default: default,
        max_switches_per_run: max_switches,
        state_key: state_key,
        tool_name: tool_name,
        on_switch: on_switch
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
    ## Modes

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
        info = %{
          from: current,
          to: mode,
          name: display_name(config, mode),
          tools: tools_added(context, current, mode)
        }

        {:ok, switch_message(config, info), State.delta(%{metadata: %{config.state_key => mode}})}
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

  # The target set's tools that the current set does not already provide. The
  # chain context carries the tool-to-sets map; outside an agent chain there is
  # none, and no tools are listed.
  defp tools_added(%{ability_sets: %{tool_sets: tool_sets}}, current, mode)
       when is_map(tool_sets) do
    for({tool, sets} <- tool_sets, mode in sets, current not in sets, do: tool)
    |> Enum.sort()
  end

  defp tools_added(_context, _current, _mode), do: []

  defp switch_message(config, info) do
    case config.sets[info.to].switch_message do
      nil -> default_switch_message(info)
      message when is_binary(message) -> message
      callback -> callback_switch_message(callback, info)
    end
  end

  defp callback_switch_message(callback, info) do
    case apply_callback(callback, info) do
      {:ok, message} when is_binary(message) and message != "" ->
        message

      {:ok, other} ->
        Logger.warning(
          "switch_message callback for ability set #{inspect(info.to)} returned " <>
            "#{inspect(other)}, not a non-empty string; using the default message"
        )

        default_switch_message(info)

      {:error, _reason} ->
        default_switch_message(info)
    end
  end

  defp default_switch_message(%{name: name, tools: []}), do: "Switched to the #{name} mode."

  defp default_switch_message(%{name: name, tools: tools}),
    do: "Switched to the #{name} mode. Tools now available: #{Enum.join(tools, ", ")}."

  @doc false
  # Call a `:switch_message` or `:on_switch` callback with `info`. An exception,
  # throw or exit is logged and returned as `{:error, reason}`, so a faulty
  # callback never ends the run.
  @spec apply_callback(callback(), map()) :: {:ok, term()} | {:error, term()}
  def apply_callback(callback, info) do
    {:ok, invoke(callback, info)}
  rescue
    exception ->
      Logger.error(
        "Ability set callback #{inspect(callback)} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, exception}
  catch
    kind, reason ->
      Logger.error("Ability set callback #{inspect(callback)} failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp invoke(fun, info) when is_function(fun, 1), do: fun.(info)
  defp invoke({module, function, args}, info), do: apply(module, function, [info | args])

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

  # The config keeps each set's catalog fields. Its :middleware is emptied: the
  # members are entries of `agent.middleware`, tagged with their sets.
  defp validate_set(name, definition)
       when (is_atom(name) or is_binary(name)) and
              (is_map(definition) or is_list(definition)) do
    set_name = set_name(name)

    if Regex.match?(@set_name_pattern, set_name) do
      case AbilitySet.cast_set(definition) do
        {:ok, %AbilitySet{} = set} ->
          {:ok, set_name,
           %AbilitySet{set | name: set.name || String.capitalize(set_name), middleware: []}}

        {:error, reason} ->
          {:error, "ability set #{inspect(set_name)}: #{reason}"}
      end
    else
      {:error,
       "ability set name #{inspect(set_name)} must match #{inspect(Regex.source(@set_name_pattern))}"}
    end
  end

  defp validate_set(name, definition),
    do: {:error, "invalid ability set #{inspect(name)}: #{inspect(definition)}"}

  # An option the switcher does not know is an error, so a misspelled key such
  # as `:on_swich` cannot be dropped without a trace. `Sagents.Agent.new/2`
  # adds its own context keys to every middleware's options.
  defp validate_option_keys(opts) do
    known = @option_keys ++ Sagents.Agent.injected_context_keys()

    case Enum.reject(Keyword.keys(opts), &(&1 in known)) do
      [] ->
        :ok

      unknown ->
        {:error,
         "unknown #{inspect(__MODULE__)} options #{inspect(unknown)}; " <>
           "valid options are #{inspect(@option_keys)}"}
    end
  end

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

  defp validate_on_switch(nil), do: {:ok, nil}

  defp validate_on_switch(callback) do
    if AbilitySet.callback?(callback),
      do: {:ok, callback},
      else:
        {:error,
         ":on_switch must be a 1-arity function or a {module, function, args} tuple, " <>
           "got: #{inspect(callback)}"}
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""
end
