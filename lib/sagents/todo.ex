defmodule Sagents.Todo do
  @moduledoc """
  TODO item structure for task tracking.

  TODOs help agents break down complex tasks into manageable steps and track
  progress through multi-step workflows.

  ## Identity

  Each TODO's `id` is a positive integer that is unique **within a single
  list**. There is no global ID space — IDs only need to distinguish items
  within the same conversation's todo list. When building a list, prefer
  `list_from_maps/1`, which assigns positional IDs (1..N) for any item that
  doesn't supply one.

  ## Status Values

  - `:pending` - Task not yet started
  - `:in_progress` - Currently being worked on
  - `:completed` - Task finished successfully
  - `:cancelled` - Task no longer needed

  ## Usage

      # Create a single TODO (id is required)
      {:ok, todo} = Todo.new(%{id: 1, content: "Implement user authentication"})

      # Build a list, letting positional defaults assign IDs
      {:ok, todos} = Todo.list_from_maps([
        %{"content" => "Task A", "status" => "pending"},
        %{"content" => "Task B", "status" => "pending"}
      ])
      # todos[0].id == 1, todos[1].id == 2
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias __MODULE__

  @primary_key false
  embedded_schema do
    field :id, :integer
    field :content, :string

    field :status, Ecto.Enum,
      values: [:pending, :in_progress, :completed, :cancelled],
      default: :pending
  end

  @type t :: %Todo{
          id: integer(),
          content: String.t(),
          status: :pending | :in_progress | :completed | :cancelled
        }

  @doc """
  Create a new TODO item with validation.

  Requires an explicit positive-integer `id`. There is no auto-generation —
  callers building a list should use `list_from_maps/1` instead, which
  assigns positional IDs.

  Stringified integer ids (e.g. `"5"`) are coerced to integers so payloads
  arriving from JSON tool calls keep working.

  ## Examples

      {:ok, todo} = Todo.new(%{id: 1, content: "Write tests"})
      {:ok, todo} = Todo.new(%{id: "1", content: "Write tests"})  # coerced
  """
  def new(attrs \\ %{}) do
    attrs
    |> coerce_id()
    |> cast_and_validate()
  end

  @doc """
  Create a new TODO item, raising on error.

  ## Examples

      todo = Todo.new!(%{id: 1, content: "Deploy to production"})
  """
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, todo} -> todo
      {:error, changeset} -> raise LangChain.LangChainError, changeset
    end
  end

  @doc """
  Convert a TODO struct to a map for serialization.

  ## Examples

      todo = Todo.new!(%{id: 1, content: "Task"})
      map = Todo.to_map(todo)
      # => %{"id" => 1, "content" => "Task", "status" => "pending"}
  """
  def to_map(%Todo{} = todo) do
    %{
      "id" => todo.id,
      "content" => todo.content,
      "status" => Atom.to_string(todo.status)
    }
  end

  @doc """
  Create a single TODO from a map (for deserialization).

  Coerces a stringified integer id to an integer. A missing or non-numeric
  id is an error from this entry point; callers handling a whole list
  should use `list_from_maps/1` to get positional ID defaults.

  ## Examples

      {:ok, todo} = Todo.from_map(%{"id" => 1, "content" => "Task", "status" => "pending"})
      {:ok, todo} = Todo.from_map(%{"id" => "1", "content" => "Task"})
  """
  def from_map(map) when is_map(map) do
    attrs = %{
      id: map["id"] || map[:id],
      content: map["content"] || map[:content],
      status: parse_status(map["status"] || map[:status] || "pending")
    }

    new(attrs)
  end

  @doc """
  Build a list of TODOs from an ordered list of maps.

  This is the canonical ingest point for any list of incoming todo data:
  tool calls, persisted state, conversation rehydrate. It guarantees every
  TODO has a positive integer id by assigning positional defaults:

  - Missing, nil, or non-numeric id → `id = index + 1` (1-based).
  - Positive integer id → kept as is.
  - Numeric-string id (e.g. `"5"`, `"01"`) → coerced to integer.

  The non-numeric fallback exists for backward compatibility with snapshots
  persisted before IDs were typed as integers (which used random base64
  strings). Those legacy IDs lose their original identity on reload, but
  in-list order is preserved.

  Returns `{:ok, [Todo.t()]}` if every item parses, or `{:error, reason}`
  on the first failure.
  """
  def list_from_maps(todos) when is_list(todos) do
    results =
      todos
      |> Enum.with_index()
      |> Enum.map(fn {map, index} ->
        map
        |> assign_positional_id(index)
        |> from_map()
      end)

    case Enum.find(results, fn result -> match?({:error, _changeset}, result) end) do
      nil ->
        {:ok, Enum.map(results, fn {:ok, todo} -> todo end)}

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        {:error, inspect(errors)}
    end
  end

  # Private functions

  defp assign_positional_id(map, index) when is_map(map) do
    raw = map["id"] || map[:id]

    case coerce_to_positive_integer(raw) do
      {:ok, _int} ->
        # Keep the original key shape; coerce_id/1 in `new/1` handles it.
        map

      :error ->
        # Missing or non-numeric → assign positional default.
        positional = index + 1

        if Map.has_key?(map, "id") do
          Map.put(map, "id", positional)
        else
          Map.put(map, :id, positional)
        end
    end
  end

  defp coerce_id(%{id: id} = attrs) do
    case coerce_to_positive_integer(id) do
      {:ok, int} -> %{attrs | id: int}
      :error -> attrs
    end
  end

  defp coerce_id(attrs), do: attrs

  defp coerce_to_positive_integer(int) when is_integer(int) and int > 0, do: {:ok, int}

  defp coerce_to_positive_integer(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} when int > 0 -> {:ok, int}
      _other -> :error
    end
  end

  defp coerce_to_positive_integer(_other), do: :error

  defp cast_and_validate(attrs) do
    %Todo{}
    |> cast(attrs, [:id, :content, :status])
    |> validate_required([:id, :content, :status])
    |> validate_number(:id, greater_than: 0)
    |> validate_length(:content, min: 1, max: 1000)
    |> validate_inclusion(:status, [:pending, :in_progress, :completed, :cancelled])
    |> apply_action(:insert)
  end

  defp parse_status(status) when is_atom(status), do: status
  defp parse_status("pending"), do: :pending
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("completed"), do: :completed
  defp parse_status("cancelled"), do: :cancelled
  defp parse_status(_other), do: :pending
end
