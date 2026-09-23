defmodule Sagents.NarrationContinuationLiveTest do
  @moduledoc """
  A real agent run against the OpenAI Responses API, through each adapter that
  speaks it.

  The model labels an assistant message item as commentary when it is saying
  what it intends to do. A run that ends on one has stopped mid-turn: the
  caller gets a sentence of intent and no answer.

  What these tests assert is the property a user cares about, that the run
  reaches an answer and that any narration on the way is marked as narration.
  They do not assert that a commentary-only response occurred, because whether
  the model sends one is its own decision; it usually attaches the tool calls
  to the same response, which keeps the turn going for a different reason. The
  trajectory each run took is printed so a miss is visible rather than silent.

  Run with:

      mix test test/sagents/narration_continuation_live_test.exs --include live_open_ai

  Override the model with `OPENAI_PHASE_TEST_MODEL`.
  """
  use ExUnit.Case, async: false

  alias LangChain.ChatModels.ChatOpenAIResponses
  alias LangChain.ChatModels.ChatReqLLM
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias Sagents.Agent
  alias Sagents.State

  @moduletag live_call: true, live_open_ai: true
  @moduletag timeout: 600_000

  @default_model "gpt-5.4"

  # Asks the model to speak before it acts, which is what produces a commentary
  # item, and to hand the plan over on its own, which is what can leave that
  # item alone in a response with nothing attached.
  @system_prompt """
  <tool_preambles>
  - Always begin by rephrasing the user's goal in a friendly, clear, and concise manner, before calling any tools.
  - Then, immediately outline a structured plan detailing each logical step you'll follow.
  - As you execute each step, narrate it succinctly and sequentially, marking progress clearly.
  - Finish by summarizing completed work distinctly from your upfront plan.
  </tool_preambles>

  Send your restated goal and your plan as your first reply, on its own. Do not
  call any tools in that same reply. Begin calling tools only after that reply
  has been sent.
  """

  @user_prompt "why did this deploy fail, check a bunch of things pls"

  setup do
    api_key = System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      raise "OPENAI_API_KEY is not set. Source the project's .env before running live tests."
    end

    %{model_id: System.get_env("OPENAI_PHASE_TEST_MODEL", @default_model)}
  end

  defp inspect_tool do
    Function.new!(%{
      name: "inspect_resource",
      description:
        "Inspect one deployment resource and return what it reports. " <>
          "Valid kinds: deployment_status, events, pod_logs, image_detail.",
      parameters_schema: %{
        type: "object",
        properties: %{
          kind: %{type: "string", description: "Which resource to inspect"}
        },
        required: ["kind"]
      },
      function: fn args, _context ->
        {:ok, canned_result(args["kind"])}
      end
    })
  end

  defp canned_result("deployment_status"), do: "status: ImagePullBackOff, replicas 0/3"
  defp canned_result("events"), do: "Failed to pull image: manifest unknown"
  defp canned_result("pod_logs"), do: "no logs, the container never started"

  defp canned_result("image_detail"),
    do: "registry.internal/app:v4.2.1 => manifest unknown"

  defp canned_result(other), do: "unknown resource #{inspect(other)}"

  defp run_and_report(label, model) do
    {:ok, agent} =
      Agent.new(
        %{
          model: model,
          base_system_prompt: @system_prompt,
          tools: [inspect_tool()]
        },
        replace_default_middleware: true
      )

    state = State.new!(%{messages: [Message.new_user!(@user_prompt)]})
    result = Agent.execute(agent, state, max_runs: 12)

    IO.puts("\n=== #{label} ===")

    case result do
      {:ok, final} ->
        report_trajectory(final)
        final

      other ->
        IO.puts("run did not complete: #{inspect(other, limit: 5)}")
        flunk("#{label}: agent did not complete, got #{inspect(elem(other, 0))}")
    end
  end

  defp report_trajectory(%State{messages: messages}) do
    Enum.each(messages, fn message ->
      IO.puts("  #{describe(message)}")
    end)

    assistants = Enum.filter(messages, &(&1.role == :assistant))

    IO.puts("  ---")
    IO.puts("  assistant messages: #{length(assistants)}")
    IO.puts("  tool results: #{Enum.count(messages, &(&1.role == :tool))}")

    IO.puts(
      "  commentary-only responses (the shape that used to stop the run): " <>
        "#{Enum.count(assistants, &Message.narration?/1)}"
    )
  end

  defp describe(%Message{role: :tool, tool_results: results}) when is_list(results) do
    "tool     #{Enum.map_join(results, ", ", & &1.name)}"
  end

  defp describe(%Message{role: role, content: parts, tool_calls: calls}) do
    marks =
      case parts do
        parts when is_list(parts) ->
          for %ContentPart{type: :text} = part <- parts do
            "#{ContentPart.utterance(part) || "unmarked"}(#{String.length(part.content || "")}ch)"
          end
          |> Enum.join(" ")

        text when is_binary(text) ->
          "text(#{String.length(text)}ch)"

        _other ->
          ""
      end

    tools =
      case calls do
        [_call | _rest] -> " +tools[#{Enum.map_join(calls, ",", & &1.name)}]"
        _none -> ""
      end

    "#{String.pad_trailing(to_string(role), 8)} #{marks}#{tools}"
  end

  defp assert_reached_an_answer(label, %State{messages: messages} = state) do
    last = List.last(messages)

    assert last.role == :assistant,
           "#{label}: the run ended on a #{last.role} message, not the model's reply"

    refute Message.narration?(last),
           "#{label}: the run ended on narration, which is the bug this guards. " <>
             "Last message: #{inspect(ContentPart.content_to_string(last.content))}"

    answer = Message.answer_content(last)

    assert is_binary(answer) and answer != "",
           "#{label}: the final message carried no answer text"

    # Narration that did occur is labelled, so a caller can tell it from a
    # reply. Nothing asserts that narration happened; that is the model's call.
    for message <- Enum.filter(messages, &(&1.role == :assistant)),
        Message.narration?(message) do
      assert Message.answer_content(message) in [nil, ""],
             "#{label}: a message marked entirely narration also carried answer text"
    end

    state
  end

  test "ChatOpenAIResponses: a narrated run reaches an answer", %{model_id: model_id} do
    model = ChatOpenAIResponses.new!(%{model: model_id, stream: false})

    "ChatOpenAIResponses (non-streaming)"
    |> run_and_report(model)
    |> then(&assert_reached_an_answer("ChatOpenAIResponses", &1))
  end

  test "ChatOpenAIResponses streaming: a narrated run reaches an answer", %{model_id: model_id} do
    model = ChatOpenAIResponses.new!(%{model: model_id, stream: true})

    "ChatOpenAIResponses (streaming)"
    |> run_and_report(model)
    |> then(&assert_reached_an_answer("ChatOpenAIResponses streaming", &1))
  end

  test "ChatReqLLM on the Responses API: a narrated run reaches an answer", %{model_id: model_id} do
    model = ChatReqLLM.new!(%{model: "openai:#{model_id}", stream: false})

    "ChatReqLLM (non-streaming)"
    |> run_and_report(model)
    |> then(&assert_reached_an_answer("ChatReqLLM", &1))
  end

  test "ChatReqLLM streaming: a narrated run reaches an answer", %{model_id: model_id} do
    model = ChatReqLLM.new!(%{model: "openai:#{model_id}", stream: true})

    "ChatReqLLM (streaming)"
    |> run_and_report(model)
    |> then(&assert_reached_an_answer("ChatReqLLM streaming", &1))
  end
end
