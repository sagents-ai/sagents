defmodule Sagents.AgentServerUserRequestTest do
  @moduledoc """
  AgentServer numbers user requests: the counter advances when a human message
  lands, a tool's queued message continues the current user request, and every
  stored message and display row carries the number it belongs to.

  `Sagents.Agent.execute/3` is stubbed and gated on a message, so the test
  controls when each run starts and finishes. A finisher runs inside the run's
  task and can fire the server's own callbacks, as a real chain would.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, UserRequest, State}
  alias Sagents.Persistence.StateSerializer
  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias LangChain.Message.ContentPart

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  # A DisplayMessagePersistence that reports every save to the test and returns
  # one row per saved message.
  defmodule ReportingPersistence do
    @behaviour Sagents.DisplayMessagePersistence

    defp report(event) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil), do: send(pid, event)
    end

    @impl true
    def save_message(_scope, message, context) do
      report({:saved, message, context})
      {:ok, [%{id: System.unique_integer([:positive]), content_type: "text", message: message}]}
    end

    @impl true
    def save_synthetic_message(_scope, attrs, context) do
      report({:saved_synthetic, attrs, context})
      {:ok, %{id: System.unique_integer([:positive])}}
    end

    @impl true
    def complete_user_request(_scope, report, context) do
      report({:completed_user_request, report, context})
      :ok
    end

    @impl true
    def update_tool_status(_scope, _status, _info, _context), do: {:ok, nil}
  end

  # Implements only the required callbacks.
  defmodule MinimalPersistence do
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_scope, _message, _context), do: {:ok, []}

    @impl true
    def update_tool_status(_scope, _status, _info, _context), do: {:ok, nil}
  end

  defmodule RejectingPreprocessor do
    @behaviour Sagents.MessagePreprocessor

    @impl true
    def preprocess(_scope, _message, _context), do: {:error, :rejected}
  end

  setup do
    :persistent_term.put({ReportingPersistence, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({ReportingPersistence, :test_pid}) end)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp expect_gated_run(count) do
    test_pid = self()

    Agent
    |> expect(:execute, count, fn _agent, state, opts ->
      send(test_pid, {:run_started, state, opts})

      receive do
        {:finish, finisher} -> finisher.(state, opts)
      after
        5_000 -> {:ok, state}
      end
    end)
  end

  defp start_server(agent, opts \\ []) do
    {:ok, pid} =
      AgentServer.start_link(
        [
          agent: agent,
          initial_state: Keyword.get(opts, :initial_state, State.new!()),
          name: AgentServer.get_name(agent.agent_id),
          pubsub: nil,
          display_message_persistence: ReportingPersistence,
          conversation_id: "conv-user_requests"
        ]
        |> Keyword.merge(Keyword.drop(opts, [:initial_state]))
      )

    {:ok, _pid, _ref} = AgentServer.subscribe(agent.agent_id)
    assert_receive {:agent, {:status_changed, :idle, nil}}, 1_000
    pid
  end

  defp send_finish(agent_id, finisher) do
    task = :sys.get_state(AgentServer.get_pid(agent_id)) |> Map.get(:task)
    send(task.pid, {:finish, finisher})
    :ok
  end

  defp finish_ok(agent_id), do: send_finish(agent_id, fn state, _opts -> {:ok, state} end)

  # Fire the server's on_message_processed callback the way a running chain
  # does, from inside the run's task, then return the message.
  defp process_message(opts, %Message{} = message) do
    [callbacks] = Keyword.fetch!(opts, :callbacks)

    chain = %LLMChain{
      custom_context: %{user_request_seq: Keyword.fetch!(opts, :user_request_seq)}
    }

    callbacks.on_message_processed.(chain, message)
    message
  end

  defp server_state(agent_id), do: :sys.get_state(AgentServer.get_pid(agent_id))

  defp with_usage(%Message{} = message, input, output) do
    usage = LangChain.TokenUsage.new!(%{input: input, output: output})
    %Message{message | metadata: Map.put(message.metadata || %{}, :usage, usage)}
  end

  # Run the message through the server's callback and add it, stamped, to the
  # state the run returns, as a chain does.
  defp produce(state, opts, %Message{} = message) do
    message = process_message(opts, message)
    State.add_message(state, UserRequest.stamp(message, opts[:user_request_seq]))
  end

  # Main-channel events received until `stop` matches, in arrival order.
  defp events_until(stop, acc \\ []) do
    receive do
      {:agent, event} ->
        if stop.(event), do: Enum.reverse([event | acc]), else: events_until(stop, [event | acc])
    after
      2_000 -> flunk("stop event never arrived; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp idle?(event), do: match?({:status_changed, :idle, nil}, event)

  defp completed?({:user_request_completed, _report}), do: true
  defp completed?(_event), do: false

  defp text_of(%Message{content: content}), do: ContentPart.content_to_string(content)

  defp wait_for_status(agent_id, status) do
    assert wait_until(fn -> AgentServer.get_status(agent_id) == status end)
  end

  # ── Advancing ────────────────────────────────────────────────────

  describe "the human door" do
    test "the first message opens user request 1" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("hello"))

      assert_receive {:saved, %Message{role: :user} = saved, %{user_request_seq: 1}}, 1_000
      assert UserRequest.seq(saved) == 1
      assert_receive {:agent, {:user_request_started, %{seq: 1}}}, 1_000

      assert_receive {:run_started, state, opts}, 1_000
      assert Keyword.fetch!(opts, :user_request_seq) == 1
      assert state.user_request_seq == 1
      assert [%Message{role: :user} = stored] = state.messages
      assert UserRequest.seq(stored) == 1

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end

    test "a second message after the first finishes opens user request 2" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("one"))
      assert_receive {:run_started, _state, _opts}, 1_000
      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("two"))
      assert_receive {:agent, {:user_request_started, %{seq: 2}}}, 1_000
      assert_receive {:run_started, state, opts}, 1_000
      assert Keyword.fetch!(opts, :user_request_seq) == 2
      assert Enum.map(state.messages, &UserRequest.seq/1) == [1, 2]

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end

    test "a rejected message leaves the counter unchanged" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      start_server(agent, message_preprocessor: RejectingPreprocessor)

      assert {:error, :rejected} = AgentServer.add_message(agent_id, Message.new_user!("no"))
      assert server_state(agent_id).state.user_request_seq == 0
      refute_received {:agent, {:user_request_started, _}}
    end
  end

  describe "messages queued during a run" do
    test "a tool's queued message continues the current user request" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:agent, {:user_request_started, %{seq: 1}}}, 1_000
      assert_receive {:run_started, _state, _opts}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("PLAYBOOK"),
          display: :none
        )

      assert wait_until(fn -> server_state(agent_id).pending_message != nil end)
      assert UserRequest.seq(server_state(agent_id).pending_message) == 1

      finish_ok(agent_id)
      assert_receive {:run_started, state2, opts2}, 2_000
      assert state2.user_request_seq == 1
      assert Keyword.fetch!(opts2, :user_request_seq) == 1
      assert UserRequest.seq(List.last(state2.messages)) == 1
      refute_received {:agent, {:user_request_started, _}}

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end

    test "a human message typed during a run is saved as the next user request and opens it at the drain" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("one"))
      assert_receive {:saved, _message, %{user_request_seq: 1}}, 1_000
      assert_receive {:run_started, _state, _opts}, 1_000

      :ok = AgentServer.add_message(agent_id, Message.new_user!("two"))

      # Saved right away, under the user request it will open.
      assert_receive {:saved, %Message{} = saved_two, %{user_request_seq: 2}}, 1_000
      assert text_of(saved_two) == "two"
      assert server_state(agent_id).state.user_request_seq == 1
      refute_received {:agent, {:user_request_started, %{seq: 2}}}

      finish_ok(agent_id)
      assert_receive {:agent, {:user_request_started, %{seq: 2}}}, 2_000
      assert_receive {:run_started, state2, opts2}, 2_000
      assert state2.user_request_seq == 2
      assert Keyword.fetch!(opts2, :user_request_seq) == 2

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end

    test "two human messages during a run join the same user request" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("one"))
      assert_receive {:run_started, _state, _opts}, 1_000

      :ok = AgentServer.add_message(agent_id, Message.new_user!("two"))
      :ok = AgentServer.add_message(agent_id, Message.new_user!("three"))

      assert_receive {:saved, _two, %{user_request_seq: 2}}, 1_000
      assert_receive {:saved, _three, %{user_request_seq: 2}}, 1_000
      assert UserRequest.seq(server_state(agent_id).pending_message) == 2

      finish_ok(agent_id)
      assert_receive {:run_started, state2, _opts2}, 2_000
      assert state2.user_request_seq == 2

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end

    test "a tool message then a human message merge into the human's user request" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("one"))
      assert_receive {:run_started, _state, _opts}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("PLAYBOOK"),
          display: :none
        )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("two"))
      assert_receive {:saved, _two, %{user_request_seq: 2}}, 1_000

      pending = server_state(agent_id).pending_message
      assert UserRequest.seq(pending) == 2
      assert text_of(pending) =~ "PLAYBOOK"
      assert text_of(pending) =~ "two"

      finish_ok(agent_id)
      assert_receive {:agent, {:user_request_started, %{seq: 2}}}, 2_000
      assert_receive {:run_started, _state2, _opts2}, 2_000

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end

    test "after an error, a new human message joins the held one's user request" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(3)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("one"))
      assert_receive {:run_started, _state, _opts}, 1_000

      :ok = AgentServer.add_message(agent_id, Message.new_user!("two"))
      assert_receive {:saved, _two, %{user_request_seq: 2}}, 1_000

      send_finish(agent_id, fn _state, _opts -> {:error, :boom} end)
      wait_for_status(agent_id, :error)
      assert UserRequest.seq(server_state(agent_id).pending_message) == 2

      :ok = AgentServer.add_message(agent_id, Message.new_user!("three"))
      assert_receive {:saved, three, %{user_request_seq: 2}}, 1_000
      assert text_of(three) == "three"

      assert_receive {:agent, {:user_request_started, %{seq: 2}}}, 1_000
      assert_receive {:run_started, state2, opts2}, 1_000
      assert state2.user_request_seq == 2
      assert Keyword.fetch!(opts2, :user_request_seq) == 2

      # The held message is delivered at the next clean boundary. It already
      # belongs to user request 2, so delivering it does not advance.
      finish_ok(agent_id)
      assert_receive {:run_started, state3, _opts3}, 2_000
      assert state3.user_request_seq == 2
      assert text_of(List.last(state3.messages)) == "two"
      refute_received {:agent, {:user_request_started, %{seq: 2}}}

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end
  end

  # ── Stamping during a run ────────────────────────────────────────

  describe "messages produced during a run" do
    test "processed messages are stamped before they are saved and reach the rolling state" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, opts ->
        answer = process_message(opts, Message.new_assistant!("done"))
        {:ok, State.add_message(state, UserRequest.stamp(answer, opts[:user_request_seq]))}
      end)

      assert_receive {:saved, %Message{role: :assistant} = saved, %{user_request_seq: 1}}, 1_000
      assert UserRequest.seq(saved) == 1

      wait_for_status(agent_id, :idle)
    end

    test "a synthetic row saved during a run carries the current user request" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000

      :ok =
        AgentServer.save_synthetic_message_from(agent_id, %{
          message_type: :assistant,
          content_type: :command_chip,
          content: %{command: "outline"}
        })

      assert_receive {:saved_synthetic, _attrs, %{user_request_seq: 1}}, 1_000

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end

    test "cancel leaves every message in the rolling state stamped" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, fn _agent, state, opts ->
        # An unstamped message reaching the rolling state directly, as a turn
        # cast from a callback that did not stamp would.
        exec_seq = :sys.get_state(AgentServer.get_pid(agent_id)).execution_seq

        GenServer.cast(
          AgentServer.get_name(agent_id),
          {:turn_state_update, exec_seq, Message.new_assistant!("partial")}
        )

        send(test_pid, {:run_started, state, opts})
        Process.sleep(5_000)
        {:ok, state}
      end)

      start_server(agent)
      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000
      assert wait_until(fn -> length(server_state(agent_id).state.messages) == 2 end)

      :ok = AgentServer.cancel(agent_id)

      messages = AgentServer.get_state(agent_id).messages
      assert [%Message{role: :user}, %Message{role: :assistant}] = messages
      assert Enum.all?(messages, &(UserRequest.seq(&1) == 1))
    end
  end

  # ── Persistence ──────────────────────────────────────────────────

  describe "restore" do
    test "a restored pending human message keeps its number and advances at the drain" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)

      state =
        State.new!(%{
          messages: [UserRequest.put_seq(Message.new_user!("one"), 1)],
          user_request_seq: 1
        })

      pending = UserRequest.put_seq(Message.new_user!("two"), 2)
      serialized = StateSerializer.serialize_server_state(agent, state, pending_message: pending)

      {:ok, _pid} =
        AgentServer.start_link_from_state(serialized,
          agent: agent,
          agent_id: agent_id,
          name: AgentServer.get_name(agent_id),
          pubsub: nil
        )

      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id)
      assert server_state(agent_id).state.user_request_seq == 1
      assert UserRequest.seq(server_state(agent_id).pending_message) == 2

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _state, _opts}, 1_000
      finish_ok(agent_id)

      assert_receive {:agent, {:user_request_started, %{seq: 2}}}, 2_000
      assert_receive {:run_started, state2, _opts2}, 2_000
      assert state2.user_request_seq == 2

      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end
  end

  # ── Completion ───────────────────────────────────────────────────

  describe "completion reporting" do
    test "a plain run is reported once, before :idle, with its answer's rows" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, opts ->
        {:ok, produce(state, opts, Message.new_assistant!("The answer"))}
      end)

      events = events_until(&idle?/1)

      assert [{:user_request_completed, report}] =
               Enum.filter(events, &completed?/1)

      assert List.last(events) == {:status_changed, :idle, nil}
      assert %{seq: 1, status: :completed, final_rows: [row]} = report
      assert text_of(row.message) == "The answer"
      assert text_of(report.final_message) == "The answer"
      assert report.assistant_message_count == 1

      assert_received {:completed_user_request, %{seq: 1, final_rows: [^row]},
                       %{conversation_id: "conv-user_requests", user_request_seq: 1}}
    end

    test "nothing is reported before the first human message" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _state, _opts}, 1_000
      finish_ok(agent_id)

      events = events_until(&idle?/1)
      refute Enum.any?(events, &completed?/1)
      refute_received {:completed_user_request, _, _}
    end

    test "a tool-queued follow-up run is part of the same user request, reported once" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("/outline"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, opts ->
        state = produce(state, opts, Message.new_assistant!("Running /outline"))

        :ok =
          AgentServer.queue_message_from_tool(agent_id, Message.new_user!("PLAYBOOK"),
            display: :none
          )

        {:ok, state}
      end)

      assert_receive {:run_started, _state2, _opts2}, 2_000
      refute_received {:completed_user_request, _, _}

      send_finish(agent_id, fn state, opts ->
        {:ok, produce(state, opts, Message.new_assistant!("Here is the outline"))}
      end)

      events = events_until(&idle?/1)

      assert [{:user_request_completed, %{seq: 1, final_rows: [row]}}] =
               Enum.filter(events, &completed?/1)

      assert text_of(row.message) == "Here is the outline"
      assert_received {:completed_user_request, %{seq: 1}, _context}
      refute_received {:completed_user_request, _, _}
    end

    test "narration is never the final answer" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, opts ->
        state =
          state
          |> produce(
            opts,
            Message.new_assistant!(%{content: [ContentPart.narration!("Looking")]})
          )
          |> produce(opts, Message.new_assistant!("Found it"))
          |> produce(opts, Message.new_assistant!(%{content: [ContentPart.narration!("Bye")]}))

        {:ok, state}
      end)

      assert_receive {:completed_user_request, %{final_rows: [row]}, _context}, 2_000
      assert text_of(row.message) == "Found it"
    end

    test "a human message queued during a run ends the user request at the drain" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("one"))
      assert_receive {:run_started, _state, _opts}, 1_000
      :ok = AgentServer.add_message(agent_id, Message.new_user!("two"))

      send_finish(agent_id, fn state, opts ->
        {:ok, produce(state, opts, Message.new_assistant!("first answer"))}
      end)

      events = events_until(&match?({:user_request_started, %{seq: 2}}, &1))

      assert [{:user_request_completed, %{seq: 1, status: :completed, final_rows: [row]}}] =
               Enum.filter(events, &completed?/1)

      assert text_of(row.message) == "first answer"
      refute Enum.any?(events, &idle?/1)

      assert_receive {:run_started, _state2, _opts2}, 2_000

      send_finish(agent_id, fn state, opts ->
        {:ok, produce(state, opts, Message.new_assistant!("second answer"))}
      end)

      events = events_until(&idle?/1)

      assert [{:user_request_completed, %{seq: 2, final_rows: [row2]}}] =
               Enum.filter(events, &completed?/1)

      assert text_of(row2.message) == "second answer"
    end

    test "an error is reported, and a run continued after a restore reports it again" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000
      send_finish(agent_id, fn _state, _opts -> {:error, :boom} end)

      assert_receive {:completed_user_request, %{seq: 1, status: :error}, _context}, 2_000
      wait_for_status(agent_id, :error)

      :ok = AgentServer.restore_state(agent_id, AgentServer.export_state(agent_id))
      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _state2, opts2}, 1_000
      assert Keyword.fetch!(opts2, :user_request_seq) == 1

      send_finish(agent_id, fn state, opts ->
        {:ok, produce(state, opts, Message.new_assistant!("recovered"))}
      end)

      assert_receive {:completed_user_request, %{seq: 1, status: :completed}, _context}, 2_000
    end

    test "cancel is reported with the usage of the messages that completed" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, fn _agent, state, opts ->
        process_message(opts, with_usage(Message.new_assistant!("partial one"), 100, 10))
        process_message(opts, with_usage(Message.new_assistant!("partial two"), 200, 20))
        send(test_pid, {:run_started, state, opts})
        Process.sleep(5_000)
        {:ok, state}
      end)

      start_server(agent)
      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000
      assert wait_until(fn -> length(server_state(agent_id).state.messages) == 3 end)

      :ok = AgentServer.cancel(agent_id)

      assert_receive {:completed_user_request, report, _context}, 1_000

      assert %{
               seq: 1,
               status: :cancelled,
               token_usage: %LangChain.TokenUsage{input: 300, output: 30}
             } = report
    end

    test "a new message sent instead of answering an interrupt supersedes it" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(2)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, _opts ->
        {:interrupt, state, %{action_requests: [], review_configs: %{}}}
      end)

      wait_for_status(agent_id, :interrupted)
      refute_received {:completed_user_request, _, _}

      :ok = AgentServer.add_message(agent_id, Message.new_user!("never mind"))

      assert_receive {:completed_user_request, %{seq: 1, status: :superseded}, _context}, 1_000
      assert_receive {:agent, {:user_request_started, %{seq: 2}}}, 1_000

      assert_receive {:run_started, _state2, _opts2}, 1_000
      finish_ok(agent_id)
      wait_for_status(agent_id, :idle)
    end

    test "dismissing a halt completes the user request" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, _opts ->
        {:interrupt, state, %{type: :halt, message: "Stopping here."}}
      end)

      wait_for_status(agent_id, :interrupted)
      refute_received {:completed_user_request, _, _}

      :ok = AgentServer.dismiss_interrupt(agent_id)
      assert_receive {:completed_user_request, %{seq: 1, status: :completed}, _context}, 1_000
    end

    test "a persistence module without complete_user_request/3 still gets the broadcast" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent, display_message_persistence: MinimalPersistence)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("go"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, opts ->
        {:ok, produce(state, opts, Message.new_assistant!("ok"))}
      end)

      events = events_until(&idle?/1)

      # MinimalPersistence returns no rows, so the answer's rows are empty.
      assert [{:user_request_completed, %{seq: 1, final_rows: []}}] =
               Enum.filter(events, &completed?/1)
    end
  end

  # ── Sub-agent usage ──────────────────────────────────────────────

  describe "sub-agent usage" do
    alias LangChain.Message.{ToolCall, ToolResult}
    alias LangChain.TokenUsage

    defp task_calls(ids) do
      Message.new_assistant!(%{
        tool_calls:
          Enum.map(
            ids,
            &ToolCall.new!(%{status: :complete, call_id: &1, name: "task", arguments: %{}})
          )
      })
    end

    defp task_results(ids) do
      Message.new_tool_result!(%{
        tool_results:
          Enum.map(ids, &ToolResult.new!(%{tool_call_id: &1, name: "task", content: "done"}))
      })
    end

    test "usage recorded during a run lands on the tool message and in the report" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("delegate"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, opts ->
        :ok =
          AgentServer.record_subagent_usage(
            agent_id,
            "call_a",
            TokenUsage.new!(%{input: 1000, output: 100})
          )

        :ok =
          AgentServer.record_subagent_usage(
            agent_id,
            "call_b",
            TokenUsage.new!(%{input: 2000, output: 200})
          )

        state =
          state
          |> produce(opts, with_usage(task_calls(["call_a", "call_b"]), 10, 1))
          |> produce(opts, task_results(["call_a", "call_b"]))
          |> produce(opts, with_usage(Message.new_assistant!("All done"), 20, 2))

        {:ok, state}
      end)

      assert_receive {:completed_user_request, report, _context}, 2_000
      assert %TokenUsage{input: 3030, output: 303} = report.token_usage

      wait_for_status(agent_id, :idle)

      tool_message =
        Enum.find(AgentServer.get_state(agent_id).messages, &(&1.role == :tool))

      assert %TokenUsage{input: 3000, output: 300} = tool_message.metadata.subagent_usage
      assert server_state(agent_id).subagent_usage == %{}
    end

    test "usage for a call whose tool message is not in the state yet waits" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("delegate"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn state, _opts ->
        :ok =
          AgentServer.record_subagent_usage(
            agent_id,
            "call_later",
            TokenUsage.new!(%{input: 5, output: 5})
          )

        {:ok, state}
      end)

      wait_for_status(agent_id, :idle)
      assert %{"call_later" => %TokenUsage{}} = server_state(agent_id).subagent_usage
    end

    test "a run that errors before the call's result puts the usage on the call" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      expect_gated_run(1)
      start_server(agent)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("delegate"))
      assert_receive {:run_started, _state, _opts}, 1_000

      send_finish(agent_id, fn _state, opts ->
        process_message(opts, with_usage(task_calls(["call_a"]), 10, 1))

        :ok =
          AgentServer.record_subagent_usage(
            agent_id,
            "call_a",
            TokenUsage.new!(%{input: 1000, output: 100})
          )

        {:error, :boom}
      end)

      assert_receive {:completed_user_request, report, _context}, 2_000
      assert %{status: :error, token_usage: %TokenUsage{input: 1010, output: 101}} = report

      call_message =
        Enum.find(AgentServer.get_state(agent_id).messages, &(&1.role == :assistant))

      assert %TokenUsage{input: 1000, output: 100} = call_message.metadata.subagent_usage
      assert server_state(agent_id).subagent_usage == %{}
    end

    test "usage that arrives while a cancel is in progress is counted" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, fn _agent, state, opts ->
        process_message(opts, with_usage(task_calls(["call_a"]), 10, 1))

        # A sub-agent reporting at the moment the run is shut down: the cast
        # lands while the server is inside the cancel.
        Process.flag(:trap_exit, true)
        send(test_pid, {:run_started, state, opts})

        receive do
          {:EXIT, _from, :shutdown} ->
            AgentServer.record_subagent_usage(
              agent_id,
              "call_a",
              TokenUsage.new!(%{input: 500, output: 50})
            )

            exit(:shutdown)
        end
      end)

      start_server(agent)
      :ok = AgentServer.add_message(agent_id, Message.new_user!("delegate"))
      assert_receive {:run_started, _state, _opts}, 1_000
      assert wait_until(fn -> length(server_state(agent_id).state.messages) == 2 end)

      :ok = AgentServer.cancel(agent_id)

      assert_receive {:completed_user_request, report, _context}, 1_000
      assert %{status: :cancelled, token_usage: %TokenUsage{input: 510, output: 51}} = report
    end

    test "recording with no server answers :no_server" do
      assert {:error, :no_server} =
               AgentServer.record_subagent_usage(
                 "no-such-agent",
                 "call_x",
                 TokenUsage.new!(%{input: 1, output: 1})
               )
    end
  end
end
