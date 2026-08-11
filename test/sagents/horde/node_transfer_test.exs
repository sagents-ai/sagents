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

  # Timeout for waiting for Horde's CRDTs to replicate an agent to another node.
  # The sync interval is 300ms, so this is generous.
  @replication_timeout 10_000

  # Additional settle for the part of Horde's convergence that is not observable
  # from outside. See wait_for_replication/4.
  @convergence_settle 2_000

  setup_all do
    LocalCluster.start()

    unless Node.alive?() do
      raise """
      Distributed Erlang did not start. LocalCluster.start/0 could not make this \
      node distributed, most likely because EPMD is not running on localhost:4369.

      Start EPMD and retry:

          epmd -daemon

      (LocalCluster 2.1.0 swallows :net_kernel.start errors silently, so the \
      underlying failure surfaces later as :peer :not_alive.)
      """
    end

    :ok
  end

  defp start_horde_cluster(count) do
    {:ok, cluster} =
      LocalCluster.start_link(count,
        environment: [
          # :participation scopes membership to the nodes that run
          # Sagents.Supervisor (started below), automatically excluding the
          # manager/test-runner node — which `:auto` would wrongly pull in.
          sagents: [distribution: :horde, horde: [members: :participation]]
        ]
      )

    {:ok, nodes} = LocalCluster.nodes(cluster)

    # Start Sagents.Supervisor (registry + Horde supervisors + membership
    # manager) on each node. ClusterTestHelper unlinks from the RPC caller so
    # the supervisor survives the temporary RPC process exiting.
    for node <- nodes do
      {:ok, _pid} = :rpc.call(node, Sagents.ClusterTestHelper, :start_supervisor, [])
    end

    # Wait for :pg participation + Horde CRDTs to converge across nodes before
    # placing agents.
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

      _other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(delay)
          do_wait_for_agent(node, agent_id, deadline, min(delay * 2, 500))
        else
          {:error, :timeout}
        end
    end
  end

  # An agent can only be handed to a survivor that already knows about it, so
  # every one of these tests has to let Horde converge before it takes a node
  # away. Two parts, because one is observable and one is not:
  #
  #   1. `replicated?/3` asserts the observable preconditions — the registry
  #      entry, the child spec, and an `:alive` member entry for the departing
  #      node — and normally passes within ~100ms.
  #
  #   2. `@convergence_settle` covers Horde's remaining internal convergence,
  #      which is not observable from outside its GenServer state. Removing a
  #      node before it completes strands the agent instead of moving it: the
  #      child spec is dropped from the process CRDT and never re-added, and
  #      nothing restarts it. On the observable preconditions alone, roughly one
  #      departure in four strands.
  #
  # A stranded agent is recoverable, not lost: the registry and the process CRDT
  # are left clean, so the next `Session.ensure_running/3` starts it again from
  # persisted state. Redistribution is an optimization, so the settle belongs
  # here rather than being something the library should guarantee away.
  defp wait_for_replication(node, departing_node, agent_ids, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    result = do_wait_for_replication(node, departing_node, agent_ids, deadline)
    if result == :ok, do: Process.sleep(@convergence_settle)
    result
  end

  defp do_wait_for_replication(node, departing_node, agent_ids, deadline) do
    if replicated?(node, departing_node, agent_ids) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        do_wait_for_replication(node, departing_node, agent_ids, deadline)
      else
        {:error, :timeout}
      end
    end
  end

  defp replicated?(node, departing_node, agent_ids) do
    # The registry CRDT: every agent resolves from this node.
    registrations_replicated? =
      Enum.all?(agent_ids, fn agent_id ->
        match?(
          {:ok, pid} when is_pid(pid),
          :rpc.call(node, Sagents.AgentSupervisor, :get_pid, [agent_id])
        )
      end)

    # The supervisor CRDT: this node knows the child specs it would have to
    # restart. count_children/1 reports the cluster-wide view, not the local one.
    specs_replicated? =
      case :rpc.call(node, Horde.DynamicSupervisor, :count_children, [
             Sagents.AgentsDynamicSupervisor
           ]) do
        %{specs: specs} -> specs >= length(agent_ids)
        _other -> false
      end

    # Horde's member bookkeeping: this node must already see the departing node
    # as an :alive member, because handing its processes over means marking that
    # entry :dead, and an entry that was never there cannot be marked.
    member_converged? =
      :rpc.call(node, Sagents.ClusterTestHelper, :member_alive?, [
        Sagents.AgentsDynamicSupervisor,
        departing_node
      ]) == true

    registrations_replicated? and specs_replicated? and member_converged?
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

      assert :ok =
               wait_for_replication(surviving_node, agent_node, [agent_id], @replication_timeout)

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

      # The surviving node can only take the agent over once Horde has
      # replicated it there. Without this wait the node departs before the
      # replica lands and the agent is lost rather than moved — which has
      # nothing to do with the shutdown being graceful.
      assert :ok =
               wait_for_replication(surviving_node, agent_node, [agent_id], @replication_timeout)

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
      agents_on_node1 = Enum.filter(agents, fn {_id, _pid, n} -> n == node1 end)
      agents_on_node2 = Enum.filter(agents, fn {_id, _pid, n} -> n == node2 end)

      # Wait for CRDT to sync process entries to both nodes
      all_ids = Enum.map(agents, fn {id, _pid, _node} -> id end)
      assert :ok = wait_for_replication(node2, node1, all_ids, @replication_timeout)

      # Stop node1
      LocalCluster.stop(cluster, node1)

      # All agents that were on node1 should move to node2
      for {agent_id, _old_pid, _node} <- agents_on_node1 do
        assert {:ok, new_pid} = wait_for_agent(node2, agent_id, @redistribution_timeout),
               "Agent #{agent_id} was not redistributed to node2"

        assert node(new_pid) == node2
      end

      # Agents that were already on node2 should still be there
      for {agent_id, old_pid, _node} <- agents_on_node2 do
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
