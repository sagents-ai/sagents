defmodule Sagents.Horde.ClusterConfigTest do
  use ExUnit.Case, async: false

  alias Sagents.Horde.ClusterConfig

  # Store original config values
  setup do
    original_distribution = Application.get_env(:sagents, :distribution)
    original_horde = Application.get_env(:sagents, :horde)

    on_exit(fn ->
      if original_distribution,
        do: Application.put_env(:sagents, :distribution, original_distribution),
        else: Application.delete_env(:sagents, :distribution)

      if original_horde,
        do: Application.put_env(:sagents, :horde, original_horde),
        else: Application.delete_env(:sagents, :horde)
    end)

    :ok
  end

  describe "validate!/0" do
    test "passes with :local distribution" do
      Application.put_env(:sagents, :distribution, :local)

      assert :ok = ClusterConfig.validate!()
    end

    test "passes with no config set (defaults to :local)" do
      Application.delete_env(:sagents, :distribution)

      assert :ok = ClusterConfig.validate!()
    end

    test "passes with :horde distribution" do
      Application.put_env(:sagents, :distribution, :horde)

      assert :ok = ClusterConfig.validate!()
    end

    test "raises error on unrecognized distribution type" do
      Application.put_env(:sagents, :distribution, :invalid)

      assert_raise RuntimeError,
                   ~r/unrecognized distribution type/,
                   fn ->
                     ClusterConfig.validate!()
                   end
    end

    test "validates :auto members config" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: :auto)

      assert :ok = ClusterConfig.validate!()
    end

    test "validates :participation members config" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: :participation)

      assert :ok = ClusterConfig.validate!()
    end

    test "validates :participation with a partition" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: :participation, partition: "ord")

      assert :ok = ClusterConfig.validate!()
    end

    test "raises when :partition is set with non-:participation members" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: :auto, partition: "ord")

      assert_raise ArgumentError, ~r/:partition only applies to participation/, fn ->
        ClusterConfig.validate!()
      end
    end

    test "raises on a string members config" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: "invalid")

      assert_raise ArgumentError, ~r/Invalid :members configuration/, fn ->
        ClusterConfig.validate!()
      end
    end

    test "raises on a now-unsupported static list members config" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: [{SomeModule, :nonode@nohost}])

      assert_raise ArgumentError, ~r/Invalid :members configuration/, fn ->
        ClusterConfig.validate!()
      end
    end
  end

  describe "resolve_members/1" do
    test "passes the literal :auto atom through to Horde when config is :auto" do
      Application.put_env(:sagents, :horde, members: :auto)

      assert :auto = ClusterConfig.resolve_members(TestModule)
    end

    test "passes the literal :auto atom through when no members config is set" do
      Application.delete_env(:sagents, :horde)

      assert :auto = ClusterConfig.resolve_members(TestModule)
    end

    test "returns a self-only seed for :participation" do
      Application.put_env(:sagents, :horde, members: :participation)

      assert [{TestModule, node}] = ClusterConfig.resolve_members(TestModule)
      assert node == Node.self()
    end

    test "raises for an unsupported members value" do
      Application.put_env(:sagents, :horde, members: [{MyModule, :node1@host}])

      assert_raise ArgumentError, ~r/Invalid :members configuration/, fn ->
        ClusterConfig.resolve_members(TestModule)
      end
    end
  end

  describe "participation_membership?/0" do
    test "true under :horde with members: :participation" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: :participation)

      assert ClusterConfig.participation_membership?()
    end

    test "false when members is not :participation" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: :auto)

      refute ClusterConfig.participation_membership?()
    end

    test "false under :local even if members: :participation" do
      Application.put_env(:sagents, :distribution, :local)
      Application.put_env(:sagents, :horde, members: :participation)

      refute ClusterConfig.participation_membership?()
    end
  end

  describe "partition/0" do
    test "returns the configured partition" do
      Application.put_env(:sagents, :horde, members: :participation, partition: "ord")

      assert ClusterConfig.partition() == "ord"
    end

    test "returns nil when unset" do
      Application.put_env(:sagents, :horde, members: :participation)

      assert ClusterConfig.partition() == nil
    end
  end
end
