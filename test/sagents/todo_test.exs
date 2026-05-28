defmodule Sagents.TodoTest do
  use ExUnit.Case, async: true

  alias Sagents.Todo

  doctest Todo

  describe "new/1" do
    test "creates a todo with an integer id" do
      assert {:ok, todo} = Todo.new(%{id: 1, content: "Test task"})
      assert todo.id == 1
      assert todo.content == "Test task"
      assert todo.status == :pending
    end

    test "coerces a stringified integer id to an integer" do
      assert {:ok, todo} = Todo.new(%{id: "5", content: "Task"})
      assert todo.id == 5
    end

    test "rejects a missing id (no auto-generation)" do
      assert {:error, changeset} = Todo.new(%{content: "Task"})
      assert "can't be blank" in errors_on(changeset).id
    end

    test "rejects a non-positive id" do
      assert {:error, changeset} = Todo.new(%{id: 0, content: "Task"})
      assert errors_on(changeset).id != []
    end

    test "rejects a non-numeric string id" do
      assert {:error, changeset} = Todo.new(%{id: "abc", content: "Task"})
      assert errors_on(changeset).id != []
    end

    test "creates a todo with specified status" do
      assert {:ok, todo} = Todo.new(%{id: 1, content: "Task", status: :in_progress})
      assert todo.status == :in_progress
    end

    test "accepts all valid statuses" do
      for status <- [:pending, :in_progress, :completed, :cancelled] do
        assert {:ok, todo} = Todo.new(%{id: 1, content: "Task", status: status})
        assert todo.status == status
      end
    end

    test "requires content" do
      assert {:error, changeset} = Todo.new(%{id: 1})
      assert "can't be blank" in errors_on(changeset).content
    end

    test "validates content length" do
      long_content = String.duplicate("a", 1001)
      assert {:error, changeset} = Todo.new(%{id: 1, content: long_content})
      errors = errors_on(changeset).content
      assert is_list(errors)
      assert errors != []
      assert hd(errors) =~ "should be at most"
    end

    test "rejects invalid status" do
      assert {:error, changeset} = Todo.new(%{id: 1, content: "Task", status: :invalid})
      assert "is invalid" in errors_on(changeset).status
    end

    test "rejects empty content" do
      assert {:error, changeset} = Todo.new(%{id: 1, content: ""})
      errors = errors_on(changeset).content
      assert is_list(errors)
      assert errors != []
      assert hd(errors) =~ "blank" or hd(errors) =~ "at least"
    end
  end

  describe "new!/1" do
    test "creates a todo successfully" do
      todo = Todo.new!(%{id: 1, content: "Task"})
      assert %Todo{} = todo
      assert todo.content == "Task"
    end

    test "raises on invalid data" do
      assert_raise LangChain.LangChainError, fn ->
        Todo.new!(%{id: 1, content: ""})
      end
    end
  end

  describe "to_map/1" do
    test "converts todo to map with integer id" do
      todo = Todo.new!(%{id: 123, content: "Task", status: :in_progress})
      map = Todo.to_map(todo)

      assert map == %{
               "id" => 123,
               "content" => "Task",
               "status" => "in_progress"
             }
    end

    test "converts all statuses correctly" do
      for status <- [:pending, :in_progress, :completed, :cancelled] do
        todo = Todo.new!(%{id: 1, content: "Task", status: status})
        map = Todo.to_map(todo)
        assert map["status"] == Atom.to_string(status)
      end
    end
  end

  describe "from_map/1" do
    test "creates todo from string-keyed map with integer id" do
      map = %{"id" => 123, "content" => "Task", "status" => "pending"}
      assert {:ok, todo} = Todo.from_map(map)
      assert todo.id == 123
      assert todo.content == "Task"
      assert todo.status == :pending
    end

    test "creates todo from atom-keyed map" do
      map = %{id: 123, content: "Task", status: "completed"}
      assert {:ok, todo} = Todo.from_map(map)
      assert todo.id == 123
      assert todo.status == :completed
    end

    test "coerces a numeric-string id to an integer" do
      map = %{"id" => "7", "content" => "Task"}
      assert {:ok, todo} = Todo.from_map(map)
      assert todo.id == 7
    end

    test "parses all status strings" do
      for status_str <- ["pending", "in_progress", "completed", "cancelled"] do
        map = %{"id" => 1, "content" => "Task", "status" => status_str}
        assert {:ok, todo} = Todo.from_map(map)
        assert is_atom(todo.status)
      end
    end

    test "errors when id is missing" do
      map = %{"content" => "Task"}
      assert {:error, _changeset} = Todo.from_map(map)
    end

    test "errors when id is non-numeric" do
      map = %{"id" => "abc-xyz", "content" => "Task"}
      assert {:error, _changeset} = Todo.from_map(map)
    end

    test "defaults to pending for invalid status string" do
      map = %{"id" => 1, "content" => "Task", "status" => "invalid"}
      assert {:ok, todo} = Todo.from_map(map)
      assert todo.status == :pending
    end
  end

  describe "list_from_maps/1" do
    test "assigns positional ids 1..N when ids are missing" do
      maps = [
        %{"content" => "First"},
        %{"content" => "Second"},
        %{"content" => "Third"}
      ]

      assert {:ok, todos} = Todo.list_from_maps(maps)
      assert Enum.map(todos, & &1.id) == [1, 2, 3]
    end

    test "preserves provided integer ids" do
      maps = [
        %{"id" => 7, "content" => "Seven"},
        %{"id" => 3, "content" => "Three"}
      ]

      assert {:ok, todos} = Todo.list_from_maps(maps)
      assert Enum.map(todos, & &1.id) == [7, 3]
    end

    test "coerces numeric-string ids to integers" do
      maps = [
        %{"id" => "01", "content" => "One"},
        %{"id" => "02", "content" => "Two"}
      ]

      assert {:ok, todos} = Todo.list_from_maps(maps)
      assert Enum.map(todos, & &1.id) == [1, 2]
    end

    test "renumbers non-numeric ids positionally (legacy random-base64 case)" do
      maps = [
        %{"id" => "A2c9-xyz", "content" => "Legacy 1"},
        %{"id" => "Q0p1-abc", "content" => "Legacy 2"}
      ]

      assert {:ok, todos} = Todo.list_from_maps(maps)
      assert Enum.map(todos, & &1.id) == [1, 2]
    end

    test "handles a mix of provided and missing ids" do
      maps = [
        %{"id" => 5, "content" => "Has id"},
        %{"content" => "No id"},
        %{"id" => 9, "content" => "Has id"}
      ]

      assert {:ok, todos} = Todo.list_from_maps(maps)
      assert Enum.map(todos, & &1.id) == [5, 2, 9]
    end
  end

  describe "round-trip conversion" do
    test "to_map and from_map preserve data" do
      original = Todo.new!(%{id: 42, content: "Important task", status: :in_progress})
      map = Todo.to_map(original)
      {:ok, restored} = Todo.from_map(map)

      assert restored.id == original.id
      assert restored.content == original.content
      assert restored.status == original.status
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
