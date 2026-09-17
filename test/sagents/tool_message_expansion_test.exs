defmodule Sagents.ToolMessageExpansionTest do
  @moduledoc """
  A tool result can expand into messages rather than reaching the model as
  tool-result content, and the model reads them on its very next LLM call in the
  same run.

  These cover the agent layer: what reaches `Sagents.State`, what reaches a
  host's transcript, and what survives storage.
  """
  use Sagents.BaseCase, async: true
  use Mimic

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias LangChain.MessageExpansion
  alias Sagents.Agent
  alias Sagents.Persistence.StateSerializer
  alias Sagents.State

  setup :verify_on_exit!

  @material "POLICY SECTION 4: refunds are issued within 30 days."

  defp loading_tool do
    Function.new!(%{
      name: "load_reference",
      description: "Load the reference material",
      parameters_schema: %{type: "object", properties: %{}},
      function: fn _args, _ctx ->
        MessageExpansion.expand(
          "Loaded 1 document.\n\n" <> @material,
          [
            Message.new_assistant!(@material),
            Message.new_user!("Answer using the policy above.")
          ],
          result_content: "Loaded 1 document."
        )
      end
    })
  end

  # A tool taking full control of its result: it expands into messages *and*
  # returns a state delta on `processed_content`, the slot that stays the tool
  # author's.
  defp loading_tool_with_state_delta do
    Function.new!(%{
      name: "load_reference",
      description: "Load the reference material",
      parameters_schema: %{type: "object", properties: %{}},
      function: fn _args, _ctx ->
        {:ok, staged} =
          MessageExpansion.expand(
            "Loaded 1 document.\n\n" <> @material,
            [Message.new_assistant!(@material)],
            result_content: "Loaded 1 document."
          )

        {:ok,
         %ToolResult{
           staged
           | processed_content: %State{
               todos: [%{"id" => "1", "content" => "Answer the question", "status" => "pending"}]
             }
         }}
      end
    })
  end

  defp tool_call(name, call_id) do
    ToolCall.new!(%{status: :complete, call_id: call_id, name: name, arguments: %{}})
  end

  defp calls_loader do
    {:ok, [Message.new_assistant!(%{tool_calls: [tool_call("load_reference", "call_1")]})]}
  end

  defp text_of(%Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%ContentPart{type: :text}, &1))
    |> Enum.map_join(" ", & &1.content)
  end

  defp text_of(%Message{content: content}) when is_binary(content), do: content
  defp text_of(%Message{}), do: ""

  defp agent_with(tools, opts \\ []) do
    {:ok, agent} =
      Agent.new(
        %{
          model: mock_model(),
          tools: tools,
          base_system_prompt: "Test agent",
          middleware: Keyword.get(opts, :middleware, [])
        },
        [replace_default_middleware: true] ++ Keyword.take(opts, [:interrupt_on])
      )

    agent
  end

  describe "Agent.execute/3" do
    test "the inserted messages are part of the state the run returns" do
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools -> calls_loader() end)
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("30 days.")]}
      end)

      state = State.new!(%{messages: [Message.new_user!("Policy?")]})

      assert {:ok, %State{} = final_state} =
               Agent.execute(agent_with([loading_tool()]), state)

      assert [
               %Message{role: :user},
               %Message{role: :assistant, tool_calls: [_call]},
               %Message{role: :tool},
               %Message{role: :assistant} = material,
               %Message{role: :user} = anchor,
               %Message{role: :assistant}
             ] = final_state.messages

      assert text_of(material) == @material
      assert text_of(anchor) == "Answer using the policy above."
    end

    test "the inserted messages produce no transcript rows" do
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools -> calls_loader() end)
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("30 days.")]}
      end)

      test_pid = self()

      callbacks = [
        %{
          on_message_processed: fn _chain, message ->
            send(test_pid, {:processed, message})
          end
        }
      ]

      state = State.new!(%{messages: [Message.new_user!("Policy?")]})

      assert {:ok, %State{}} =
               Agent.execute(agent_with([loading_tool()]), state, callbacks: callbacks)

      announced = collect_processed()

      # The model's turns and the tool result are announced. The inserted
      # messages are conversation state, not transcript, exactly like a queued
      # message sent with `display: :none`.
      assert Enum.any?(announced, &(&1.role == :tool))
      refute Enum.any?(announced, &(text_of(&1) =~ @material))
      refute Enum.any?(announced, &(text_of(&1) =~ "Answer using the policy above."))
    end

    test "a tool can expand into messages and return a state delta" do
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools -> calls_loader() end)
      |> expect(:call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("30 days.")]}
      end)

      state = State.new!(%{messages: [Message.new_user!("Policy?")]})

      assert {:ok, %State{} = final_state} =
               Agent.execute(agent_with([loading_tool_with_state_delta()]), state)

      assert [%{"content" => "Answer the question"}] = final_state.todos

      assert 1 = Enum.count(final_state.messages, &(text_of(&1) == @material))
    end
  end

  describe "a tool gated behind human approval" do
    test "expands on the first LLM call after the resume" do
      test_pid = self()

      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools -> calls_loader() end)
      # Called during the resume, once the approved tool has run.
      |> expect(:call, fn _model, messages, _tools ->
        send(test_pid, {:after_resume, messages})
        {:ok, [Message.new_assistant!("30 days.")]}
      end)

      agent =
        agent_with([loading_tool()],
          middleware: [
            {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{"load_reference" => true}]}
          ],
          interrupt_on: %{"load_reference" => true}
        )

      state = State.new!(%{messages: [Message.new_user!("Policy?")]})

      assert {:interrupt, interrupted_state, %{action_requests: [request]}} =
               Agent.execute(agent, state)

      assert request.tool_name == "load_reference"
      # The tool has not run, so nothing is expanded yet.
      refute Enum.any?(interrupted_state.messages, &(text_of(&1) =~ @material))

      assert {:ok, %State{} = final_state} =
               Agent.resume(agent, interrupted_state, [%{type: :approve}])

      # The approved tool ran outside the pipeline, so the resumed run starts
      # with a chain it did not build. The expansion still lands before the
      # model is asked to continue.
      assert_received {:after_resume, messages}

      assert Enum.any?(messages, fn message ->
               message.role == :assistant and text_of(message) == @material
             end)

      assert %Message{role: :user} = List.last(messages)

      assert Enum.any?(final_state.messages, fn message ->
               message.role == :assistant and text_of(message) == @material
             end)

      trimmed = Enum.find(final_state.messages, &(&1.role == :tool))

      assert [%ToolResult{content: [%ContentPart{content: "Loaded 1 document."}]}] =
               trimmed.tool_results
    end
  end

  describe "storage" do
    test "an unapplied expansion does not survive a round trip" do
      {:ok, staged} =
        MessageExpansion.expand(
          "Loaded 1 document.\n\n" <> @material,
          [Message.new_assistant!(@material)],
          result_content: "Loaded 1 document."
        )

      result = %ToolResult{staged | tool_call_id: "call_1", name: "load_reference"}

      state =
        State.new!(%{
          agent_id: "agent-1",
          messages: [
            Message.new_user!("Policy?"),
            Message.new_tool_result!(%{content: nil, tool_results: [result]})
          ]
        })

      restored =
        state
        |> StateSerializer.serialize_state()
        |> then(&StateSerializer.deserialize_state("agent-1", &1))

      assert {:ok, %State{} = restored} = restored
      assert [_user, %Message{role: :tool} = tool_message] = restored.messages
      assert [%ToolResult{message_expansion: nil} = restored_result] = tool_message.tool_results

      # Expansion is at-most-once across storage, and what the model can still
      # read is the fail-open copy the tool put in its result.
      assert [%ContentPart{content: text}] = restored_result.content
      assert text =~ @material
    end
  end

  defp collect_processed(acc \\ []) do
    receive do
      {:processed, message} -> collect_processed([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
