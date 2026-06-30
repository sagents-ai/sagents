defmodule Sagents.Horde.ParticipationMembershipTest do
  @moduledoc """
  Multi-node tests that `members: :participation` scopes Horde membership to
  exactly the nodes running `Sagents.Supervisor` — and keeps it current as those
  nodes come and go.

  Uses LocalCluster to start real Erlang nodes. Run with:

      mix test --include cluster
  """
  use ExUnit.Case, async: false

  @moduletag :cluster

  @converge_timeout 10_000

  @hordes [
    Sagents.Registry,
    Sagents.AgentsDynamicSupervisor,
    Sagents.FileSystem.FileSystemSupervisor
  ]

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

  describe "members: :participation" do
    test "membership is scoped to nodes running Sagents.Supervisor" do
      {cluster, [web1, web2, other]} = start_participation_cluster(3)

      # Start Sagents.Supervisor on the two "web" nodes only. `other` is connected
      # but does not participate (mirrors a non-agent service role).
      start_supervisor_on([web1, web2])

      expected = Enum.sort([web1, web2])

      # Both participating nodes converge to exactly the participating member set.
      assert wait_until(fn -> members(web1, Sagents.AgentsDynamicSupervisor) == expected end),
             "web1 members: #{inspect(members(web1, Sagents.AgentsDynamicSupervisor))}"

      assert wait_until(fn -> members(web2, Sagents.AgentsDynamicSupervisor) == expected end)

      # All three Horde clusters are scoped identically, as seen from each node.
      for node <- [web1, web2], horde <- @hordes do
        assert members(node, horde) == expected,
               "#{inspect(horde)} on #{inspect(node)}: #{inspect(members(node, horde))}"
      end

      # The non-participating node and the test runner are NOT members — the very
      # thing :auto gets wrong (it would include both).
      assert other not in members(web1, Sagents.AgentsDynamicSupervisor)
      assert node() not in members(web1, Sagents.AgentsDynamicSupervisor)

      LocalCluster.stop(cluster)
    end

    test "a departing participant is pruned from membership" do
      {cluster, [web1, web2]} = start_participation_cluster(2)
      start_supervisor_on([web1, web2])

      assert wait_until(fn ->
               members(web1, Sagents.AgentsDynamicSupervisor) == Enum.sort([web1, web2])
             end)

      # web2 leaves the cluster; :pg drops it and the manager re-applies.
      LocalCluster.stop(cluster, web2)

      assert wait_until(fn -> members(web1, Sagents.AgentsDynamicSupervisor) == [web1] end),
             "web1 members after web2 left: #{inspect(members(web1, Sagents.AgentsDynamicSupervisor))}"

      LocalCluster.stop(cluster)
    end
  end

  describe "members: :participation with partition" do
    test "membership is isolated per partition within one connected cluster" do
      {cluster, [ord1, ord2, cdg1, cdg2]} = start_participation_cluster(4)

      # All four nodes are one connected BEAM cluster, but split into two
      # partitions. Set each node's partition before starting its supervisor.
      set_partition_on([ord1, ord2], "ord")
      set_partition_on([cdg1, cdg2], "cdg")
      start_supervisor_on([ord1, ord2, cdg1, cdg2])

      ord = Enum.sort([ord1, ord2])
      cdg = Enum.sort([cdg1, cdg2])

      # Each partition converges to only its own nodes, for all three instances.
      for node <- [ord1, ord2], horde <- @hordes do
        assert wait_until(fn -> members(node, horde) == ord end),
               "#{inspect(horde)} on ord node #{inspect(node)}: #{inspect(members(node, horde))}"
      end

      for node <- [cdg1, cdg2], horde <- @hordes do
        assert wait_until(fn -> members(node, horde) == cdg end),
               "#{inspect(horde)} on cdg node #{inspect(node)}: #{inspect(members(node, horde))}"
      end

      # The partitions are disjoint — no cross-partition members.
      assert ord1 not in members(cdg1, Sagents.AgentsDynamicSupervisor)
      assert cdg1 not in members(ord1, Sagents.AgentsDynamicSupervisor)

      LocalCluster.stop(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_participation_cluster(count) do
    {:ok, cluster} =
      LocalCluster.start_link(count,
        environment: [
          sagents: [distribution: :horde, horde: [members: :participation]]
        ]
      )

    {:ok, nodes} = LocalCluster.nodes(cluster)
    {cluster, nodes}
  end

  defp start_supervisor_on(nodes) do
    for node <- nodes do
      {:ok, _pid} = :rpc.call(node, Sagents.ClusterTestHelper, :start_supervisor, [])
    end
  end

  # Set each node's partition before its supervisor (and thus its membership
  # manager) starts, so it joins the right partition's :pg group.
  defp set_partition_on(nodes, partition) do
    for node <- nodes do
      :ok =
        :rpc.call(node, Application, :put_env, [
          :sagents,
          :horde,
          [members: :participation, partition: partition]
        ])
    end
  end

  # The node()s currently in `horde`'s member set, as observed from `node`.
  defp members(node, horde) do
    :rpc.call(node, Horde.Cluster, :members, [horde])
    |> Enum.map(fn {_name, member_node} -> member_node end)
    |> Enum.uniq()
    |> Enum.sort()
  end

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
