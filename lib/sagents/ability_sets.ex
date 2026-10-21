defmodule Sagents.AbilitySets do
  @moduledoc """
  Pure functions behind `Sagents.Middleware.AbilitySetSwitcher`: expanding the declared
  sets into the middleware stack, resolving the active set from `State`, and
  computing what a chain built for a set carries.

  Every middleware in every set is initialized once, in `Sagents.Agent.new/2`,
  and stays in `agent.middleware`. A set switch changes only which entries
  contribute their system prompt, their tools and their model hooks to a chain.
  Nothing is mounted or unmounted at runtime, so the AgentServer's middleware
  registry, `on_server_start/2` and LangChain callbacks are the same in every
  set.

  An agent without a switcher takes a fast path through every function here:
  `active/2` is `nil` and `effective/2` returns the agent's own middleware,
  tools and assembled prompt.
  """

  require Logger

  alias LangChain.Message
  alias Sagents.AbilitySets.Index
  alias Sagents.AbilitySets.Switch
  alias Sagents.Middleware
  alias Sagents.Middleware.AbilitySetSwitcher
  alias Sagents.MiddlewareEntry
  alias Sagents.State

  # A set's point is a short tool list. Past this many tools, say so.
  @large_set_tool_count 15

  @switched_event [:sagents, :ability_sets, :switched]

  @doc """
  The active set for `state`: `nil` (rails only) or a set name.

  Reads the switcher's state key from `state.metadata`, falling back to the
  switcher's `:default`. A value naming no declared set falls back to the
  default with a warning, so a conversation saved under a set a deploy removed
  continues in the default set instead of failing.

  Always `nil` for an agent without a switcher.
  """
  @spec active(Sagents.Agent.t(), State.t()) :: String.t() | nil
  def active(%{ability_index: %Index{config: config}}, %State{metadata: metadata}),
    do: resolve(config, metadata)

  def active(_agent, _state), do: nil

  @doc """
  Resolve the active set from a metadata map, given the switcher's config.
  See `active/2`.
  """
  @spec resolve(map(), map() | nil) :: String.t() | nil
  def resolve(config, metadata) do
    case Map.get(metadata || %{}, config.state_key) do
      nil ->
        config.default

      name when is_map_key(config.sets, name) ->
        name

      unknown ->
        Logger.warning(
          "Ability set #{inspect(unknown)} in state is not declared; " <>
            "using the default #{inspect(config.default)}"
        )

        config.default
    end
  end

  @doc """
  What a chain built for the `active` set carries:
  `%{middleware: [...], tools: [...], system_prompt: "..."}`.

  The middleware are the rails plus the entries in `active`, in stack order. The
  prompt is assembled from their fragments the way `Sagents.Agent.new/2`
  assembles the full prompt, with the switcher's fragment naming `active`.
  Each set's result is computed once in `Sagents.Agent.new/2`.

  For an agent without a switcher, returns the agent's own middleware, tools and
  assembled prompt.
  """
  @spec effective(Sagents.Agent.t(), String.t() | nil) :: Index.effective()
  def effective(%{ability_index: %Index{effective: effective}}, active),
    do: Map.fetch!(effective, active)

  def effective(agent, _active) do
    %{
      middleware: agent.middleware,
      tools: agent.tools,
      system_prompt: agent.assembled_system_prompt
    }
  end

  @doc """
  The middleware a dynamic sub-agent inherits: the effective middleware without
  the switcher. A sub-agent works in its parent's current set and cannot
  switch.
  """
  @spec inheritable_middleware([MiddlewareEntry.t()]) :: [MiddlewareEntry.t()]
  def inheritable_middleware(middleware), do: Enum.reject(middleware, &switcher?/1)

  @doc """
  The `custom_context.ability_sets` value for a chain built for `active`, or
  `nil` for an agent without a switcher.

  It records the set the chain was built for and the switches made so far in
  the current `Sagents.Agent.execute/3`. The `switch_mode` tool reads both,
  and `Sagents.Mode.Steps.check_ability_switch/2` compares the state against
  `:active` after each tool batch.
  """
  @spec chain_context(Sagents.Agent.t(), String.t() | nil, non_neg_integer()) :: map() | nil
  def chain_context(
        %{ability_index: %Index{config: config, tool_sets: tool_sets}},
        active,
        switches
      ) do
    %{active: active, switches: switches, config: config, tool_sets: tool_sets}
  end

  def chain_context(_agent, _active, _switches), do: nil

  @doc """
  Remove the reasoning from a state that names a different set than
  `built_for`, the set of the chain that produced it.

  Providers that sign reasoning (Anthropic) bind each block to the system
  prompt and tool list it was produced under, and reject it once either
  changes. A switch changes both, so every reasoning part from before it is
  dead: it cannot be replayed to the new set, and it cannot be replayed after a
  switch back either, because the other set's turns now sit in between. The
  parts are dropped from `State.messages` once, at the switch, and the state is
  stored that way. Reasoning produced after the switch is bound to the new
  prefix and is kept.

  Applies however the chain ended. A switch recorded in the same batch as an
  interrupt or an `until_tool` hit ends the call without a rebuild, and the next
  chain built from that state is built for the new set.

  The state passes through unchanged when the set did not change, and always
  for an agent without a switcher.
  """
  @spec strip_reasoning_if_switched(Sagents.Agent.t(), State.t(), String.t() | nil) :: State.t()
  def strip_reasoning_if_switched(%{ability_index: %Index{}} = agent, %State{} = state, built_for) do
    if active(agent, state) == built_for,
      do: state,
      else: %State{state | messages: Message.strip_reasoning(state.messages)}
  end

  def strip_reasoning_if_switched(_agent, state, _built_for), do: state

  @doc """
  Announce a switch: publish `{:ability_set_changed, from, to}` on the agent's
  main channel, emit the `[:sagents, :ability_sets, :switched]` telemetry
  event, and run the switcher's `:on_switch` callback.

  The telemetry metadata and the callback's argument hold `:agent_id`, `:from`,
  `:to` and `:mid_run`, which is `true` when the model switched during a run.
  A failing callback is logged and does not affect the caller.
  """
  @spec notify_switch(Sagents.Agent.t(), Switch.t(), keyword()) :: :ok
  def notify_switch(agent, %Switch{from: from, to: to}, opts \\ []) do
    agent_id = agent.agent_id

    if agent_id,
      do: Sagents.AgentServer.publish_event_from(agent_id, {:ability_set_changed, from, to})

    info = %{agent_id: agent_id, from: from, to: to, mid_run: Keyword.get(opts, :mid_run, true)}

    :telemetry.execute(@switched_event, %{count: 1}, info)

    case agent.ability_index do
      %Index{config: %{on_switch: on_switch}} when not is_nil(on_switch) ->
        AbilitySetSwitcher.apply_callback(on_switch, info)

      _no_callback ->
        :ok
    end

    :ok
  end

  # ── Construction ───────────────────────────────────────────────

  @doc false
  # Expand the switcher's sets into the stack, at the switcher's position.
  #
  # Returns `{:ok, [{spec, ability_sets}]}`, where `ability_sets` is `nil` for a
  # rail and the list of set names for a set member. Each member spec has
  # `inject` applied, the same agent context injection the factory's own specs
  # receive. A member listed in several sets appears once, with every name.
  @spec expand(list(), (term() -> term())) ::
          {:ok, [{term(), [String.t()] | nil}]} | {:error, String.t()}
  def expand(specs, inject) when is_list(specs) do
    case Enum.split_with(specs, &switcher_spec?/1) do
      {[], _rails} ->
        {:ok, Enum.map(specs, &{&1, nil})}

      {[switcher], rails} ->
        rail_ids = MapSet.new(rails, &spec_id/1)

        with {:ok, members} <- collect_members(switcher, rail_ids) do
          {before, [_switcher | after_switcher]} =
            Enum.split_while(specs, &(not switcher_spec?(&1)))

          tagged_members = Enum.map(members, fn {spec, sets} -> {inject.(spec), sets} end)

          {:ok,
           Enum.map(before, &{&1, nil}) ++
             [{switcher, nil} | tagged_members] ++ Enum.map(after_switcher, &{&1, nil})}
        end

      {_switchers, _rails} ->
        {:error, "a middleware stack may hold only one #{inspect(AbilitySetSwitcher)}"}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp collect_members(switcher, rail_ids) do
    {_module, opts} = Middleware.normalize(switcher)

    case Keyword.get(opts, :sets) do
      sets when is_map(sets) ->
        sets
        |> Enum.map(fn {name, definition} -> {set_name_or_raw(name), definition} end)
        |> Enum.sort_by(fn {name, _definition} -> name end)
        |> Enum.reduce_while({:ok, []}, fn {set, definition}, {:ok, acc} ->
          case add_set_members(acc, set, set_middleware(definition), rail_ids) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, members} -> {:ok, Enum.reverse(members)}
          error -> error
        end

      # The switcher's init/1 reports the missing or invalid catalog.
      _other ->
        {:ok, []}
    end
  end

  defp set_middleware(definition) when is_map(definition),
    do: Map.get(definition, :middleware, [])

  defp set_middleware(definition) when is_list(definition),
    do: Keyword.get(definition, :middleware, [])

  defp set_middleware(_definition), do: []

  # Members are kept newest first while collecting.
  defp add_set_members(members, set, specs, rail_ids) when is_list(specs) do
    Enum.reduce_while(specs, {:ok, members}, fn spec, {:ok, acc} ->
      id = spec_id(spec)

      cond do
        switcher_spec?(spec) ->
          {:halt,
           {:error, "ability set #{inspect(set)} contains another #{inspect(AbilitySetSwitcher)}"}}

        MapSet.member?(rail_ids, id) ->
          {:halt,
           {:error,
            "#{inspect(id)} is in ability set #{inspect(set)} and also outside every set; " <>
              "a middleware outside the sets is already active in every set"}}

        true ->
          case add_member(acc, set, spec, id) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  defp add_set_members(_members, set, specs, _rail_ids),
    do: {:error, "ability set #{inspect(set)} :middleware must be a list, got: #{inspect(specs)}"}

  defp add_member(members, set, spec, id) do
    case Enum.find_index(members, fn {existing, _sets} -> spec_id(existing) == id end) do
      nil ->
        {:ok, [{spec, [set]} | members]}

      index ->
        {existing, sets} = Enum.at(members, index)

        if Middleware.normalize(existing) == Middleware.normalize(spec) do
          {:ok, List.replace_at(members, index, {existing, sets ++ [set]})}
        else
          {:error,
           "#{inspect(id)} appears in more than one ability set with different options; " <>
             "give each instance its own :id"}
        end
    end
  end

  defp set_name_or_raw(name) when is_atom(name) or is_binary(name),
    do: AbilitySetSwitcher.set_name(name)

  defp set_name_or_raw(name), do: name

  @doc false
  # Build the index for an initialized stack, or `{:ok, nil}` when it has no
  # switcher. Validates that no tool name is provided twice where a set member
  # is involved, and warns about sets with many tools.
  @spec build_index([MiddlewareEntry.t()], list(), String.t() | nil) ::
          {:ok, Index.t() | nil} | {:error, String.t()}
  def build_index(entries, base_tools, base_prompt) do
    case Enum.find(entries, &switcher?/1) do
      nil ->
        {:ok, nil}

      %MiddlewareEntry{config: config} ->
        contributions = Enum.map(entries, &{&1, Middleware.get_tools(&1)})

        with :ok <- validate_unique_tools(contributions, base_tools) do
          warn_about_large_sets(contributions, config)

          effective =
            [nil | AbilitySetSwitcher.set_names(config)]
            |> Map.new(fn set ->
              {set, effective_for(set, contributions, base_tools, base_prompt, config)}
            end)

          {:ok, %Index{config: config, effective: effective, tool_sets: tool_sets(contributions)}}
        end
    end
  end

  defp effective_for(set, contributions, base_tools, base_prompt, config) do
    active = Enum.filter(contributions, fn {entry, _tools} -> active_in?(entry, set) end)
    middleware = Enum.map(active, &elem(&1, 0))

    fragments =
      Enum.map(middleware, fn entry ->
        if switcher?(entry),
          do: AbilitySetSwitcher.catalog_prompt(config, set),
          else: Middleware.get_system_prompt(entry)
      end)

    %{
      middleware: middleware,
      tools: base_tools ++ Enum.flat_map(active, &elem(&1, 1)),
      system_prompt:
        [base_prompt || "" | fragments]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
    }
  end

  defp active_in?(%MiddlewareEntry{ability_sets: nil}, _set), do: true
  defp active_in?(%MiddlewareEntry{ability_sets: sets}, set), do: set in sets

  defp tool_sets(contributions) do
    for {%MiddlewareEntry{ability_sets: sets}, tools} <- contributions,
        is_list(sets),
        tool <- tools,
        into: %{},
        do: {tool.name, sets}
  end

  # Tool lookup, HITL and `ToolCall.name` are all keyed by name, so a name a set
  # member provides must be unique across every set and the rails.
  defp validate_unique_tools(contributions, base_tools) do
    owners =
      Enum.map(base_tools, &{&1.name, :base, nil}) ++
        for(
          {entry, tools} <- contributions,
          tool <- tools,
          do: {tool.name, entry.id, entry.ability_sets}
        )

    duplicate =
      owners
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.find(fn {_name, owned} ->
        length(owned) > 1 and Enum.any?(owned, fn {_name, _id, sets} -> is_list(sets) end)
      end)

    case duplicate do
      nil ->
        :ok

      {name, owned} ->
        {:error,
         "tool #{inspect(name)} is provided by more than one middleware " <>
           "(#{Enum.map_join(owned, ", ", &inspect(elem(&1, 1)))}); tool names must be " <>
           "unique across ability sets"}
    end
  end

  defp warn_about_large_sets(contributions, config) do
    for set <- AbilitySetSwitcher.set_names(config) do
      count =
        contributions
        |> Enum.filter(fn {entry, _tools} ->
          is_list(entry.ability_sets) and set in entry.ability_sets
        end)
        |> Enum.map(fn {_entry, tools} -> length(tools) end)
        |> Enum.sum()

      if count > @large_set_tool_count do
        Logger.warning(
          "Ability set #{inspect(set)} has #{count} tools. A set exists to keep the tool " <>
            "list short; consider splitting it."
        )
      end
    end

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────

  @doc false
  def switcher?(%MiddlewareEntry{module: AbilitySetSwitcher}), do: true
  def switcher?(_entry), do: false

  defp switcher_spec?(AbilitySetSwitcher), do: true
  defp switcher_spec?({AbilitySetSwitcher, _opts}), do: true
  defp switcher_spec?(_spec), do: false

  defp spec_id(spec) do
    {module, opts} = Middleware.normalize(spec)
    Keyword.get(opts, :id, module)
  end
end
