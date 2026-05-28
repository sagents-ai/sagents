defmodule Sagents.Middleware.HaltableTest do
  use ExUnit.Case, async: true

  alias Sagents.Middleware
  alias Sagents.Middleware.Haltable
  alias Sagents.State

  describe "init/1" do
    test "accepts empty options" do
      assert {:ok, %{}} = Haltable.init([])
    end

    test "accepts arbitrary opts as map" do
      assert {:ok, %{custom: true}} = Haltable.init(custom: true)
    end
  end

  describe "system_prompt/1 and tools/1" do
    test "contributes no system prompt" do
      assert Haltable.system_prompt(%{}) == ""
    end

    test "contributes no tools" do
      assert Haltable.tools(%{}) == []
    end
  end

  describe "restorable_interrupt?/1" do
    test "returns true for :halt interrupt data" do
      assert Haltable.restorable_interrupt?(%{type: :halt, message: "stop"})
    end

    test "returns true for :multiple_interrupts containing any :halt" do
      data = %{
        type: :multiple_interrupts,
        interrupts: [
          %{type: :ask_user_question, question: "?"},
          %{type: :halt, message: "stop"}
        ]
      }

      assert Haltable.restorable_interrupt?(data)
    end

    test "returns false for :multiple_interrupts with no :halt" do
      data = %{
        type: :multiple_interrupts,
        interrupts: [%{type: :ask_user_question, question: "?"}]
      }

      refute Haltable.restorable_interrupt?(data)
    end

    test "returns false for unrelated interrupt types" do
      refute Haltable.restorable_interrupt?(%{type: :ask_user_question})
      refute Haltable.restorable_interrupt?(%{type: :subagent_hitl})
      refute Haltable.restorable_interrupt?(%{})
    end
  end

  describe "handle_resume/5 cold-start re-surface" do
    test "re-emits the halt interrupt when resume_data is nil" do
      halt = %{
        type: :halt,
        message: "Outline too coarse",
        source_tool: "scout_outline",
        tool_call_id: "call_1"
      }

      state = State.new!(%{interrupt_data: halt})

      assert {:interrupt, ^state, ^halt} =
               Haltable.handle_resume(nil, state, nil, %{}, [])
    end

    test "re-emits :multiple_interrupts when it contains a :halt" do
      halt = %{type: :halt, message: "stop", source_tool: "scout"}
      question = %{type: :ask_user_question, question: "?"}

      data = %{type: :multiple_interrupts, interrupts: [question, halt]}
      state = State.new!(%{interrupt_data: data})

      assert {:interrupt, ^state, ^data} =
               Haltable.handle_resume(nil, state, nil, %{}, [])
    end

    test "passes :multiple_interrupts without :halt through to next middleware" do
      data = %{
        type: :multiple_interrupts,
        interrupts: [%{type: :ask_user_question, question: "?"}]
      }

      state = State.new!(%{interrupt_data: data})

      assert {:cont, ^state} = Haltable.handle_resume(nil, state, nil, %{}, [])
    end

    test "does not claim non-halt single interrupts" do
      state =
        State.new!(%{interrupt_data: %{type: :ask_user_question, question: "?"}})

      assert {:cont, ^state} = Haltable.handle_resume(nil, state, nil, %{}, [])
    end

    test "falls through when resume_data is supplied (no resume payload for halts)" do
      halt = %{type: :halt, message: "stop", source_tool: "scout"}
      state = State.new!(%{interrupt_data: halt})

      # Any resume_data on a halt is a programmer error; the framework
      # demotes via cancel_pending_interrupts on the add_message path,
      # not via Agent.resume/3. Falling through to :cont lets
      # Agent.resume/3 surface its "no middleware handled the resume"
      # error.
      assert {:cont, ^state} =
               Haltable.handle_resume(nil, state, %{some: :payload}, %{}, [])
    end
  end

  describe "middleware integration" do
    test "registers via Middleware.init_middleware/1" do
      entry = Middleware.init_middleware(Haltable)
      assert entry.module == Haltable
    end

    test "Middleware.apply_restorable_interrupt? routes through this middleware" do
      entry = Middleware.init_middleware(Haltable)

      assert Middleware.apply_restorable_interrupt?(entry, %{type: :halt, message: "x"})
      refute Middleware.apply_restorable_interrupt?(entry, %{type: :ask_user_question})
    end

    test "Middleware.apply_handle_resume re-surfaces a halt" do
      entry = Middleware.init_middleware(Haltable)
      halt = %{type: :halt, message: "stop", source_tool: "scout"}
      state = State.new!(%{interrupt_data: halt})

      assert {:interrupt, ^state, ^halt} =
               Middleware.apply_handle_resume(nil, state, nil, entry, [])
    end
  end

  describe "State.cancel_pending_interrupts/1 with halt" do
    test "preserves the halt message in the demoted tool result content" do
      halt = %{
        type: :halt,
        message: "Outline needs subdivision before drafting.",
        source_tool: "scout_outline"
      }

      interrupt_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_42",
          content: "Workflow halted",
          name: "scout_outline",
          is_interrupt: true,
          interrupt_data: halt
        })

      tool_msg =
        LangChain.Message.new_tool_result!(%{content: nil, tool_results: [interrupt_result]})

      state = State.new!(%{messages: [tool_msg], interrupt_data: halt})

      cancelled = State.cancel_pending_interrupts(state)

      [demoted] =
        cancelled.messages
        |> List.last()
        |> Map.fetch!(:tool_results)

      refute demoted.is_interrupt
      assert demoted.is_error
      assert demoted.interrupt_data == nil
      assert demoted.content =~ "Tool halted:"
      assert demoted.content =~ "Outline needs subdivision before drafting."
      assert demoted.content =~ "proceed with their new request"
      assert cancelled.interrupt_data == nil
    end

    test "non-halt interrupts still get the generic user-cancelled text" do
      question = %{
        type: :ask_user_question,
        question: "Which DB?",
        response_type: :single_select,
        options: [],
        allow_other: false,
        allow_cancel: true,
        tool_call_id: "call_99"
      }

      interrupt_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_99",
          content: "Waiting for user response...",
          name: "ask_user",
          is_interrupt: true,
          interrupt_data: question
        })

      tool_msg =
        LangChain.Message.new_tool_result!(%{content: nil, tool_results: [interrupt_result]})

      state = State.new!(%{messages: [tool_msg], interrupt_data: question})

      cancelled = State.cancel_pending_interrupts(state)

      [demoted] =
        cancelled.messages
        |> List.last()
        |> Map.fetch!(:tool_results)

      assert demoted.content =~ "the user did not respond"
      refute demoted.content =~ "Tool halted:"
    end
  end

  describe "State.clean_stale_interrupts/2 cold-start restoration" do
    test "preserves a halt interrupt when Haltable is in the stack" do
      halt = %{type: :halt, message: "stop", source_tool: "scout"}

      interrupt_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_1",
          content: "Workflow halted",
          name: "scout_outline",
          is_interrupt: true,
          interrupt_data: halt
        })

      tool_msg =
        LangChain.Message.new_tool_result!(%{content: nil, tool_results: [interrupt_result]})

      state = State.new!(%{messages: [tool_msg]})
      entry = Middleware.init_middleware(Haltable)

      cleaned = State.clean_stale_interrupts(state, [entry])

      [preserved] =
        cleaned.messages
        |> List.last()
        |> Map.fetch!(:tool_results)

      assert preserved.is_interrupt
      assert preserved.interrupt_data == halt
    end

    test "demotes a halt interrupt when Haltable is NOT in the stack" do
      halt = %{type: :halt, message: "stop", source_tool: "scout"}

      interrupt_result =
        LangChain.Message.ToolResult.new!(%{
          tool_call_id: "call_1",
          content: "Workflow halted",
          name: "scout_outline",
          is_interrupt: true,
          interrupt_data: halt
        })

      tool_msg =
        LangChain.Message.new_tool_result!(%{content: nil, tool_results: [interrupt_result]})

      state = State.new!(%{messages: [tool_msg]})

      cleaned = State.clean_stale_interrupts(state, [])

      [demoted] =
        cleaned.messages
        |> List.last()
        |> Map.fetch!(:tool_results)

      refute demoted.is_interrupt
      assert demoted.is_error
    end
  end
end
