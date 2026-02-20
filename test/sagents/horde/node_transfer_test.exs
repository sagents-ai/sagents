defmodule Sagents.Horde.NodeTransferTest do
  @moduledoc """
  Tests for Horde-based process redistribution when nodes leave the cluster.

  These tests use LocalCluster to start real Erlang nodes and verify that
  agent processes are redistributed to surviving nodes when a node departs.

  Run with: mix test --include cluster
  """
  use ExUnit.Case, async: false

  @moduletag :cluster

  alias Sagents.Agent
  alias Sagents.State
  alias LangChain.ChatModels.ChatAnthropic

  # Timeout for waiting for Horde to redistribute processes after node departure
  @redistribution_timeout 15_000

  setup_all do
    LocalCluster.start()
    :ok
  end

  defp start_horde_cluster(count) do
    {:ok, cluster} =
      LocalCluster.start_link(count,
        environment: [
          sagents: [distribution: :horde]
        ]
      )

    {:ok, nodes} = LocalCluster.nodes(cluster)

    # Start Sagents.Supervisor (registry + Horde supervisors) on each node.
    # Uses ClusterTestHelper to unlink from the RPC caller process, otherwise
    # the supervisor dies when the temporary RPC process exits.
    for node <- nodes do
      {:ok, _} = :rpc.call(node, Sagents.ClusterTestHelper, :start_supervisor, [])
    end

    # Set explicit Horde members on each node, excluding the test runner (manager) node.
    # auto_members includes all connected nodes, which includes the test runner that
    # doesn't run Horde processes - this confuses distribution and redistribution.
    agent_members = Enum.map(nodes, &{Sagents.AgentsDynamicSupervisor, &1})
    fs_members = Enum.map(nodes, &{Sagents.FileSystem.FileSystemSupervisor, &1})
    registry_members = Enum.map(nodes, &{Sagents.Registry, &1})

    for node <- nodes do
      :ok =
        :rpc.call(node, Horde.Cluster, :set_members, [
          Sagents.AgentsDynamicSupervisor,
          agent_members
        ])

      :ok =
        :rpc.call(node, Horde.Cluster, :set_members, [
          Sagents.FileSystem.FileSystemSupervisor,
          fs_members
        ])

      :ok = :rpc.call(node, Horde.Cluster, :set_members, [Sagents.Registry, registry_members])
    end

    # Wait for Horde CRDTs to sync membership between nodes.
    Process.sleep(2_000)

    {cluster, nodes}
  end

  defp create_test_agent(agent_id) do
    Agent.new!(%{
      agent_id: agent_id,
      model:
        ChatAnthropic.new!(%{
          model: "claude-sonnet-4-5-20250929",
          api_key: "test_key"
        }),
      base_system_prompt: "Test agent for node transfer",
      replace_default_middleware: true,
      middleware: []
    })
  end

  defp start_agent_on_cluster(node, agent_id, opts \\ []) do
    agent = create_test_agent(agent_id)
    initial_state = Keyword.get(opts, :initial_state, State.new!(%{}))

    start_opts =
      [
        agent_id: agent_id,
        agent: agent,
        initial_state: initial_state
      ] ++ Keyword.drop(opts, [:initial_state])

    {:ok, pid} =
      :rpc.call(node, Sagents.AgentsDynamicSupervisor, :start_agent_sync, [start_opts])

    {agent_id, pid}
  end

  defp wait_for_agent(node, agent_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_agent(node, agent_id, deadline, 100)
  end

  defp do_wait_for_agent(node, agent_id, deadline, delay) do
    case :rpc.call(node, Sagents.AgentSupervisor, :get_pid, [agent_id]) do
      {:ok, pid} when is_pid(pid) ->
        {:ok, pid}

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(delay)
          do_wait_for_agent(node, agent_id, deadline, min(delay * 2, 500))
        else
          {:error, :timeout}
        end
    end
  end

  defp wait_for_node_down(node, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_node_down(node, deadline)
  end

  defp do_wait_for_node_down(node, deadline) do
    if node in Node.list() do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(200)
        do_wait_for_node_down(node, deadline)
      else
        {:error, :timeout}
      end
    else
      :ok
    end
  end

  describe "process redistribution on node departure" do
    test "agent process is redistributed to surviving node when a node stops" do
      {cluster, [node1, node2]} = start_horde_cluster(2)

      agent_id = "transfer-test-#{System.unique_integer([:positive])}"
      {_agent_id, original_pid} = start_agent_on_cluster(node1, agent_id)

      agent_node = node(original_pid)
      surviving_node = if agent_node == node1, do: node2, else: node1

      assert is_pid(original_pid)

      # Wait for CRDT to sync the process entry to the surviving node.
      # Without this, the surviving node may not know the process exists.
      Process.sleep(2_000)

      # Stop the node that has the agent
      LocalCluster.stop(cluster, agent_node)

      # Wait for Horde to detect node departure and redistribute
      assert {:ok, new_pid} = wait_for_agent(surviving_node, agent_id, @redistribution_timeout),
             "Agent was not redistributed to surviving node"

      assert node(new_pid) == surviving_node
      assert new_pid != original_pid

      LocalCluster.stop(cluster)
    end

    test "agent process is redistributed on graceful shutdown" do
      {cluster, [node1, node2]} = start_horde_cluster(2)

      agent_id = "graceful-test-#{System.unique_integer([:positive])}"
      {_agent_id, original_pid} = start_agent_on_cluster(node1, agent_id)

      agent_node = node(original_pid)
      surviving_node = if agent_node == node1, do: node2, else: node1

      # Graceful shutdown: call :init.stop on the node (like System.stop/0)
      :rpc.cast(agent_node, :init, :stop, [])

      # Wait for the node to fully disconnect before checking for redistribution.
      # :init.stop is async; during shutdown Horde may briefly re-place the process
      # on the dying node. Once it's fully gone, the process settles on the survivor.
      assert :ok = wait_for_node_down(agent_node, @redistribution_timeout)

      # Now wait for the agent to appear on the surviving node
      assert {:ok, new_pid} = wait_for_agent(surviving_node, agent_id, @redistribution_timeout),
             "Agent was not redistributed after graceful shutdown"

      assert node(new_pid) == surviving_node
      assert new_pid != original_pid

      # Clean up remaining cluster node
      LocalCluster.stop(cluster)
    end

    test "multiple agents are redistributed when a node stops" do
      {cluster, [node1, node2]} = start_horde_cluster(2)

      # Start 3 agents
      agents =
        for i <- 1..3 do
          agent_id = "multi-test-#{i}-#{System.unique_integer([:positive])}"
          {agent_id, pid} = start_agent_on_cluster(node1, agent_id)
          {agent_id, pid, node(pid)}
        end

      # Group agents by which node they're on
      agents_on_node1 = Enum.filter(agents, fn {_, _, n} -> n == node1 end)
      agents_on_node2 = Enum.filter(agents, fn {_, _, n} -> n == node2 end)

      # Wait for CRDT to sync process entries to both nodes
      Process.sleep(2_000)

      # Stop node1
      LocalCluster.stop(cluster, node1)

      # All agents that were on node1 should move to node2
      for {agent_id, _old_pid, _} <- agents_on_node1 do
        assert {:ok, new_pid} = wait_for_agent(node2, agent_id, @redistribution_timeout),
               "Agent #{agent_id} was not redistributed to node2"

        assert node(new_pid) == node2
      end

      # Agents that were already on node2 should still be there
      for {agent_id, old_pid, _} <- agents_on_node2 do
        assert {:ok, ^old_pid} =
                 :rpc.call(node2, Sagents.AgentSupervisor, :get_pid, [agent_id]),
               "Agent #{agent_id} should still be on node2 with same PID"
      end

      LocalCluster.stop(cluster)
    end

    test "normal agent shutdown (inactivity) does not trigger redistribution" do
      {cluster, [node1, node2]} = start_horde_cluster(2)

      agent_id = "no-redistribute-test-#{System.unique_integer([:positive])}"

      {_agent_id, _pid} =
        start_agent_on_cluster(node1, agent_id,
          inactivity_timeout: 2_000,
          shutdown_delay: 0
        )

      # Wait for inactivity shutdown to trigger (2s timeout + buffer)
      Process.sleep(5_000)

      # Agent should NOT be running on either node
      # (normal :normal exit with :transient = no restart, no redistribution)
      assert {:error, :not_found} =
               :rpc.call(node1, Sagents.AgentSupervisor, :get_pid, [agent_id])

      assert {:error, :not_found} =
               :rpc.call(node2, Sagents.AgentSupervisor, :get_pid, [agent_id])

      LocalCluster.stop(cluster)
    end
  end
end
