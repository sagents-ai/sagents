defmodule Sagents.Horde.StopAgentTest do
  @moduledoc """
  `Sagents.AgentsDynamicSupervisor.stop_agent/1` stops an agent from any node in
  the cluster, including one whose registry replica already names the agent
  while its supervisor CRDT does not yet hold the child.

  Run with: mix test --include cluster
  """
  use ExUnit.Case, async: false

  @moduletag :cluster

  @attempts 10

  setup_all do
    LocalCluster.start()

    unless Node.alive?() do
      raise "Distributed Erlang did not start. Run `epmd -daemon` and retry."
    end

    {:ok, cluster} =
      LocalCluster.start_link(2,
        environment: [sagents: [distribution: :horde, horde: [members: :participation]]]
      )

    {:ok, nodes} = LocalCluster.nodes(cluster)

    for node <- nodes do
      {:ok, _pid} = :rpc.call(node, Sagents.ClusterTestHelper, :start_supervisor, [])
    end

    # Let :pg participation and the Horde CRDTs converge before placing agents.
    Process.sleep(2_000)

    on_exit(fn -> LocalCluster.stop(cluster) end)

    %{nodes: nodes}
  end

  test "stops an agent the moment another node's registry names it", %{nodes: [node1, node2]} do
    for attempt <- 1..@attempts do
      agent_id = "stop-agent-test-#{attempt}-#{System.unique_integer([:positive])}"

      # Start from node1 and stop from node2, and the reverse, so the agent is
      # placed on the far side of the stopping node at least some of the time.
      {start_node, stop_node} = if rem(attempt, 2) == 0, do: {node1, node2}, else: {node2, node1}

      stopper =
        Task.async(fn ->
          :rpc.call(stop_node, Sagents.ClusterTestHelper, :stop_agent_when_visible, [agent_id])
        end)

      # Not start_agent_sync/1: the stop can land before the AgentServer
      # registers, and the sync start would then wait out its timeout.
      assert {:ok, _sup_pid} =
               :rpc.call(start_node, Sagents.ClusterTestHelper, :start_agent, [
                 agent_id,
                 :start_agent
               ])

      assert {:ok, pid} = Task.await(stopper, 10_000)
      assert is_pid(pid)

      refute :rpc.call(node(pid), Process, :alive?, [pid]),
             "attempt #{attempt}: stop_agent/1 on #{stop_node} returned :ok for an agent " <>
               "on #{node(pid)} that is still running"
    end
  end
end
