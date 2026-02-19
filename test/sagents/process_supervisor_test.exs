defmodule Sagents.ProcessSupervisorTest do
  use ExUnit.Case, async: true

  alias Sagents.ProcessSupervisor

  describe "with :local configuration" do
    test "supervisor_module/0 returns DynamicSupervisor" do
      assert ProcessSupervisor.supervisor_module() == DynamicSupervisor
    end

    test "distribution_type/0 returns :local" do
      assert ProcessSupervisor.distribution_type() == :local
    end

    test "agents_supervisor_child_spec/0 returns DynamicSupervisor spec" do
      spec = ProcessSupervisor.agents_supervisor_child_spec([])
      assert {DynamicSupervisor, opts} = spec
      assert Keyword.get(opts, :name) == Sagents.AgentsDynamicSupervisor
      assert Keyword.get(opts, :strategy) == :one_for_one
    end

    test "filesystem_supervisor_child_spec/0 returns DynamicSupervisor spec" do
      spec = ProcessSupervisor.filesystem_supervisor_child_spec([])
      assert {DynamicSupervisor, opts} = spec
      assert Keyword.get(opts, :name) == Sagents.FileSystem.FileSystemSupervisor
      assert Keyword.get(opts, :strategy) == :one_for_one
    end
  end

  describe "start_child/2" do
    test "delegates to DynamicSupervisor in default mode" do
      # The AgentsDynamicSupervisor is already running from application startup
      # Starting a simple agent to verify the delegation works
      child_spec = %{
        id: :test_child,
        start: {Agent, :start_link, [fn -> :ok end]},
        restart: :temporary
      }

      assert {:ok, pid} =
               ProcessSupervisor.start_child(Sagents.AgentsDynamicSupervisor, child_spec)

      assert Process.alive?(pid)
      ProcessSupervisor.terminate_child(Sagents.AgentsDynamicSupervisor, pid)
    end
  end

  describe "which_children/1" do
    test "returns a list" do
      result = ProcessSupervisor.which_children(Sagents.AgentsDynamicSupervisor)
      assert is_list(result)
    end
  end

  describe "count_children/1" do
    test "returns a map with counts" do
      result = ProcessSupervisor.count_children(Sagents.AgentsDynamicSupervisor)
      assert is_map(result)
      assert Map.has_key?(result, :active)
    end
  end
end
