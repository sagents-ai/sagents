defmodule Sagents.NarrationContinuationTest do
  @moduledoc """
  An assistant message whose text is entirely narration is the model saying
  what it is about to do, not its reply. The turn is not over, so the agent
  calls the model again rather than reporting the run finished.

  These tests stub the HTTP call rather than the chat model, so the adapter
  decodes a real provider body and the marker reaches the agent the way it does
  in a live run. Each adapter that speaks the OpenAI Responses API is covered,
  because they carry the label differently: one reads it off each output item,
  the other off metadata belonging to the whole message.

  The control in each block is what makes the rest meaningful: an unmarked
  assistant message still ends the turn after a single call.

  A provider can also state the turn boundary outright with `end_turn`, which
  decides ahead of the narration marker. A response the provider cut off ends
  the run as an error without running its partial tool calls.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias LangChain.ChatModels.ChatOpenAIResponses
  alias LangChain.ChatModels.ChatReqLLM
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias Sagents.Agent
  alias Sagents.State

  setup :set_mimic_global
  setup :verify_on_exit!

  @commentary "I'll check the deployment status first."
  @answer "It failed because the image tag does not exist."

  defp inspect_tool(test_pid) do
    Function.new!(%{
      name: "inspect_resource",
      description: "Inspect a deployment resource",
      parameters_schema: %{
        type: "object",
        properties: %{name: %{type: "string", description: "Resource name"}},
        required: ["name"]
      },
      function: fn args, _context ->
        send(test_pid, {:tool_ran, args})
        {:ok, "status: ImagePullBackOff"}
      end
    })
  end

  defp run_agent(model, tools) do
    {:ok, agent} =
      Agent.new(%{model: model, tools: tools}, replace_default_middleware: true)

    Agent.execute(agent, State.new!(%{messages: [Message.new_user!("why did it fail")]}))
  end

  defp assistant_messages(%State{messages: messages}) do
    Enum.filter(messages, &(&1.role == :assistant))
  end

  defp utterances(%Message{content: parts}) when is_list(parts) do
    for %ContentPart{type: :text} = part <- parts, do: ContentPart.utterance(part)
  end

  # ── the Responses API, decoded by ChatOpenAIResponses ──────────────

  defp responses_body(items) do
    %{
      "id" => "resp_#{System.unique_integer([:positive])}",
      "object" => "response",
      "status" => "completed",
      "model" => "gpt-5.4",
      "output" => items,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
    }
  end

  defp message_item(phase, text) do
    item = %{
      "id" => "msg_#{System.unique_integer([:positive])}",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }

    if phase, do: Map.put(item, "phase", phase), else: item
  end

  defp function_call_item(name, args) do
    %{
      "id" => "fc_#{System.unique_integer([:positive])}",
      "type" => "function_call",
      "status" => "completed",
      "call_id" => "call_#{System.unique_integer([:positive])}",
      "name" => name,
      "arguments" => Jason.encode!(args)
    }
  end

  defp expect_posts(bodies) do
    Enum.reduce(bodies, Req, fn body, mod ->
      expect(mod, :post, fn _req ->
        {:ok, %Req.Response{status: 200, body: body}}
      end)
    end)
  end

  describe "ChatOpenAIResponses" do
    setup do
      %{model: ChatOpenAIResponses.new!(%{model: "gpt-5.4", api_key: "test"})}
    end

    test "a commentary-only response does not end the turn", %{model: model} do
      expect_posts([
        responses_body([message_item("commentary", @commentary)]),
        responses_body([message_item("final_answer", @answer)])
      ])

      assert {:ok, state} = run_agent(model, [])

      assert [narration, answer] = assistant_messages(state)
      assert utterances(narration) == ["narration"]
      assert utterances(answer) == ["answer"]
      assert Message.answer_content(answer) == @answer
      assert Message.narration?(narration)
    end

    test "commentary, a tool call, then the answer runs the whole trajectory", %{model: model} do
      expect_posts([
        responses_body([message_item("commentary", @commentary)]),
        responses_body([function_call_item("inspect_resource", %{"name" => "web"})]),
        responses_body([message_item("final_answer", @answer)])
      ])

      assert {:ok, state} = run_agent(model, [inspect_tool(self())])

      assert_received {:tool_ran, %{"name" => "web"}}

      assert Message.answer_content(List.last(state.messages)) == @answer
      assert Enum.any?(state.messages, &(&1.role == :tool))
    end

    test "an unmarked assistant message ends the turn (control)", %{model: model} do
      expect_posts([responses_body([message_item(nil, @answer)])])

      assert {:ok, state} = run_agent(model, [])

      assert [only] = assistant_messages(state)
      assert utterances(only) == [nil]
      refute Message.narration?(only)
    end
  end

  # ── the provider's end_turn report ─────────────────────────────────

  describe "end_turn" do
    setup do
      %{model: ChatOpenAIResponses.new!(%{model: "gpt-5.4", api_key: "test"})}
    end

    test "end_turn: false keeps the turn open on an unmarked message", %{model: model} do
      expect_posts([
        [message_item(nil, @commentary)] |> responses_body() |> Map.put("end_turn", false),
        responses_body([message_item(nil, @answer)])
      ])

      assert {:ok, state} = run_agent(model, [])

      assert [first, answer] = assistant_messages(state)
      assert Message.end_turn(first) == false
      refute Message.narration?(first)
      assert Message.answer_content(answer) == @answer
    end

    test "end_turn: true ends the turn on a commentary-only message", %{model: model} do
      expect_posts([
        [message_item("commentary", @commentary)]
        |> responses_body()
        |> Map.put("end_turn", true)
      ])

      assert {:ok, state} = run_agent(model, [])

      assert [only] = assistant_messages(state)
      assert Message.narration?(only)
      assert Message.end_turn(only) == true
    end
  end

  # ── responses the provider cut off ─────────────────────────────────

  describe "truncated responses" do
    setup do
      %{model: ChatOpenAIResponses.new!(%{model: "gpt-5.4", api_key: "test"})}
    end

    defp incomplete_body(items, reason) do
      items
      |> responses_body()
      |> Map.put("status", "incomplete")
      |> Map.put("incomplete_details", %{"reason" => reason})
    end

    test "running out of output tokens ends the run without running the partial call",
         %{model: model} do
      partial_call =
        "inspect_resource"
        |> function_call_item(%{})
        |> Map.put("status", "incomplete")
        |> Map.put("arguments", ~s({"name": "we))

      expect_posts([incomplete_body([partial_call], "max_output_tokens")])

      assert {:error, error} = run_agent(model, [inspect_tool(self())])

      assert error.type == "response_truncated"
      refute_received {:tool_ran, _args}
    end

    test "a content-filtered response ends the run", %{model: model} do
      expect_posts([incomplete_body([message_item(nil, "partial")], "content_filter")])

      assert {:error, error} = run_agent(model, [])

      assert error.type == "content_filtered"
    end
  end

  # ── the same API through req_llm, which labels the whole message ───

  describe "ChatReqLLM" do
    setup do
      %{model: ChatReqLLM.new!(%{model: "openai:gpt-5.4", api_key: "test"})}
    end

    defp req_llm_response(text, metadata) do
      %ReqLLM.Response{
        id: "resp_#{System.unique_integer([:positive])}",
        model: "gpt-5.4",
        context: ReqLLM.Context.new([]),
        message: %ReqLLM.Message{
          role: :assistant,
          content: [ReqLLM.Message.ContentPart.text(text)],
          tool_calls: nil,
          metadata: metadata
        },
        finish_reason: :stop,
        usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
        object: nil,
        stream?: false,
        stream: nil,
        provider_meta: %{},
        error: nil
      }
    end

    defp expect_generates(responses) do
      Enum.reduce(responses, ReqLLM, fn response, mod ->
        expect(mod, :generate_text, fn _model, _context, _opts -> {:ok, response} end)
      end)
    end

    test "a commentary-only response does not end the turn", %{model: model} do
      expect_generates([
        req_llm_response(@commentary, %{phase: "commentary"}),
        req_llm_response(@answer, %{phase: "final_answer"})
      ])

      assert {:ok, state} = run_agent(model, [])

      assert [narration, answer] = assistant_messages(state)
      assert utterances(narration) == ["narration"]
      assert utterances(answer) == ["answer"]
      assert Message.narration?(narration)
      assert Message.answer_content(answer) == @answer
    end

    test "commentary joined onto the answer is split, and ends the turn", %{model: model} do
      # req_llm joins every message item's text into one part and reports the
      # items separately. The joined text holds an answer, so the turn ends on
      # it; what the split buys is an answer that can be read on its own.
      response =
        req_llm_response(@commentary <> @answer, %{
          phase_items: [
            %{
              "phase" => "commentary",
              "content" => [%{"type" => "output_text", "text" => @commentary}]
            },
            %{
              "phase" => "final_answer",
              "content" => [%{"type" => "output_text", "text" => @answer}]
            }
          ]
        })

      expect_generates([response])

      assert {:ok, state} = run_agent(model, [])

      assert [message] = assistant_messages(state)
      assert utterances(message) == ["narration", "answer"]
      refute Message.narration?(message)
      assert Message.answer_content(message) == @answer
    end

    test "an unmarked assistant message ends the turn (control)", %{model: model} do
      expect_generates([req_llm_response(@answer, %{})])

      assert {:ok, state} = run_agent(model, [])

      assert [only] = assistant_messages(state)
      assert utterances(only) == [nil]
      refute Message.narration?(only)
    end
  end

  # ── the until_tool contract ────────────────────────────────────────

  describe "until_tool runs" do
    setup do
      %{model: ChatOpenAIResponses.new!(%{model: "gpt-5.4", api_key: "test"})}
    end

    test "narration before the target tool is not a failure to call it", %{model: model} do
      # An until_tool run reports `until_tool_not_called` when the chain stops
      # without reaching the tool. Narration used to stop the chain, so the
      # error named the wrong cause: the model had not declined to call the
      # tool, it had not finished speaking yet.
      expect_posts([
        responses_body([message_item("commentary", @commentary)]),
        responses_body([function_call_item("inspect_resource", %{"name" => "web"})])
      ])

      {:ok, agent} =
        Agent.new(%{model: model, tools: [inspect_tool(self())]},
          replace_default_middleware: true
        )

      state = State.new!(%{messages: [Message.new_user!("why did it fail")]})

      assert {:ok, final, tool_result} =
               Agent.execute(agent, state, until_tool: "inspect_resource")

      assert_received {:tool_ran, %{"name" => "web"}}
      assert tool_result.name == "inspect_resource"

      assert [narration | _rest] = assistant_messages(final)
      assert Message.narration?(narration)
    end

    test "a genuine failure to call the tool still reports itself", %{model: model} do
      # The control. An answer without the tool is a real until_tool_not_called,
      # and continuing on narration must not have masked it.
      expect_posts([responses_body([message_item("final_answer", @answer)])])

      {:ok, agent} =
        Agent.new(%{model: model, tools: [inspect_tool(self())]},
          replace_default_middleware: true
        )

      state = State.new!(%{messages: [Message.new_user!("why did it fail")]})

      assert {:error, error} = Agent.execute(agent, state, until_tool: "inspect_resource")

      assert error.type == "until_tool_not_called"
      refute_received {:tool_ran, _args}
    end
  end
end
