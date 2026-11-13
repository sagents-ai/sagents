defmodule Sagents.AgentsDynamicSupervisorTest do
  @moduledoc """
  Unit tests for `Sagents.AgentsDynamicSupervisor`'s handling of registration
  timeouts on start and of children its supervisor does not hold on stop.

  These tests stub `Sagents.ProcessSupervisor` and the registry lookup with
  Mimic so the recovery/retry logic can be exercised without a real Horde
  cluster.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Sagents.AgentSupervisor
  alias Sagents.AgentsDynamicSupervisor
  alias Sagents.ProcessRegistry
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

      # The readiness wait polls the AgentServer's own key, which is what
      # callers of a started agent look up.
      expect(ProcessRegistry, :fetch, fn {:agent_server, ^agent_id} -> {:ok, ready_pid} end)

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

      # Every attempt times out, so no readiness wait runs and nothing is
      # looked up.
      reject(&ProcessRegistry.fetch/1)

      assert {:error, ^reason} =
               AgentsDynamicSupervisor.start_agent_sync(
                 agent_id: agent_id,
                 registration_retries: 2,
                 registration_retry_backoff: 0
               )
    end
  end

  describe "stop_agent/2" do
    # Stands in for an AgentSupervisor: a real supervisor process the registry
    # can name, unlinked so stopping it does not take the test down.
    defp start_standin_supervisor do
      {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
      Process.unlink(pid)
      pid
    end

    test "stops the agent through its supervisor when the supervisor holds it" do
      pid = start_standin_supervisor()
      on_exit(fn -> Process.exit(pid, :kill) end)

      stub(AgentSupervisor, :get_pid, fn "conversation-held" -> {:ok, pid} end)
      expect(ProcessSupervisor, :terminate_child, fn _sup, ^pid -> :ok end)

      assert :ok = AgentsDynamicSupervisor.stop_agent("conversation-held")

      # terminate_child/2 is stubbed, so the process is untouched: nothing else
      # stopped it.
      assert Process.alive?(pid)
    end

    test "stops the agent directly when its supervisor does not hold it yet" do
      pid = start_standin_supervisor()
      ref = Process.monitor(pid)

      stub(AgentSupervisor, :get_pid, fn "conversation-unsynced" -> {:ok, pid} end)
      expect(ProcessSupervisor, :terminate_child, fn _sup, ^pid -> {:error, :not_found} end)

      assert :ok = AgentsDynamicSupervisor.stop_agent("conversation-unsynced")
      assert_received {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "uses the :reason option for a direct stop" do
      pid = start_standin_supervisor()
      ref = Process.monitor(pid)

      stub(AgentSupervisor, :get_pid, fn "conversation-reason" -> {:ok, pid} end)
      stub(ProcessSupervisor, :terminate_child, fn _sup, ^pid -> {:error, :not_found} end)

      assert :ok = AgentsDynamicSupervisor.stop_agent("conversation-reason", reason: :shutdown)
      assert_received {:DOWN, ^ref, :process, ^pid, :shutdown}
    end

    test "returns :ok when the agent exits before the direct stop reaches it" do
      pid = start_standin_supervisor()
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      stub(AgentSupervisor, :get_pid, fn "conversation-gone" -> {:ok, pid} end)
      stub(ProcessSupervisor, :terminate_child, fn _sup, ^pid -> {:error, :not_found} end)

      assert :ok = AgentsDynamicSupervisor.stop_agent("conversation-gone")
    end

    test "returns the lookup error when no agent is registered" do
      stub(AgentSupervisor, :get_pid, fn "conversation-missing" -> {:error, :not_found} end)
      reject(&ProcessSupervisor.terminate_child/2)

      assert {:error, :not_found} = AgentsDynamicSupervisor.stop_agent("conversation-missing")
    end
  end
end
