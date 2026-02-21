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

    test "validates list members config" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: [{SomeModule, :nonode@nohost}])

      assert :ok = ClusterConfig.validate!()
    end

    test "validates MFA members config" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: {SomeModule, :some_function, ["region"]})

      assert :ok = ClusterConfig.validate!()
    end

    test "raises on invalid members config" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: "invalid")

      assert_raise RuntimeError, ~r/Invalid :members configuration/, fn ->
        ClusterConfig.validate!()
      end
    end

    test "raises on invalid list members (not {module, node} tuples)" do
      Application.put_env(:sagents, :distribution, :horde)
      Application.put_env(:sagents, :horde, members: ["not_a_tuple"])

      assert_raise RuntimeError, ~r/Expected list of \{module, node\} tuples/, fn ->
        ClusterConfig.validate!()
      end
    end
  end

  describe "resolve_members/1" do
    test "returns auto members when config is :auto" do
      Application.put_env(:sagents, :horde, members: :auto)

      result = ClusterConfig.resolve_members(TestModule)
      assert [{TestModule, node}] = result
      assert node == Node.self()
    end

    test "returns auto members when config is nil" do
      Application.delete_env(:sagents, :horde)

      result = ClusterConfig.resolve_members(TestModule)
      assert [{TestModule, node}] = result
      assert node == Node.self()
    end

    test "returns static list when provided" do
      members = [{MyModule, :node1@host}, {MyModule, :node2@host}]
      Application.put_env(:sagents, :horde, members: members)

      assert ^members = ClusterConfig.resolve_members(TestModule)
    end

    test "calls function when provided" do
      Application.put_env(:sagents, :horde, members: fn -> [{TestModule, :test@host}] end)

      assert [{TestModule, :test@host}] = ClusterConfig.resolve_members(TestModule)
    end
  end

  describe "auto_members/1" do
    test "includes current node" do
      result = ClusterConfig.auto_members(TestModule)
      assert [{TestModule, node}] = result
      assert node == Node.self()
    end
  end
end
