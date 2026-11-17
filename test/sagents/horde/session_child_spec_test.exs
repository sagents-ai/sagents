defmodule Sagents.Horde.SessionChildSpecTest do
  @moduledoc """
  Under `:horde`, an agent started through `Sagents.Session` is replicated
  across the cluster without its built `%Agent{}` or its loaded state.

  When Horde places the agent on the node that requested the start, it starts
  from the build made in the calling process, so the factory runs once, with
  the caller's process context. When Horde places it on another node, that node
  builds it in the agent's own supervisor process.

  Run with: mix test --include cluster
  """
  use ExUnit.Case, async: false

  @moduletag :cluster

  alias Sagents.ClusterSessionHelper

  @replication_timeout 10_000
  @probe :session_child_spec_probe

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

  setup do
    Process.register(self(), @probe)
    :ok
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

  test "a start placed on the requesting node runs the factory once, in the caller",
       %{nodes: [node1, _node2]} do
    {agent_id, pid, runs} = start_placed(node1, node1)

    assert [{:factory_ran, ^agent_id, ^node1, _caller, "caller"}] = runs

    # Built in the caller, so ProcessContext captured the caller's marker and
    # applied it in the AgentServer.
    assert "caller" == :rpc.call(node1, ClusterSessionHelper, :agent_server_marker, [agent_id])
    assert node1 == node(pid)

    assert %{prompt_bytes: 50_000, todos: [%Sagents.Todo{content: "from persistence"}]} =
             :rpc.call(node1, ClusterSessionHelper, :running_agent_summary, [agent_id])

    # The start used the handed-off build and nothing is left waiting.
    assert 0 == :rpc.call(node1, ClusterSessionHelper, :handoff_entries, [])

    # The replica still carries no agent or state.
    assert {:ok, opts} = wait_for_replica(node1, agent_id)
    refute Keyword.has_key?(opts, :agent)
    refute Keyword.has_key?(opts, :initial_state)
    assert is_reference(Keyword.fetch!(opts, :build_handoff))
  end

  test "a start placed on another node builds there, in the agent's own supervisor",
       %{nodes: [node1, node2]} do
    {agent_id, pid, runs} = start_placed(node1, node2)

    assert [
             {:factory_ran, ^agent_id, ^node1, _caller, "caller"},
             {:factory_ran, ^agent_id, ^node2, builder_pid, nil}
           ] = runs

    assert node2 == node(pid)

    # The hosting node's build runs in the AgentSupervisor, not in Horde's
    # shared ProcessesSupervisor.
    assert {:ok, ^builder_pid} =
             :rpc.call(node2, Sagents.AgentSupervisor, :get_pid, [agent_id])

    assert %{prompt_bytes: 50_000, todos: [%Sagents.Todo{content: "from persistence"}]} =
             :rpc.call(node2, ClusterSessionHelper, :running_agent_summary, [agent_id])

    # The requesting node removed the build nobody took.
    assert 0 == :rpc.call(node1, ClusterSessionHelper, :handoff_entries, [])
  end

  # Starts sessions from `from_node` until Horde places one on `on_node`, and
  # returns that agent's id, AgentServer pid, and the factory runs it caused.
  # Placement hashes the child spec, so a fresh conversation lands on either of
  # two nodes with equal odds; agents placed elsewhere are stopped.
  defp start_placed(from_node, on_node, attempts \\ 40)

  defp start_placed(_from_node, on_node, 0),
    do: flunk("no start was placed on #{inspect(on_node)}")

  defp start_placed(from_node, on_node, attempts) do
    conversation_id = System.unique_integer([:positive])
    agent_id = "cluster-session-#{conversation_id}"
    request_opts = [report_to: {@probe, node()}]

    assert {:ok, %{agent_id: ^agent_id, pid: pid}} =
             :rpc.call(from_node, ClusterSessionHelper, :start_session, [
               conversation_id,
               request_opts,
               "caller"
             ])

    runs = collect_factory_runs(agent_id)

    if node(pid) == on_node do
      {agent_id, pid, runs}
    else
      :ok = :rpc.call(from_node, Sagents.AgentsDynamicSupervisor, :stop_agent, [agent_id])
      start_placed(from_node, on_node, attempts - 1)
    end
  end

  # Every factory run for a start sends its report before Session.start/3
  # returns, since the hosting node builds before the AgentServer registers.
  # Messages from two different nodes are not ordered with each other, so a
  # short quiet period covers the report still in flight.
  defp collect_factory_runs(agent_id, runs \\ []) do
    receive do
      {:factory_ran, ^agent_id, _node, _pid, _marker} = run ->
        collect_factory_runs(agent_id, [run | runs])
    after
      200 -> Enum.reverse(runs)
    end
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
