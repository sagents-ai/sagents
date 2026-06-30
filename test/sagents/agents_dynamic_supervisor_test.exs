defmodule Sagents.AgentsDynamicSupervisorTest do
  @moduledoc """
  Unit tests for the registration-timeout resilience added to
  `Sagents.AgentsDynamicSupervisor`.

  These tests stub `Sagents.ProcessSupervisor.start_child/2` and
  `Sagents.AgentSupervisor.get_pid/1` with Mimic so the recovery/retry logic can
  be exercised without a real Horde cluster.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Sagents.AgentSupervisor
  alias Sagents.AgentsDynamicSupervisor
  alias Sagents.ProcessSupervisor

  # The exact error shape Horde produces when a `:via` registration call exceeds
  # its hardcoded 5000ms default.
  defp registration_timeout(agent_id) do
    key = {:agent_supervisor, agent_id}

    {:timeout,
     {GenServer, :call,
      [Sagents.ProcessRegistry.registry_name(), {:register, key, nil, self()}, 5000]}}
  end

  describe "start_agent/1 registration timeout" do
    test "returns the error without consulting get_pid (no remote-liveness guess)" do
      agent_id = "conversation-reg-timeout"
      reason = registration_timeout(agent_id)

      stub(ProcessSupervisor, :start_child, fn _sup, _spec -> {:error, reason} end)

      # The placed supervisor is dead after its own registration call timed out,
      # and it may live on a remote node -- so we must never look the pid back up.
      reject(&AgentSupervisor.get_pid/1)

      assert {:error, ^reason} = AgentsDynamicSupervisor.start_agent(agent_id: agent_id)
    end

    test "does not treat an unrelated registry timeout as a registration timeout" do
      agent_id = "conversation-other-error"

      other_reason =
        {:timeout, {GenServer, :call, [SomeOther.Registry, {:register, :x, nil, self()}, 5000]}}

      stub(ProcessSupervisor, :start_child, fn _sup, _spec -> {:error, other_reason} end)

      reject(&AgentSupervisor.get_pid/1)

      assert {:error, ^other_reason} = AgentsDynamicSupervisor.start_agent(agent_id: agent_id)
    end
  end

  describe "start_agent_sync/1 registration retries" do
    test "retries after a registration timeout and succeeds on the next attempt" do
      agent_id = "conversation-retry-ok"
      ready_pid = self()

      # First start_child times out; the retry succeeds.
      expect(ProcessSupervisor, :start_child, fn _sup, _spec ->
        {:error, registration_timeout(agent_id)}
      end)

      expect(ProcessSupervisor, :start_child, fn _sup, _spec -> {:ok, ready_pid} end)

      # get_pid is only consulted by the post-start readiness wait, never on the
      # timeout path itself.
      expect(AgentSupervisor, :get_pid, fn ^agent_id -> {:ok, ready_pid} end)

      assert {:ok, ^ready_pid} =
               AgentsDynamicSupervisor.start_agent_sync(
                 agent_id: agent_id,
                 registration_retries: 1,
                 registration_retry_backoff: 0
               )
    end

    test "gives up and returns the error once retries are exhausted" do
      agent_id = "conversation-retry-exhausted"
      reason = registration_timeout(agent_id)

      stub(ProcessSupervisor, :start_child, fn _sup, _spec -> {:error, reason} end)

      # Every attempt times out, so no readiness wait runs and get_pid is never used.
      reject(&AgentSupervisor.get_pid/1)

      assert {:error, ^reason} =
               AgentsDynamicSupervisor.start_agent_sync(
                 agent_id: agent_id,
                 registration_retries: 2,
                 registration_retry_backoff: 0
               )
    end
  end
end
