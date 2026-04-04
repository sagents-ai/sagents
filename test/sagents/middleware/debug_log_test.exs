defmodule Sagents.Middleware.DebugLogTest do
  use ExUnit.Case, async: true

  alias Sagents.Middleware.DebugLog
  alias Sagents.State
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  @test_log_dir "tmp/test_debug_logs"

  setup do
    # Clean up test log directory before each test
    File.rm_rf(@test_log_dir)
    on_exit(fn -> File.rm_rf(@test_log_dir) end)

    {:ok, config} = DebugLog.init(log_dir: @test_log_dir)
    {:ok, config: config}
  end

  describe "init/1" do
    test "creates config with defaults" do
      {:ok, config} = DebugLog.init([])
      assert config.log_dir == "tmp/agent_logs"
      assert config.prefix == "debug"
      assert config.log_deltas == false
      assert config.pretty == true
      assert config.inspect_limit == :infinity
      assert is_binary(config.start_timestamp)
    end

    test "creates config with custom options" do
      {:ok, config} =
        DebugLog.init(
          log_dir: "custom/logs",
          prefix: "myapp",
          log_deltas: true,
          pretty: false,
          inspect_limit: 50
        )

      assert config.log_dir == "custom/logs"
      assert config.prefix == "myapp"
      assert config.log_deltas == true
      assert config.pretty == false
      assert config.inspect_limit == 50
    end

    test "captures start timestamp" do
      {:ok, config} = DebugLog.init([])
      assert config.start_timestamp =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}/
    end
  end

  describe "log_path/2" do
    test "computes path from config and agent_id", %{config: config} do
      path = DebugLog.log_path(config, "conversation-42")
      assert path =~ @test_log_dir
      assert path =~ ~r/debug_\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}_conversation-42\.log/
      assert path =~ ".log"
    end

    test "sanitizes invalid filename characters", %{config: config} do
      path = DebugLog.log_path(config, "agent/with/slashes")
      filename = Path.basename(path)
      refute filename =~ "/"
      assert filename =~ "agent_with_slashes"
    end

    test "sanitizes special characters", %{config: config} do
      path = DebugLog.log_path(config, "agent:with spaces!@#")
      filename = Path.basename(path)
      refute filename =~ ":"
      refute filename =~ " "
      refute filename =~ "!"
    end
  end

  describe "on_server_start/2" do
    test "writes initial state snapshot to log file", %{config: config} do
      state =
        State.new!(%{
          agent_id: "test-agent-1",
          messages: [
            Message.new_system!("You are helpful."),
            Message.new_user!("Hello!")
          ]
        })

      assert {:ok, ^state} = DebugLog.on_server_start(state, config)

      log_content = read_log(config, "test-agent-1")
      assert log_content =~ "ON_SERVER_START"
      assert log_content =~ "test-agent-1"
      assert log_content =~ "Messages: 2"
      assert log_content =~ "Todos: 0"
      assert log_content =~ "--- Messages ---"
    end

    test "creates log directory if it doesn't exist", %{config: config} do
      state = State.new!(%{agent_id: "test-agent-2", messages: []})

      refute File.dir?(@test_log_dir)
      assert {:ok, ^state} = DebugLog.on_server_start(state, config)
      assert File.dir?(@test_log_dir)
    end
  end

  describe "before_model/2" do
    test "logs message count and new messages", %{config: config} do
      state =
        State.new!(%{
          agent_id: "test-agent-bm",
          messages: [
            Message.new_system!("System prompt"),
            Message.new_user!("First message")
          ]
        })

      assert {:ok, updated_state} = DebugLog.before_model(state, config)

      log_content = read_log(config, "test-agent-bm")
      assert log_content =~ "BEFORE_MODEL"
      assert log_content =~ "Message count: 2"

      # Verify msg count is stored in metadata
      assert State.get_metadata(updated_state, "debug_log.msg_count") == 2
    end

    test "tracks new messages since last call", %{config: config} do
      state =
        State.new!(%{
          agent_id: "test-agent-bm2",
          messages: [
            Message.new_system!("System prompt"),
            Message.new_user!("First message")
          ]
        })

      # First call
      {:ok, state_after_first} = DebugLog.before_model(state, config)

      # Add a new message and call again
      state_with_new =
        %{
          state_after_first
          | messages: state_after_first.messages ++ [Message.new_user!("Second message")]
        }

      {:ok, state_after_second} = DebugLog.before_model(state_with_new, config)

      log_content = read_log(config, "test-agent-bm2")
      assert log_content =~ "1 new since last"
      assert State.get_metadata(state_after_second, "debug_log.msg_count") == 3
    end
  end

  describe "after_model/2" do
    test "logs new messages since before_model", %{config: config} do
      # Simulate state after before_model set the count to 2
      state =
        State.new!(%{
          agent_id: "test-agent-am",
          messages: [
            Message.new_system!("System prompt"),
            Message.new_user!("Hello"),
            Message.new_assistant!("Hi there!")
          ],
          metadata: %{"debug_log.msg_count" => 2}
        })

      assert {:ok, updated_state} = DebugLog.after_model(state, config)

      log_content = read_log(config, "test-agent-am")
      assert log_content =~ "AFTER_MODEL"
      assert log_content =~ "New messages since BEFORE_MODEL: 1"
      assert log_content =~ "Interrupt: none"

      assert State.get_metadata(updated_state, "debug_log.msg_count") == 3
    end

    test "logs interrupt data when present", %{config: config} do
      state =
        State.new!(%{
          agent_id: "test-agent-am2",
          messages: [Message.new_user!("Do something")],
          metadata: %{"debug_log.msg_count" => 0}
        })

      state = %{state | interrupt_data: %{action: "needs_approval", tool: "file_write"}}

      assert {:ok, _updated_state} = DebugLog.after_model(state, config)

      log_content = read_log(config, "test-agent-am2")
      assert log_content =~ "needs_approval"
      assert log_content =~ "file_write"
    end
  end

  describe "handle_resume/5" do
    test "logs interrupt and resume data", %{config: config} do
      agent = %Sagents.Agent{
        agent_id: "test-agent-hr",
        model: nil,
        middleware: []
      }

      state =
        State.new!(%{
          agent_id: "test-agent-hr",
          messages: []
        })

      state = %{state | interrupt_data: %{pending: "approval"}}
      resume_data = %{approved: true}

      assert {:cont, ^state} = DebugLog.handle_resume(agent, state, resume_data, config, [])

      log_content = read_log(config, "test-agent-hr")
      assert log_content =~ "HANDLE_RESUME"
      assert log_content =~ "pending"
      assert log_content =~ "approved"
    end
  end

  describe "handle_message/3" do
    test "logs the received message", %{config: config} do
      state = State.new!(%{agent_id: "test-agent-hm", messages: []})
      message = {:context_update, %{topic: "weather"}}

      assert {:ok, ^state} = DebugLog.handle_message(message, state, config)

      log_content = read_log(config, "test-agent-hm")
      assert log_content =~ "HANDLE_MESSAGE"
      assert log_content =~ "context_update"
      assert log_content =~ "weather"
    end
  end

  describe "callbacks/1" do
    test "returns callback map without delta handler by default", %{config: config} do
      callbacks = DebugLog.callbacks(config)

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, :on_llm_new_message)
      assert Map.has_key?(callbacks, :on_message_processed)
      assert Map.has_key?(callbacks, :on_tool_call_identified)
      assert Map.has_key?(callbacks, :on_tool_execution_started)
      assert Map.has_key?(callbacks, :on_tool_execution_completed)
      assert Map.has_key?(callbacks, :on_tool_execution_failed)
      assert Map.has_key?(callbacks, :on_tool_interrupted)
      assert Map.has_key?(callbacks, :on_tool_response_created)
      assert Map.has_key?(callbacks, :on_llm_token_usage)
      assert Map.has_key?(callbacks, :on_llm_ratelimit_info)
      assert Map.has_key?(callbacks, :on_message_processing_error)
      assert Map.has_key?(callbacks, :on_error_message_created)
      assert Map.has_key?(callbacks, :on_retries_exceeded)
      assert Map.has_key?(callbacks, :on_llm_error)
      assert Map.has_key?(callbacks, :on_error)

      refute Map.has_key?(callbacks, :on_llm_new_delta)
    end

    test "includes delta handler when log_deltas is true" do
      {:ok, config} = DebugLog.init(log_dir: @test_log_dir, log_deltas: true)
      callbacks = DebugLog.callbacks(config)

      assert Map.has_key?(callbacks, :on_llm_new_delta)
    end
  end

  describe "on_llm_error callback" do
    test "logs individual LLM call failures", %{config: config} do
      callbacks = DebugLog.callbacks(config)

      chain = build_chain("test-agent-llm-err")
      error = %LangChain.LangChainError{message: "Rate limit exceeded"}

      callbacks.on_llm_error.(chain, error)

      log_content = read_log(config, "test-agent-llm-err")
      assert log_content =~ "LLM_ERROR"
      assert log_content =~ "may be retried"
      assert log_content =~ "Rate limit exceeded"
    end
  end

  describe "on_error callback" do
    test "logs terminal chain errors", %{config: config} do
      callbacks = DebugLog.callbacks(config)

      chain = build_chain("test-agent-chain-err")
      error = %LangChain.LangChainError{message: "All retries exhausted"}

      callbacks.on_error.(chain, error)

      log_content = read_log(config, "test-agent-chain-err")
      assert log_content =~ "CHAIN_ERROR"
      assert log_content =~ "Terminal error"
      assert log_content =~ "All retries exhausted"
    end
  end

  describe "error resilience" do
    test "does not crash when log directory is unwritable" do
      {:ok, config} = DebugLog.init(log_dir: "/nonexistent/readonly/path")
      state = State.new!(%{agent_id: "test-agent-err", messages: []})

      # Should not raise
      assert {:ok, ^state} = DebugLog.on_server_start(state, config)
    end

    test "before_model returns ok even when logging fails" do
      {:ok, config} = DebugLog.init(log_dir: "/nonexistent/readonly/path")
      state = State.new!(%{agent_id: "test-agent-err2", messages: []})

      assert {:ok, _state} = DebugLog.before_model(state, config)
    end

    test "after_model returns ok even when logging fails" do
      {:ok, config} = DebugLog.init(log_dir: "/nonexistent/readonly/path")
      state = State.new!(%{agent_id: "test-agent-err3", messages: []})

      assert {:ok, _state} = DebugLog.after_model(state, config)
    end
  end

  describe "log entry format" do
    test "entries have timestamp and separator", %{config: config} do
      state =
        State.new!(%{
          agent_id: "test-agent-fmt",
          messages: [Message.new_user!("Hello")]
        })

      DebugLog.on_server_start(state, config)

      log_content = read_log(config, "test-agent-fmt")
      assert log_content =~ "================"
      assert log_content =~ ~r/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+Z\]/
    end

    test "tool call summary shows tool count", %{config: config} do
      tool_call =
        ToolCall.new!(%{
          call_id: "call-1",
          name: "write_file",
          arguments: %{"path" => "test.txt", "content" => "hello"}
        })

      state =
        State.new!(%{
          agent_id: "test-agent-tc",
          messages: [
            Message.new_user!("Write a file"),
            %Message{role: :assistant, content: "Sure", tool_calls: [tool_call]}
          ],
          metadata: %{"debug_log.msg_count" => 1}
        })

      DebugLog.after_model(state, config)

      log_content = read_log(config, "test-agent-tc")
      assert log_content =~ "with 1 tool call"
    end
  end

  # -- Helpers --

  defp read_log(config, agent_id) do
    path = DebugLog.log_path(config, agent_id)
    File.read!(path)
  end

  defp build_chain(agent_id) do
    state = State.new!(%{agent_id: agent_id, messages: []})
    %LangChain.Chains.LLMChain{custom_context: %{state: state}}
  end
end
