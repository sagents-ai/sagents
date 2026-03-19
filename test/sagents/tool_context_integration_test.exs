defmodule Sagents.ToolContextIntegrationTest do
  use ExUnit.Case
  use Mimic

  alias Sagents.Agent
  alias Sagents.State
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Function

  describe "tool_context flows from Agent struct to tool function" do
    setup do
      model = ChatOpenAI.new!(%{model: "gpt-4", stream: false, temperature: 0})
      {:ok, model: model}
    end

    test "tool function receives caller-supplied context", %{model: model} do
      test_pid = self()

      check_context_tool =
        Function.new!(%{
          name: "check_context",
          description: "Receives and reports context",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, context ->
            send(test_pid, {:received_context, context})
            {:ok, "context received"}
          end
        })

      stub(ChatOpenAI, :call, fn _model, messages, _tools ->
        case length(messages) do
          2 ->
            {:ok,
             [
               Message.new_assistant!(%{
                 tool_calls: [
                   ToolCall.new!(%{
                     call_id: "call_ctx_1",
                     name: "check_context",
                     arguments: %{}
                   })
                 ]
               })
             ]}

          _ ->
            {:ok, [Message.new_assistant!("Done.")]}
        end
      end)

      {:ok, agent} =
        Agent.new(%{
          model: model,
          tool_context: %{user_id: 42, tenant: "acme"},
          tools: [check_context_tool],
          replace_default_middleware: true,
          middleware: []
        })

      state =
        State.new!(%{
          messages: [Message.new_user!("Call check_context")]
        })

      {:ok, _final_state} = Agent.execute(agent, state)

      assert_received {:received_context, ctx}
      # Caller context is present
      assert ctx.user_id == 42
      assert ctx.tenant == "acme"
      # Internal sagents context is still present
      assert Map.has_key?(ctx, :state)
      assert Map.has_key?(ctx, :parent_middleware)
      assert Map.has_key?(ctx, :parent_tools)
    end

    test "tool_context defaults to empty map — internal context still flows", %{model: model} do
      test_pid = self()

      check_context_tool =
        Function.new!(%{
          name: "check_context",
          description: "Receives and reports context",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, context ->
            send(test_pid, {:received_context, context})
            {:ok, "ok"}
          end
        })

      stub(ChatOpenAI, :call, fn _model, messages, _tools ->
        case length(messages) do
          2 ->
            {:ok,
             [
               Message.new_assistant!(%{
                 tool_calls: [
                   ToolCall.new!(%{
                     call_id: "call_ctx_2",
                     name: "check_context",
                     arguments: %{}
                   })
                 ]
               })
             ]}

          _ ->
            {:ok, [Message.new_assistant!("Done.")]}
        end
      end)

      {:ok, agent} =
        Agent.new(%{
          model: model,
          tools: [check_context_tool],
          replace_default_middleware: true,
          middleware: []
        })

      state =
        State.new!(%{
          messages: [Message.new_user!("Call check_context")]
        })

      {:ok, _final_state} = Agent.execute(agent, state)

      assert_received {:received_context, ctx}
      assert Map.has_key?(ctx, :state)
      assert Map.has_key?(ctx, :parent_middleware)
      assert Map.has_key?(ctx, :parent_tools)
    end

    test "internal keys take precedence over tool_context keys on collision", %{model: model} do
      test_pid = self()

      check_context_tool =
        Function.new!(%{
          name: "check_context",
          description: "Receives and reports context",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, context ->
            send(test_pid, {:received_context, context})
            {:ok, "ok"}
          end
        })

      stub(ChatOpenAI, :call, fn _model, messages, _tools ->
        case length(messages) do
          2 ->
            {:ok,
             [
               Message.new_assistant!(%{
                 tool_calls: [
                   ToolCall.new!(%{
                     call_id: "call_ctx_3",
                     name: "check_context",
                     arguments: %{}
                   })
                 ]
               })
             ]}

          _ ->
            {:ok, [Message.new_assistant!("Done.")]}
        end
      end)

      {:ok, agent} =
        Agent.new(%{
          model: model,
          # Caller tries to set "state" — internal must win
          tool_context: %{state: "caller_value", user_id: 99},
          tools: [check_context_tool],
          replace_default_middleware: true,
          middleware: []
        })

      state =
        State.new!(%{
          messages: [Message.new_user!("Call check_context")]
        })

      {:ok, _final_state} = Agent.execute(agent, state)

      assert_received {:received_context, ctx}
      # Internal state struct must not be overwritten by caller string
      refute ctx.state == "caller_value"
      assert %State{} = ctx.state
      # But non-colliding caller context survives
      assert ctx.user_id == 99
    end
  end
end
