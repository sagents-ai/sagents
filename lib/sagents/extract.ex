defmodule Sagents.Extract do
  @moduledoc """
  Structured data extraction through an `Sagents.Agent`.

  This is `LangChain.Chains.DataExtractionChain` lifted to the Agent layer.
  Use it when you want a single agent run to return a structured map, *and*
  you want the call to flow through your agent's middleware stack — token
  usage attribution, tenancy/APM context propagation, scope, fallback models,
  filesystem scope, and so on.

  The trick is the same one `DataExtractionChain` uses: define a single tool
  whose `parameters_schema` is the desired result shape, run the agent with
  `until_tool_success: "<tool_name>"`, and read the result back out. `run/3`
  returns the tool's `processed_content` — the value the tool body produces — so
  the tool can shape the raw LLM arguments into whatever data structure you
  actually want (a struct, a persisted record, an id). When the tool sets no
  `processed_content`, `run/3` falls back to the LLM-supplied argument map. The
  default schema tool simply hands `args` back as `processed_content`, so the
  no-frills path still returns the LLM arguments. See "Shaping the result".

  ## Basic usage

      schema = %{
        type: "object",
        properties: %{
          "title" => %{type: "string"},
          "summary" => %{type: "string"}
        },
        required: ["title", "summary"]
      }

      state = State.new!(%{messages: [Message.new_user!("Summarize: ...")]})

      {:ok, result} = Sagents.Extract.run(agent, state, schema: schema)

      # result is the submit tool's processed_content. For the default schema
      # tool that is the LLM-supplied map: %{"title" => "...", "summary" => "..."}

  ## Options

    * `:schema` (required, unless `:tool` is given) — A JSON Schema map
      describing the result shape. Becomes the `parameters_schema` of the
      submit tool.
    * `:tool` (required, unless `:schema` is given) — A pre-built
      `LangChain.Function`. Use this when you want full control over the
      tool's name, description, `parse_args` callback, etc. When supplied,
      `:schema`, `:tool_name`, and `:description` are ignored. Return
      `{:ok, "text for LLM", processed_term}` from the tool body to make
      `processed_term` the value `run/3` returns; a 2-tuple `{:ok, "text"}`
      falls back to the LLM arguments. See "Shaping the result".
    * `:tool_name` (default `"submit_result"`) — Name of the submit tool the
      LLM will be required to call. Only meaningful when `:schema` is used.
    * `:description` (default a generic string) — Description sent to the LLM
      for the submit tool. Worth writing well; the LLM reads it to decide what
      to put in the arguments.
    * `:max_runs` (default `5`) — Maximum LLM calls. Enough for a single call
      plus a few retries if the tool body or `parse_args` validation rejects
      malformed args. Increase for complex schemas.
    * `:callbacks` — A list of callback handler maps forwarded to
      `Sagents.Agent.execute/3` (e.g. a token-usage logger). These are merged
      with the agent's middleware callbacks, not substituted, so supplying them
      never disables middleware-provided callbacks. See `Sagents.Agent.execute/3`
      for the accepted keys.

  ## What `run/3` returns

    * `{:ok, term()}` — The submit tool's `processed_content`: the value the
      tool body returns as the 3rd element of `{:ok, "text for LLM", term}`.
      This can be any term — a map, a struct, a persisted record, an id. When
      the tool sets no `processed_content` (it returned a 2-tuple
      `{:ok, "text"}`), this falls back to the LLM-supplied argument map, with
      keys exactly as the provider returned them. The default schema tool hands
      `args` back as `processed_content`, so the schema path returns the LLM
      arguments.
    * `{:error, term()}` — A `LangChainError` if the LLM never successfully
      called the submit tool within `max_runs`, if a same-named tool already
      exists on the agent, or anything else that `Sagents.Agent.execute/3` would surface.

  ## Shaping the result

  `run/3` returns whatever the submit tool *produces*, not just what the LLM
  *emitted*. That lets the tool body turn the raw LLM arguments into the exact
  data shape you want, in three escalating tiers:

  1. **Raw arguments (default).** With `:schema` and no custom tool, `run/3`
     returns the LLM-supplied argument map unchanged. Nothing to do.

  2. **Process inside the tool body.** Supply a `:tool` whose body transforms,
     validates, or persists the args and returns the shaped value as the 3rd
     element. That value is what `run/3` returns; the LLM only ever sees the
     2nd element (the string), never the 3rd.

         submit =
           LangChain.Function.new!(%{
             name: "submit_result",
             description: "Submit the structured result.",
             parameters_schema: schema,
             function: fn args, _ctx ->
               # shape the raw LLM args into the data structure you want
               person = %MyApp.Person{name: args["name"], age: args["age"]}
               # (or persist here and return the inserted struct / id instead)
               {:ok, "Saved \#{person.name}.", person}
             end
           })

         {:ok, %MyApp.Person{} = person} =
           Sagents.Extract.run(agent, state, tool: submit)

  3. **`:parse_args` for coercion/validation.** A `LangChain.Function`
     `:parse_args` callback (Zoi schemas work well) can coerce the args before
     the body runs; pair it with a body that returns the shaped value as the
     3rd element. Returning `{:error, "reason"}` from `parse_args` or the body
     keeps the loop running so the LLM corrects the call — see "Validation and
     retry".

  Callers who only care about the raw arguments need none of this: a 2-tuple
  `{:ok, "text"}`, or just using `:schema`, returns the LLM args.

  ## Provider-side `tool_choice`

  Anthropic and OpenAI both let you require the model to call a specific tool
  via `tool_choice`. Setting this on your `ChatAnthropic` / `ChatOpenAI` model
  before passing it to `Sagents.Agent.new/2` materially improves single-call
  reliability. **The name in `tool_choice` must match the submit tool's name**
  — which is whatever you pass as `:tool_name` (or `"submit_result"` if you
  don't). Mismatched names still work — `until_tool` catches whichever tool
  the LLM calls — but you lose the provider-side guarantee.

  Example:

      model =
        ChatAnthropic.new!(%{
          model: "claude-sonnet-4-6",
          tool_choice: %{"type" => "tool", "name" => "submit_result"}
        })

      {:ok, agent} = Sagents.Agent.new(%{model: model, ...})

      Sagents.Extract.run(agent, state, schema: schema)

  ## Validation and retry

  Two layers of validation are available, both caller-owned:

    1. **JSON schema** (provider-enforced) — defined by your `:schema`. The
       provider rejects shape errors before the call reaches us.
    2. **Business rules** (in your tool) — anything JSON Schema can't express.
       Use `LangChain.Function`'s `:parse_args` callback (Zoi schemas work
       well) or validate inside the tool body. Return `{:error, "reason"}`;
       the LLM sees the error and retries with corrected args until success
       or `:max_runs` is hit. Write error messages that are actionable — the
       LLM is the one reading them.

  Nothing here needs to know about either layer. The retry behavior is driven
  by `Extract` running with `until_tool_success: <submit tool>`: an error result
  from the submit tool keeps the loop running (feeding the error back to the
  LLM) instead of terminating the run with malformed args.

  ## Middleware compatibility

  Not every middleware is appropriate in a fire-and-wait run. `run/3` calls
  `Sagents.Agent.execute/3` directly — `Sagents.AgentServer` is not involved.
  Middleware that assumes a registered `AgentServer` will misbehave. In
  particular:

    * Middleware that broadcasts events over PubSub via
      `Sagents.AgentServer.publish_event_from/2`.
    * Middleware that schedules or relies on an inactivity timer.
    * Middleware that looks up an agent process by `agent_id`.

  Middleware that is purely state-shaping or context-propagating is fine:
  token-usage capture, tenancy/APM context propagation, request-scoped
  logging, scope-keyed persistence, etc. Composing a safe agent is the
  caller's responsibility.

  ## Non-mutation

  `run/3` does not modify the agent you pass in. It builds a new agent value
  with the submit tool appended to `:tools` and runs that. The submit tool
  only exists for the duration of that call; the original agent is unchanged
  and never sees it.
  """

  alias LangChain.Function
  alias LangChain.LangChainError
  alias Sagents.Agent
  alias Sagents.AgentResult
  alias Sagents.State

  @default_tool_name "submit_result"
  @default_description "Submit the final structured result. Call this exactly once when you have produced the answer."
  @default_max_runs 5

  @typedoc "Options for `run/3`."
  @type opts :: [
          schema: map(),
          tool: Function.t(),
          tool_name: String.t(),
          description: String.t(),
          max_runs: pos_integer(),
          callbacks: [map()]
        ]

  @doc """
  Run a structured extraction with the given agent and state.

  The `state` carries the full conversation (system messages, user prompts,
  any prior turns). See the module doc for option details.
  """
  @spec run(Agent.t(), State.t(), opts()) :: {:ok, any()} | {:error, term()}
  def run(%Agent{} = agent, %State{} = state, opts) when is_list(opts) do
    with {:ok, submit_tool} <- build_submit_tool(opts),
         :ok <- check_tool_name_unique(agent, submit_tool.name) do
      augmented_agent = %{agent | tools: agent.tools ++ [submit_tool]}
      max_runs = Keyword.get(opts, :max_runs, @default_max_runs)

      # Use the success variant so a validation error from the submit tool keeps
      # the loop running (the LLM retries) instead of terminating with bad args.
      execute_opts =
        [until_tool_success: submit_tool.name, max_runs: max_runs]
        |> maybe_put_callbacks(opts)

      augmented_agent
      |> Agent.execute(state, execute_opts)
      |> extract_result()
    end
  end

  # Prefer the submit tool's `processed_content` (position 3 of its 3-tuple
  # return) so a tool that validates/parses/persists can hand its processed
  # result back through Extract. Fall back to the LLM-supplied arguments only
  # when the tool set no `processed_content` (e.g. it returned a 2-tuple) — the
  # default submit tool passes `args` through, so the schema path is unchanged.
  # Genuine failures (until_tool_not_called, interrupt, pause) pass through.
  defp extract_result(execute_return) do
    case AgentResult.processed_content(execute_return) do
      {:ok, content} ->
        {:ok, content}

      {:error, %LangChainError{type: "no_processed_content"}} ->
        AgentResult.tool_arguments(execute_return)

      {:error, _reason} = err ->
        err
    end
  end

  # Forward caller-supplied callbacks only when present, so Agent.execute keeps
  # its no-`:callbacks` default behaviour otherwise.
  defp maybe_put_callbacks(execute_opts, opts) do
    case Keyword.get(opts, :callbacks) do
      nil -> execute_opts
      callbacks -> Keyword.put(execute_opts, :callbacks, callbacks)
    end
  end

  # ── Tool building ────────────────────────────────────────────────

  defp build_submit_tool(opts) do
    case {Keyword.get(opts, :tool), Keyword.get(opts, :schema)} do
      {%Function{} = tool, _schema} ->
        {:ok, tool}

      {nil, schema} when is_map(schema) ->
        name = Keyword.get(opts, :tool_name, @default_tool_name)
        description = Keyword.get(opts, :description, @default_description)

        {:ok,
         Function.new!(%{
           name: name,
           description: description,
           parameters_schema: schema,
           function: fn args, _ctx -> {:ok, Jason.encode!(args), args} end
         })}

      {nil, nil} ->
        {:error,
         LangChainError.exception(
           type: "extract_invalid_opts",
           message: "Sagents.Extract.run/3 requires either :schema or :tool option"
         )}

      {_tool, _schema} ->
        {:error,
         LangChainError.exception(
           type: "extract_invalid_opts",
           message: ":tool must be a %LangChain.Function{}"
         )}
    end
  end

  defp check_tool_name_unique(%Agent{tools: tools}, name) do
    if Enum.any?(tools, &(&1.name == name)) do
      {:error,
       LangChainError.exception(
         type: "extract_tool_conflict",
         message:
           "Agent already has a tool named #{inspect(name)}. Pass :tool_name or :tool to avoid the conflict."
       )}
    else
      :ok
    end
  end
end
