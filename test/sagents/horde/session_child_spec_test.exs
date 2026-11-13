defmodule Sagents.Horde.SessionChildSpecTest do
  @moduledoc """
  Under `:horde`, an agent started through `Sagents.Session` is replicated
  across the cluster without its built `%Agent{}` or its loaded state, and the
  hosting node builds both.

  Run with: mix test --include cluster
  """
  use ExUnit.Case, async: false

  @moduletag :cluster

  alias Sagents.ClusterSessionHelper

  @replication_timeout 10_000

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
      {:ok, _pid} = :rpc.call(node, ClusterSessionHelper, :start_pubsub, [])
      {:ok, _pid} = :rpc.call(node, Sagents.ClusterTestHelper, :start_supervisor, [])
    end

    # Let :pg participation and the Horde CRDTs converge before placing agents.
    Process.sleep(2_000)

    on_exit(fn -> LocalCluster.stop(cluster) end)

    %{nodes: nodes}
  end

  test "replicates the start without the agent or its state", %{nodes: [node1, node2]} do
    conversation_id = System.unique_integer([:positive])
    agent_id = "cluster-session-#{conversation_id}"

    assert {:ok, %{agent_id: ^agent_id, pid: pid}} =
             :rpc.call(node1, ClusterSessionHelper, :start_session, [conversation_id])

    # Read the replica on the node that did not start it, so the options seen
    # are the ones the CRDT carried there.
    assert {:ok, opts} = wait_for_replica(node2, agent_id)

    refute Keyword.has_key?(opts, :agent)
    refute Keyword.has_key?(opts, :initial_state)
    assert {Sagents.Session, :build_start_opts, [_build_args]} = Keyword.fetch!(opts, :builder)

    # Far below the 50 KB system prompt the factory builds.
    assert :erlang.external_size(opts) < 5_000

    # The hosting node built the agent and loaded its state.
    assert %{prompt_bytes: 50_000, todos: [%Sagents.Todo{content: "from persistence"}]} =
             :rpc.call(node(pid), ClusterSessionHelper, :running_agent_summary, [agent_id])
  end

  defp wait_for_replica(node, agent_id) do
    deadline = System.monotonic_time(:millisecond) + @replication_timeout
    do_wait_for_replica(node, agent_id, deadline)
  end

  defp do_wait_for_replica(node, agent_id, deadline) do
    case :rpc.call(node, ClusterSessionHelper, :replicated_start_opts, [agent_id]) do
      opts when is_list(opts) ->
        {:ok, opts}

      _other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          do_wait_for_replica(node, agent_id, deadline)
        else
          {:error, :timeout}
        end
    end
  end
end
