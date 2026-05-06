defmodule Sagents.TestAgentPersistence do
  @moduledoc """
  Test implementation of AgentPersistence that records calls in an ETS table.

  Before use, call `setup/0` in your test setup to create the ETS table.
  After the test, call `get_calls/0` or `get_calls_for/1` to inspect what was persisted.

  Records each call as `{agent_id, scope, state_data, context}`. The `context` is
  the full callback-context map including `:lifecycle`.

  ## Usage

      setup do
        Sagents.TestAgentPersistence.setup()
        :ok
      end

      test "persistence is called" do
        # ... start AgentServer with agent_persistence: Sagents.TestAgentPersistence ...
        # ... trigger execution ...

        calls = Sagents.TestAgentPersistence.get_calls()
        assert Enum.any?(calls, fn {_id, _scope, _data, ctx} -> ctx.lifecycle == :on_completion end)
      end
  """

  @behaviour Sagents.AgentPersistence

  @table_name :test_agent_persistence_calls
  @interrupt_table_name :test_agent_persistence_interrupt_calls

  @doc """
  Creates the ETS tables for recording persistence calls.
  Safe to call multiple times; recreates if the tables already exist.
  """
  def setup do
    for table <- [@table_name, @interrupt_table_name] do
      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
      end

      :ets.new(table, [:named_table, :public, :bag])
    end

    :ok
  end

  @doc """
  Returns all recorded persistence calls as a list of
  `{agent_id, scope, state_data, context}` tuples.
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
  Returns all recorded set_interrupted/3 calls as a list of
  `{agent_id, scope, context, interrupted?}` tuples.
  """
  def get_interrupt_calls do
    :ets.tab2list(@interrupt_table_name)
  end

  @doc """
  Returns set_interrupted/3 calls for a specific agent_id.
  """
  def get_interrupt_calls_for(agent_id) do
    :ets.lookup(@interrupt_table_name, agent_id)
  end

  @doc """
  Clears all recorded calls (both persist_state and set_interrupted).
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :ets.delete_all_objects(@interrupt_table_name)
    :ok
  end

  @impl true
  def persist_state(scope, state_data, context) do
    :ets.insert(@table_name, {context.agent_id, scope, state_data, context})
    :ok
  end

  @impl true
  def load_state(_scope, _context) do
    {:error, :not_found}
  end

  @impl true
  def set_interrupted(scope, context, interrupted?) do
    :ets.insert(@interrupt_table_name, {context.agent_id, scope, context, interrupted?})
    :ok
  end
end
