defmodule Sagents.MultiAgentSubscriptionTest do
  @moduledoc """
  One process observing several agents at once.

  The subs map is keyed per producer, so several subscriptions in one mailbox
  is a supported call sequence. A tag is what makes the resulting event stream
  usable: it names the subscription an event belongs to, so the receiver never
  has to infer identity from payload contents or arrival order.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.MessageDelta
  alias Sagents.{AgentServer, Subscriber}

  # Agent execution runs in a Task, so the stubs have to be visible from it.
  setup :set_mimic_global

  @stream_chunks 3

  describe "two tagged subscriptions in one mailbox" do
    test "every event is attributable to exactly one agent" do
      agent_a = create_test_agent()
      agent_b = create_test_agent()
      {:ok, _pid} = AgentServer.start_link(agent: agent_a)
      {:ok, _pid} = AgentServer.start_link(agent: agent_b)

      id_a = agent_a.agent_id
      id_b = agent_b.agent_id

      subs =
        %{}
        |> Subscriber.subscribe_to_agent(id_a, tag: :panel_a)
        |> Subscriber.subscribe_to_agent(id_b, tag: :panel_b)

      assert %{tag: {:tag, :panel_a}} = subs[{:agent, id_a}]
      assert %{tag: {:tag, :panel_b}} = subs[{:agent, id_b}]

      # Interleaved, not sequential. A sequential test passes under the bare
      # envelope, so it proves nothing.
      AgentServer.publish_event_from(id_a, {:tick, 1})
      AgentServer.publish_event_from(id_b, {:tick, 1})
      AgentServer.publish_event_from(id_a, {:tick, 2})
      AgentServer.publish_event_from(id_b, {:tick, 2})

      assert_receive {:agent, :panel_a, {:tick, 1}}, 500
      assert_receive {:agent, :panel_b, {:tick, 1}}, 500
      assert_receive {:agent, :panel_a, {:tick, 2}}, 500
      assert_receive {:agent, :panel_b, {:tick, 2}}, 500
    end

    test "a sibling's :idle does not read as this agent's :idle" do
      # A status event driving an action, not a render. Under the bare envelope
      # an :idle out of any agent in the mailbox satisfies a clause written for
      # one specific agent, and the action fires against the wrong one.
      review = create_test_agent()
      note = create_test_agent()
      {:ok, _pid} = AgentServer.start_link(agent: review)
      {:ok, _pid} = AgentServer.start_link(agent: note)

      _subs =
        %{}
        |> Subscriber.subscribe_to_agent(review.agent_id, tag: :review)
        |> Subscriber.subscribe_to_agent(note.agent_id, tag: :note)

      # Drain the subscribe-time snapshots.
      assert_receive {:agent, :review, {:status_changed, _, _}}, 500
      assert_receive {:agent, :note, {:status_changed, _, _}}, 500

      AgentServer.publish_event_from(note.agent_id, {:status_changed, :idle, nil})

      assert_receive {:agent, :note, {:status_changed, :idle, nil}}, 500
      refute_receive {:agent, :review, {:status_changed, :idle, nil}}, 50
    end

    test "concurrent streaming turns stay separable" do
      # The case the feature exists for. Two agents stream at once into one
      # mailbox; a delta names no sender, so only the tag says which
      # conversation a token belongs to.
      #
      # The reply echoes the prompt so each agent's tokens are recognizable
      # without the envelope. That is the control: the assertion below is that
      # routing by tag alone reproduces the same split.
      stub(ChatAnthropic, :call, fn model, messages, _tools ->
        word = last_user_text(messages)

        for _chunk <- 1..@stream_chunks do
          delta = MessageDelta.new!(%{content: word, role: :assistant, status: :incomplete})
          LangChain.Callbacks.fire(model.callbacks, :on_llm_new_delta, [[delta]])
        end

        {:ok, [Message.new_assistant!(word)]}
      end)

      alpha = create_test_agent()
      beta = create_test_agent()
      {:ok, _pid} = AgentServer.start_link(agent: alpha)
      {:ok, _pid} = AgentServer.start_link(agent: beta)

      _subs =
        %{}
        |> Subscriber.subscribe_to_agent(alpha.agent_id, tag: :alpha)
        |> Subscriber.subscribe_to_agent(beta.agent_id, tag: :beta)

      # Both turns are in flight before either finishes, so the two delta
      # streams share the mailbox rather than arriving one after the other.
      :ok = AgentServer.add_message(alpha.agent_id, Message.new_user!("alpha"))
      :ok = AgentServer.add_message(beta.agent_id, Message.new_user!("beta"))

      collected = collect_delta_text([:alpha, :beta], @stream_chunks)

      assert collected[:alpha] == List.duplicate("alpha", @stream_chunks)
      assert collected[:beta] == List.duplicate("beta", @stream_chunks)
    end
  end

  describe "the untagged promise" do
    test "an untagged subscription receives the bare envelope and nothing else" do
      agent = create_test_agent()
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      _subs = Subscriber.subscribe_to_agent(%{}, agent.agent_id)

      assert_receive {:agent, {:status_changed, _, _}}, 500

      AgentServer.publish_event_from(agent.agent_id, {:tick, 1})

      assert_receive {:agent, {:tick, 1}}, 500
      refute_receive {:agent, _tag, _event}, 50
    end

    test "a tagged and an untagged subscriber on the same agent each get their own shape" do
      agent = create_test_agent()
      {:ok, _pid} = AgentServer.start_link(agent: agent)

      test_pid = self()
      bare = spawn_link(fn -> relay_loop(test_pid, :bare) end)

      {:ok, _server_pid, _ref} =
        AgentServer.subscribe(agent.agent_id, channel: :main, subscriber_pid: bare)

      _subs = Subscriber.subscribe_to_agent(%{}, agent.agent_id, tag: :mine)

      AgentServer.publish_event_from(agent.agent_id, {:tick, 1})

      assert_receive {:agent, :mine, {:tick, 1}}, 500
      assert_receive {:relayed, :bare, {:agent, {:tick, 1}}}, 500
    end
  end

  describe "recovery with several subscriptions" do
    test "a crash names one panel and leaves the other's in-flight state alone" do
      # A host that cannot tell which producer died blanks a healthy sibling's
      # streaming state, so a conversation still mid-response visibly loses its
      # text.
      dying = create_test_agent()
      healthy = create_test_agent()
      {:ok, dying_pid} = AgentServer.start_link(agent: dying)
      {:ok, _pid} = AgentServer.start_link(agent: healthy)

      subs =
        %{}
        |> Subscriber.subscribe_to_agent(dying.agent_id, tag: :dying_panel)
        |> Subscriber.subscribe_to_agent(healthy.agent_id, tag: :healthy_panel)

      %{client_ref: ref} = subs[{:agent, dying.agent_id}]

      Process.unlink(dying_pid)
      Process.exit(dying_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^dying_pid, _reason}, 500

      dying_id = dying.agent_id
      healthy_id = healthy.agent_id

      assert {:matched, {:agent, ^dying_id}, new_subs} =
               Subscriber.handle_publisher_down(subs, ref, :killed, report: true)

      assert Subscriber.tag_for(new_subs, {:agent, dying_id}) == {:ok, :dying_panel}
      assert %{state: :subscribed} = new_subs[{:agent, healthy_id}]

      # The surviving panel still receives its own events, tagged as before.
      AgentServer.publish_event_from(healthy_id, {:tick, 1})
      assert_receive {:agent, :healthy_panel, {:tick, 1}}, 500
    end
  end

  # Read the mailbox in arrival order and file each delta under the tag it
  # carries, until every tag has `per_tag` chunks. Routing on the tag is the
  # whole mechanism under test, so the collector is not allowed to peek at
  # content or to receive selectively per tag.
  defp collect_delta_text(tags, per_tag) do
    collect_delta_text(tags, per_tag, Map.new(tags, &{&1, []}))
  end

  defp collect_delta_text(tags, per_tag, acc) do
    if Enum.all?(tags, &(length(acc[&1]) >= per_tag)) do
      Map.new(acc, fn {tag, chunks} -> {tag, Enum.reverse(chunks)} end)
    else
      receive do
        {:agent, tag, {:llm_deltas, deltas}} when is_map_key(acc, tag) ->
          chunks = Enum.reduce(deltas, acc[tag], &[&1.content | &2])
          collect_delta_text(tags, per_tag, Map.put(acc, tag, chunks))

        _other ->
          collect_delta_text(tags, per_tag, acc)
      after
        2_000 ->
          flunk("timed out; collected #{inspect(Map.new(acc, fn {t, c} -> {t, length(c)} end))}")
      end
    end
  end

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("unknown", fn
      %Message{role: :user, content: content} -> content_text(content)
      _other -> nil
    end)
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %ContentPart{type: :text, content: text} -> text
      _other -> ""
    end)
  end

  defp relay_loop(target, label) do
    receive do
      msg ->
        send(target, {:relayed, label, msg})
        relay_loop(target, label)
    end
  end
end
