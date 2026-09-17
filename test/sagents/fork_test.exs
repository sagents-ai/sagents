defmodule Sagents.ForkTest do
  @moduledoc """
  Covers building a fork base: what a fork inherits, what it refuses to inherit,
  and what it refuses to build from at all.

  Not `async: true`: the round-trip and precondition tests run real
  `AgentServer` processes against the global process registry, and the stubbed
  model is reached from a spawned task, which needs Mimic in global mode.
  """
  use Sagents.BaseCase, async: false
  use Mimic

  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.{ContentPart, ToolCall, ToolResult}
  alias Sagents.{Agent, AgentServer, Fork, State, Todo}
  alias Sagents.Persistence.StateSerializer

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp conversation do
    [
      Message.new_user!("What is the capital of France?"),
      Message.new_assistant!("Paris."),
      Message.new_user!("And of Spain?"),
      Message.new_assistant!("Madrid.")
    ]
  end

  defp start_server(agent, opts) do
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

  # An assistant message calling `name`, and the tool message answering it.
  defp tool_call_message(call_id, name) do
    Message.new_assistant!(%{
      tool_calls: [ToolCall.new!(%{call_id: call_id, name: name, arguments: %{}})]
    })
  end

  defp tool_result_message(call_ids, name) do
    results =
      Enum.map(call_ids, fn id ->
        ToolResult.new!(%{tool_call_id: id, name: name, content: "done"})
      end)

    Message.new_tool_result!(%{content: nil, tool_results: results})
  end

  defp interrupt_message(call_id) do
    result =
      ToolResult.new!(%{
        tool_call_id: call_id,
        name: "ask_user",
        content: "Waiting...",
        is_interrupt: true,
        interrupt_data: %{type: :ask_user_question, question: "Which one?"}
      })

    Message.new_tool_result!(%{content: nil, tool_results: [result]})
  end

  # A DisplayMessagePersistence that reports every save back to the test.
  defmodule ReportingPersistence do
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_scope, message, _context) do
      send(Sagents.ForkTest.test_pid(), {:saved_display, message})
      {:ok, []}
    end

    @impl true
    def update_tool_status(_scope, _status, _info, _context), do: {:ok, nil}
  end

  @doc false
  def test_pid, do: :persistent_term.get(:fork_test_pid)

  # ── Messages ─────────────────────────────────────────────────────

  describe "prepare/2 message handling" do
    test "carries every message through unchanged and in order" do
      messages = conversation()
      state = State.new!(%{messages: messages})

      {:ok, base} = Fork.prepare(state)

      assert base.messages == messages
    end

    test "a live state and its exported payload produce equal bases" do
      state = State.new!(%{messages: conversation(), todos: [], metadata: %{}})
      exported = StateSerializer.serialize_server_state(nil, state)

      {:ok, from_state} = Fork.prepare(state)
      {:ok, from_payload} = Fork.prepare(exported)

      assert from_state == from_payload
    end

    test "accepts the inner state map as well as the full envelope" do
      state = State.new!(%{messages: conversation()})
      exported = StateSerializer.serialize_server_state(nil, state)

      {:ok, from_envelope} = Fork.prepare(exported)
      {:ok, from_inner} = Fork.prepare(exported["state"])

      assert from_envelope == from_inner
    end

    test "an empty conversation prepares to an empty base" do
      {:ok, base} = Fork.prepare(State.new!())

      assert base.messages == []
    end
  end

  # ── Hygiene ──────────────────────────────────────────────────────

  describe "prepare/2 todos" do
    setup do
      todos = [Todo.new!(%{id: 1, content: "Parent task"})]
      {:ok, state: State.new!(%{messages: conversation(), todos: todos}), todos: todos}
    end

    test "are blank by default", %{state: state} do
      {:ok, base} = Fork.prepare(state)

      assert base.todos == []
    end

    test "are kept under :inherit", %{state: state, todos: todos} do
      {:ok, base} = Fork.prepare(state, todos: :inherit)

      assert base.todos == todos
    end

    test "are replaced by an explicit list", %{state: state} do
      seeded = [Todo.new!(%{id: 1, content: "Fork task"})]

      {:ok, base} = Fork.prepare(state, todos: seeded)

      assert base.todos == seeded
    end

    test "raise on an unrecognized value", %{state: state} do
      assert_raise ArgumentError, ~r/:todos accepts a list or :inherit/, fn ->
        Fork.prepare(state, todos: :keep_them)
      end
    end
  end

  describe "prepare/2 metadata" do
    setup do
      metadata = %{
        "conversation_title" => "Parent thread",
        "conversation_title_triggered" => true,
        "debug_log.msg_count" => 12,
        "tenant_id" => "acme"
      }

      {:ok,
       state: State.new!(%{messages: conversation(), metadata: metadata}), metadata: metadata}
    end

    test "is empty by default", %{state: state} do
      {:ok, base} = Fork.prepare(state)

      assert base.metadata == %{}
    end

    test "drops the title keys, so a fork names itself", %{state: state} do
      {:ok, base} = Fork.prepare(state)

      refute Map.has_key?(base.metadata, "conversation_title")
      refute Map.has_key?(base.metadata, "conversation_title_triggered")
    end

    test "is kept under :inherit", %{state: state, metadata: metadata} do
      {:ok, base} = Fork.prepare(state, metadata: :inherit)

      assert base.metadata == metadata
    end

    test "is replaced by an explicit map", %{state: state} do
      {:ok, base} = Fork.prepare(state, metadata: %{"scope" => "narrow"})

      assert base.metadata == %{"scope" => "narrow"}
    end

    test "retains exactly the named keys under {:keep, keys}", %{state: state} do
      {:ok, base} = Fork.prepare(state, metadata: {:keep, ["tenant_id", "absent"]})

      assert base.metadata == %{"tenant_id" => "acme"}
    end

    test "raises on an unrecognized value", %{state: state} do
      assert_raise ArgumentError, ~r/:metadata accepts a map/, fn ->
        Fork.prepare(state, metadata: "everything")
      end
    end
  end

  describe "prepare/2 runtime fields" do
    test "every virtual field is back at its default" do
      state =
        State.new!(%{
          agent_id: "parent-agent",
          messages: conversation(),
          runtime: %{token: make_ref()},
          interrupt_data: %{type: :ask_user_question},
          pause_reason: :node_draining,
          conversation_id: 42
        })

      {:ok, base} = Fork.prepare(state)

      assert base.agent_id == nil
      assert base.runtime == %{}
      assert base.interrupt_data == nil
      assert base.pause_reason == nil
      assert base.conversation_id == nil
    end
  end

  # ── Interrupts ───────────────────────────────────────────────────

  describe "prepare/2 interrupts" do
    setup do
      messages =
        conversation() ++
          [tool_call_message("call_ask", "ask_user"), interrupt_message("call_ask")]

      {:ok, messages: messages}
    end

    test "demotes a pending interrupt result", %{messages: messages} do
      state = State.new!(%{messages: messages, interrupt_data: %{type: :ask_user_question}})

      {:ok, base} = Fork.prepare(state)

      [result] = List.last(base.messages).tool_results
      refute result.is_interrupt
      assert result.is_error
      assert is_nil(result.interrupt_data)
      assert base.interrupt_data == nil
    end

    test "a fork booted from the base does not start interrupted", %{messages: messages} do
      {:ok, base} = Fork.prepare(State.new!(%{messages: messages}))
      {:ok, stored} = Fork.to_stored(base)

      fork_agent = create_test_agent()

      {:ok, _pid} =
        AgentServer.start_link_from_state(stored,
          agent: fork_agent,
          agent_id: fork_agent.agent_id,
          name: AgentServer.get_name(fork_agent.agent_id),
          pubsub: nil
        )

      assert AgentServer.get_status(fork_agent.agent_id) == :idle
    end

    test "preparing an already-prepared base changes nothing", %{messages: messages} do
      {:ok, once} = Fork.prepare(State.new!(%{messages: messages}))
      {:ok, twice} = Fork.prepare(once)

      assert once == twice
    end
  end

  # ── Unanswered tool calls ────────────────────────────────────────

  describe "prepare/2 unanswered tool calls" do
    test "reports a trailing tool call with no result" do
      messages = conversation() ++ [tool_call_message("call_1", "search")]

      assert {:error, {:unanswered_tool_calls, ["call_1"]}} =
               Fork.prepare(State.new!(%{messages: messages}))
    end

    test "reports the unanswered half of a parallel call" do
      calls =
        Message.new_assistant!(%{
          tool_calls: [
            ToolCall.new!(%{call_id: "call_1", name: "search", arguments: %{}}),
            ToolCall.new!(%{call_id: "call_2", name: "search", arguments: %{}})
          ]
        })

      messages = conversation() ++ [calls, tool_result_message(["call_1"], "search")]

      assert {:error, {:unanswered_tool_calls, ["call_2"]}} =
               Fork.prepare(State.new!(%{messages: messages}))
    end

    test "passes a history whose tool calls are all answered" do
      messages =
        conversation() ++
          [
            tool_call_message("call_1", "search"),
            tool_result_message(["call_1"], "search"),
            Message.new_assistant!("Found it.")
          ]

      assert {:ok, base} = Fork.prepare(State.new!(%{messages: messages}))
      assert base.messages == messages
    end

    test "does not fire on answered tool calls sitting mid-history" do
      messages =
        [
          Message.new_user!("Search please"),
          tool_call_message("call_1", "search"),
          tool_result_message(["call_1"], "search"),
          Message.new_assistant!("Found it."),
          Message.new_user!("Thanks")
        ]

      assert {:ok, _base} = Fork.prepare(State.new!(%{messages: messages}))
    end

    test "catches a gap that is not at the tail" do
      messages =
        [
          tool_call_message("call_1", "search"),
          Message.new_assistant!("Never mind."),
          Message.new_user!("Ok")
        ]

      assert {:error, {:unanswered_tool_calls, ["call_1"]}} =
               Fork.prepare(State.new!(%{messages: messages}))
    end

    test "reports through from_agent/2 as well" do
      messages = conversation() ++ [tool_call_message("call_1", "search")]
      agent = create_test_agent()
      start_server(agent, initial_state: State.new!(%{messages: messages}))

      assert {:error, {:unanswered_tool_calls, ["call_1"]}} =
               Fork.from_agent(agent.agent_id)
    end
  end

  # ── The stored envelope ──────────────────────────────────────────

  describe "to_stored/1" do
    test "matches the shape export_state/1 produces" do
      agent = create_test_agent()
      start_server(agent, initial_state: State.new!(%{messages: conversation()}))

      exported = AgentServer.export_state(agent.agent_id)
      {:ok, base} = Fork.prepare(exported)
      {:ok, stored} = Fork.to_stored(base)

      assert Map.keys(stored) == Map.keys(exported)
      assert stored["version"] == StateSerializer.current_version()
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(stored["serialized_at"])
      assert Map.keys(stored["state"]) == Map.keys(exported["state"])
    end

    test "drops a pending message the source envelope carried" do
      state = State.new!(%{messages: conversation()})

      exported =
        StateSerializer.serialize_server_state(nil, state,
          pending_message: Message.new_user!("Queued mid-run")
        )

      assert Map.has_key?(exported, "pending_message")

      {:ok, base} = Fork.prepare(exported)
      {:ok, stored} = Fork.to_stored(base)

      refute Map.has_key?(stored, "pending_message")
    end

    test "round trips back to the same messages" do
      {:ok, base} = Fork.prepare(State.new!(%{messages: conversation()}))
      {:ok, stored} = Fork.to_stored(base)

      {:ok, restored} = StateSerializer.deserialize_state("fork-1", stored["state"])

      assert Enum.map(restored.messages, & &1.role) == Enum.map(conversation(), & &1.role)
      assert restored.todos == []
      assert restored.metadata == %{}
    end
  end

  # ── The idle precondition ────────────────────────────────────────

  describe "from_agent/2 preconditions" do
    test "returns a prepared base from an idle agent" do
      agent = create_test_agent()

      start_server(agent,
        initial_state:
          State.new!(%{messages: conversation(), metadata: %{"conversation_title" => "Parent"}})
      )

      assert {:ok, base} = Fork.from_agent(agent.agent_id)
      assert Enum.map(base.messages, & &1.role) == [:user, :assistant, :user, :assistant]
      assert base.metadata == %{}
      assert base.agent_id == nil
    end

    test "forwards its options to prepare/2" do
      agent = create_test_agent()

      start_server(agent,
        initial_state: State.new!(%{messages: conversation(), metadata: %{"tenant_id" => "acme"}})
      )

      assert {:ok, base} = Fork.from_agent(agent.agent_id, metadata: :inherit)
      assert base.metadata == %{"tenant_id" => "acme"}
    end

    test "refuses a running agent, and replies while the run is still in flight" do
      test_pid = self()
      agent = create_test_agent()

      expect(Agent, :execute, fn _agent, state, _opts ->
        send(test_pid, {:run_started, self()})

        receive do
          :finish -> {:ok, state}
        after
          5_000 -> {:ok, state}
        end
      end)

      start_server(agent, initial_state: State.new!(%{messages: conversation()}))

      :ok = AgentServer.execute(agent.agent_id)
      assert_receive {:run_started, task_pid}, 1_000

      # The reply must arrive while the task is still blocked. If the call had
      # queued behind the run, this would time out rather than refuse.
      assert {:error, {:agent_busy, :running}} = Fork.from_agent(agent.agent_id)

      # Release the run so the server settles before the test ends.
      send(task_pid, :finish)
    end

    test "refuses every non-idle status and names it" do
      for status <- [:interrupted, :cancelled, :error, :paused] do
        agent = create_test_agent()
        start_server(agent, initial_state: State.new!(%{messages: conversation()}))

        :sys.replace_state(AgentServer.get_pid(agent.agent_id), fn server_state ->
          %{server_state | status: status}
        end)

        assert {:error, {:agent_busy, ^status}} = Fork.from_agent(agent.agent_id)
      end
    end

    test "a refusal leaves the server untouched" do
      agent = create_test_agent()
      start_server(agent, initial_state: State.new!(%{messages: conversation()}))

      :sys.replace_state(AgentServer.get_pid(agent.agent_id), fn server_state ->
        %{server_state | status: :error}
      end)

      before = AgentServer.get_state(agent.agent_id)

      assert {:error, {:agent_busy, :error}} = Fork.from_agent(agent.agent_id)

      assert AgentServer.get_status(agent.agent_id) == :error
      assert AgentServer.get_state(agent.agent_id).messages == before.messages
    end

    test "returns an error rather than exiting when no agent is running" do
      assert {:error, :not_running} = Fork.from_agent("fork-test-no-such-agent")
    end
  end

  describe "export_state_if_idle/1 alongside export_state/1" do
    test "export_state/1 still answers on a running agent" do
      test_pid = self()
      agent = create_test_agent()

      expect(Agent, :execute, fn _agent, state, _opts ->
        send(test_pid, {:run_started, self()})

        receive do
          :finish -> {:ok, state}
        after
          5_000 -> {:ok, state}
        end
      end)

      start_server(agent, initial_state: State.new!(%{messages: conversation()}))

      :ok = AgentServer.execute(agent.agent_id)
      assert_receive {:run_started, task_pid}, 1_000

      exported = AgentServer.export_state(agent.agent_id)
      assert exported["version"] == StateSerializer.current_version()
      assert length(exported["state"]["messages"]) == 4

      assert {:error, {:agent_busy, :running}} =
               AgentServer.export_state_if_idle(agent.agent_id)

      send(task_pid, :finish)
    end
  end

  # ── Round trip ───────────────────────────────────────────────────

  describe "forking end to end" do
    setup do
      :persistent_term.put(:fork_test_pid, self())
      on_exit(fn -> :persistent_term.erase(:fork_test_pid) end)
      :ok
    end

    test "a fork answers from inherited context under its own configuration" do
      stub(ChatOpenAI, :call, fn _model, messages, tools ->
        send(test_pid(), {:llm_called, messages, tools})
        {:ok, [Message.new_assistant!("Madrid, as established.")]}
      end)

      model = ChatOpenAI.new!(%{model: "gpt-4", stream: false})

      parent =
        Agent.new!(
          %{
            agent_id: "fork-test-parent",
            model: model,
            base_system_prompt: "You are the parent agent.",
            middleware: []
          },
          replace_default_middleware: true
        )

      start_server(parent, initial_state: State.new!(%{messages: conversation()}))

      {:ok, base} = Fork.from_agent(parent.agent_id)

      {:ok, stored} =
        base
        |> State.add_message(Message.new_user!("Remind me about Spain."))
        |> Fork.to_stored()

      fork_tool =
        Function.new!(%{
          name: "fork_only_tool",
          description: "A tool the parent never had",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:ok, "ok"} end
        })

      fork_agent =
        Agent.new!(
          %{
            agent_id: "fork-test-child",
            model: model,
            base_system_prompt: "You are the fork. Answer only about Spain.",
            tools: [fork_tool],
            middleware: []
          },
          replace_default_middleware: true
        )

      {:ok, _pid} =
        AgentServer.start_link_from_state(stored,
          agent: fork_agent,
          agent_id: fork_agent.agent_id,
          name: AgentServer.get_name(fork_agent.agent_id),
          pubsub: nil
        )

      :ok = AgentServer.execute(fork_agent.agent_id)

      assert_receive {:llm_called, messages, tools}, 2_000

      # The inherited history reached the provider ...
      texts = Enum.map(messages, &to_text/1)
      assert Enum.any?(texts, &(&1 =~ "capital of France"))
      assert Enum.any?(texts, &(&1 =~ "Remind me about Spain"))

      # ... under the fork's own configuration, not the parent's.
      assert Enum.any?(texts, &(&1 =~ "You are the fork"))
      refute Enum.any?(texts, &(&1 =~ "You are the parent agent"))
      assert Enum.any?(tools, &(&1.name == "fork_only_tool"))

      # The parent is where it was.
      assert AgentServer.get_status(parent.agent_id) == :idle
      assert length(AgentServer.get_state(parent.agent_id).messages) == 4
    end

    test "two forks from one base do not affect each other" do
      {:ok, base} = Fork.prepare(State.new!(%{messages: conversation()}))

      {:ok, first} =
        base |> State.add_message(Message.new_user!("Branch one.")) |> Fork.to_stored()

      {:ok, second} =
        base |> State.add_message(Message.new_user!("Branch two.")) |> Fork.to_stored()

      assert length(first["state"]["messages"]) == 5
      assert length(second["state"]["messages"]) == 5
      assert base.messages == conversation()

      refute first["state"]["messages"] == second["state"]["messages"]
    end

    test "a primed message writes no display rows" do
      stub(ChatOpenAI, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Understood.")]}
      end)

      model = ChatOpenAI.new!(%{model: "gpt-4", stream: false})

      {:ok, base} = Fork.prepare(State.new!(%{messages: conversation()}))

      {:ok, stored} =
        base
        |> State.add_message(Message.new_user!("Invisible priming instruction."))
        |> Fork.to_stored()

      fork_agent =
        Agent.new!(
          %{
            agent_id: "fork-test-display",
            model: model,
            base_system_prompt: "Fork.",
            middleware: []
          },
          replace_default_middleware: true
        )

      {:ok, _pid} =
        AgentServer.start_link_from_state(stored,
          agent: fork_agent,
          agent_id: fork_agent.agent_id,
          name: AgentServer.get_name(fork_agent.agent_id),
          pubsub: nil,
          conversation_id: "fork-conversation",
          display_message_persistence: ReportingPersistence
        )

      # Booting alone must not render the primed history.
      _synchronize = AgentServer.get_state(fork_agent.agent_id)
      refute_received {:saved_display, _message}

      :ok = AgentServer.execute(fork_agent.agent_id)

      assert_receive {:saved_display, saved}, 2_000
      assert saved.role == :assistant

      # Nothing from the inherited or primed history was ever displayed.
      refute_received {:saved_display, %Message{role: :user}}
    end
  end

  defp to_text(%Message{content: content}) when is_binary(content), do: content

  defp to_text(%Message{content: content}) when is_list(content) do
    ContentPart.parts_to_string(content) || ""
  end

  defp to_text(_other), do: ""
end
