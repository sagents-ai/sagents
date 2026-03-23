defmodule Sagents.AgentServerMessagePreprocessorTest do
  use ExUnit.Case, async: false

  alias Sagents.{Agent, AgentServer, State}
  alias LangChain.Message
  alias LangChain.ChatModels.ChatOpenAI

  defmodule PassthroughPreprocessor do
    @behaviour Sagents.MessagePreprocessor

    @impl true
    def preprocess(message, _context) do
      {:ok, message, message}
    end
  end

  defmodule SplittingPreprocessor do
    @behaviour Sagents.MessagePreprocessor

    @impl true
    def preprocess(_message, _context) do
      display_msg = Message.new_user!("[display] original")
      llm_msg = Message.new_user!("[llm] original")
      {:ok, display_msg, llm_msg}
    end
  end

  defmodule RejectingPreprocessor do
    @behaviour Sagents.MessagePreprocessor

    @impl true
    def preprocess(_message, _context) do
      {:error, :message_rejected}
    end
  end

  defmodule ContextCapturingPreprocessor do
    @behaviour Sagents.MessagePreprocessor

    @impl true
    def preprocess(message, context) do
      # Send context to the registered test process
      send(context.tool_context[:test_pid], {:preprocessor_context, context})
      {:ok, message, message}
    end
  end

  defmodule CrashingPreprocessor do
    @behaviour Sagents.MessagePreprocessor

    @impl true
    def preprocess(_message, _context) do
      raise "preprocessor crashed"
    end
  end

  defmodule TrackingPersistence do
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_conversation_id, message) do
      # Use the process dictionary to find the test pid
      # (set by the test before starting the server)
      if pid = Process.get(:test_pid) do
        send(pid, {:persisted_message, message})
      end

      {:ok, []}
    end

    @impl true
    def update_tool_status(_status, _info), do: {:ok, nil}
  end

  defp create_agent(agent_id, opts \\ []) do
    {:ok, model} = ChatOpenAI.new(%{model: "gpt-4", api_key: "test-key"})

    tool_context = Keyword.get(opts, :tool_context, %{})

    {:ok, agent} =
      Agent.new(%{
        agent_id: agent_id,
        model: model,
        base_system_prompt: "You are helpful",
        tool_context: tool_context
      })

    agent
  end

  # Helper to extract text content from a message
  defp text_content(%Message{content: content}) when is_binary(content), do: content

  defp text_content(%Message{content: [%{content: text} | _]}), do: text

  describe "without message_preprocessor" do
    test "message flows unchanged to both state and display" do
      agent = create_agent("no-preproc-1")

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          pubsub: nil
        )

      msg = Message.new_user!("Hello")
      :ok = GenServer.call(AgentServer.get_name("no-preproc-1"), {:add_message, msg})

      # Message should be in state
      state = AgentServer.get_state("no-preproc-1")
      last_msg = List.last(state.messages)
      assert text_content(last_msg) == "Hello"

      AgentServer.stop("no-preproc-1")
    end
  end

  describe "with passthrough preprocessor" do
    test "message flows unchanged when preprocessor returns same message" do
      agent = create_agent("passthrough-1")

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          pubsub: nil,
          message_preprocessor: PassthroughPreprocessor
        )

      msg = Message.new_user!("Hello")
      :ok = GenServer.call(AgentServer.get_name("passthrough-1"), {:add_message, msg})

      state = AgentServer.get_state("passthrough-1")
      last_msg = List.last(state.messages)
      assert text_content(last_msg) == "Hello"

      AgentServer.stop("passthrough-1")
    end
  end

  describe "with splitting preprocessor" do
    test "display message goes to persistence, LLM message goes to state" do
      # Store test pid so the persistence module can send messages back
      Process.put(:test_pid, self())

      agent = create_agent("split-1")

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          pubsub: nil,
          conversation_id: "conv-3",
          message_preprocessor: SplittingPreprocessor,
          display_message_persistence: TrackingPersistence
        )

      msg = Message.new_user!("Hello")
      :ok = GenServer.call(AgentServer.get_name("split-1"), {:add_message, msg})

      # State message should have [llm] prefix
      state = AgentServer.get_state("split-1")
      last_msg = List.last(state.messages)
      assert text_content(last_msg) == "[llm] original"

      AgentServer.stop("split-1")
    end
  end

  describe "with rejecting preprocessor" do
    test "returns error and does not modify state" do
      agent = create_agent("reject-1")

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          pubsub: nil,
          message_preprocessor: RejectingPreprocessor
        )

      msg = Message.new_user!("Hello")

      result =
        GenServer.call(AgentServer.get_name("reject-1"), {:add_message, msg})

      assert result == {:error, :message_rejected}

      # State should be unchanged (no messages)
      state = AgentServer.get_state("reject-1")
      assert state.messages == []

      AgentServer.stop("reject-1")
    end
  end

  describe "preprocessor context" do
    test "receives agent_id, conversation_id, tool_context, and state" do
      tool_context = %{current_scope: {:user, 42}, custom_key: "value", test_pid: self()}
      agent = create_agent("ctx-1", tool_context: tool_context)

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          pubsub: nil,
          conversation_id: "conv-5",
          message_preprocessor: ContextCapturingPreprocessor
        )

      msg = Message.new_user!("Hello")
      :ok = GenServer.call(AgentServer.get_name("ctx-1"), {:add_message, msg})

      assert_received {:preprocessor_context, context}
      assert context.agent_id == "ctx-1"
      assert context.conversation_id == "conv-5"
      assert context.tool_context.current_scope == {:user, 42}
      assert context.tool_context.custom_key == "value"
      assert %State{} = context.state

      AgentServer.stop("ctx-1")
    end
  end

  describe "with crashing preprocessor" do
    test "returns error and does not modify state" do
      agent = create_agent("crash-1")

      {:ok, _pid} =
        AgentServer.start_link(
          agent: agent,
          pubsub: nil,
          message_preprocessor: CrashingPreprocessor
        )

      msg = Message.new_user!("Hello")

      result =
        GenServer.call(AgentServer.get_name("crash-1"), {:add_message, msg})

      assert {:error, {:preprocessor_error, %RuntimeError{message: "preprocessor crashed"}}} =
               result

      # State should be unchanged
      state = AgentServer.get_state("crash-1")
      assert state.messages == []

      AgentServer.stop("crash-1")
    end
  end
end
