defmodule Sagents.TestStoredPersistence do
  @moduledoc """
  An `Sagents.AgentPersistence` that loads back what was last persisted, the
  way a database does, so a restarted agent has a real conversation to reload.
  Every write is also recorded, in order, with its lifecycle.

  Call `setup/0` before use. `store/2` seeds a conversation; `fail_loads/1`
  makes every load answer `{:error, reason}`.
  """
  @behaviour Sagents.AgentPersistence

  alias Sagents.Persistence.StateSerializer
  alias Sagents.State

  @table :test_stored_persistence

  def setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  def store(agent_id, %State{} = state) do
    :ets.insert(
      @table,
      {{:latest, agent_id}, StateSerializer.serialize_server_state(nil, state)}
    )
  end

  def fail_loads(reason), do: :ets.insert(@table, {:load_error, reason})

  def writes(agent_id) do
    case :ets.lookup(@table, {:writes, agent_id}) do
      [{_key, writes}] -> Enum.reverse(writes)
      [] -> []
    end
  end

  @impl true
  def persist_state(_scope, state_data, context) do
    :ets.insert(@table, {{:latest, context.agent_id}, state_data})
    writes = [{context.lifecycle, state_data} | writes_raw(context.agent_id)]
    :ets.insert(@table, {{:writes, context.agent_id}, writes})
    :ok
  end

  @impl true
  def load_state(_scope, context) do
    case :ets.lookup(@table, :load_error) do
      [{:load_error, reason}] ->
        {:error, reason}

      [] ->
        case :ets.lookup(@table, {:latest, context.agent_id}) do
          [{_key, data}] -> {:ok, data}
          [] -> {:error, :not_found}
        end
    end
  end

  defp writes_raw(agent_id) do
    case :ets.lookup(@table, {:writes, agent_id}) do
      [{_key, writes}] -> writes
      [] -> []
    end
  end
end
