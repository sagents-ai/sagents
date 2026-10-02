defmodule Sagents.ClosuresTest do
  use ExUnit.Case, async: true

  alias Sagents.Closures

  doctest Sagents.Closures

  # Compiles `module` with a closure-returning function. A different `build`
  # value produces different bytecode, the way a new release does.
  defp compile(module, build) do
    Code.put_compiler_option(:ignore_module_conflict, true)

    Code.compile_string("""
    defmodule #{inspect(module)} do
      def build, do: #{inspect(build)}
      def closure, do: fn value -> value end
      def wrapping(inner), do: fn value -> inner.(value) end
    end
    """)

    :ok
  end

  defp unique_module, do: :"Elixir.Sagents.ClosuresTest.M#{System.unique_integer([:positive])}"

  describe "stale_modules/1" do
    test "reports nothing for a term without functions" do
      assert [] == Closures.stale_modules(%{a: [1, "two", {:three, 4.0}], b: nil})
    end

    test "reports nothing for closures created by the loaded version of a module" do
      module = unique_module()
      compile(module, 1)

      assert [] == Closures.stale_modules(tools: [%{function: module.closure()}])
    end

    test "reports the module of a closure created by a version that is no longer loaded" do
      module = unique_module()
      compile(module, 1)
      closure = module.closure()
      compile(module, 2)

      assert [module] == Closures.stale_modules(closure)
    end

    test "finds closures nested in structs, maps, tuples, and lists" do
      module = unique_module()
      compile(module, 1)
      closure = module.closure()
      compile(module, 2)

      assert [module] == Closures.stale_modules(%{a: [{:ok, %URI{path: closure}}]})
      assert [module] == Closures.stale_modules(%{closure => :as_a_key})
      assert [module] == Closures.stale_modules([:improper | closure])
    end

    test "finds a closure captured by another closure" do
      inner_module = unique_module()
      outer_module = unique_module()
      compile(inner_module, 1)
      compile(outer_module, 1)
      wrapped = outer_module.wrapping(inner_module.closure())
      compile(inner_module, 2)

      assert [inner_module] == Closures.stale_modules(wrapped)
    end

    test "never reports a capture of a named function" do
      module = unique_module()
      compile(module, 1)
      capture = Function.capture(module, :build, 0)
      compile(module, 2)

      assert [] == Closures.stale_modules(capture)
      assert 2 == capture.()
    end

    test "reports a closure whose module does not exist on this node" do
      module = unique_module()
      compile(module, 1)
      closure = module.closure()
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)

      assert [module] == Closures.stale_modules(closure)
    end
  end
end
