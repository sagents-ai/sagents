defmodule Sagents.AgentServerPendingMessageTest do
  @moduledoc """
  Covers the pending-message queue: messages that arrive while a run is in
  flight are held on `ServerState` and delivered at the next clean run boundary.

  The queue serves two features at once, and that matters to the justification:
  it is the tool-injection mechanism (a tool hands the model *instructions*
  rather than data), and it is the fix for a separately-filed bug where a user
  typing during a run had their message silently destroyed.

  Most tests stub `Sagents.Agent.execute/3` through Mimic and gate it on a
  message, so the test controls exactly when a "run" starts and finishes. That
  is what makes assertions about *ordering* (queued during run 1, delivered on
  run 2) deterministic rather than timing-dependent.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, State}
  alias Sagents.Persistence.StateSerializer
  alias LangChain.Message
  alias LangChain.Message.ContentPart

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  # A stubbed run that reports when it has started and then blocks until the
  # test releases it. Releasing with a function lets each test decide the
  # terminal result, which is how the five-clause drain policy gets covered.
  defp gated_run(test_pid) do
    fn _agent, state, _opts ->
      send(test_pid, {:run_started, state})

      receive do
        {:finish, finisher} -> finisher.(state)
      after
        5_000 -> {:ok, state}
      end
    end
  end

  defp text_of(%Message{content: content}), do: ContentPart.content_to_string(content)

  defp start_server(agent, opts \\ []) do
    {:ok, pid} =
      AgentServer.start_link(
        [
          agent: agent,
          initial_state: Keyword.get(opts, :initial_state, State.new!()),
          name: AgentServer.get_name(agent.agent_id),
          pubsub: nil
        ] ++ Keyword.drop(opts, [:initial_state])
      )

    pid
  end

  # Expects `count` gated runs. Each reports in and blocks until `send_finish/2`.
  defp expect_gated_run(test_pid, count) do
    Agent
    |> expect(:execute, count, fn agent, state, opts ->
      gated_run(test_pid).(agent, state, opts)
    end)
  end

  # A DisplayMessagePersistence that reports every save back to the test.
  defmodule ReportingPersistence do
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_scope, message, context) do
      send(context.tool_context_test_pid || self(), {:saved_display, message})
      {:ok, []}
    end

    @impl true
    def update_tool_status(_scope, _status, _info, _context), do: {:ok, nil}
  end

  # Uses the process dictionary for the test pid, mirroring the convention in
  # agent_server_message_preprocessor_test.exs.
  defmodule PdPersistence do
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_scope, message, _context) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:saved_display, message})
      end

      {:ok, []}
    end

    @impl true
    def update_tool_status(_scope, _status, _info, _context), do: {:ok, nil}
  end

  # Implements the OPTIONAL save_synthetic_message/3 callback.
  defmodule PdSyntheticPersistence do
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_scope, message, _context) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:saved_display, message})
      end

      {:ok, []}
    end

    @impl true
    def save_synthetic_message(_scope, attrs, _context) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:saved_synthetic, attrs})
      end

      {:ok, %{id: 1, content: attrs[:content] || attrs["content"]}}
    end

    @impl true
    def update_tool_status(_scope, _status, _info, _context), do: {:ok, nil}
  end

  defmodule SplittingPreprocessor do
    @behaviour Sagents.MessagePreprocessor

    @impl true
    def preprocess(_scope, _message, _context) do
      {:ok, Message.new_user!("[display] preprocessed"), Message.new_user!("[llm] preprocessed")}
    end
  end

  defp set_test_pid(module), do: :persistent_term.put({module, :test_pid}, self())

  # ── 1-5. The load-bearing tests, through a real AgentServer ──────

  describe "delivery at the run boundary" do
    test "a message queued by a tool reaches the model on the NEXT run, as a :user message" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      # Run 1 queues, run 2 must see the queued content.
      Agent
      |> expect(:execute, 2, fn _agent, state, _opts ->
        send(test_pid, {:run_started, state})

        receive do
          {:finish, f} -> f.(state)
        after
          5_000 -> {:ok, state}
        end
      end)

      start_server(agent, initial_state: State.new!(%{messages: [Message.new_user!("Hi")]}))

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _state1}, 1_000

      # A tool, running inside the agent's Task, queues a message.
      assert :ok =
               AgentServer.queue_message_from_tool(agent_id, Message.new_user!("PLAYBOOK"),
                 display: :none
               )

      # Let run 1 finish cleanly. The drain should start run 2 by itself.
      send_finish(agent_id, fn s -> {:ok, s} end)

      assert_receive {:run_started, state2}, 2_000

      queued = List.last(state2.messages)

      # Assert the ROLE, not just the text. A test that only greps for the
      # content would also pass under "return the playbook as the tool result",
      # which is precisely the design this replaces.
      assert queued.role == :user
      assert text_of(queued) == "PLAYBOOK"

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "the drained message lands in state exactly once, after run 1's final message" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, 2, fn _agent, state, _opts ->
        send(test_pid, {:run_started, state})

        receive do
          {:finish, f} -> f.(state)
        after
          5_000 -> {:ok, state}
        end
      end)

      start_server(agent, initial_state: State.new!(%{messages: [Message.new_user!("Hi")]}))

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("QUEUED"), display: :none)

      # Run 1 ends with an assistant turn, as a real run would.
      send_finish(agent_id, fn s ->
        {:ok, State.add_message(s, Message.new_assistant!(%{content: "Sounds good."}))}
      end)

      assert_receive {:run_started, _}, 2_000
      send_finish(agent_id, fn s -> {:ok, s} end)

      wait_until_idle(agent_id)

      messages = AgentServer.get_state(agent_id).messages
      queued = Enum.filter(messages, &(text_of(&1) == "QUEUED"))

      assert length(queued) == 1, "expected the queued message exactly once"

      # Positioned after run 1's final assistant message: plain alternation.
      texts = Enum.map(messages, &text_of/1)

      assert Enum.find_index(texts, &(&1 == "QUEUED")) >
               Enum.find_index(texts, &(&1 == "Sounds good."))
    end

    test "NO :idle is broadcast between the two runs" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, 2, fn _agent, state, _opts ->
        send(test_pid, {:run_started, state})

        receive do
          {:finish, f} -> f.(state)
        after
          5_000 -> {:ok, state}
        end
      end)

      start_server(agent, initial_state: State.new!(%{messages: [Message.new_user!("Hi")]}))
      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      # Drain the initial :idle broadcast the server emits on start.
      assert_receive {:agent, {:status_changed, :idle, nil}}, 1_000
      assert_receive {:agent, {:status_changed, :running, nil}}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("QUEUED"), display: :none)

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, _}, 2_000

      # The drain re-enters :running without passing through :idle. Every UI
      # treats :idle as "done, re-enable the input"; a flicker here would clear
      # the loading state a beat before the agent resumes.
      assert_receive {:agent, {:status_changed, :running, nil}}, 1_000
      refute_received {:agent, {:status_changed, :idle, nil}}

      send_finish(agent_id, fn s -> {:ok, s} end)

      # Exactly one :idle, at the very end.
      assert_receive {:agent, {:status_changed, :idle, nil}}, 2_000
    end

    test "a user message added while :running is NOT lost (the regression this fixes)" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, 2, fn _agent, state, _opts ->
        send(test_pid, {:run_started, state})

        receive do
          {:finish, f} -> f.(state)
        after
          5_000 -> {:ok, state}
        end
      end)

      start_server(agent, initial_state: State.new!(%{messages: [Message.new_user!("Hi")]}))

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      # The user types while the agent is working.
      assert :ok = AgentServer.add_message(agent_id, Message.new_user!("Actually, wait"))

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, state2}, 2_000

      # Before this change the message was written into the rolling state and
      # then destroyed when the canonical state replaced it wholesale.
      assert Enum.any?(state2.messages, &(text_of(&1) == "Actually, wait"))

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "a message queued while no run is in flight is delivered immediately" do
      # Defensive path: tools normally run only while :running. Without this,
      # such a message would sit in the queue until some unrelated future run
      # happened to finish. That is the same class of silent loss this queue fixes.
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> expect(:execute, 1, fn _agent, state, _opts ->
        send(test_pid, {:run_started, state})
        {:ok, state}
      end)

      start_server(agent)
      wait_until_idle(agent_id)

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("NOW"), display: :none)

      assert_receive {:run_started, state}, 2_000
      assert Enum.any?(state.messages, &(text_of(&1) == "NOW"))
    end

    test "add_message/2 returns :ok (not an error) when the message is queued" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      # Previously this returned {:error, "Cannot execute, server is in state:
      # running"} while having actually accepted the message. chat_live.ex and
      # consumers written the same way match only :ok and {:error, reason}, so
      # a new {:ok, :queued} shape would raise CaseClauseError.
      assert :ok == AgentServer.add_message(agent_id, Message.new_user!("queued one"))

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, _}, 2_000
      send_finish(agent_id, fn s -> {:ok, s} end)
    end
  end

  # ── 6-10. Drain policy, one test per terminal clause ─────────────

  describe "drain policy across all five terminal clauses" do
    test "{:ok, _} drains and re-executes" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000
      :ok = AgentServer.queue_message_from_tool(agent_id, Message.new_user!("Q"), display: :none)

      send_finish(agent_id, fn s -> {:ok, s} end)

      assert_receive {:run_started, state2}, 2_000
      assert Enum.any?(state2.messages, &(text_of(&1) == "Q"))

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "{:ok, _, extra} drains too (it delegates to the {:ok, _} clause)" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000
      :ok = AgentServer.queue_message_from_tool(agent_id, Message.new_user!("Q"), display: :none)

      send_finish(agent_id, fn s -> {:ok, s, %{structured: true}} end)

      assert_receive {:run_started, state2}, 2_000
      assert Enum.any?(state2.messages, &(text_of(&1) == "Q"))

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "{:interrupt, _, _} HOLDS: nothing re-executes and the queue survives" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      # Exactly ONE run. A second call would mean the drain fired.
      expect_gated_run(test_pid, 1)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("HELD"), display: :none)

      send_finish(agent_id, fn s -> {:interrupt, s, %{type: :test_interrupt}} end)

      wait_for_status(agent_id, :interrupted)

      # The user is answering a question, not extending the conversation.
      refute_received {:run_started, _}
      assert pending_message(agent_id) != nil
      refute Enum.any?(AgentServer.get_state(agent_id).messages, &(text_of(&1) == "HELD"))
    end

    test "the held message drains once the interrupt resolves" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 1)

      Agent
      |> expect(:resume, 1, fn _agent, state, _decisions, _opts ->
        {:ok, state}
      end)

      Agent
      |> expect(:execute, 1, fn _agent, state, _opts ->
        send(test_pid, {:run_started, state})
        {:ok, state}
      end)

      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("HELD"), display: :none)

      send_finish(agent_id, fn s -> {:interrupt, s, %{type: :test_interrupt}} end)
      wait_for_status(agent_id, :interrupted)

      # Resuming completes as {:ok, _}, which is the drain's boundary.
      :ok = AgentServer.resume(agent_id, %{})

      assert_receive {:run_started, resumed_state}, 2_000
      assert Enum.any?(resumed_state.messages, &(text_of(&1) == "HELD"))
    end

    test "{:error, _} HOLDS, and surfaces a debug event" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 1)
      start_server(agent)
      {:ok, _pid, _ref} = AgentServer.subscribe(agent_id, :debug)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("HELD"), display: :none)

      send_finish(agent_id, fn _s -> {:error, "boom"} end)

      wait_for_status(agent_id, :error)

      # Delivering a queued message into a failed run compounds the failure.
      refute_received {:run_started, _}
      assert pending_message(agent_id) != nil
      assert_receive {:agent, {:debug, {:pending_message_held, :error}}}, 1_000
    end

    test "{:pause, _} HOLDS" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 1)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("HELD"), display: :none)

      send_finish(agent_id, fn s -> {:pause, s} end)

      wait_for_status(agent_id, :paused)

      refute_received {:run_started, _}
      assert pending_message(agent_id) != nil
    end
  end

  # ── 11-13. Merging ───────────────────────────────────────────────

  describe "merging multiple queued messages" do
    test "two messages queued during one run arrive as ONE :user message with two parts" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("first"), display: :none)

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("second"), display: :none)

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, state2}, 2_000

      # Assert the message COUNT, since collapsing two turns into one is the
      # entire reason the merge exists.
      assert length(state2.messages) == 1

      merged = List.first(state2.messages)
      assert merged.role == :user
      assert length(merged.content) == 2
      assert text_of(merged) =~ "first"
      assert text_of(merged) =~ "second"

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "a single queued message is stored as-is, content untouched" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 1)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("solo"), display: :none)

      pending = pending_message(agent_id)
      assert pending.role == :user
      assert length(pending.content) == 1
      assert text_of(pending) == "solo"

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "a non-:user message arriving while running is rejected, not merged" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 1)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("legit"), display: :none)

      # Injecting an assistant turn mid-run is not a supported operation. This
      # constraint is what lets merge_pending/2 be unconditional.
      assert {:error, reason} =
               AgentServer.add_message(agent_id, Message.new_assistant!(%{content: "nope"}))

      assert reason =~ "Only :user messages can be queued"

      pending = pending_message(agent_id)
      assert length(pending.content) == 1
      assert text_of(pending) == "legit"

      send_finish(agent_id, fn s -> {:ok, s} end)
    end
  end

  # ── 14-16. Circuit breaker ───────────────────────────────────────

  describe "circuit breaker on machine-initiated runs" do
    test "a tool that queues on every run stops after 10 consecutive auto-executions" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      # 1 human-initiated run + 10 auto runs = 11. An 12th would mean the
      # breaker never tripped; Mimic fails the test if the stub is over-called.
      Agent
      |> expect(:execute, 11, fn _agent, state, _opts ->
        send(test_pid, :run_started)
        # Every run queues another message. This is the runaway shape.
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("again"), display: :none)
        {:ok, state}
      end)

      start_server(agent)
      :ok = AgentServer.execute(agent_id)

      for _run <- 1..11 do
        assert_receive :run_started, 2_000
      end

      wait_until_idle(agent_id)

      # Assert the run count, not merely that it stopped.
      refute_received :run_started

      # The final message is real conversation, so it is kept even though the
      # breaker declined to act on it.
      assert Enum.any?(AgentServer.get_state(agent_id).messages, &(text_of(&1) == "again"))
      assert pending_message(agent_id) == nil
    end

    test "add_message/2 resets the counter, so a long human conversation never trips it" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)
      start_server(agent)

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      # Drive the counter up as if several auto-runs had happened.
      :sys.replace_state(AgentServer.get_pid(agent_id), fn ss ->
        %{ss | consecutive_auto_executions: 9}
      end)

      # The human door resets it. The tool door never does.
      :ok = AgentServer.add_message(agent_id, Message.new_user!("human speaks"))
      assert auto_execution_count(agent_id) == 0

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, _}, 2_000
      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "the max_runs gap is real: run_count resets to 0 on every fresh chain" do
      # This is the test that documents WHY the breaker exists, and the one that
      # stops a future reader from deleting it as redundant with :max_runs.
      #
      # `Mode.Steps.check_max_runs/2` compares against `get_run_count/1`, which
      # reads chain.custom_context[:mode_state][:run_count]. `Agent.execute/3`
      # builds a fresh chain per call, so a drain-triggered run gets a brand new
      # budget. max_runs bounds work *per execution*; it cannot see across a drain.
      alias LangChain.Chains.LLMChain
      alias LangChain.Chains.LLMChain.Mode.Steps

      {:ok, model} = LangChain.ChatModels.ChatAnthropic.new(%{api_key: "test"})

      fresh = LLMChain.new!(%{llm: model})
      assert Steps.get_run_count(fresh) == 0

      # A chain mid-execution carries a count...
      used = LLMChain.update_custom_context(fresh, %{mode_state: %{run_count: 42}})
      assert Steps.get_run_count(used) == 42

      # ...but the next execution builds a new chain, which starts at 0 again.
      next_execution = LLMChain.new!(%{llm: model})
      assert Steps.get_run_count(next_execution) == 0
    end
  end

  # ── 17-23. The display / LLM split ───────────────────────────────

  describe "display and LLM halves" do
    test "display: :none produces no DisplayMessage while the LLM half still lands" do
      set_test_pid(PdPersistence)
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)

      start_server(agent,
        display_message_persistence: PdPersistence,
        conversation_id: "conv-none"
      )

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("INVISIBLE"),
          display: :none
        )

      refute_receive {:saved_display, _}, 300

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, state2}, 2_000

      # Assert BOTH halves: nothing in the transcript, present for the model.
      assert Enum.any?(state2.messages, &(text_of(&1) == "INVISIBLE"))

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "an explicit display: message is saved at QUEUE time and may differ in content" do
      set_test_pid(PdPersistence)
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)

      start_server(agent,
        display_message_persistence: PdPersistence,
        conversation_id: "conv-explicit"
      )

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("THE FULL PLAYBOOK"),
          display: Message.new_user!("/outline-scene")
        )

      # Immediately, not a turn later. A user who typed while the agent was busy
      # sees their words right away.
      assert_receive {:saved_display, saved}, 1_000
      assert text_of(saved) == "/outline-scene"

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, state2}, 2_000

      assert Enum.any?(state2.messages, &(text_of(&1) == "THE FULL PLAYBOOK"))

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "case B: the halves may differ in ROLE, so tool-injected text is not attributed to the author" do
      set_test_pid(PdPersistence)
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)

      start_server(agent,
        display_message_persistence: PdPersistence,
        conversation_id: "conv-roles"
      )

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("PLAYBOOK"),
          display: Message.new_assistant!(%{content: "It looks like /outline-scene matches."})
        )

      # save_message/3 derives transcript attribution from message.role, so the
      # display half is an ASSISTANT entry...
      assert_receive {:saved_display, saved}, 1_000
      assert saved.role == :assistant

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, state2}, 2_000

      # ...while the model receives a USER turn. Nobody typed the playbook; a
      # :user-attributed transcript entry would put words in the author's mouth.
      #
      # This assertion is what stops a future "simplification" from collapsing
      # the two halves back into a single message.
      queued = Enum.find(state2.messages, &(text_of(&1) == "PLAYBOOK"))
      assert queued.role == :user

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "two merged queued messages still produce TWO separate DisplayMessages" do
      set_test_pid(PdPersistence)
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)

      start_server(agent,
        display_message_persistence: PdPersistence,
        conversation_id: "conv-two-display"
      )

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      :ok = AgentServer.add_message(agent_id, Message.new_user!("first"))
      :ok = AgentServer.add_message(agent_id, Message.new_user!("second"))

      # The merge is LLM-side only. The transcript keeps them distinct, because
      # the user really did send two messages.
      assert_receive {:saved_display, one}, 1_000
      assert_receive {:saved_display, two}, 1_000
      assert text_of(one) == "first"
      assert text_of(two) == "second"

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, state2}, 2_000

      # ...but the model sees one turn.
      assert length(state2.messages) == 1

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "an explicit display: bypasses a configured preprocessor; queue_message_from_tool never runs it" do
      set_test_pid(PdPersistence)
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)

      start_server(agent,
        display_message_persistence: PdPersistence,
        conversation_id: "conv-preproc",
        message_preprocessor: SplittingPreprocessor
      )

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      # The caller already made the decision the preprocessor exists to make,
      # so there is nothing coherent for it to do with a pair it did not produce.
      :ok =
        AgentServer.add_message(agent_id, Message.new_user!("raw llm"),
          display: Message.new_user!("raw display")
        )

      assert_receive {:saved_display, saved}, 1_000
      assert text_of(saved) == "raw display"
      refute text_of(saved) =~ "preprocessed"

      # And the tool door never runs it at all: a machine-generated playbook is
      # not a message a human submitted.
      :ok = AgentServer.queue_message_from_tool(agent_id, Message.new_user!("tool text"))
      assert_receive {:saved_display, tool_saved}, 1_000
      assert text_of(tool_saved) == "tool text"

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, state2}, 2_000

      text = state2.messages |> List.first() |> text_of()
      assert text =~ "raw llm"
      assert text =~ "tool text"
      refute text =~ "preprocessed"

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "with no :display option and no preprocessor, behavior is unchanged" do
      set_test_pid(PdPersistence)
      agent = create_test_agent()
      agent_id = agent.agent_id

      Agent
      |> stub(:execute, fn _agent, state, _opts -> {:ok, state} end)

      start_server(agent,
        display_message_persistence: PdPersistence,
        conversation_id: "conv-plain"
      )

      :ok = AgentServer.add_message(agent_id, Message.new_user!("plain"))

      assert_receive {:saved_display, saved}, 1_000
      assert text_of(saved) == "plain"

      wait_until_idle(agent_id)
      assert Enum.any?(AgentServer.get_state(agent_id).messages, &(text_of(&1) == "plain"))
    end

    test "structured display content goes through save_synthetic_message_from/2 with display: :none" do
      set_test_pid(PdSyntheticPersistence)
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      expect_gated_run(test_pid, 2)

      start_server(agent,
        display_message_persistence: PdSyntheticPersistence,
        conversation_id: "conv-synthetic"
      )

      :ok = AgentServer.execute(agent_id)
      assert_receive {:run_started, _}, 1_000

      # The two primitives compose: a deterministic acknowledgement to the human
      # via the synthetic path, the playbook to the model via the queue.
      :ok =
        AgentServer.save_synthetic_message_from(agent_id, %{
          message_type: :assistant,
          content_type: :command_chip,
          content: %{command: "outline-scene"}
        })

      :ok =
        AgentServer.queue_message_from_tool(agent_id, Message.new_user!("PLAYBOOK"),
          display: :none
        )

      assert_receive {:saved_synthetic, attrs}, 1_000
      assert attrs.content_type == :command_chip

      send_finish(agent_id, fn s -> {:ok, s} end)
      assert_receive {:run_started, state2}, 2_000
      assert Enum.any?(state2.messages, &(text_of(&1) == "PLAYBOOK"))

      send_finish(agent_id, fn s -> {:ok, s} end)
    end

    test "the synthetic path degrades rather than raising when the optional callback is absent" do
      set_test_pid(PdPersistence)
      agent = create_test_agent()
      agent_id = agent.agent_id

      Agent
      |> stub(:execute, fn _agent, state, _opts -> {:ok, state} end)

      # PdPersistence does NOT implement the optional save_synthetic_message/3.
      # This is exactly why the core :display path routes through the REQUIRED
      # save_message/3 instead.
      start_server(agent,
        display_message_persistence: PdPersistence,
        conversation_id: "conv-no-synthetic"
      )

      assert :ok =
               AgentServer.save_synthetic_message_from(agent_id, %{
                 message_type: :assistant,
                 content_type: :text,
                 content: "hi"
               })

      # Server survives.
      assert AgentServer.get_status(agent_id) in [:idle, :running]
    end
  end

  # ── 24-25. Degradation ───────────────────────────────────────────

  describe "degradation when there is no AgentServer" do
    test "queue_message_from_tool/2 returns {:error, :no_server} and does not raise" do
      # Mirrors the TodoList.save_todo_snapshot/2 guard: unit tests and bare
      # Agent.execute/3 degrade to a reportable no-op so a tool can fall back to
      # inline content instead of silently doing nothing.
      assert {:error, :no_server} =
               AgentServer.queue_message_from_tool(
                 "definitely-not-running-#{System.unique_integer([:positive])}",
                 Message.new_user!("nobody home")
               )
    end

    test "a sub-agent id does not resolve, so a tool inside one takes the fallback" do
      # Sub-agents register under {:sub_agent, id}, not {:agent_server, id}, and
      # SubAgentServer.execute/1 blocks their own process for the whole run.
      # Queueing into the PARENT conversation is deliberately not offered: that
      # is a different and much larger feature.
      sub_agent_id = "sub-agent-#{System.unique_integer([:positive])}"

      assert {:error, :no_server} =
               AgentServer.queue_message_from_tool(
                 sub_agent_id,
                 Message.new_user!("from a sub-agent")
               )
    end
  end

  # ── 26-27. Persistence ───────────────────────────────────────────

  describe "persisting the queue" do
    test "a pending message survives serialize/deserialize" do
      agent = create_test_agent()
      state = State.new!(%{messages: [Message.new_user!("history")]})
      pending = Message.new_user!("still waiting")

      serialized = StateSerializer.serialize_server_state(agent, state, pending_message: pending)

      assert %{"pending_message" => _serialized_pending} = serialized

      restored = StateSerializer.deserialize_pending_message(serialized)
      assert restored.role == :user
      assert text_of(restored) == "still waiting"
    end

    test "no pending message, and older payloads lacking the key, both work" do
      agent = create_test_agent()
      state = State.new!(%{messages: [Message.new_user!("history")]})

      # Nothing queued: the key is simply absent.
      serialized = StateSerializer.serialize_server_state(agent, state)
      refute Map.has_key?(serialized, "pending_message")
      assert StateSerializer.deserialize_pending_message(serialized) == nil

      # A payload written before this key existed reads as "nothing queued"
      # rather than raising. The serializer is already versioned, so a key that
      # older payloads lack is a solved shape in this module.
      legacy = %{"version" => 2, "state" => %{"messages" => [], "todos" => [], "metadata" => %{}}}
      assert StateSerializer.deserialize_pending_message(legacy) == nil
    end

    test "a restored server boots with its pending message intact" do
      agent = create_test_agent()
      agent_id = agent.agent_id
      state = State.new!(%{messages: [Message.new_user!("history")]})
      pending = Message.new_user!("survived the crash")

      Agent
      |> stub(:execute, fn _agent, s, _opts -> {:ok, s} end)

      serialized = StateSerializer.serialize_server_state(agent, state, pending_message: pending)

      {:ok, _pid} =
        AgentServer.start_link_from_state(serialized,
          agent: agent,
          agent_id: agent_id,
          name: AgentServer.get_name(agent_id),
          pubsub: nil
        )

      restored = pending_message(agent_id)
      assert restored != nil
      assert text_of(restored) == "survived the crash"
    end
  end

  # ── 28. Cancellation interaction ─────────────────────────────────

  describe "cancellation" do
    test "cancelling while a tool is queueing does not deadlock" do
      # This test pins WHY queue_message_from_tool/2 is a cast, and it will be the
      # first thing someone tries to "simplify" into a call.
      #
      # handle_call(:cancel, ...) blocks the AgentServer in Task.shutdown(task,
      # 2_000). If tool code inside that Task were blocked in a GenServer.call
      # back to the same server, the two would wait on each other until the
      # grace expired.
      agent = create_test_agent()
      agent_id = agent.agent_id
      test_pid = self()

      Agent
      |> stub(:execute, fn _agent, state, _opts ->
        send(test_pid, :run_started)

        # Hammer the queue from inside the run, then keep running so cancel
        # actually has something to shut down.
        for i <- 1..50 do
          AgentServer.queue_message_from_tool(agent_id, Message.new_user!("q#{i}"),
            display: :none
          )
        end

        Process.sleep(3_000)
        {:ok, state}
      end)

      start_server(agent)
      :ok = AgentServer.execute(agent_id)
      assert_receive :run_started, 1_000

      started = System.monotonic_time(:millisecond)
      assert :ok = AgentServer.cancel(agent_id)
      elapsed = System.monotonic_time(:millisecond) - started

      # Well inside the 2s grace window, so no mutual wait occurred.
      assert elapsed < 2_500, "cancel took #{elapsed}ms, suggesting a deadlock"
      assert AgentServer.get_status(agent_id) == :cancelled
    end
  end

  # ── Test-local plumbing ──────────────────────────────────────────

  defp send_finish(agent_id, finisher) do
    task = :sys.get_state(AgentServer.get_pid(agent_id)) |> Map.get(:task)
    send(task.pid, {:finish, finisher})
    :ok
  end

  defp pending_message(agent_id) do
    :sys.get_state(AgentServer.get_pid(agent_id)).pending_message
  end

  defp auto_execution_count(agent_id) do
    :sys.get_state(AgentServer.get_pid(agent_id)).consecutive_auto_executions
  end

  defp wait_for_status(agent_id, status, attempts \\ 100) do
    cond do
      AgentServer.get_status(agent_id) == status ->
        :ok

      attempts == 0 ->
        flunk("agent never reached #{inspect(status)}; it is #{AgentServer.get_status(agent_id)}")

      true ->
        Process.sleep(20)
        wait_for_status(agent_id, status, attempts - 1)
    end
  end

  defp wait_until_idle(agent_id), do: wait_for_status(agent_id, :idle)
end
