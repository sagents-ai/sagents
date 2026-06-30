defmodule Sagents.Horde.MembershipManagerTest do
  # async: false + global Mimic because the manager calls Horde.Cluster from its
  # own GenServer process during init.
  use ExUnit.Case, async: false
  use Mimic

  alias Sagents.Horde.MembershipManager

  setup :set_mimic_global

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

    test "joins the partition group and sets members from it" do
      test_pid = self()

      stub(Horde.Cluster, :set_members, fn horde, members ->
        send(test_pid, {:set_members, horde, members})
        :ok
      end)

      start_supervised!(MembershipManager.pg_scope_spec())
      start_supervised!(MembershipManager)

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
    test "sets members on all three Horde clusters scoped to participating nodes" do
      test_pid = self()

      stub(Horde.Cluster, :set_members, fn horde, members ->
        send(test_pid, {:set_members, horde, members})
        :ok
      end)

      start_supervised!(MembershipManager.pg_scope_spec())
      start_supervised!(MembershipManager)

      # Only this node participates, so each cluster's members is the self-node.
      for horde <- MembershipManager.hordes() do
        assert_receive {:set_members, ^horde, members}
        assert members == [{horde, node()}]
      end
    end

    test "re-applies membership when the participation group changes" do
      test_pid = self()

      stub(Horde.Cluster, :set_members, fn horde, members ->
        send(test_pid, {:set_members, horde, members})
        :ok
      end)

      start_supervised!(MembershipManager.pg_scope_spec())
      start_supervised!(MembershipManager)

      # Drain the startup set_members messages.
      for horde <- MembershipManager.hordes() do
        assert_receive {:set_members, ^horde, _members}
      end

      # A second marker pid on this same node must NOT change the node set, so no
      # further set_members calls should fire (membership is by node, not pid).
      extra = spawn(fn -> Process.sleep(:infinity) end)
      :ok = :pg.join(MembershipManager.scope(), MembershipManager.group(), extra)

      refute_receive {:set_members, _horde, _members}, 200
    end
  end
end
