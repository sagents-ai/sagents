defmodule Sagents.StateTest do
  use Sagents.BaseCase, async: true

  alias Sagents.State
  alias LangChain.Message

  doctest State

  describe "new/1" do
    test "creates a state with default values" do
      assert {:ok, state} = State.new()
      assert state.messages == []
      assert state.todos == []
      assert state.metadata == %{}
      assert state.agent_id == nil
    end

    test "creates a state with provided attributes" do
      message = Message.new_user!("hello")

      attrs = %{
        messages: [message],
        todos: [%{id: "1", content: "task"}],
        metadata: %{key: "value"}
      }

      assert {:ok, state} = State.new(attrs)
      assert state.messages == attrs.messages
      assert state.todos == attrs.todos
      assert state.metadata == attrs.metadata
    end
  end

  describe "new!/1" do
    test "creates a state successfully" do
      state = State.new!()
      assert %State{} = state
    end

    test "creates state with attributes" do
      state = State.new!(%{messages: [Message.new_user!("hi")]})
      assert length(state.messages) == 1
    end
  end

  describe "merge_states/2 with two State structs" do
    test "merges messages by concatenating" do
      left = State.new!(%{messages: [Message.new_user!("hello")]})
      right = State.new!(%{messages: [Message.new_assistant!("hi")]})

      merged = State.merge_states(left, right)

      assert length(merged.messages) == 2
      assert merged.messages == left.messages ++ right.messages
    end

    test "merges todos by using right if present" do
      left = State.new!(%{todos: [%{id: "1", content: "old"}]})
      right = State.new!(%{todos: [%{id: "2", content: "new"}]})

      merged = State.merge_states(left, right)

      assert length(merged.todos) == 1
      assert Enum.at(merged.todos, 0).id == "2"
    end

    test "replaces todos with empty list when right is empty (allows clearing)" do
      left = State.new!(%{todos: [%{id: "1", content: "task"}]})
      right = State.new!(%{todos: []})

      merged = State.merge_states(left, right)

      # Empty list on right should replace and clear the todos
      assert merged.todos == []
    end

    test "deep merges metadata" do
      left = State.new!(%{metadata: %{a: 1, nested: %{x: 1, y: 2}}})
      right = State.new!(%{metadata: %{b: 2, nested: %{y: 3, z: 4}}})

      merged = State.merge_states(left, right)

      assert merged.metadata.a == 1
      assert merged.metadata.b == 2
      assert merged.metadata.nested.x == 1
      assert merged.metadata.nested.y == 3
      assert merged.metadata.nested.z == 4
    end
  end

  describe "merge_states/2 with map updates" do
    test "merges map into state" do
      state = State.new!(%{messages: [Message.new_user!("hello")]})

      merged = State.merge_states(state, %{metadata: %{key: "value"}})

      assert merged.messages == state.messages
      assert merged.metadata == %{key: "value"}
    end
  end

  describe "pause_reason" do
    test "defaults to nil" do
      assert State.new!().pause_reason == nil
    end

    test "merge_states/2 uses right if present, otherwise left" do
      left = %{State.new!() | pause_reason: {:node_draining, "node-1"}}
      right = State.new!()

      assert State.merge_states(left, right).pause_reason == {:node_draining, "node-1"}

      newer = %{State.new!() | pause_reason: :rate_limited}
      assert State.merge_states(left, newer).pause_reason == :rate_limited
    end

    test "is virtual: dropped on a serialize round-trip, like interrupt_data" do
      original = %{
        State.new!(%{messages: [Message.new_user!("hello")]})
        | pause_reason: {:node_draining, "node-1"}
      }

      serialized = Sagents.Persistence.StateSerializer.serialize_state(original)

      assert {:ok, %State{} = restored} = State.from_serialized("agent-1", serialized)
      assert restored.pause_reason == nil
    end
  end

  describe "add_message/2" do
    test "adds a message to empty state" do
      state = State.new!()
      message = Message.new_user!("hello")

      updated = State.add_message(state, message)

      assert length(updated.messages) == 1
      assert Enum.at(updated.messages, 0) == message
    end

    test "appends message to existing messages" do
      state = State.new!(%{messages: [Message.new_user!("first")]})
      message = Message.new_assistant!("second")

      updated = State.add_message(state, message)

      assert length(updated.messages) == 2
      assert Enum.at(updated.messages, 1) == message
    end
  end

  describe "add_messages/2" do
    test "adds multiple messages" do
      state = State.new!()

      messages = [
        Message.new_user!("first"),
        Message.new_assistant!("second")
      ]

      updated = State.add_messages(state, messages)

      assert length(updated.messages) == 2
    end
  end

  describe "put_metadata/3" do
    test "adds metadata" do
      state = State.new!()
      updated = State.put_metadata(state, :key, "value")

      assert updated.metadata.key == "value"
    end

    test "overwrites existing metadata" do
      state = State.new!(%{metadata: %{key: "old"}})
      updated = State.put_metadata(state, :key, "new")

      assert updated.metadata.key == "new"
    end
  end

  describe "get_metadata/3" do
    test "retrieves existing metadata" do
      state = State.new!(%{metadata: %{key: "value"}})
      assert State.get_metadata(state, :key) == "value"
    end

    test "returns nil for missing metadata" do
      state = State.new!()
      assert State.get_metadata(state, :missing) == nil
    end

    test "returns default for missing metadata" do
      state = State.new!()
      assert State.get_metadata(state, :missing, "default") == "default"
    end
  end

  describe "put_todo/2" do
    test "adds a new todo" do
      alias Sagents.Todo

      state = State.new!()
      todo = Todo.new!(%{id: 1, content: "Task", status: :pending})

      updated = State.put_todo(state, todo)

      assert length(updated.todos) == 1
      assert hd(updated.todos).id == 1
    end

    test "replaces existing todo with same ID" do
      alias Sagents.Todo

      todo1 = Todo.new!(%{id: 1, content: "Original", status: :pending})
      state = State.new!(%{todos: [todo1]})

      todo2 = Todo.new!(%{id: 1, content: "Updated", status: :completed})
      updated = State.put_todo(state, todo2)

      assert length(updated.todos) == 1
      assert hd(updated.todos).content == "Updated"
      assert hd(updated.todos).status == :completed
    end

    test "maintains insertion order for todos" do
      alias Sagents.Todo

      state = State.new!()
      todo_c = Todo.new!(%{id: 3, content: "C"})
      todo_a = Todo.new!(%{id: 1, content: "A"})
      todo_b = Todo.new!(%{id: 2, content: "B"})

      updated =
        state
        |> State.put_todo(todo_c)
        |> State.put_todo(todo_a)
        |> State.put_todo(todo_b)

      ids = Enum.map(updated.todos, & &1.id)
      # Insertion order is preserved, not sorted by ID
      assert ids == [3, 1, 2]
    end

    test "updating a todo maintains its position in the list" do
      alias Sagents.Todo

      # Create initial list of todos
      todo1 = Todo.new!(%{id: 1, content: "First", status: :pending})
      todo2 = Todo.new!(%{id: 2, content: "Second", status: :pending})
      todo3 = Todo.new!(%{id: 3, content: "Third", status: :pending})

      state = State.new!(%{todos: [todo1, todo2, todo3]})

      # Update the middle todo
      updated_todo2 = Todo.new!(%{id: 2, content: "Second Updated", status: :completed})
      updated_state = State.put_todo(state, updated_todo2)

      # Check order is maintained
      ids = Enum.map(updated_state.todos, & &1.id)
      assert ids == [1, 2, 3], "Order should be preserved when updating"

      # Check the content was updated
      second = Enum.at(updated_state.todos, 1)
      assert second.content == "Second Updated"
      assert second.status == :completed

      # Update the first todo
      updated_todo1 = Todo.new!(%{id: 1, content: "First Updated", status: :in_progress})
      updated_state2 = State.put_todo(updated_state, updated_todo1)

      ids2 = Enum.map(updated_state2.todos, & &1.id)
      assert ids2 == [1, 2, 3], "Order should still be preserved"

      first = Enum.at(updated_state2.todos, 0)
      assert first.content == "First Updated"
      assert first.status == :in_progress
    end
  end

  describe "get_todo/2" do
    test "retrieves todo by ID" do
      alias Sagents.Todo

      todo = Todo.new!(%{id: 42, content: "Task"})
      state = State.new!(%{todos: [todo]})

      retrieved = State.get_todo(state, 42)
      assert retrieved.id == 42
      assert retrieved.content == "Task"
    end

    test "returns nil for non-existent ID" do
      state = State.new!()
      assert State.get_todo(state, 999) == nil
    end
  end

  describe "delete_todo/2" do
    test "removes todo by ID" do
      alias Sagents.Todo

      todo1 = Todo.new!(%{id: 1, content: "Keep"})
      todo2 = Todo.new!(%{id: 2, content: "Remove"})
      state = State.new!(%{todos: [todo1, todo2]})

      updated = State.delete_todo(state, 2)

      assert length(updated.todos) == 1
      assert hd(updated.todos).id == 1
    end

    test "handles deleting non-existent todo" do
      alias Sagents.Todo

      todo = Todo.new!(%{id: 1, content: "Task"})
      state = State.new!(%{todos: [todo]})

      updated = State.delete_todo(state, 999)

      assert length(updated.todos) == 1
    end
  end

  describe "get_todos_by_status/2" do
    test "filters todos by status" do
      alias Sagents.Todo

      todo1 = Todo.new!(%{id: 1, content: "Task 1", status: :pending})
      todo2 = Todo.new!(%{id: 2, content: "Task 2", status: :completed})
      todo3 = Todo.new!(%{id: 3, content: "Task 3", status: :pending})

      state = State.new!(%{todos: [todo1, todo2, todo3]})

      pending = State.get_todos_by_status(state, :pending)
      assert length(pending) == 2
      assert Enum.all?(pending, &(&1.status == :pending))

      completed = State.get_todos_by_status(state, :completed)
      assert length(completed) == 1
      assert hd(completed).status == :completed
    end

    test "returns empty list when no matches" do
      alias Sagents.Todo

      todo = Todo.new!(%{id: 1, content: "Task", status: :pending})
      state = State.new!(%{todos: [todo]})

      completed = State.get_todos_by_status(state, :completed)
      assert completed == []
    end
  end

  describe "set_todos/2" do
    test "replaces all todos" do
      alias Sagents.Todo

      old_todo = Todo.new!(%{id: 99, content: "Old"})
      state = State.new!(%{todos: [old_todo]})

      new_todos = [
        Todo.new!(%{id: 1, content: "New 1"}),
        Todo.new!(%{id: 2, content: "New 2"})
      ]

      updated = State.set_todos(state, new_todos)

      assert length(updated.todos) == 2
      ids = Enum.map(updated.todos, & &1.id)
      assert 1 in ids
      assert 2 in ids
      refute 99 in ids
    end

    test "can set empty list" do
      alias Sagents.Todo

      todo = Todo.new!(%{id: 1, content: "Task"})
      state = State.new!(%{todos: [todo]})

      updated = State.set_todos(state, [])
      assert updated.todos == []
    end
  end

  describe "reset/1" do
    test "clears messages, todos, and metadata" do
      state =
        State.new!(%{
          messages: [Message.new_user!("test")],
          todos: [%{id: "1", content: "task", status: :pending}],
          metadata: %{config: "value", other: "data"}
        })

      reset_state = State.reset(state)

      assert reset_state.messages == []
      assert reset_state.todos == []
      assert reset_state.metadata == %{}
    end

    test "works with empty state" do
      state = State.new!()
      reset_state = State.reset(state)

      assert reset_state.messages == []
      assert reset_state.todos == []
      assert reset_state.metadata == %{}
    end
  end

  describe "replace_tool_result/3" do
    alias LangChain.Message.ToolResult

    test "replaces a tool result by tool_call_id" do
      placeholder =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "task",
          content: "placeholder",
          is_interrupt: true,
          interrupt_data: %{type: :subagent_hitl}
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [placeholder]})
      state = State.new!(%{messages: [Message.new_user!("hi"), tool_msg]})

      new_result =
        ToolResult.new!(%{tool_call_id: "call_1", name: "task", content: "completed"})

      updated = State.replace_tool_result(state, "call_1", new_result)

      tool_message = Enum.find(updated.messages, &(&1.role == :tool))
      [replaced] = tool_message.tool_results
      assert replaced.is_interrupt == false
      assert replaced.tool_call_id == "call_1"
    end
  end

  describe "clean_stale_interrupts/1" do
    alias LangChain.Message.ToolResult

    test "converts is_interrupt: true tool results to error results" do
      interrupt_result =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "task",
          content: "'researcher' requires human approval.",
          is_interrupt: true,
          interrupt_data: %{type: :subagent_hitl, sub_agent_id: "sa-1"}
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [interrupt_result]})
      state = State.new!(%{messages: [Message.new_user!("hi"), tool_msg]})

      cleaned = State.clean_stale_interrupts(state)

      tool_message = Enum.find(cleaned.messages, &(&1.role == :tool))
      [result] = tool_message.tool_results

      assert result.is_interrupt == false
      assert result.is_error == true
      assert result.content =~ "interrupted and could not be resumed"
      assert result.content =~ "sub-agent's work was lost"
      assert result.tool_call_id == "call_1"
    end

    test "leaves non-interrupt tool results untouched" do
      normal_result =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "search",
          content: "search results here"
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [normal_result]})
      state = State.new!(%{messages: [Message.new_user!("hi"), tool_msg]})

      cleaned = State.clean_stale_interrupts(state)

      tool_message = Enum.find(cleaned.messages, &(&1.role == :tool))
      [result] = tool_message.tool_results

      assert result.is_interrupt == false
      assert result.is_error == false
      assert result.content == [LangChain.Message.ContentPart.text!("search results here")]
    end

    test "handles mixed interrupt and normal results in same message" do
      interrupt_result =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "task",
          content: "requires approval",
          is_interrupt: true
        })

      normal_result =
        ToolResult.new!(%{
          tool_call_id: "call_2",
          name: "search",
          content: "found results"
        })

      tool_msg =
        Message.new_tool_result!(%{
          content: nil,
          tool_results: [interrupt_result, normal_result]
        })

      state = State.new!(%{messages: [tool_msg]})

      cleaned = State.clean_stale_interrupts(state)

      [cleaned_interrupt, cleaned_normal] =
        Enum.find(cleaned.messages, &(&1.role == :tool)).tool_results

      # Interrupt result was cleaned
      assert cleaned_interrupt.is_interrupt == false
      assert cleaned_interrupt.is_error == true
      assert cleaned_interrupt.content =~ "interrupted"

      # Normal result was left alone
      assert cleaned_normal.is_interrupt == false
      assert cleaned_normal.is_error == false
    end

    test "is a no-op when no interrupts exist" do
      state = State.new!(%{messages: [Message.new_user!("hello")]})
      cleaned = State.clean_stale_interrupts(state)
      assert cleaned.messages == state.messages
    end

    test "is a no-op on empty state" do
      state = State.new!()
      cleaned = State.clean_stale_interrupts(state)
      assert cleaned.messages == []
    end
  end

  describe "clean_stale_interrupts/2 (middleware-aware)" do
    alias LangChain.Message.ToolResult
    alias Sagents.Middleware

    defp build_interrupt_state(interrupt_data) do
      result =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "ask_user",
          content: "Waiting...",
          is_interrupt: true,
          interrupt_data: interrupt_data
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [result]})
      State.new!(%{messages: [tool_msg]})
    end

    test "empty middleware list demotes every interrupt (preserves prior behaviour)" do
      state = build_interrupt_state(%{type: :ask_user_question, question: "?"})
      cleaned = State.clean_stale_interrupts(state, [])

      [tool_msg] = cleaned.messages
      [result] = tool_msg.tool_results
      refute result.is_interrupt
      assert result.is_error
      assert is_nil(result.interrupt_data)
    end

    test "preserves :ask_user_question when AskUserQuestion is in the middleware list" do
      state = build_interrupt_state(%{type: :ask_user_question, question: "?"})
      ask_entry = Middleware.init_middleware(Sagents.Middleware.AskUserQuestion)

      cleaned = State.clean_stale_interrupts(state, [ask_entry])

      [tool_msg] = cleaned.messages
      [result] = tool_msg.tool_results
      assert result.is_interrupt
      refute result.is_error
      assert result.interrupt_data == %{type: :ask_user_question, question: "?"}
    end

    test "demotes :subagent_hitl even when AskUserQuestion is in the list" do
      state = build_interrupt_state(%{type: :subagent_hitl, sub_agent_id: "sa-1"})
      ask_entry = Middleware.init_middleware(Sagents.Middleware.AskUserQuestion)

      cleaned = State.clean_stale_interrupts(state, [ask_entry])

      [tool_msg] = cleaned.messages
      [result] = tool_msg.tool_results
      refute result.is_interrupt
      assert result.is_error
      assert result.content =~ "interrupted"
      assert result.content =~ "sub-agent"
    end

    test "demotes when interrupt_data is nil regardless of middleware (decode-failed path)" do
      result =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "ask_user",
          content: "Waiting...",
          is_interrupt: true,
          interrupt_data: nil
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [result]})
      state = State.new!(%{messages: [tool_msg]})
      ask_entry = Middleware.init_middleware(Sagents.Middleware.AskUserQuestion)

      cleaned = State.clean_stale_interrupts(state, [ask_entry])

      [tool_msg] = cleaned.messages
      [result] = tool_msg.tool_results
      refute result.is_interrupt
      assert result.is_error
      # The "incompatible data" demotion message
      assert result.content =~ "incompatible"
    end

    test "preserves :multiple_interrupts when every sub-interrupt is restorable" do
      data = %{
        type: :multiple_interrupts,
        interrupts: [
          %{type: :ask_user_question, question: "a"},
          %{type: :ask_user_question, question: "b"}
        ]
      }

      state = build_interrupt_state(data)
      ask_entry = Middleware.init_middleware(Sagents.Middleware.AskUserQuestion)

      cleaned = State.clean_stale_interrupts(state, [ask_entry])

      [tool_msg] = cleaned.messages
      [result] = tool_msg.tool_results
      assert result.is_interrupt
      assert result.interrupt_data == data
    end

    test "demotes :multiple_interrupts wholesale if any sub-interrupt is not restorable" do
      data = %{
        type: :multiple_interrupts,
        interrupts: [
          %{type: :ask_user_question, question: "a"},
          %{type: :subagent_hitl, sub_agent_id: "sa-1"}
        ]
      }

      state = build_interrupt_state(data)
      ask_entry = Middleware.init_middleware(Sagents.Middleware.AskUserQuestion)

      cleaned = State.clean_stale_interrupts(state, [ask_entry])

      [tool_msg] = cleaned.messages
      [result] = tool_msg.tool_results
      refute result.is_interrupt
      assert result.is_error
    end
  end

  describe "interrupt_restorable?/2" do
    setup do
      %{
        ask: Sagents.Middleware.init_middleware(Sagents.Middleware.AskUserQuestion),
        hitl: Sagents.Middleware.init_middleware(Sagents.Middleware.HumanInTheLoop),
        halt: Sagents.Middleware.init_middleware(Sagents.Middleware.Haltable)
      }
    end

    test "nil is never restorable", %{ask: ask} do
      refute State.interrupt_restorable?(nil, [ask])
    end

    test "an empty middleware list never restores anything" do
      refute State.interrupt_restorable?(%{type: :ask_user_question}, [])
    end

    test "a question is restorable when AskUserQuestion is in the stack", %{ask: ask} do
      assert State.interrupt_restorable?(%{type: :ask_user_question, question: "?"}, [ask])
    end

    test "a question is not restorable without AskUserQuestion", %{halt: halt} do
      refute State.interrupt_restorable?(%{type: :ask_user_question, question: "?"}, [halt])
    end

    test "a halt is restorable when Haltable is in the stack", %{halt: halt} do
      assert State.interrupt_restorable?(%{type: :halt, message: "done"}, [halt])
    end

    test "a sub-agent approval is never restorable: its chain dies with the process",
         %{ask: ask, hitl: hitl, halt: halt} do
      refute State.interrupt_restorable?(
               %{type: :subagent_hitl, sub_agent_id: "sa-1"},
               [ask, hitl, halt]
             )
    end

    test ":multiple_interrupts needs every sub-interrupt claimed", %{ask: ask, halt: halt} do
      all_questions = %{
        type: :multiple_interrupts,
        interrupts: [%{type: :ask_user_question}, %{type: :ask_user_question}]
      }

      mixed = %{
        type: :multiple_interrupts,
        interrupts: [%{type: :ask_user_question}, %{type: :subagent_hitl, sub_agent_id: "sa-1"}]
      }

      assert State.interrupt_restorable?(all_questions, [ask, halt])
      # Partial restore is a footgun: a resumed agent would dispatch responses
      # that don't all have valid targets.
      refute State.interrupt_restorable?(mixed, [ask, halt])
    end

    test "a question/halt mix is restorable when both middleware are present",
         %{ask: ask, halt: halt} do
      data = %{
        type: :multiple_interrupts,
        interrupts: [%{type: :ask_user_question}, %{type: :halt, message: "stop"}]
      }

      assert State.interrupt_restorable?(data, [ask, halt])
      refute State.interrupt_restorable?(data, [ask])
    end

    test "an empty :multiple_interrupts wrapper is not restorable", %{ask: ask} do
      # Degenerate shape (the wrapper is only ever built from 2+ results), but
      # there would be nothing for a resume to answer.
      refute State.interrupt_restorable?(%{type: :multiple_interrupts, interrupts: []}, [ask])
    end

    test "agrees with what clean_stale_interrupts/2 actually does", %{ask: ask} do
      # The whole point of exposing this: a caller must never be able to decide
      # "keep the prompt" for an interrupt the next boot will demote.
      for data <- [
            %{type: :ask_user_question, question: "?"},
            %{type: :subagent_hitl, sub_agent_id: "sa-1"},
            %{type: :multiple_interrupts, interrupts: [%{type: :ask_user_question}]}
          ] do
        state = build_interrupt_state(data)
        [tool_msg] = State.clean_stale_interrupts(state, [ask]).messages
        [result] = tool_msg.tool_results

        assert result.is_interrupt == State.interrupt_restorable?(data, [ask]),
               "mismatch for #{inspect(data)}"
      end
    end
  end

  describe "cancel_pending_interrupts/1" do
    alias LangChain.Message.ToolResult

    test "demotes a single is_interrupt: true tool result with the cancellation message" do
      result =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "ask_user",
          content: "Waiting...",
          is_interrupt: true,
          interrupt_data: %{type: :ask_user_question, question: "?"}
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [result]})
      state = State.new!(%{messages: [tool_msg]})

      cancelled = State.cancel_pending_interrupts(state)

      [tool_msg] = cancelled.messages
      [result] = tool_msg.tool_results

      refute result.is_interrupt
      assert result.is_error
      assert is_nil(result.interrupt_data)
      assert result.content =~ "user did not respond"
      assert result.content =~ "proceed with their new request"
    end

    test "demotes every interrupt in a tool message with multiple results" do
      r1 =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "ask_user",
          content: "Q1?",
          is_interrupt: true,
          interrupt_data: %{type: :ask_user_question, question: "Q1"}
        })

      r2 =
        ToolResult.new!(%{
          tool_call_id: "call_2",
          name: "ask_user",
          content: "Q2?",
          is_interrupt: true,
          interrupt_data: %{type: :ask_user_question, question: "Q2"}
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [r1, r2]})
      state = State.new!(%{messages: [tool_msg]})

      cancelled = State.cancel_pending_interrupts(state)

      [tool_msg] = cancelled.messages
      [c1, c2] = tool_msg.tool_results

      refute c1.is_interrupt
      refute c2.is_interrupt
      assert c1.is_error
      assert c2.is_error
    end

    test "leaves non-interrupt tool results untouched" do
      normal =
        ToolResult.new!(%{
          tool_call_id: "call_1",
          name: "search",
          content: "results"
        })

      tool_msg = Message.new_tool_result!(%{content: nil, tool_results: [normal]})
      state = State.new!(%{messages: [tool_msg]})

      cancelled = State.cancel_pending_interrupts(state)

      [tool_msg] = cancelled.messages
      [result] = tool_msg.tool_results

      refute result.is_interrupt
      refute result.is_error
    end

    test "clears state.interrupt_data (the virtual field)" do
      state =
        State.new!(%{
          messages: [],
          interrupt_data: %{type: :ask_user_question, question: "?"}
        })

      cancelled = State.cancel_pending_interrupts(state)

      assert is_nil(cancelled.interrupt_data)
    end

    test "is a no-op when no interrupts are pending" do
      state = State.new!(%{messages: [Message.new_user!("hello")]})
      cancelled = State.cancel_pending_interrupts(state)
      assert cancelled.messages == state.messages
      assert is_nil(cancelled.interrupt_data)
    end
  end

  describe "load_or_new/3" do
    # Process-dictionary-backed stub of Sagents.AgentPersistence — each test
    # seeds the response it wants, then asserts on the resulting state.
    defmodule StubPersistence do
      @behaviour Sagents.AgentPersistence

      @impl true
      def persist_state(_scope, _state_data, _context), do: :ok

      @impl true
      def load_state(_scope, _context) do
        case Process.get(:stub_load_response) do
          nil -> {:error, :not_found}
          response -> response
        end
      end
    end

    setup do
      on_exit(fn -> Process.delete(:stub_load_response) end)
      :ok
    end

    test "returns a fresh state when persistence has no saved entry" do
      Process.put(:stub_load_response, {:error, :not_found})

      assert {:ok, %State{} = state} =
               State.load_or_new(StubPersistence, nil, %{
                 agent_id: "conversation-1",
                 conversation_id: 1
               })

      assert state.messages == []
      assert state.agent_id == nil
    end

    test "returns a fresh state when the saved envelope has no 'state' field" do
      Process.put(:stub_load_response, {:ok, %{"version" => 1}})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %State{} = state} =
                   State.load_or_new(StubPersistence, nil, %{
                     agent_id: "conversation-2",
                     conversation_id: 2
                   })

          assert state.messages == []
        end)

      assert log =~ "no 'state' field"
      assert log =~ "conversation-2"
    end

    test "restores state from a valid serialized envelope" do
      # Round-trip a real state through the serializer to produce a valid
      # envelope, then feed it back in.
      original =
        State.new!(%{
          messages: [Message.new_user!("hello")],
          metadata: %{"foo" => "bar"}
        })

      serialized = Sagents.Persistence.StateSerializer.serialize_state(original)

      Process.put(:stub_load_response, {:ok, %{"state" => serialized}})

      assert {:ok, %State{} = restored} =
               State.load_or_new(StubPersistence, nil, %{
                 agent_id: "conversation-4",
                 conversation_id: 4
               })

      assert restored.agent_id == "conversation-4"
      assert length(restored.messages) == 1

      assert hd(restored.messages).content == [
               %LangChain.Message.ContentPart{type: :text, content: "hello", options: []}
             ] or
               hd(restored.messages).content == "hello"
    end

    test "load_state context carries agent_id and conversation_id" do
      defmodule CapturingPersistence do
        @behaviour Sagents.AgentPersistence
        @impl true
        def persist_state(_scope, _state, _ctx), do: :ok
        @impl true
        def load_state(_scope, ctx) do
          send(self(), {:loaded, ctx})
          {:error, :not_found}
        end
      end

      State.load_or_new(CapturingPersistence, nil, %{
        agent_id: "agent-X",
        conversation_id: "conv-Y"
      })

      assert_received {:loaded, %{agent_id: "agent-X", conversation_id: "conv-Y"}}
    end
  end
end
