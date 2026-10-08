defmodule Sagents.Horde.MembershipManagerTest do
  # async: false + global Mimic because the manager calls Horde.Cluster from its
  # own GenServer process during init.
  use ExUnit.Case, async: false
  use Mimic

  alias Sagents.Horde.MembershipManager

  setup :set_mimic_global

  # What Horde answers for `members/1`, and a mailbox record of every
  # `set_members/2` it receives. The real Horde instances are not running under
  # `:horde` distribution in this suite, so both sides are stubbed.
  defp stub_horde(member_nodes) do
    test_pid = self()

    stub(Horde.Cluster, :members, fn horde -> Enum.map(member_nodes, &{horde, &1}) end)

    stub(Horde.Cluster, :set_members, fn horde, members ->
      send(test_pid, {:set_members, horde, members})
      :ok
    end)
  end

  defp start_manager! do
    start_supervised!(MembershipManager.pg_scope_spec())
    start_supervised!(MembershipManager)
  end

  describe "member_nodes/1" do
    test "dedups and sorts the nodes hosting participation markers" do
      assert MembershipManager.member_nodes([self(), self()]) == [node()]
    end

    test "returns [] for no markers" do
      assert MembershipManager.member_nodes([]) == []
    end
  end

  describe "group_for/1" do
    test "uses the base group when unpartitioned" do
      assert MembershipManager.group_for(nil) == :sagents_members
    end

    test "keys the group by partition when set" do
      assert MembershipManager.group_for("ord") == {:sagents_members, "ord"}
    end
  end

  describe "partitioned membership" do
    setup do
      original = Application.get_env(:sagents, :horde)
      Application.put_env(:sagents, :horde, members: :participation, partition: "ord")

      on_exit(fn ->
        if original,
          do: Application.put_env(:sagents, :horde, original),
          else: Application.delete_env(:sagents, :horde)
      end)

      :ok
    end

    test "joins the partition group and adds its members" do
      stub_horde([])
      start_manager!()

      # The manager joined this node into the "ord" group, so membership is the
      # self-node and a marker pid is present in the partitioned group.
      for horde <- MembershipManager.hordes() do
        assert_receive {:set_members, ^horde, members}
        assert members == [{horde, node()}]
      end

      assert [_pid] = :pg.get_members(MembershipManager.scope(), {:sagents_members, "ord"})
      assert :pg.get_members(MembershipManager.scope(), :sagents_members) == []
    end
  end

  describe "membership application on startup" do
    test "adds the nodes in view that the Horde clusters do not hold yet" do
      stub_horde([])
      start_manager!()

      # Only this node participates, so each cluster gains the self-node.
      for horde <- MembershipManager.hordes() do
        assert_receive {:set_members, ^horde, members}
        assert members == [{horde, node()}]
      end
    end

    test "leaves the Horde clusters alone when the view adds nothing" do
      # Horde already holds this node from its own initial members.
      stub_horde([node()])
      start_manager!()

      refute_receive {:set_members, _horde, _members}, 200
    end

    test "never removes members a partial view does not show" do
      # :pg discovery is asynchronous: at init the group can show only this
      # node while Horde, through replication, already holds a peer. Handing
      # that view to Horde as the member set would remove the peer and drop
      # every registration it owns, cluster-wide.
      stub_horde([node(), :"peer@127.0.0.1"])
      start_manager!()

      refute_receive {:set_members, _horde, _members}, 200
    end
  end

  describe "membership changes" do
    test "a second marker pid on the same node changes nothing" do
      stub_horde([node()])
      start_manager!()

      # Membership is by node, not pid, so another marker here adds no member.
      extra = spawn(fn -> Process.sleep(:infinity) end)
      :ok = :pg.join(MembershipManager.scope(), MembershipManager.group(), extra)

      refute_receive {:set_members, _horde, _members}, 200
    end

    test "a marker pid leaving while another remains removes nothing" do
      stub_horde([node(), :"peer@127.0.0.1"])
      start_manager!()

      extra = spawn(fn -> Process.sleep(:infinity) end)
      :ok = :pg.join(MembershipManager.scope(), MembershipManager.group(), extra)
      :ok = :pg.leave(MembershipManager.scope(), MembershipManager.group(), extra)

      refute_receive {:set_members, _horde, _members}, 200
    end

    test "a node whose last marker pid left is removed, and only that node" do
      stub_horde([node(), :"peer@127.0.0.1"])
      manager = start_manager!()

      # The manager's own marker is this node's last one.
      :ok = :pg.leave(MembershipManager.scope(), MembershipManager.group(), manager)

      for horde <- MembershipManager.hordes() do
        assert_receive {:set_members, ^horde, members}
        assert members == [{horde, :"peer@127.0.0.1"}]
      end
    end
  end
end
