defmodule Sagents.AgentContextTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sagents.AgentContext
  alias Sagents.Middleware
  alias Sagents.MiddlewareEntry

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

  describe "add_restore_fn/2" do
    test "appends a restore function to __context_restore_fns__" do
      context = %{trace_id: "abc"}
      fun1 = fn _ctx -> :ok end
      fun2 = fn _ctx -> :ok end

      context = AgentContext.add_restore_fn(context, fun1)
      assert [^fun1] = context.__context_restore_fns__

      context = AgentContext.add_restore_fn(context, fun2)
      assert [^fun1, ^fun2] = context.__context_restore_fns__
    end

    test "creates __context_restore_fns__ key if not present" do
      context = %{trace_id: "abc"}
      fun = fn _ctx -> :ok end
      result = AgentContext.add_restore_fn(context, fun)
      assert Map.has_key?(result, :__context_restore_fns__)
      assert [^fun] = result.__context_restore_fns__
    end
  end

  describe "init/1 with restore functions" do
    test "calls restore functions and strips __context_restore_fns__" do
      test_pid = self()
      fun1 = fn ctx -> send(test_pid, {:restored, 1, ctx}) end
      fun2 = fn ctx -> send(test_pid, {:restored, 2, ctx}) end

      context = %{trace_id: "abc", __context_restore_fns__: [fun1, fun2]}
      assert :ok = AgentContext.init(context)

      # Restore functions should have been called with clean context
      clean = %{trace_id: "abc"}
      assert_receive {:restored, 1, ^clean}
      assert_receive {:restored, 2, ^clean}

      # Stored context should not contain __context_restore_fns__
      assert AgentContext.get() == clean
    end

    test "handles restore function failures gracefully" do
      test_pid = self()
      failing_fn = fn _ctx -> raise "boom" end
      ok_fn = fn ctx -> send(test_pid, {:restored, ctx}) end

      context = %{key: "val", __context_restore_fns__: [failing_fn, ok_fn]}

      log =
        capture_log(fn ->
          assert :ok = AgentContext.init(context)
        end)

      # The failing function should have been logged
      assert log =~ "AgentContext restore function failed"
      assert log =~ "boom"

      # The second function should still have been called
      clean = %{key: "val"}
      assert_receive {:restored, ^clean}

      # Context should still be stored correctly
      assert AgentContext.get() == clean
    end

    test "works normally when no restore functions present" do
      context = %{trace_id: "abc"}
      assert :ok = AgentContext.init(context)
      assert AgentContext.get() == context
    end
  end

  describe "fork_with_middleware/1" do
    defmodule ForkInjector do
      @behaviour Sagents.Middleware

      @impl true
      def on_fork_context(context, config) do
        context
        |> Map.put(:injected_by, config.name)
        |> AgentContext.add_restore_fn(fn _ctx -> :ok end)
      end
    end

    defmodule NoForkMiddleware do
      @behaviour Sagents.Middleware
      # Does not implement on_fork_context/2
    end

    test "returns context unchanged with empty middleware list" do
      AgentContext.init(%{trace_id: "abc"})
      result = AgentContext.fork_with_middleware([])
      assert result == %{trace_id: "abc"}
    end

    test "applies on_fork_context from middleware that implements it" do
      AgentContext.init(%{trace_id: "abc"})

      entry = %MiddlewareEntry{
        id: ForkInjector,
        module: ForkInjector,
        config: %{name: "test_injector"}
      }

      result = AgentContext.fork_with_middleware([entry])
      assert result.trace_id == "abc"
      assert result.injected_by == "test_injector"
      assert is_list(result.__context_restore_fns__)
      assert length(result.__context_restore_fns__) == 1
    end

    test "passes through unchanged for middleware without on_fork_context" do
      AgentContext.init(%{trace_id: "abc"})

      entry = Middleware.init_middleware(NoForkMiddleware)

      result = AgentContext.fork_with_middleware([entry])
      assert result == %{trace_id: "abc"}
    end

    test "applies middleware in order" do
      defmodule ForkInjectorA do
        @behaviour Sagents.Middleware

        @impl true
        def on_fork_context(context, _config) do
          order = Map.get(context, :order, [])
          Map.put(context, :order, order ++ [:a])
        end
      end

      defmodule ForkInjectorB do
        @behaviour Sagents.Middleware

        @impl true
        def on_fork_context(context, _config) do
          order = Map.get(context, :order, [])
          Map.put(context, :order, order ++ [:b])
        end
      end

      AgentContext.init(%{trace_id: "abc"})

      entries = [
        %MiddlewareEntry{id: ForkInjectorA, module: ForkInjectorA, config: %{}},
        %MiddlewareEntry{id: ForkInjectorB, module: ForkInjectorB, config: %{}}
      ]

      result = AgentContext.fork_with_middleware(entries)
      assert result.order == [:a, :b]
    end

    test "does not modify the original process context" do
      AgentContext.init(%{trace_id: "abc"})

      entry = %MiddlewareEntry{
        id: ForkInjector,
        module: ForkInjector,
        config: %{name: "test"}
      }

      _result = AgentContext.fork_with_middleware([entry])
      assert AgentContext.get() == %{trace_id: "abc"}
    end
  end
end
