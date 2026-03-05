defmodule Sagents.TestAgentPersistence do
  @moduledoc """
  Test implementation of AgentPersistence that records calls in an ETS table.

  Before use, call `setup/0` in your test setup to create the ETS table.
  After the test, call `get_calls/0` or `get_calls_for/1` to inspect what was persisted.

  ## Usage

      setup do
        Sagents.TestAgentPersistence.setup()
        :ok
      end

      test "persistence is called" do
        # ... start AgentServer with agent_persistence: Sagents.TestAgentPersistence ...
        # ... trigger execution ...

        calls = Sagents.TestAgentPersistence.get_calls()
        assert Enum.any?(calls, fn {_id, _data, ctx} -> ctx == :on_completion end)
      end
  """

  @behaviour Sagents.AgentPersistence

  @table_name :test_agent_persistence_calls

  @doc """
  Creates the ETS table for recording persistence calls.
  Safe to call multiple times; recreates if the table already exists.
  """
  def setup do
    if :ets.whereis(@table_name) != :undefined do
      :ets.delete(@table_name)
    end

    :ets.new(@table_name, [:named_table, :public, :bag])
    :ok
  end

  @doc """
  Returns all recorded persistence calls as a list of `{agent_id, state_data, context}` tuples.
  """
  def get_calls do
    :ets.tab2list(@table_name)
  end

  @doc """
  Returns persistence calls for a specific agent_id.
  """
  def get_calls_for(agent_id) do
    :ets.lookup(@table_name, agent_id)
  end

  @doc """
  Clears all recorded calls.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @impl true
  def persist_state(agent_id, state_data, context) do
    :ets.insert(@table_name, {agent_id, state_data, context})
    :ok
  end

  @impl true
  def load_state(_agent_id) do
    {:error, :not_found}
  end
end
