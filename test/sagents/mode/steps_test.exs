defmodule Sagents.Mode.StepsTest do
  use ExUnit.Case, async: true

  alias Sagents.Mode.Steps
  alias Sagents.State
  alias Sagents.MiddlewareEntry
  alias Sagents.Middleware.HumanInTheLoop
  alias LangChain.Chains.LLMChain
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult

  # ── Helpers ──────────────────────────────────────────────────────

  defp chain_with_context(messages \\ [], custom_context \\ %{}) do
    chain = %LLMChain{
      messages: messages,
      exchanged_messages: messages,
      custom_context: custom_context
    }

    chain
  end

  defp assistant_with_tool_call(tool_name, call_id \\ "call_1") do
    tool_call =
      ToolCall.new!(%{
        status: :complete,
        call_id: call_id,
        name: tool_name,
        arguments: %{}
      })

    Message.new_assistant!(%{tool_calls: [tool_call]})
  end

  defp tool_result_message(call_id, content, processed_content \\ nil) do
    tool_result =
      ToolResult.new!(%{
        tool_call_id: call_id,
        name: "test_tool",
        content: content,
        processed_content: processed_content
      })

    Message.new_tool_result!(%{tool_results: [tool_result]})
  end

  defp hitl_middleware(interrupt_on) do
    {:ok, config} = HumanInTheLoop.init(interrupt_on: interrupt_on)

    %MiddlewareEntry{
      id: HumanInTheLoop,
      module: HumanInTheLoop,
      config: config
    }
  end

  # ── check_pre_tool_hitl/2 ──────────────────────────────────────

  describe "check_pre_tool_hitl/2" do
    test "continues when no middleware is configured" do
      chain = chain_with_context()
      result = Steps.check_pre_tool_hitl({:continue, chain}, [])

      assert {:continue, ^chain} = result
    end

    test "continues when middleware list has no HITL middleware" do
      non_hitl = %MiddlewareEntry{
        id: SomeOtherMiddleware,
        module: SomeOtherMiddleware,
        config: %{}
      }

      chain = chain_with_context()
      result = Steps.check_pre_tool_hitl({:continue, chain}, middleware: [non_hitl])

      assert {:continue, ^chain} = result
    end

    test "continues when HITL is present but no tool calls in messages" do
      hitl = hitl_middleware(%{"dangerous_tool" => true})
      # No assistant message with tool calls
      plain_msg = Message.new_assistant!(%{content: "Just text, no tools."})
      chain = chain_with_context([plain_msg], %{state: State.new!(%{agent_id: "test"})})

      result = Steps.check_pre_tool_hitl({:continue, chain}, middleware: [hitl])

      assert {:continue, ^chain} = result
    end

    test "interrupts when HITL tool call is detected" do
      hitl = hitl_middleware(%{"write_file" => true})

      assistant_msg = assistant_with_tool_call("write_file")

      chain =
        chain_with_context(
          [assistant_msg],
          %{state: State.new!(%{agent_id: "hitl-test"})}
        )

      result = Steps.check_pre_tool_hitl({:continue, chain}, middleware: [hitl])

      assert {:interrupt, ^chain, interrupt_data} = result
      assert is_map(interrupt_data)
      assert Map.has_key?(interrupt_data, :action_requests)
    end

    test "continues when tool call does not match HITL policy" do
      hitl = hitl_middleware(%{"dangerous_tool" => true})

      # Tool call for a non-HITL tool
      assistant_msg = assistant_with_tool_call("safe_tool")

      chain =
        chain_with_context(
          [assistant_msg],
          %{state: State.new!(%{agent_id: "no-match-test"})}
        )

      result = Steps.check_pre_tool_hitl({:continue, chain}, middleware: [hitl])

      assert {:continue, ^chain} = result
    end

    test "extracts agent_id from custom_context state" do
      hitl = hitl_middleware(%{"write_file" => true})
      assistant_msg = assistant_with_tool_call("write_file")

      chain =
        chain_with_context(
          [assistant_msg],
          %{state: State.new!(%{agent_id: "my-agent-123"})}
        )

      result = Steps.check_pre_tool_hitl({:continue, chain}, middleware: [hitl])

      assert {:interrupt, _chain, _data} = result
    end

    test "uses first HITL middleware when multiple middleware entries exist" do
      hitl = hitl_middleware(%{"write_file" => true})

      non_hitl = %MiddlewareEntry{
        id: SomeOtherMiddleware,
        module: SomeOtherMiddleware,
        config: %{}
      }

      assistant_msg = assistant_with_tool_call("write_file")

      chain =
        chain_with_context(
          [assistant_msg],
          %{state: State.new!(%{agent_id: "multi-mw-test"})}
        )

      # HITL is second in the list — Enum.find should still find it
      result = Steps.check_pre_tool_hitl({:continue, chain}, middleware: [non_hitl, hitl])

      assert {:interrupt, ^chain, _data} = result
    end

    test "passes through terminal tuples unchanged" do
      chain = %LLMChain{}

      assert {:ok, ^chain} = Steps.check_pre_tool_hitl({:ok, chain}, middleware: [])
      assert {:error, ^chain, "err"} = Steps.check_pre_tool_hitl({:error, chain, "err"}, [])

      assert {:interrupt, ^chain, %{}} =
               Steps.check_pre_tool_hitl({:interrupt, chain, %{}}, [])
    end
  end

  # ── propagate_state/2 ──────────────────────────────────────────

  describe "propagate_state/2" do
    test "does nothing when no tool results have State deltas" do
      plain_tool_result =
        tool_result_message("call_1", "plain text result")

      chain =
        chain_with_context(
          [assistant_with_tool_call("tool", "call_1"), plain_tool_result],
          %{state: State.new!(%{agent_id: "test"})}
        )

      result = Steps.propagate_state({:continue, chain}, [])

      assert {:continue, updated_chain} = result
      # Chain should be unchanged (no state deltas to merge)
      assert updated_chain.custom_context.state.agent_id == "test"
    end

    test "merges State delta from tool result processed_content" do
      state_delta = State.new!(%{agent_id: "delta", metadata: %{key: "value"}})

      tool_msg = tool_result_message("call_1", "text result", state_delta)

      chain =
        chain_with_context(
          [assistant_with_tool_call("tool", "call_1"), tool_msg],
          %{state: State.new!(%{agent_id: "original"})}
        )

      result = Steps.propagate_state({:continue, chain}, [])

      assert {:continue, updated_chain} = result
      merged_state = updated_chain.custom_context.state
      assert merged_state.metadata == %{key: "value"}
    end

    test "handles chain with no custom_context state gracefully" do
      tool_msg = tool_result_message("call_1", "result")

      chain =
        chain_with_context(
          [assistant_with_tool_call("tool", "call_1"), tool_msg],
          %{}
        )

      result = Steps.propagate_state({:continue, chain}, [])

      assert {:continue, _updated_chain} = result
    end

    test "handles chain with empty messages" do
      chain = chain_with_context([], %{state: State.new!(%{agent_id: "test"})})

      result = Steps.propagate_state({:continue, chain}, [])

      assert {:continue, ^chain} = result
    end

    test "handles tool_results being nil" do
      # Create a tool message with nil tool_results
      tool_msg = %Message{role: :tool, tool_results: nil}

      chain =
        chain_with_context(
          [tool_msg],
          %{state: State.new!(%{agent_id: "test"})}
        )

      result = Steps.propagate_state({:continue, chain}, [])

      assert {:continue, _chain} = result
    end

    test "passes through terminal tuples unchanged" do
      chain = %LLMChain{}

      assert {:ok, ^chain} = Steps.propagate_state({:ok, chain}, [])
      assert {:error, ^chain, "err"} = Steps.propagate_state({:error, chain, "err"}, [])
      assert {:interrupt, ^chain, %{}} = Steps.propagate_state({:interrupt, chain, %{}}, [])
    end
  end

  # ── continue_or_done_safe/3 ────────────────────────────────────

  describe "continue_or_done_safe/3" do
    test "without until_tool active, needs_response true calls run_fn (loops)" do
      chain = %LLMChain{needs_response: true}
      opts = []

      run_fn = fn returned_chain, _opts ->
        {:ok, returned_chain}
      end

      result = Steps.continue_or_done_safe({:continue, chain}, run_fn, opts)

      assert {:ok, ^chain} = result
    end

    test "without until_tool active, needs_response false returns {:ok, chain}" do
      chain = %LLMChain{needs_response: false}
      opts = []

      run_fn = fn _chain, _opts ->
        flunk("run_fn should not be called when needs_response is false")
      end

      result = Steps.continue_or_done_safe({:continue, chain}, run_fn, opts)

      assert {:ok, ^chain} = result
    end

    test "with until_tool active, needs_response true calls run_fn (loops)" do
      chain = %LLMChain{needs_response: true}
      opts = [until_tool_active: true, tool_names: ["submit_report"]]

      run_fn = fn returned_chain, _opts ->
        {:ok, returned_chain}
      end

      result = Steps.continue_or_done_safe({:continue, chain}, run_fn, opts)

      assert {:ok, ^chain} = result
    end

    test "with until_tool active, needs_response false returns error with tool names" do
      chain = %LLMChain{needs_response: false}
      tool_names = ["submit_report", "finalize"]
      opts = [until_tool_active: true, tool_names: tool_names]

      run_fn = fn _chain, _opts ->
        flunk("run_fn should not be called when needs_response is false")
      end

      result = Steps.continue_or_done_safe({:continue, chain}, run_fn, opts)

      assert {:error, ^chain, %LangChainError{type: "until_tool_not_called"} = error} = result
      assert error.message =~ "submit_report"
      assert error.message =~ "finalize"
      assert error.message =~ "Agent completed without calling target tool(s)"
    end

    test "terminal {:ok, chain} passes through unchanged" do
      chain = %LLMChain{}

      run_fn = fn _chain, _opts ->
        flunk("run_fn should not be called for terminal tuples")
      end

      result = Steps.continue_or_done_safe({:ok, chain}, run_fn, [])

      assert {:ok, ^chain} = result
    end

    test "terminal {:ok, chain, extra} passes through unchanged" do
      chain = %LLMChain{}
      extra = %{some: "data"}

      run_fn = fn _chain, _opts ->
        flunk("run_fn should not be called for terminal tuples")
      end

      result = Steps.continue_or_done_safe({:ok, chain, extra}, run_fn, [])

      assert {:ok, ^chain, ^extra} = result
    end

    test "terminal {:error, chain, reason} passes through unchanged" do
      chain = %LLMChain{}
      reason = "something went wrong"

      run_fn = fn _chain, _opts ->
        flunk("run_fn should not be called for terminal tuples")
      end

      result = Steps.continue_or_done_safe({:error, chain, reason}, run_fn, [])

      assert {:error, ^chain, ^reason} = result
    end

    test "terminal {:interrupt, chain, data} passes through unchanged" do
      chain = %LLMChain{}
      interrupt_data = %{action: "approve"}

      run_fn = fn _chain, _opts ->
        flunk("run_fn should not be called for terminal tuples")
      end

      result = Steps.continue_or_done_safe({:interrupt, chain, interrupt_data}, run_fn, [])

      assert {:interrupt, ^chain, ^interrupt_data} = result
    end

    test "terminal {:pause, chain} passes through unchanged" do
      chain = %LLMChain{}

      run_fn = fn _chain, _opts ->
        flunk("run_fn should not be called for terminal tuples")
      end

      result = Steps.continue_or_done_safe({:pause, chain}, run_fn, [])

      assert {:pause, ^chain} = result
    end
  end
end
