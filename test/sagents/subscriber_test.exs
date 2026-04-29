defmodule Sagents.SubscriberTest do
  use Sagents.BaseCase, async: false

  alias Sagents.{AgentServer, FileSystemServer, Subscriber}

  describe "subscribe_to_agent/3" do
    test "tracks a live subscription when the agent is running" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, server_pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, :main)

      assert %{
               {:agent, ^agent_id} => %{
                 channel: :main,
                 server_pid: ^server_pid,
                 monitor_ref: ref,
                 state: :subscribed
               }
             } = subs

      assert is_reference(ref)
    end

    test "marks subscription :pending when the agent is not running" do
      missing = "ghost-agent-#{System.unique_integer([:positive])}"

      subs = Subscriber.subscribe_to_agent(%{}, missing)

      assert %{{:agent, ^missing} => %{state: :pending, server_pid: nil}} = subs
    end

    test "events are delivered to the subscriber" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      _ = Subscriber.subscribe_to_agent(%{}, agent_id, :main)

      # Trigger an event by publishing via the AgentServer's helper.
      AgentServer.publish_event_from(agent_id, {:custom_test_event, 42})

      assert_receive {:agent, {:custom_test_event, 42}}, 100
    end
  end

  describe "subscribe_to_filesystem/3" do
    test "tracks a live filesystem subscription and receives events" do
      scope = {:agent, "fs-sub-test-#{System.unique_integer([:positive])}"}
      {:ok, _pid} = FileSystemServer.start_link(scope_key: scope)

      _ = Subscriber.subscribe_to_filesystem(%{}, scope)

      {:ok, _entry} = FileSystemServer.write_file(scope, "/x.txt", "hello")
      assert_receive {:file_system, {:file_updated, "/x.txt"}}, 100
    end
  end

  describe "handle_publisher_down/3" do
    test "flips the subscription to :pending when the producer dies" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, :main)
      %{client_ref: ref} = Map.fetch!(subs, {:agent, agent_id})

      # Stop the agent — we should receive a :DOWN with our client_ref
      :ok = AgentServer.stop(agent_id)

      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 500

      assert {:matched, new_subs} = Subscriber.handle_publisher_down(subs, ref, :normal)
      assert %{{:agent, ^agent_id} => %{state: :pending, server_pid: nil}} = new_subs
    end

    test "returns :no_match for an unrelated DOWN ref" do
      subs = %{}
      assert :no_match = Subscriber.handle_publisher_down(subs, make_ref(), :normal)
    end
  end

  describe "handle_presence_diff/3" do
    test "auto-resubscribes pending entries on presence join" do
      missing_id = "join-test-#{System.unique_integer([:positive])}"

      pending_subs = Subscriber.subscribe_to_agent(%{}, missing_id, :main)
      assert match?(%{state: :pending}, pending_subs[{:agent, missing_id}])

      # Now actually start that agent
      agent = create_test_agent(agent_id: missing_id)
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      # Simulate a presence_diff with a join for this agent
      diff = %{joins: %{missing_id => %{}}, leaves: %{}}
      new_subs = Subscriber.handle_presence_diff(pending_subs, Subscriber.presence_topic(), diff)

      assert %{{:agent, ^missing_id} => %{state: :subscribed}} = new_subs
    end

    test "is a no-op for unrelated topics" do
      subs = %{{:agent, "x"} => %{state: :pending, channel: :main}}

      assert ^subs =
               Subscriber.handle_presence_diff(subs, "other:topic", %{joins: %{}, leaves: %{}})
    end
  end

  describe "lifecycle scenario: server crash + restart" do
    test "subscription is restored after crash via re-subscribe" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, server_pid} = AgentServer.start_link(agent: agent)
      # Unlink so the test process doesn't die when we kill the agent.
      Process.unlink(server_pid)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, :main)
      %{client_ref: ref} = Map.fetch!(subs, {:agent, agent_id})

      # Kill the server
      Process.exit(server_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server_pid, _reason}, 500

      {:matched, subs} = Subscriber.handle_publisher_down(subs, ref, :killed)
      assert %{{:agent, ^agent_id} => %{state: :pending}} = subs

      # Restart it under the same name
      {:ok, _new_pid} = AgentServer.start_link(agent: agent)

      # Re-subscribe — this is what a presence join would trigger
      subs = Subscriber.subscribe_to_agent(subs, agent_id, :main)
      assert %{{:agent, ^agent_id} => %{state: :subscribed}} = subs

      # Events flow to us again
      AgentServer.publish_event_from(agent_id, :hello_again)
      assert_receive {:agent, :hello_again}, 100
    end
  end
end
