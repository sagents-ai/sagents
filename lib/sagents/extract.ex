defmodule Sagents.Extract do
  @moduledoc """
  Structured data extraction through an `Sagents.Agent`.

  This is `LangChain.Chains.DataExtractionChain` lifted to the Agent layer.
  Use it when you want a single agent run to return a structured map, *and*
  you want the call to flow through your agent's middleware stack — token
  usage attribution, tenancy/APM context propagation, scope, fallback models,
  filesystem scope, and so on.

  The trick is the same one `DataExtractionChain` uses: the agent owns a single
  "submit" tool whose `parameters_schema` is the desired result shape, the run
  stops on that tool, and `run/3` reads the result back out. `run/3` returns the
  tool's `processed_content` — the value the tool body produces — so the tool can
  shape the raw LLM arguments into whatever data structure you actually want (a
  struct, a persisted record, an id). When the tool sets no `processed_content`,
  `run/3` falls back to the LLM-supplied argument map. See "Shaping the result".

  ## Agent-owned tool

  The submit tool lives on the agent — defined alongside its system prompt and
  middleware as one self-contained package — and you name it via
  `:until_tool_success` (or `:until_tool`). `Sagents.Agent` owns its tools
  (`Agent.new!(%{tools: [t]})` merges caller tools with middleware tools) and
  `Sagents.Agent.execute/3` validates that the named tool is present. `run/3`
  forwards the stop condition to `execute` and reads the result back out.

  ## Basic usage

      schema = %{
        type: "object",
        properties: %{
          "title" => %{type: "string"},
          "summary" => %{type: "string"}
        },
        required: ["title", "summary"]
      }

      submit =
        LangChain.Function.new!(%{
          name: "submit_result",
          description: "Submit the structured result.",
          parameters_schema: schema,
          function: fn args, _ctx -> {:ok, Jason.encode!(args), args} end
        })

      {:ok, agent} = Sagents.Agent.new(%{model: model, tools: [submit]})

      state = State.new!(%{messages: [Message.new_user!("Summarize: ...")]})

      {:ok, result} = Sagents.Extract.run(agent, state, until_tool_success: "submit_result")

      # result is the submit tool's processed_content. The tool above hands
      # `args` back as the 3rd element, so result is the LLM-supplied map:
      # %{"title" => "...", "summary" => "..."}

  ## Options

  Exactly one of `:until_tool_success` / `:until_tool` is required (naming a tool
  on the agent). The two are mutually exclusive; passing both is rejected by
  `Sagents.Agent.execute/3`.

    * `:until_tool_success` — Name of the agent-owned submit tool. The run stops
      only when this tool returns a *successful* (non-error) result; an error
      result keeps the loop running so the LLM can correct its arguments,
      bounded by `:max_runs`. This is the loop most extraction callers want.
    * `:until_tool` — Name of the agent-owned submit tool. The run stops as soon
      as this tool is *called*: the tool executes, then the loop stops.
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
      keys exactly as the provider returned them.
    * `{:error, term()}` — A `LangChainError` if neither stop option is given
      (`type: "extract_invalid_opts"`), if the named tool is not on the agent
      (`type: "extract_tool_not_found"`), if the LLM never successfully called
      the submit tool within `max_runs`, or anything else that
      `Sagents.Agent.execute/3` would surface.

  ## Shaping the result

  `run/3` returns whatever the submit tool *produces*, not just what the LLM
  *emitted*. That lets the tool body turn the raw LLM arguments into the exact
  data shape you want, in three escalating tiers:

  1. **Raw arguments.** A tool body that returns `{:ok, Jason.encode!(args),
     args}` (or a 2-tuple `{:ok, text}`) makes `run/3` return the LLM-supplied
     argument map unchanged.

  2. **Process inside the tool body.** Transform, validate, or persist the args
     and return the shaped value as the 3rd element. That value is what `run/3`
     returns; the LLM only ever sees the 2nd element (the string), never the
     3rd.

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

         {:ok, agent} = Sagents.Agent.new(%{model: model, tools: [submit]})

         {:ok, %MyApp.Person{} = person} =
           Sagents.Extract.run(agent, state, until_tool_success: "submit_result")

  3. **`:parse_args` for coercion/validation.** A `LangChain.Function`
     `:parse_args` callback (Zoi schemas work well) can coerce the args before
     the body runs; pair it with a body that returns the shaped value as the
     3rd element. Returning `{:error, "reason"}` from `parse_args` or the body
     keeps the loop running so the LLM corrects the call — see "Validation and
     retry".

  ## Provider-side `tool_choice`

  Anthropic and OpenAI both let you require the model to call a specific tool
  via `tool_choice`. Setting this on your `ChatAnthropic` / `ChatOpenAI` model
  before passing it to `Sagents.Agent.new/2` materially improves single-call
  reliability. **The name in `tool_choice` must match the submit tool's name**
  — the same name you attach to the agent and pass as `:until_tool_success`.
  Mismatched names still work — `until_tool_success` catches the tool whenever
  the LLM calls it — but you lose the provider-side guarantee.

  Example:

      model =
        ChatAnthropic.new!(%{
          model: "claude-sonnet-4-6",
          tool_choice: %{"type" => "tool", "name" => "submit_result"}
        })

      {:ok, agent} = Sagents.Agent.new(%{model: model, tools: [submit]})

      Sagents.Extract.run(agent, state, until_tool_success: "submit_result")

  ## Validation and retry

  Two layers of validation are available, both caller-owned:

    1. **JSON schema** (provider-enforced) — defined by the submit tool's
       `parameters_schema`. The provider rejects shape errors before the call
       reaches us.
    2. **Business rules** (in your tool) — anything JSON Schema can't express.
       Use `LangChain.Function`'s `:parse_args` callback (Zoi schemas work
       well) or validate inside the tool body. Return `{:error, "reason"}`;
       the LLM sees the error and retries with corrected args until success
       or `:max_runs` is hit. Write error messages that are actionable — the
       LLM is the one reading them.

  Nothing here needs to know about either layer. The retry behavior is driven
  by `Extract` running with `until_tool_success: <submit tool>`: an error result
  from the submit tool keeps the loop running, feeding the error back to the LLM
  so it can correct its arguments. `until_tool` stops on the first call, whatever
  the tool returns.

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
  """

  alias LangChain.LangChainError
  alias Sagents.Agent
  alias Sagents.AgentResult
  alias Sagents.State

  @default_max_runs 5

  @typedoc "Options for `run/3`."
  @type opts :: [
          until_tool_success: String.t(),
          until_tool: String.t(),
          max_runs: pos_integer(),
          callbacks: [map()]
        ]

  @doc """
  Run a structured extraction with the given agent and state.

  The `state` carries the full conversation (system messages, user prompts,
  any prior turns). The submit tool must be on the agent and named via
  `:until_tool_success` or `:until_tool`. See the module doc for option details.
  """
  @spec run(Agent.t(), State.t(), opts()) :: {:ok, any()} | {:error, term()}
  def run(%Agent{} = agent, %State{} = state, opts) when is_list(opts) do
    with :ok <- validate_stop_option(opts),
         :ok <- validate_tool_present(agent, opts) do
      execute_opts =
        opts
        |> Keyword.take([:until_tool_success, :until_tool, :max_runs, :callbacks])
        |> Keyword.put_new(:max_runs, @default_max_runs)

      agent
      |> Agent.execute(state, execute_opts)
      |> extract_result()
    end
  end

  # Prefer the submit tool's `processed_content` (position 3 of its 3-tuple
  # return) so a tool that validates/parses/persists can hand its processed
  # result back through Extract. Fall back to the LLM-supplied arguments only
  # when the tool set no `processed_content` (e.g. it returned a 2-tuple). Note
  # the relied-upon quirk: `AgentResult.processed_content/1` reports a `nil`
  # processed_content as the typed "no_processed_content" error, which is what
  # triggers the fallback. Genuine failures (until_tool_not_called, interrupt,
  # pause) pass through.
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

  # At least one stop option must name a tool on the agent. When both are given,
  # Agent.execute's validate_until_tool/2 rejects the combination downstream (the
  # two are mutually exclusive there).
  defp validate_stop_option(opts) do
    case {Keyword.get(opts, :until_tool_success), Keyword.get(opts, :until_tool)} do
      {nil, nil} ->
        {:error,
         LangChainError.exception(
           type: "extract_invalid_opts",
           message:
             "Sagents.Extract.run/3 requires :until_tool_success or :until_tool naming a tool on the agent"
         )}

      _one_or_both ->
        :ok
    end
  end

  # Friendlier, typed pre-check that the named tool exists on the agent.
  # Agent.execute's validate_until_tool/2 also checks presence but surfaces a
  # plain string; this gives callers a structured LangChainError to match on.
  # Reads whichever stop option is set (preferring :until_tool_success).
  defp validate_tool_present(%Agent{tools: tools}, opts) do
    name = Keyword.get(opts, :until_tool_success) || Keyword.get(opts, :until_tool)

    if Enum.any?(tools, &(&1.name == name)) do
      :ok
    else
      {:error,
       LangChainError.exception(
         type: "extract_tool_not_found",
         message:
           "Sagents.Extract.run/3: tool #{inspect(name)} is not on the agent. Attach it via Agent.new!(%{tools: [tool]})."
       )}
    end
  end
end
