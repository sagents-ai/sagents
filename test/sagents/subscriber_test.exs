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

      _subs = Subscriber.subscribe_to_agent(%{}, agent_id, :main)

      # Trigger an event by publishing via the AgentServer's helper.
      AgentServer.publish_event_from(agent_id, {:custom_test_event, 42})

      assert_receive {:agent, {:custom_test_event, 42}}, 100
    end

    test "no tag options store :untagged and deliver the bare envelope" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id)

      assert %{{:agent, ^agent_id} => %{tag: :untagged}} = subs

      AgentServer.publish_event_from(agent_id, {:tick, 1})

      assert_receive {:agent, {:tick, 1}}, 100
      refute_receive {:agent, _tag, _event}, 50
    end

    test "tag: stores the wrapped tag and delivers the three-tuple envelope" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, tag: {:card, 7})

      assert %{{:agent, ^agent_id} => %{channel: :main, tag: {:tag, {:card, 7}}}} = subs

      AgentServer.publish_event_from(agent_id, {:tick, 1})

      assert_receive {:agent, {:card, 7}, {:tick, 1}}, 100
    end

    test "tagged: true addresses events with the agent id" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, tagged: true)

      assert %{{:agent, ^agent_id} => %{tag: {:tag, ^agent_id}}} = subs

      AgentServer.publish_event_from(agent_id, {:tick, 1})

      assert_receive {:agent, ^agent_id, {:tick, 1}}, 100
    end

    test "nil is a legal tag" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, tag: nil)

      assert %{{:agent, ^agent_id} => %{tag: {:tag, nil}}} = subs

      AgentServer.publish_event_from(agent_id, {:tick, 1})

      assert_receive {:agent, nil, {:tick, 1}}, 100
    end

    test "the tag applies to the debug channel too" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, channel: :debug, tag: :dbg)

      assert %{{:agent, ^agent_id} => %{channel: :debug, tag: {:tag, :dbg}}} = subs

      AgentServer.publish_debug_event_from(agent_id, {:tick, 1})

      assert_receive {:agent, :dbg, {:debug, {:tick, 1}}}, 100
    end

    test "a pending subscription records its tag" do
      missing = "ghost-agent-#{System.unique_integer([:positive])}"

      subs = Subscriber.subscribe_to_agent(%{}, missing, tag: :card_a)

      assert %{{:agent, ^missing} => %{state: :pending, tag: {:tag, :card_a}}} = subs
    end

    test "the positional channel form still works" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, server_pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, :debug)

      assert %{
               {:agent, ^agent_id} => %{
                 channel: :debug,
                 tag: :untagged,
                 server_pid: ^server_pid,
                 state: :subscribed
               }
             } = subs
    end

    test "the positional subscriber_pid form still works" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      test_pid = self()
      relay = spawn_link(fn -> relay_loop(test_pid) end)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, :main, relay)

      assert %{{:agent, ^agent_id} => %{channel: :main, state: :subscribed}} = subs

      AgentServer.publish_event_from(agent_id, {:tick, 1})

      assert_receive {:relayed, {:agent, {:tick, 1}}}, 200
    end
  end

  describe "tag_for/2" do
    test "reports the tag, the bare envelope, and an unknown key" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      tagged = Subscriber.subscribe_to_agent(%{}, agent_id, tag: {:card, 7})
      assert Subscriber.tag_for(tagged, {:agent, agent_id}) == {:ok, {:card, 7}}

      bare = Subscriber.subscribe_to_agent(%{}, agent_id)
      assert Subscriber.tag_for(bare, {:agent, agent_id}) == :untagged

      assert Subscriber.tag_for(%{}, {:agent, "never-subscribed"}) == :error
    end
  end

  describe "subscribe_to_filesystem/3" do
    test "tracks a live filesystem subscription and receives events" do
      scope = {:agent, "fs-sub-test-#{System.unique_integer([:positive])}"}
      {:ok, _pid} = FileSystemServer.start_link(scope_key: scope)

      _subs = Subscriber.subscribe_to_filesystem(%{}, scope)

      {:ok, _entry} = FileSystemServer.write_file(scope, "/x.txt", "hello")
      assert_receive {:file_system, {:file_updated, "/x.txt"}}, 100
    end

    test "tagged: true stores the scope key and delivers it on every change" do
      scope = {:agent, "fs-tag-test-#{System.unique_integer([:positive])}"}
      {:ok, _pid} = FileSystemServer.start_link(scope_key: scope)

      subs = Subscriber.subscribe_to_filesystem(%{}, scope, tagged: true)

      assert %{{:filesystem, ^scope} => %{tag: {:tag, ^scope}}} = subs

      {:ok, _entry} = FileSystemServer.write_file(scope, "/x.txt", "hello")
      assert_receive {:file_system, ^scope, {:file_updated, "/x.txt"}}, 100
    end

    test "tag: addresses filesystem events with the host's routing key" do
      scope = {:agent, "fs-tag-test-#{System.unique_integer([:positive])}"}
      {:ok, _pid} = FileSystemServer.start_link(scope_key: scope)

      subs = Subscriber.subscribe_to_filesystem(%{}, scope, tag: :files_panel)

      assert %{{:filesystem, ^scope} => %{tag: {:tag, :files_panel}}} = subs

      {:ok, _entry} = FileSystemServer.write_file(scope, "/x.txt", "hello")
      assert_receive {:file_system, :files_panel, {:file_updated, "/x.txt"}}, 100
    end

    test "a pending filesystem subscription records its tag" do
      scope = {:agent, "fs-missing-#{System.unique_integer([:positive])}"}

      subs = Subscriber.subscribe_to_filesystem(%{}, scope, tag: :files_panel)

      assert %{{:filesystem, ^scope} => %{state: :pending, tag: {:tag, :files_panel}}} = subs
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

    test "reports the subscription key only when asked" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      {:ok, _pid} = AgentServer.start_link(agent: agent)

      subs = Subscriber.subscribe_to_agent(%{}, agent_id, :main)
      %{client_ref: ref} = Map.fetch!(subs, {:agent, agent_id})

      :ok = AgentServer.stop(agent_id)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 500

      assert {:matched, {:agent, ^agent_id}, _new_subs} =
               Subscriber.handle_publisher_down(subs, ref, :normal, report: true)
    end

    test "names the subscription that went down and leaves siblings alone" do
      agent_a = create_test_agent()
      agent_b = create_test_agent()
      {:ok, pid_a} = AgentServer.start_link(agent: agent_a)
      {:ok, _pid_b} = AgentServer.start_link(agent: agent_b)

      id_a = agent_a.agent_id
      id_b = agent_b.agent_id

      subs =
        %{}
        |> Subscriber.subscribe_to_agent(id_a, tag: :panel_a)
        |> Subscriber.subscribe_to_agent(id_b, tag: :panel_b)

      %{client_ref: ref_a} = Map.fetch!(subs, {:agent, id_a})
      sibling_before = Map.fetch!(subs, {:agent, id_b})

      Process.unlink(pid_a)
      Process.exit(pid_a, :kill)
      assert_receive {:DOWN, ^ref_a, :process, ^pid_a, _reason}, 500

      assert {:matched, {:agent, ^id_a}, new_subs} =
               Subscriber.handle_publisher_down(subs, ref_a, :killed, report: true)

      # The downed entry keeps its tag so the revival can restore the envelope.
      assert %{state: :pending, tag: {:tag, :panel_a}} = Map.fetch!(new_subs, {:agent, id_a})
      assert ^sibling_before = Map.fetch!(new_subs, {:agent, id_b})
    end

    test "returns :no_match for an unrelated DOWN ref" do
      subs = %{}
      assert :no_match = Subscriber.handle_publisher_down(subs, make_ref(), :normal)
      assert :no_match = Subscriber.handle_publisher_down(subs, make_ref(), :normal, report: true)
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

    test "reports revived keys only when asked" do
      missing_id = "join-report-#{System.unique_integer([:positive])}"

      pending_subs = Subscriber.subscribe_to_agent(%{}, missing_id, :main)

      agent = create_test_agent(agent_id: missing_id)
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      diff = %{joins: %{missing_id => %{}}, leaves: %{}}

      {new_subs, revived} =
        Subscriber.handle_presence_diff(
          pending_subs,
          Subscriber.presence_topic(),
          diff,
          report: true
        )

      assert %{{:agent, ^missing_id} => %{state: :subscribed}} = new_subs
      assert revived == [{:agent, missing_id}]
    end

    test "a join for an agent we do not track revives nothing" do
      subs = Subscriber.subscribe_to_agent(%{}, "tracked-#{System.unique_integer([:positive])}")
      diff = %{joins: %{"someone-elses-agent" => %{}}, leaves: %{}}

      assert ^subs = Subscriber.handle_presence_diff(subs, Subscriber.presence_topic(), diff)

      assert {^subs, []} =
               Subscriber.handle_presence_diff(subs, Subscriber.presence_topic(), diff,
                 report: true
               )
    end

    test "a revived pending subscription comes back carrying its tag" do
      # Subscribe *before* the agent exists. Starting the agent first passes
      # either way, so the ordering here is the whole point: the tag has to
      # survive in the subs entry across the pending window.
      missing_id = "revive-tag-#{System.unique_integer([:positive])}"

      pending_subs = Subscriber.subscribe_to_agent(%{}, missing_id, tag: :card_a)
      assert %{state: :pending, tag: {:tag, :card_a}} = pending_subs[{:agent, missing_id}]

      agent = create_test_agent(agent_id: missing_id)
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      diff = %{joins: %{missing_id => %{}}, leaves: %{}}

      {new_subs, revived} =
        Subscriber.handle_presence_diff(
          pending_subs,
          Subscriber.presence_topic(),
          diff,
          report: true
        )

      assert %{state: :subscribed, tag: {:tag, :card_a}} = new_subs[{:agent, missing_id}]
      assert revived == [{:agent, missing_id}]

      AgentServer.publish_event_from(missing_id, {:tick, 1})

      assert_receive {:agent, :card_a, {:tick, 1}}, 100
    end

    test "a revived untagged subscription still gets the bare envelope" do
      missing_id = "revive-bare-#{System.unique_integer([:positive])}"

      pending_subs = Subscriber.subscribe_to_agent(%{}, missing_id)
      agent = create_test_agent(agent_id: missing_id)
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      diff = %{joins: %{missing_id => %{}}, leaves: %{}}

      new_subs = Subscriber.handle_presence_diff(pending_subs, Subscriber.presence_topic(), diff)

      assert %{state: :subscribed, tag: :untagged} = new_subs[{:agent, missing_id}]

      AgentServer.publish_event_from(missing_id, {:tick, 1})

      assert_receive {:agent, {:tick, 1}}, 100
      refute_receive {:agent, _tag, _event}, 50
    end

    test "is a no-op for unrelated topics" do
      subs = %{{:agent, "x"} => %{state: :pending, channel: :main, tag: :untagged}}

      assert ^subs =
               Subscriber.handle_presence_diff(subs, "other:topic", %{joins: %{}, leaves: %{}})

      assert {^subs, []} =
               Subscriber.handle_presence_diff(subs, "other:topic", %{joins: %{}, leaves: %{}},
                 report: true
               )
    end

    test "raises at the call site when handed a report: true result" do
      subs = %{{:agent, "x"} => %{state: :pending, channel: :main, tag: :untagged}}
      diff = %{joins: %{}, leaves: %{}}

      # The mistake this guards: feeding `{subs, revived}` back in on the next
      # diff. Without it the tuple is carried into `revive_pending/2` and
      # surfaces as a `BadMapError` from inside this module, two events later.
      # Through apply/3 because the type checker rejects the bad call outright,
      # which is itself the point: a host writing this gets a compile warning
      # before it ever runs.
      assert_raise FunctionClauseError, fn ->
        apply(Subscriber, :handle_presence_diff, [{subs, []}, Subscriber.presence_topic(), diff])
      end
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

  defp relay_loop(target) do
    receive do
      msg ->
        send(target, {:relayed, msg})
        relay_loop(target)
    end
  end
end
