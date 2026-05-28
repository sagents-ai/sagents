defmodule Sagents.Middleware.TodoListTest do
  use ExUnit.Case, async: true

  alias Sagents.{State, Todo}
  alias Sagents.Middleware.TodoList
  alias LangChain.Function

  describe "system_prompt/1" do
    test "returns TODO management prompt" do
      prompt = TodoList.system_prompt(nil)
      assert is_binary(prompt)
      assert prompt =~ "write_todos"
      assert prompt =~ "To-Do"
    end
  end

  describe "tools/1" do
    test "provides write_todos tool" do
      tools = TodoList.tools(nil)
      assert length(tools) == 1

      tool = hd(tools)
      assert %Function{} = tool
      assert tool.name == "write_todos"
    end

    test "write_todos tool has proper schema" do
      [tool] = TodoList.tools(nil)

      schema = tool.parameters_schema
      assert schema[:type] == "object" or schema["type"] == "object"

      properties = schema[:properties] || schema["properties"]
      required = schema[:required] || schema["required"]

      assert properties != nil
      assert required != nil
    end

    test "write_todos tool declares id as integer" do
      [tool] = TodoList.tools(nil)
      properties = tool.parameters_schema[:properties]
      items = properties[:todos][:items]
      assert items[:properties][:id][:type] == "integer"
    end
  end

  describe "display_text configuration" do
    test "defaults to 'Updating task list' when called with nil" do
      [tool] = TodoList.tools(nil)
      assert tool.display_text == "Updating task list"
    end

    test "uses default when init/1 is called with empty opts" do
      {:ok, config} = TodoList.init([])
      [tool] = TodoList.tools(config)
      assert tool.display_text == "Updating task list"
    end

    test "uses custom display_text from init/1 opts" do
      {:ok, config} = TodoList.init(display_text: "Updating my notes")
      [tool] = TodoList.tools(config)
      assert tool.display_text == "Updating my notes"
    end

    test "flows through Middleware.init_middleware/1 end-to-end" do
      entry =
        Sagents.Middleware.init_middleware({TodoList, display_text: "Keeping myself organized"})

      [tool] = Sagents.Middleware.get_tools(entry)
      assert tool.display_text == "Keeping myself organized"
    end
  end

  describe "write_todos tool - replace mode" do
    test "replaces all todos when merge is false" do
      old = Todo.new!(%{id: 99, content: "Old task", status: :pending})
      state = State.new!(%{todos: [old]})

      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "New task 1", "status" => "pending"},
          %{"id" => 2, "content" => "New task 2", "status" => "in_progress"}
        ]
      }

      context = %{state: state}
      assert {:ok, message, updated_state} = tool.function.(params, context)

      assert is_binary(message)
      assert message =~ "replaced"
      assert message =~ "2 TODO"

      assert length(updated_state.todos) == 2
      assert Enum.all?(updated_state.todos, &match?(%Todo{}, &1))

      ids = Enum.map(updated_state.todos, & &1.id)
      assert 1 in ids
      assert 2 in ids
      refute 99 in ids
    end

    test "creates todos with proper status types" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "Task 1", "status" => "pending"},
          %{"id" => 2, "content" => "Task 2", "status" => "in_progress"},
          %{"id" => 3, "content" => "Task 3", "status" => "completed"}
        ]
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      assert Enum.at(updated_state.todos, 0).status == :pending
      assert Enum.at(updated_state.todos, 1).status == :in_progress
      assert Enum.at(updated_state.todos, 2).status == :completed
    end

    test "preserves declared order for double-digit IDs (regression for /draft)" do
      # The original bug: ten todos with IDs 1..10 rendered as
      # [1, 10, 2, 3, ...] because string IDs sorted lexicographically.
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos:
          Enum.map(1..10, fn n ->
            %{"id" => n, "content" => "Task #{n}", "status" => "pending"}
          end)
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      assert Enum.map(updated_state.todos, & &1.id) == Enum.to_list(1..10)
    end

    test "accepts stringified integer ids from LLM tool calls (back-compat)" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"id" => "1", "content" => "Task 1", "status" => "pending"},
          %{"id" => "7", "content" => "Task 7", "status" => "pending"}
        ]
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      assert Enum.map(updated_state.todos, & &1.id) == [1, 7]
    end

    test "assigns positional ids when the agent omits them" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"content" => "First", "status" => "pending"},
          %{"content" => "Second", "status" => "pending"},
          %{"content" => "Third", "status" => "pending"}
        ]
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      assert Enum.map(updated_state.todos, & &1.id) == [1, 2, 3]
    end
  end

  describe "write_todos tool - merge mode" do
    test "merges with existing todos by ID" do
      existing_todo1 = Todo.new!(%{id: 1, content: "Keep me", status: :pending})
      existing_todo2 = Todo.new!(%{id: 2, content: "Update me", status: :pending})

      state = State.new!(%{todos: [existing_todo1, existing_todo2]})
      [tool] = TodoList.tools(nil)

      params = %{
        merge: true,
        todos: [
          %{"id" => 2, "content" => "Updated task", "status" => "completed"},
          %{"id" => 3, "content" => "New task", "status" => "pending"}
        ]
      }

      {:ok, message, updated_state} = tool.function.(params, %{state: state})

      assert message =~ "merged"
      assert length(updated_state.todos) == 3

      todo1 = Enum.find(updated_state.todos, &(&1.id == 1))
      assert todo1.content == "Keep me"
      assert todo1.status == :pending

      todo2 = Enum.find(updated_state.todos, &(&1.id == 2))
      assert todo2.content == "Updated task"
      assert todo2.status == :completed

      todo3 = Enum.find(updated_state.todos, &(&1.id == 3))
      assert todo3.content == "New task"
    end

    test "preserves all existing todos when merging with only a subset" do
      # This test reproduces the exact scenario from the original bug report:
      # 1. Create 6 todos with merge=false
      # 2. Update only 2 of them with merge=true
      # 3. All 6 todos should still exist (with 2 updated)

      [tool] = TodoList.tools(nil)

      initial_state = State.new!()

      first_params = %{
        merge: false,
        todos: [
          %{
            "id" => 1,
            "content" => "Create directory structure for the quantum physics curriculum",
            "status" => "in_progress"
          },
          %{
            "id" => 2,
            "content" => "Create prerequisite mathematics document covering required topics",
            "status" => "pending"
          },
          %{
            "id" => 3,
            "content" => "Create week-by-week study plan (16-week comprehensive curriculum)",
            "status" => "pending"
          },
          %{
            "id" => 4,
            "content" => "Create 10 key concept explanation documents (separate files)",
            "status" => "pending"
          },
          %{
            "id" => 5,
            "content" => "Create practice problem sets with varying difficulty levels",
            "status" => "pending"
          },
          %{"id" => 6, "content" => "Create progress tracking sheet", "status" => "pending"}
        ]
      }

      {:ok, _msg1, state_after_first_call} = tool.function.(first_params, %{state: initial_state})
      assert length(state_after_first_call.todos) == 6

      second_params = %{
        merge: true,
        todos: [
          %{
            "id" => 1,
            "content" => "Create directory structure for the quantum physics curriculum",
            "status" => "completed"
          },
          %{
            "id" => 2,
            "content" => "Create prerequisite mathematics document covering required topics",
            "status" => "in_progress"
          }
        ]
      }

      {:ok, msg2, state_after_second_call} =
        tool.function.(second_params, %{state: state_after_first_call})

      assert msg2 =~ "merged"

      assert length(state_after_second_call.todos) == 6,
             "Expected 6 todos after merge, but got #{length(state_after_second_call.todos)}. " <>
               "IDs present: #{Enum.map_join(state_after_second_call.todos, ", ", &Integer.to_string(&1.id))}"

      todo1 = Enum.find(state_after_second_call.todos, &(&1.id == 1))
      assert todo1 != nil, "Todo with ID 1 should exist"
      assert todo1.status == :completed

      todo2 = Enum.find(state_after_second_call.todos, &(&1.id == 2))
      assert todo2 != nil, "Todo with ID 2 should exist"
      assert todo2.status == :in_progress

      for id <- [3, 4, 5, 6] do
        todo = Enum.find(state_after_second_call.todos, &(&1.id == id))
        assert todo != nil, "Todo with ID #{id} should still exist"
        assert todo.status == :pending
      end
    end

    test "preserves existing todos when merging with non-overlapping IDs" do
      existing = Todo.new!(%{id: 100, content: "Keep", status: :completed})
      state = State.new!(%{todos: [existing]})
      [tool] = TodoList.tools(nil)

      params = %{
        merge: true,
        todos: [%{"id" => 200, "content" => "New", "status" => "pending"}]
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      assert length(updated_state.todos) == 2
      ids = Enum.map(updated_state.todos, & &1.id)
      assert 100 in ids
      assert 200 in ids
    end
  end

  describe "write_todos tool - validation" do
    test "returns error for invalid todo data" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [%{"id" => 1, "content" => "", "status" => "pending"}]
      }

      assert {:error, message} = tool.function.(params, %{state: state})
      assert message =~ "Failed to parse"
    end

    test "returns error when todos is not an array" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: "not an array"
      }

      assert {:error, message} = tool.function.(params, %{state: state})
      assert message =~ "must be an array"
    end

    test "handles invalid status gracefully" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [%{"id" => 1, "content" => "Task", "status" => "invalid_status"}]
      }

      # Invalid status defaults to pending
      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})
      assert hd(updated_state.todos).status == :pending
    end
  end

  describe "write_todos tool - response messages" do
    test "includes count and status summary in response" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "Task 1", "status" => "pending"},
          %{"id" => 2, "content" => "Task 2", "status" => "pending"},
          %{"id" => 3, "content" => "Task 3", "status" => "in_progress"}
        ]
      }

      {:ok, message, _state} = tool.function.(params, %{state: state})

      assert message =~ "3 TODO"
      assert message =~ "2 pending"
      assert message =~ "1 in_progress"
    end

    test "indicates merge vs replace in message" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: true,
        todos: [%{"id" => 1, "content" => "Task", "status" => "pending"}]
      }

      {:ok, merge_msg, _state} = tool.function.(params, %{state: state})
      assert merge_msg =~ "merged"

      params_replace = %{merge: false, todos: params.todos}
      {:ok, replace_msg, _state} = tool.function.(params_replace, %{state: state})
      assert replace_msg =~ "replaced"
    end
  end

  describe "integration with State helpers" do
    test "todos can be accessed with State.get_todo/2" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [%{"id" => 42, "content" => "Task", "status" => "pending"}]
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      todo = State.get_todo(updated_state, 42)
      assert todo.content == "Task"
    end

    test "todos can be filtered by status" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "Task 1", "status" => "pending"},
          %{"id" => 2, "content" => "Task 2", "status" => "completed"},
          %{"id" => 3, "content" => "Task 3", "status" => "pending"}
        ]
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      pending_todos = State.get_todos_by_status(updated_state, :pending)
      assert length(pending_todos) == 2

      completed_todos = State.get_todos_by_status(updated_state, :completed)
      assert length(completed_todos) == 1
    end
  end

  describe "inline mode" do
    setup do
      agent_id = "todo-list-inline-test-#{System.unique_integer([:positive])}"
      {:ok, _owner} = Registry.register(Sagents.Registry, {:agent_server, agent_id}, nil)
      {:ok, agent_id: agent_id}
    end

    test "inline: false (default) does not save a synthetic message", %{agent_id: agent_id} do
      {:ok, config} = TodoList.init([])
      [tool] = TodoList.tools(config)

      state = State.new!(%{agent_id: agent_id})

      params = %{
        merge: false,
        todos: [%{"id" => 1, "content" => "Task", "status" => "pending"}]
      }

      {:ok, _msg, _state} = tool.function.(params, %{state: state})

      refute_received {:"$gen_cast", {:save_synthetic_message, _attrs}}
    end

    test "inline: true saves a todo_snapshot synthetic message", %{agent_id: agent_id} do
      {:ok, config} = TodoList.init(inline: true)
      [tool] = TodoList.tools(config)

      state = State.new!(%{agent_id: agent_id})

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "Task A", "status" => "pending"},
          %{"id" => 2, "content" => "Task B", "status" => "in_progress"},
          %{"id" => 3, "content" => "Task C", "status" => "completed"}
        ]
      }

      {:ok, _msg, _state} = tool.function.(params, %{state: state})

      assert_received {:"$gen_cast", {:save_synthetic_message, attrs}}
      assert attrs.message_type == "system"
      assert attrs.content_type == "todo_snapshot"

      assert [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}] = attrs.content["todos"]
      assert Enum.find(attrs.content["todos"], &(&1["id"] == 2))["status"] == "in_progress"

      assert attrs.content["summary"]["total"] == 3
      assert attrs.content["summary"]["pending"] == 1
      assert attrs.content["summary"]["in_progress"] == 1
      assert attrs.content["summary"]["completed"] == 1
    end

    test "inline: true snapshots the pre-clear state when auto-clear fires",
         %{agent_id: agent_id} do
      {:ok, config} = TodoList.init(inline: true)
      [tool] = TodoList.tools(config)

      state = State.new!(%{agent_id: agent_id})

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "Task A", "status" => "completed"},
          %{"id" => 2, "content" => "Task B", "status" => "completed"}
        ]
      }

      {:ok, _msg, returned_state} = tool.function.(params, %{state: state})

      assert returned_state.todos == []

      assert_received {:"$gen_cast", {:save_synthetic_message, attrs}}
      assert attrs.content_type == "todo_snapshot"
      assert length(attrs.content["todos"]) == 2
      assert Enum.all?(attrs.content["todos"], &(&1["status"] == "completed"))
      assert attrs.content["summary"]["total"] == 2
      assert attrs.content["summary"]["completed"] == 2
    end

    test "inline: true is a silent no-op when no AgentServer is registered" do
      {:ok, config} = TodoList.init(inline: true)
      [tool] = TodoList.tools(config)

      state = State.new!(%{agent_id: "todo-list-no-server-#{System.unique_integer([:positive])}"})

      params = %{
        merge: false,
        todos: [%{"id" => 1, "content" => "Task", "status" => "pending"}]
      }

      assert {:ok, _msg, updated_state} = tool.function.(params, %{state: state})
      assert length(updated_state.todos) == 1
      refute_received {:"$gen_cast", {:save_synthetic_message, _attrs}}
    end
  end

  describe "auto-cleanup when all todos completed" do
    test "clears todo list when all todos marked as completed in replace mode" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "Task 1", "status" => "completed"},
          %{"id" => 2, "content" => "Task 2", "status" => "completed"}
        ]
      }

      {:ok, msg, updated_state} = tool.function.(params, %{state: state})

      assert updated_state.todos == []
      assert msg == "TODO list cleared - all tasks completed"
    end

    test "clears todo list when all todos marked as completed in merge mode" do
      existing = Todo.new!(%{id: 1, content: "Task 1", status: :pending})
      state = State.new!(%{todos: [existing]})
      [tool] = TodoList.tools(nil)

      params = %{
        merge: true,
        todos: [%{"id" => 1, "content" => "Task 1", "status" => "completed"}]
      }

      {:ok, msg, updated_state} = tool.function.(params, %{state: state})

      assert updated_state.todos == []
      assert msg == "TODO list cleared - all tasks completed"
    end

    test "keeps todo list when not all todos are completed" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "Task 1", "status" => "completed"},
          %{"id" => 2, "content" => "Task 2", "status" => "pending"}
        ]
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      assert length(updated_state.todos) == 2
    end

    test "keeps todo list when todos have in_progress status" do
      state = State.new!()
      [tool] = TodoList.tools(nil)

      params = %{
        merge: false,
        todos: [
          %{"id" => 1, "content" => "Task 1", "status" => "completed"},
          %{"id" => 2, "content" => "Task 2", "status" => "in_progress"}
        ]
      }

      {:ok, _msg, updated_state} = tool.function.(params, %{state: state})

      assert length(updated_state.todos) == 2
    end

    test "clears list immediately after completing final todo via merge" do
      todo1 = Todo.new!(%{id: 1, content: "Task 1", status: :completed})
      todo2 = Todo.new!(%{id: 2, content: "Task 2", status: :pending})
      state = State.new!(%{todos: [todo1, todo2]})
      [tool] = TodoList.tools(nil)

      params = %{
        merge: true,
        todos: [%{"id" => 2, "content" => "Task 2", "status" => "completed"}]
      }

      {:ok, msg, updated_state} = tool.function.(params, %{state: state})

      assert updated_state.todos == []
      assert msg == "TODO list cleared - all tasks completed"
    end
  end
end
