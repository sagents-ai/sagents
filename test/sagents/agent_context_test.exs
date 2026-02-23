defmodule Sagents.AgentContextTest do
  use ExUnit.Case, async: true

  alias Sagents.AgentContext

  describe "init/1" do
    test "sets context in process dictionary" do
      ctx = %{trace_id: "abc", tenant_id: 42}
      assert :ok = AgentContext.init(ctx)
      assert AgentContext.get() == ctx
    end

    test "overwrites previous context" do
      AgentContext.init(%{a: 1})
      AgentContext.init(%{b: 2})
      assert AgentContext.get() == %{b: 2}
    end
  end

  describe "get/0" do
    test "returns empty map when no context initialized" do
      # Run in a fresh process to guarantee no PD pollution
      task =
        Task.async(fn ->
          AgentContext.get()
        end)

      assert Task.await(task) == %{}
    end

    test "returns the initialized context" do
      ctx = %{trace_id: "xyz"}
      AgentContext.init(ctx)
      assert AgentContext.get() == ctx
    end
  end

  describe "fetch/2" do
    test "returns value for existing key" do
      AgentContext.init(%{tenant_id: 42})
      assert AgentContext.fetch(:tenant_id) == 42
    end

    test "returns default for missing key" do
      AgentContext.init(%{tenant_id: 42})
      assert AgentContext.fetch(:missing, :default_val) == :default_val
    end

    test "returns nil as default when not specified" do
      AgentContext.init(%{})
      assert AgentContext.fetch(:missing) == nil
    end
  end

  describe "fork/1" do
    test "returns a copy of the current context" do
      ctx = %{trace_id: "abc", tenant_id: 42}
      AgentContext.init(ctx)
      forked = AgentContext.fork()
      assert forked == ctx
    end

    test "applies transform function" do
      AgentContext.init(%{trace_id: "abc"})
      forked = AgentContext.fork(fn ctx -> Map.put(ctx, :parent_span_id, "span-1") end)
      assert forked == %{trace_id: "abc", parent_span_id: "span-1"}
    end

    test "fork does not modify original context" do
      ctx = %{trace_id: "abc"}
      AgentContext.init(ctx)
      _forked = AgentContext.fork(fn c -> Map.put(c, :extra, true) end)
      assert AgentContext.get() == ctx
    end

    test "returns empty map when no context set" do
      task =
        Task.async(fn ->
          AgentContext.fork()
        end)

      assert Task.await(task) == %{}
    end
  end

  describe "process isolation" do
    test "context is isolated between processes" do
      AgentContext.init(%{process: :parent})

      task =
        Task.async(fn ->
          AgentContext.init(%{process: :child})
          AgentContext.get()
        end)

      child_ctx = Task.await(task)
      assert child_ctx == %{process: :child}
      assert AgentContext.get() == %{process: :parent}
    end
  end

  describe "explicit fork + init propagation" do
    test "fork then init in child process propagates context" do
      AgentContext.init(%{trace_id: "parent-trace"})
      forked = AgentContext.fork()

      task =
        Task.async(fn ->
          AgentContext.init(forked)
          AgentContext.get()
        end)

      assert Task.await(task) == %{trace_id: "parent-trace"}
    end

    test "fork with transform propagates modified context" do
      AgentContext.init(%{trace_id: "parent-trace"})
      forked = AgentContext.fork(fn ctx -> Map.put(ctx, :depth, 1) end)

      task =
        Task.async(fn ->
          AgentContext.init(forked)
          {AgentContext.get(), AgentContext.fetch(:depth)}
        end)

      {child_ctx, depth} = Task.await(task)
      assert child_ctx == %{trace_id: "parent-trace", depth: 1}
      assert depth == 1
      # Parent unchanged
      assert AgentContext.get() == %{trace_id: "parent-trace"}
    end

    test "child init does not affect parent" do
      AgentContext.init(%{trace_id: "parent"})
      forked = AgentContext.fork()

      task =
        Task.async(fn ->
          AgentContext.init(Map.put(forked, :child_only, true))
          AgentContext.get()
        end)

      child_ctx = Task.await(task)
      assert child_ctx == %{trace_id: "parent", child_only: true}
      assert AgentContext.get() == %{trace_id: "parent"}
    end
  end
end
