defmodule Sagents.TestDisplayMessagePersistence do
  @moduledoc """
  Test implementation of DisplayMessagePersistence for use in tests.

  Converts Messages to simple display data maps.
  """

  @behaviour Sagents.DisplayMessagePersistence

  @impl true
  def save_message(_scope, %LangChain.Message{} = message, _context) do
    display_data = Sagents.TestingHelpers.message_to_display_data(message)
    {:ok, [display_data]}
  end

  @impl true
  def update_tool_status(_scope, _status, _tool_info, _context) do
    {:error, :not_found}
  end
end

defmodule Sagents.TestDisplayMessagePersistenceRaising do
  @moduledoc """
  Test implementation that raises on save_message for error handling tests.
  """

  @behaviour Sagents.DisplayMessagePersistence

  @impl true
  def save_message(_scope, _message, _context) do
    raise "Simulated persistence error"
  end

  @impl true
  def update_tool_status(_scope, _status, _tool_info, _context) do
    {:error, :not_found}
  end
end

defmodule Sagents.TestDisplayMessagePersistenceForwarding do
  @moduledoc """
  Test implementation that forwards messages and display items to a registered process.

  Register a test process with `register_test_process/1` before use.
  """

  @behaviour Sagents.DisplayMessagePersistence

  def register_test_process(pid) do
    :persistent_term.put({__MODULE__, :test_pid}, pid)
  end

  @impl true
  def save_message(_scope, %LangChain.Message{} = message, _context) do
    display_items = Sagents.Message.DisplayHelpers.extract_display_items(message)
    pid = :persistent_term.get({__MODULE__, :test_pid})
    send(pid, {:saved_message, message, display_items})
    {:ok, []}
  end

  @impl true
  def update_tool_status(_scope, _status, _tool_info, _context) do
    {:error, :not_found}
  end

  @impl true
  def save_synthetic_message(scope, attrs, context) do
    pid = :persistent_term.get({__MODULE__, :test_pid})
    send(pid, {:saved_synthetic_message, scope, attrs, context})

    case :persistent_term.get({__MODULE__, :synthetic_response}, :ok) do
      :ok -> {:ok, %{id: "synthetic-#{System.unique_integer([:positive])}", attrs: attrs}}
      {:error, _} = err -> err
      :raise -> raise "Simulated synthetic persistence error"
    end
  end

  def set_synthetic_response(response) do
    :persistent_term.put({__MODULE__, :synthetic_response}, response)
  end

  def clear_synthetic_response do
    :persistent_term.erase({__MODULE__, :synthetic_response})
  end
end
