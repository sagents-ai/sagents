defmodule Sagents.Mode.StepsTest do
  use ExUnit.Case, async: true

  alias Sagents.Mode.Steps
  alias LangChain.Chains.LLMChain
  alias LangChain.LangChainError

  describe "continue_or_done_safe/4" do
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
