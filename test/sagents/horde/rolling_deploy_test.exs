defmodule Sagents.Horde.RollingDeployTest do
  @moduledoc """
  How Sagents behaves on a node that is draining during a rolling deploy, and
  when a registry crashes.

  These tests use real Erlang nodes via LocalCluster. They are slow by design:
  the behaviour under test is a lifecycle transition, and the only honest way to
  observe it is to drive real supervision trees up and down.

      mix test test/sagents/horde/rolling_deploy_test.exs --include cluster --include slow

  ## What is asserted

  1. **The unguarded lookup raises.** `Horde.Registry`'s ETS tables are owned by
     the local `Horde.RegistryImpl` process, and `Horde.Registry.lookup/2`
     derives the table name arithmetically (`:"keys_\#{registry}"`) and reads it
     with no liveness guard. Once that process is gone, a raw lookup raises
     `ArgumentError` from `:ets` rather than answering `:undefined`. This is
     what `Sagents.ProcessRegistry`'s guard exists to sit in front of.

  2. **The guarded API reports it as a value.** On the same node,
     `Sagents.AgentServer.fetch_pid/1` answers
     `{:error, :registry_unavailable}` and `Sagents.ready?/0` answers `false`,
     so a host can pull the node out of rotation and answer 503.

  3. **The condition persists for the rest of the node's life.** Once
     `Sagents.Supervisor` has shut down, every subsequent lookup on that node
     reports unavailable for as long as the BEAM lives, which is the whole drain
     period. Retrying on the same node never recovers; the request has to go
     elsewhere.

  4. **Only the draining node is affected.** Survivors keep resolving the agent
     and keep reporting ready, so this is a routing and readiness concern rather
     than a cluster-wide outage.

  5. **A registry crash self-heals from a peer.** Horde replicates membership
     through the same CRDT as registrations, so a surviving peer restores both
     within milliseconds and no agent is lost.

  6. **Without a peer, the restart chain does the work instead.**
     `Sagents.Supervisor` is `:rest_for_one` and `Sagents.RegistryWatcher` puts
     a registry failure into that chain, so agents stop and are re-created from
     persisted state rather than surviving unregistered. A conversation never
     ends up with two AgentServers.
  """
  use ExUnit.Case, async: false

  @moduletag :cluster
  @moduletag :slow
  @moduletag timeout: 180_000

  alias Sagents.ClusterTestHelper, as: Helper

  @converge_timeout 15_000

  setup_all do
    LocalCluster.start()

    unless Node.alive?() do
      raise """
      Distributed Erlang did not start. LocalCluster.start/0 could not make this \
      node distributed, most likely because EPMD is not running on localhost:4369.

      Start EPMD and retry:

          epmd -daemon
      """
    end

    :ok
  end

  # ===========================================================================
  # 1. A node whose Sagents tree has shut down
  # ===========================================================================

  describe "lookups against a shut-down registry" do
    test "the raw Horde lookup raises, and the Sagents API reports the condition" do
      {cluster, [node1]} = start_cluster(1)
      start_supervisor_on([node1])

      agent_id = "conversation-sconv_2b39f4bd8eec45beadb"

      # Baseline: with the registry up, an unknown agent answers cleanly.
      assert {:ok, nil} = rpc(node1, :probe_once, [agent_id])
      assert rpc(node1, :registry_table_present?, [])

      # An orderly OTP shutdown of the Sagents tree, what SIGTERM does on a
      # rolling deploy. The node stays up, exactly as it does while draining.
      assert :ok = rpc(node1, :stop_supervisor, [])

      # Horde's own lookup, bypassing the guard. Sagents.ProcessRegistry wraps
      # this rather than replacing it, so the raw behaviour is what the guard
      # has to protect against.
      assert {:raised, ArgumentError, message, stacktrace} =
               rpc(node1, :raw_whereis_probe, [agent_id])

      assert message =~ "the table identifier does not refer to an existing ETS table"

      # The frames that carry the raise up to a caller, in order.
      assert stacktrace =~ ~s|:ets.lookup(:"keys_Elixir.Sagents.Registry"|
      assert stacktrace =~ "Horde.Registry.lookup/2"
      assert stacktrace =~ "Horde.Registry.whereis_name/2"
      assert stacktrace =~ "GenServer.whereis/1"

      # The precondition Horde.Registry.lookup/2 needs but never checks is
      # cheaply observable: `:ets.whereis/1` answers `:undefined` rather than
      # raising. That is what Sagents.ProcessRegistry.available?/0 checks.
      refute rpc(node1, :registry_table_present?, [])

      # The Sagents API keeps that :ets error away from a caller. get_pid/1
      # raises a named error that says what to do, because its pid()|nil shape
      # cannot carry the condition, and fetch_pid/1 reports it as a value.
      assert {:raised, Sagents.RegistryUnavailableError, sagents_message, _stack} =
               rpc(node1, :probe_once, [agent_id])

      assert sagents_message =~ "Sagents.Registry is not available on this node"
      assert sagents_message =~ "Sagents.ready?/0"

      assert {:error, :registry_unavailable} = rpc(node1, :fetch_probe, [agent_id])

      LocalCluster.stop(cluster)
    end

    test "the condition persists for the rest of the node's life, it is not transient" do
      {cluster, [node1]} = start_cluster(1)
      start_supervisor_on([node1])

      # A caller outside the Sagents tree, in the position a Phoenix Endpoint
      # and its Absinthe resolvers occupy, polling as requests arrive through
      # the guarded API a request path should use.
      probe = rpc(node1, :start_probe, ["conversation-drain", 2, :fetch_probe])

      Process.sleep(300)
      assert :ok = rpc(node1, :stop_supervisor, [])
      Process.sleep(700)

      send(probe, {:report, self()})
      assert_receive {:probe_report, results}, 5_000

      counts = Enum.frequencies(results)
      unavailable = {:error, :registry_unavailable}

      assert Map.get(counts, :not_registered, 0) > 0,
             "expected clean answers before shutdown, got #{inspect(counts)}"

      assert Map.get(counts, unavailable, 0) > 0,
             "expected :registry_unavailable after shutdown, got #{inspect(counts)}"

      # Nothing ever raised: the whole point of the guard is that this path
      # stays a value.
      assert Enum.all?(results, &(not match?({:raised, _}, &1))),
             "expected no raises through the guarded API, got #{inspect(counts)}"

      # The condition is terminal for this node, not transient. Once it starts,
      # nothing on this node recovers, so there is no retry-here that helps and
      # the request has to be answered 503 and retried elsewhere.
      tail = Enum.drop_while(results, &(&1 != unavailable))
      assert Enum.uniq(tail) == [unavailable]

      LocalCluster.stop(cluster)
    end
  end

  # ===========================================================================
  # 2. Rolling deploy: which node is affected
  # ===========================================================================

  describe "rolling deploy across a 3 node cluster" do
    test "only the draining node is affected; survivors keep answering" do
      {cluster, [node1, node2, node3]} = start_cluster(3)
      start_supervisor_on([node1, node2, node3])

      assert wait_until(fn ->
               member_nodes(node1, Sagents.Registry) == Enum.sort([node1, node2, node3])
             end),
             "cluster did not converge"

      agent_id = "conversation-rolling-#{System.unique_integer([:positive])}"
      {:ok, _pid} = rpc(node1, :start_agent, [agent_id])

      assert wait_until(fn ->
               match?({:ok, pid} when is_pid(pid), rpc(node2, :probe_once, [agent_id]))
             end),
             "agent registration did not replicate to node2"

      # Probes on all three nodes, then take node1 out of service the way a
      # rolling deploy does: stop its supervision tree, drain, then kill it.
      probes =
        for n <- [node1, node2, node3],
            do: {n, rpc(n, :start_probe, [agent_id, 5, :fetch_probe])}

      Process.sleep(300)
      assert :ok = rpc(node1, :stop_supervisor, [])
      Process.sleep(1_500)

      reports =
        for {n, probe} <- probes, into: %{} do
          send(probe, {:report, self()})
          assert_receive {:probe_report, results}, 5_000
          {n, Enum.frequencies(results)}
        end

      unavailable = {:error, :registry_unavailable}

      # The draining node reports :registry_unavailable for every request it is
      # handed, and reports itself not ready.
      assert Map.get(reports[node1], unavailable, 0) > 0,
             "draining node should report unavailable: #{inspect(reports[node1])}"

      refute rpc(node1, :ready?, [])

      # Survivors are unaffected: they still resolve the agent, they never see
      # the condition, and they still report ready. The fault is local to the
      # node whose registry went away, so this is not a cluster-wide outage. It
      # is a routing and readiness failure, and the request belongs on one of
      # these nodes instead.
      for n <- [node2, node3] do
        assert Map.get(reports[n], unavailable, 0) == 0,
               "surviving node #{inspect(n)} saw the condition: #{inspect(reports[n])}"

        assert Map.get(reports[n], :found, 0) > 0,
               "surviving node #{inspect(n)} should still resolve the agent: " <>
                 inspect(reports[n])

        assert rpc(n, :ready?, [])
      end

      LocalCluster.stop(cluster)
    end
  end

  # ===========================================================================
  # 2b. The drain window through the guarded API
  # ===========================================================================

  describe "guarded API on a draining node" do
    test "reports readiness false and returns :registry_unavailable instead of raising" do
      {cluster, [node1]} = start_cluster(1)
      start_supervisor_on([node1])

      agent_id = "conversation-guarded-#{System.unique_integer([:positive])}"

      assert rpc(node1, :ready?, [])
      assert {:error, :not_running} = rpc(node1, :fetch_probe, [agent_id])

      assert :ok = rpc(node1, :stop_supervisor, [])

      # Readiness flips, which is the signal a load balancer needs before the
      # tree comes down. See docs/deployment.md.
      refute rpc(node1, :ready?, [])

      # And the request path gets a value it can turn into a 503, rather than
      # the ArgumentError asserted above.
      assert {:error, :registry_unavailable} = rpc(node1, :fetch_probe, [agent_id])

      LocalCluster.stop(cluster)
    end

    test "an agent that IS running is never reported as merely not running" do
      {cluster, [node1]} = start_cluster(1)
      start_supervisor_on([node1])

      agent_id = "conversation-nolie-#{System.unique_integer([:positive])}"
      {:ok, _sup} = rpc(node1, :start_agent, [agent_id])
      assert {:ok, pid} = rpc(node1, :fetch_probe, [agent_id])
      assert is_pid(pid)

      assert :ok = rpc(node1, :stop_supervisor, [])

      # The distinction that matters: a draining node must not answer
      # :not_running, because the caller acts on that by starting a duplicate.
      assert {:error, :registry_unavailable} = rpc(node1, :fetch_probe, [agent_id])

      LocalCluster.stop(cluster)
    end
  end

  # ===========================================================================
  # 3. Registry crash: heals from a peer, restarts without one
  # ===========================================================================

  describe "registry crash under Sagents.Supervisor's :one_for_one strategy" do
    test "a peer repairs both membership and registrations after a registry crash" do
      {cluster, [node1, node2]} = start_cluster(2)
      start_supervisor_on([node1, node2])

      both = Enum.sort([node1, node2])

      assert wait_until(fn -> member_nodes(node1, Sagents.Registry) == both end),
             "registry membership did not converge: " <>
               inspect(member_nodes(node1, Sagents.Registry))

      agent_id = "conversation-crash-#{System.unique_integer([:positive])}"
      {:ok, _sup_pid} = rpc(node1, :start_agent, [agent_id])

      assert wait_until(fn ->
               match?({:ok, pid} when is_pid(pid), rpc(node2, :probe_once, [agent_id]))
             end),
             "registration did not replicate to node2"

      {:ok, before_pid} = rpc(node1, :probe_once, [agent_id])
      assert is_pid(before_pid)

      assert {:ok, _dead_pid} = rpc(node1, :kill_registry, [])

      assert wait_until(fn -> rpc(node1, :registered?, [Sagents.Registry]) end),
             "registry was not restarted by Sagents.Supervisor"

      # `ClusterConfig.resolve_members/1` seeds the restarted registry with a
      # self-only member set, and MembershipManager only re-applies members on a
      # :pg join or leave, neither of which happened. Membership is nonetheless
      # restored, because Horde replicates the member set through the same CRDT
      # as registrations and node2 still lists node1 as a neighbour.
      assert wait_until(fn -> member_nodes(node1, Sagents.Registry) == both end),
             "membership did not heal from the peer: " <>
               inspect(member_nodes(node1, Sagents.Registry))

      # The registration comes back for the same reason, pointing at the same
      # still-running process. No agent was lost.
      assert wait_until(fn -> rpc(node1, :probe_once, [agent_id]) == {:ok, before_pid} end),
             "registration did not heal from the peer: " <>
               inspect(rpc(node1, :probe_once, [agent_id]))

      LocalCluster.stop(cluster)
    end

    test "on a single-node cluster the crash takes the agent down rather than orphaning it" do
      {cluster, [node1]} = start_cluster(1)
      start_supervisor_on([node1])

      agent_id = "conversation-orphan-#{System.unique_integer([:positive])}"
      {:ok, first} = rpc(node1, :start_agent, [agent_id])

      {:ok, ^first} = rpc(node1, :agent_supervisor_pid, [agent_id])

      assert {:ok, _dead_pid} = rpc(node1, :kill_registry, [])
      assert wait_until(fn -> rpc(node1, :registered?, [Sagents.Registry]) end)

      # No peer here, so nothing re-supplies the CRDT the way the previous test
      # relies on. Sagents.RegistryWatcher notices the registry going down and
      # fails in its place, and Sagents.Supervisor's :rest_for_one strategy
      # takes the registry's dependents down with it.
      assert wait_until(fn -> not :rpc.call(node1, Process, :alive?, [first]) end),
             "the AgentSupervisor should have been restarted with the registry"

      # Settle, then confirm this is a steady state and not a mid-restart sample.
      Process.sleep(3_000)

      assert wait_until(fn ->
               rpc(node1, :registered?, [Sagents.AgentsDynamicSupervisor])
             end),
             "the agents supervisor should have been restarted too"

      assert {:ok, nil} = rpc(node1, :probe_once, [agent_id])
      assert :rpc.call(node1, Sagents.AgentsDynamicSupervisor, :count_agents, []) == 0

      # Starting again yields one agent, not two, and state is durable so the
      # replacement picks up where its predecessor left off.
      assert {:ok, second} = rpc(node1, :start_agent, [agent_id])
      assert second != first
      assert :rpc.call(node1, Process, :alive?, [second])

      assert :rpc.call(node1, Sagents.AgentsDynamicSupervisor, :count_agents, []) == 1
      assert :rpc.call(node1, Sagents.AgentsDynamicSupervisor, :list_agents, []) == [agent_id]

      LocalCluster.stop(cluster)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp start_cluster(count, opts \\ []) do
    members = Keyword.get(opts, :members, :participation)

    {:ok, cluster} =
      LocalCluster.start_link(count,
        environment: [
          sagents: [distribution: :horde, horde: [members: members]]
        ]
      )

    {:ok, nodes} = LocalCluster.nodes(cluster)
    {cluster, nodes}
  end

  defp start_supervisor_on(nodes) do
    for node <- nodes do
      {:ok, _pid} = :rpc.call(node, Helper, :start_supervisor, [])
    end
  end

  defp rpc(node, fun, args), do: :rpc.call(node, Helper, fun, args)

  defp member_nodes(node, horde), do: rpc(node, :member_nodes, [horde])

  defp wait_until(fun, timeout \\ @converge_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(100)
        do_wait_until(fun, deadline)
      else
        false
      end
    end
  end
end
