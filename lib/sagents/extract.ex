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
  `until_tool: "<that tool>"`, and read the LLM-supplied arguments back out.
  The tool's body never has to do real work — it just hands `args` back as
  `processed_content`.

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

      # result is the LLM-supplied map: %{"title" => "...", "summary" => "..."}

  ## Options

    * `:schema` (required, unless `:tool` is given) — A JSON Schema map
      describing the result shape. Becomes the `parameters_schema` of the
      submit tool.
    * `:tool` (required, unless `:schema` is given) — A pre-built
      `LangChain.Function`. Use this when you want full control over the
      tool's name, description, `parse_args` callback, etc. When supplied,
      `:schema`, `:tool_name`, and `:description` are ignored.
    * `:tool_name` (default `"submit_result"`) — Name of the submit tool the
      LLM will be required to call. Only meaningful when `:schema` is used.
    * `:description` (default a generic string) — Description sent to the LLM
      for the submit tool. Worth writing well; the LLM reads it to decide what
      to put in the arguments.
    * `:max_runs` (default `5`) — Maximum LLM calls. Enough for a single call
      plus a few retries if the tool body or `parse_args` validation rejects
      malformed args. Increase for complex schemas.

  ## What `run/3` returns

    * `{:ok, map()}` — The arguments the LLM passed to the submit tool, with
      keys exactly as the provider returned them (or as the `parse_args`
      callback processes them).
    * `{:error, term()}` — A `LangChainError` if the LLM never successfully
      called the submit tool within `max_runs`, if a same-named tool already
      exists on the agent, or anything else that `Agent.execute/3` would surface.

  ## Provider-side `tool_choice`

  Anthropic and OpenAI both let you require the model to call a specific tool
  via `tool_choice`. Setting this on your `ChatAnthropic` / `ChatOpenAI` model
  before passing it to `Agent.new/2` materially improves single-call
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

  Nothing here needs to know about either layer. They fall out of how
  `until_tool` already loops.

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
          max_runs: pos_integer()
        ]

  @doc """
  Run a structured extraction with the given agent and state.

  The `state` carries the full conversation (system messages, user prompts,
  any prior turns). See the module doc for option details.
  """
  @spec run(Agent.t(), State.t(), opts()) :: {:ok, map()} | {:error, term()}
  def run(%Agent{} = agent, %State{} = state, opts) when is_list(opts) do
    with {:ok, submit_tool} <- build_submit_tool(opts),
         :ok <- check_tool_name_unique(agent, submit_tool.name) do
      augmented_agent = %{agent | tools: agent.tools ++ [submit_tool]}
      max_runs = Keyword.get(opts, :max_runs, @default_max_runs)

      augmented_agent
      |> Agent.execute(state, until_tool: submit_tool.name, max_runs: max_runs)
      |> AgentResult.tool_arguments()
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
