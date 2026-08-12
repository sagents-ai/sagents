defmodule Sagents.DrainPathsTest do
  @moduledoc """
  Coverage for the paths a host reaches while this node's registry cannot
  answer: the drain window of a rolling deploy.

  The distinction these guard is that a `GenServer.call` on a `:via` tuple
  raises `ArgumentError` from inside `:ets` when the registry's table is gone,
  and a `catch :exit` clause does not catch a raise. Every function here sits
  behind such a `catch` and reads as though it already handled the condition.

  Uses the same unavailable-registry construction as
  `Sagents.ProcessRegistryAvailabilityTest`: pointing the backend at a registry
  name that owns no table is observably identical to a shut-down registry.
  """
  use ExUnit.Case, async: false

  alias Sagents.AgentServer
  alias Sagents.FileSystemServer
  alias Sagents.Subscriber

  setup do
    original = Application.get_env(:sagents, :distribution, :local)
    Application.put_env(:sagents, :distribution, :horde)
    on_exit(fn -> Application.put_env(:sagents, :distribution, original) end)

    refute Sagents.ready?()
    :ok
  end

  describe "AgentServer.notify_middleware/3" do
    test "drops the message and returns :ok rather than raising" do
      assert :ok = AgentServer.notify_middleware("anything", :some_middleware, :ping)
    end
  end

  describe "AgentServer.subscribe/3 and unsubscribe/3" do
    test "subscribe/3 reports the condition instead of raising" do
      assert {:error, :registry_unavailable} = AgentServer.subscribe("anything")
    end

    test "unsubscribe/3 is a no-op instead of raising" do
      assert :ok = AgentServer.unsubscribe("anything")
    end
  end

  describe "Subscriber.subscribe_to_agent/3" do
    test "records the entry as :pending rather than raising" do
      # :pending is the correct resting state. Nothing starts an agent off the
      # back of a pending entry, so this is not the not_running conflation the
      # release exists to prevent, and the next presence diff revives it.
      subs = Subscriber.subscribe_to_agent(%{}, "anything")

      assert %{state: :pending, server_pid: nil} = subs[{:agent, "anything"}]
    end

    test "unsubscribe_from_agent/2 drops the entry rather than raising" do
      subs = Subscriber.subscribe_to_agent(%{}, "anything")

      assert Subscriber.unsubscribe_from_agent(subs, "anything") == %{}
    end
  end

  describe "Subscriber.subscribe_to_filesystem/3" do
    test "records the entry as :pending rather than raising" do
      subs = Subscriber.subscribe_to_filesystem(%{}, {:user, 1})

      assert %{state: :pending, server_pid: nil} = subs[{:filesystem, {:user, 1}}]
    end

    test "unsubscribe_from_filesystem/2 drops the entry rather than raising" do
      subs = Subscriber.subscribe_to_filesystem(%{}, {:user, 1})

      assert Subscriber.unsubscribe_from_filesystem(subs, {:user, 1}) == %{}
    end
  end

  describe "Subscriber.handle_presence_diff/3" do
    test "leaves pending entries pending rather than raising" do
      # The host never makes this call. The generated helper routes
      # presence_diff broadcasts into it from handle_info, and the presence
      # topic is cluster-wide, so an agent booting on any node would otherwise
      # crash every open LiveView on a draining node.
      subs = Subscriber.subscribe_to_agent(%{}, "anything")

      result =
        Subscriber.handle_presence_diff(
          subs,
          Subscriber.presence_topic(),
          %{joins: %{"anything" => %{}}, leaves: %{}}
        )

      assert %{state: :pending} = result[{:agent, "anything"}]
    end

    test "keeps entries it cannot resubscribe rather than dropping them" do
      subs = Subscriber.subscribe_to_agent(%{}, "anything")

      result =
        Subscriber.handle_presence_diff(
          subs,
          Subscriber.presence_topic(),
          %{joins: %{"anything" => %{}}, leaves: %{}}
        )

      assert Map.keys(result) == Map.keys(subs)
    end
  end

  describe "the Sagents.FileSystem public API" do
    test "stop_filesystem/2 reports the condition rather than raising" do
      # A best-effort cleanup that raises takes its caller's whole operation
      # down with it. The host case that found this ran stop_filesystem/2
      # before a Repo.transaction, so the raise meant the record was never
      # deleted, not merely that scratch space survived.
      assert {:error, :registry_unavailable} = Sagents.FileSystem.stop_filesystem({:user, 1})
    end

    test "get_filesystem_pid/1 reports the condition rather than raising" do
      assert {:error, :registry_unavailable} = Sagents.FileSystem.get_filesystem_pid({:user, 1})
    end

    test "ensure_filesystem/3 refuses to start rather than guessing" do
      # Starting one here is the duplicate-creation hazard the release exists
      # to prevent: this node cannot see whether a filesystem already exists.
      assert {:error, :registry_unavailable} =
               Sagents.FileSystem.ensure_filesystem({:user, 1}, [])
    end

    test "fetch_filesystem_running/1 reports the condition as a value" do
      assert {:error, :registry_unavailable} =
               Sagents.FileSystem.fetch_filesystem_running({:user, 1})
    end

    test "filesystem_running?/1 raises rather than answering false" do
      # false reads as "nothing is running", which a caller responds to by
      # starting one. Same reasoning as Session.running?/2.
      assert_raise Sagents.RegistryUnavailableError, fn ->
        Sagents.FileSystem.filesystem_running?({:user, 1})
      end
    end

    test "list_filesystems/0 raises rather than answering []" do
      assert_raise Sagents.RegistryUnavailableError, fn ->
        Sagents.FileSystem.list_filesystems()
      end
    end
  end

  describe "AgentSupervisor.stop/2" do
    test "reports the condition rather than raising CaseClauseError" do
      # get_pid/1 gained a third answer in v0.12.0; a case matching only the
      # two it had before turns a drain into an unrelated-looking crash.
      assert {:error, :registry_unavailable} = Sagents.AgentSupervisor.stop("anything")
    end
  end

  describe "FileSystemServer.whereis/1" do
    test "raises a named error rather than answering nil" do
      # nil reads as "no filesystem server is running", which a caller responds
      # to by starting one.
      assert_raise Sagents.RegistryUnavailableError, fn ->
        FileSystemServer.whereis({:user, 1})
      end
    end

    test "fetch_pid/1 reports the condition as a value" do
      assert {:error, :registry_unavailable} = FileSystemServer.fetch_pid({:user, 1})
    end
  end
end
