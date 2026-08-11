defmodule Sagents.ProcessRegistryAvailabilityTest do
  @moduledoc """
  Unit coverage for `Sagents.ProcessRegistry`'s availability contract: which
  functions report an unavailable registry as a value, which raise, and the
  guarantee that neither ever answers with a plausible-looking default.

  The test suite runs with `config :sagents, :distribution, :local` and a live
  `Sagents.Supervisor`, so the available path is exercised directly. The
  unavailable path is exercised by pointing the backend at a registry name that
  has no table, which is precisely the condition a draining node is in.

  The multi-node behaviour is covered in
  `test/sagents/horde/rolling_deploy_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Sagents.{AgentServer, AgentSupervisor, ProcessRegistry}

  describe "available?/1 with a live registry" do
    test "reports true and names the registry the tests actually use" do
      assert ProcessRegistry.available?()
      assert ProcessRegistry.registry_name() == Sagents.Registry
    end

    test "ensure_available!/1 passes through" do
      assert :ok = ProcessRegistry.ensure_available!(:some_operation)
    end

    test "the ETS table it checks is the one the backend reads" do
      # :local reads a table named after the registry itself, via
      # Registry.key_info!/1. If that ever stops being true, available?/0 would
      # silently start reporting the wrong thing, so pin it here.
      assert :ets.whereis(Sagents.Registry) != :undefined
    end
  end

  describe "fetch/1 keeps 'not registered' and 'cannot answer' distinct" do
    test "returns {:error, :not_registered} for an unknown key" do
      assert {:error, :not_registered} =
               ProcessRegistry.fetch({:agent_server, "no-such-agent-#{unique()}"})
    end

    test "returns {:ok, pid} for a registered key" do
      agent_id = "fetch-test-#{unique()}"
      name = ProcessRegistry.via_tuple({:agent_server, agent_id})
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)

      assert {:ok, ^pid} = ProcessRegistry.fetch({:agent_server, agent_id})
    end
  end

  describe "with no registry table (a draining node)" do
    setup do
      # Point the abstraction at a backend whose table does not exist. This is
      # the same observable state as a shut-down registry: the name resolves to
      # an atom, and no ETS table answers to it.
      original = Application.get_env(:sagents, :distribution, :local)
      Application.put_env(:sagents, :distribution, :horde)
      on_exit(fn -> Application.put_env(:sagents, :distribution, original) end)

      # Sanity: the horde keys table for Sagents.Registry is genuinely absent
      # in this (local-backed) test VM.
      refute ProcessRegistry.available?()
      :ok
    end

    test "available?/0 reports false" do
      refute ProcessRegistry.available?()
      refute Sagents.ready?()
    end

    test "fetch/1 returns :registry_unavailable, never :not_registered" do
      assert {:error, :registry_unavailable} =
               ProcessRegistry.fetch({:agent_server, "anything"})
    end

    test "AgentServer.fetch_pid/1 returns :registry_unavailable, never :not_running" do
      assert {:error, :registry_unavailable} = AgentServer.fetch_pid("anything")
    end

    test "AgentSupervisor.get_pid/1 returns :registry_unavailable, never :not_found" do
      assert {:error, :registry_unavailable} = AgentSupervisor.get_pid("anything")
    end

    test "AgentServer.get_pid/1 raises rather than answering nil" do
      # nil would be indistinguishable from "not running", and callers act on
      # that by starting a duplicate agent.
      assert_raise Sagents.RegistryUnavailableError, fn ->
        AgentServer.get_pid("anything")
      end
    end

    test "lookup/1 raises rather than answering []" do
      assert_raise Sagents.RegistryUnavailableError, fn ->
        ProcessRegistry.lookup({:agent_server, "anything"})
      end
    end

    test "select/1 raises rather than answering []" do
      assert_raise Sagents.RegistryUnavailableError, fn ->
        ProcessRegistry.select([{{{:agent_server, :"$1"}, :_, :_}, [], [:"$1"]}])
      end
    end

    test "count/0 raises rather than answering 0" do
      assert_raise Sagents.RegistryUnavailableError, fn -> ProcessRegistry.count() end
    end

    test "keys/1 raises rather than answering []" do
      assert_raise Sagents.RegistryUnavailableError, fn -> ProcessRegistry.keys(self()) end
    end

    test "ensure_available!/1 raises with an actionable message" do
      error =
        assert_raise Sagents.RegistryUnavailableError, fn ->
          ProcessRegistry.ensure_available!(:my_operation)
        end

      message = Exception.message(error)

      assert message =~ "Sagents.Registry is not available on this node"
      assert message =~ "my_operation"
      assert message =~ "Sagents.ready?/0"
      assert message =~ "docs/deployment.md"
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
