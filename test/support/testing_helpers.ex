defmodule Sagents.TestingHelpers do
  @moduledoc """
  Shared testing helper functions used across test suites.
  """

  alias Sagents.{Agent, AgentServer, AgentSupervisor, FileSystemServer}
  alias LangChain.ChatModels.ChatAnthropic

  @doc """
  Collects all messages sent to the current test process and returns them as a
  list.

  This is useful for testing callbacks that send messages to the test process.
  It's a bit of a hack, but it's the best way I can think of to test callbacks
  that send an unspecified number of messages to the test process.
  """
  def collect_messages do
    collect_messages([])
  end

  defp collect_messages(acc) do
    receive do
      message -> collect_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Helper to get a file entry from FileSystemServer's GenServer state.

  This is useful for inspecting the internal state of the filesystem in tests.

  ## Parameters

  - `agent_id` - The agent identifier
  - `path` - The file path to retrieve

  ## Returns

  The FileEntry struct or nil if not found.

  ## Examples

      entry = get_entry("agent-123", "/file.txt")
      assert entry.content == "test content"
  """
  def get_entry(agent_id, path) do
    pid = FileSystemServer.whereis({:agent, agent_id})
    state = :sys.get_state(pid)
    Map.get(state.files, path)
  end

  @doc """
  Generate a new, unique test agent_id.
  """
  def generate_test_agent_id() do
    "test-agent-#{System.unique_integer()}"
  end

  @doc """
  Polls a function until it returns a truthy value or the timeout elapses.

  Useful for synchronizing tests with asynchronous state changes that don't
  expose a direct hook to wait on — for example, waiting for an Elixir
  `Registry` to process the `:DOWN` message that follows a `GenServer.stop/2`,
  or waiting for an ETS table to reflect an out-of-band write.

  Returns `true` if the function returned a truthy value before the deadline, or
  `false` if the timeout elapsed first. Pair it with `assert/1` so failures
  surface at the test's call site:

      assert wait_until(fn -> SubAgentServer.whereis(id) == nil end)

  ## Options

  - `:timeout` - total time to wait, in milliseconds (default: `1_000`)
  - `:interval` - sleep duration between checks, in milliseconds (default: `10`)

  ## Examples

      # Wait for a process to be deregistered after stop
      assert wait_until(fn ->
        SubAgentServer.whereis(sub_agent_id) == nil
      end)

      # Custom timeout for a slower condition
      assert wait_until(fn -> some_async_condition() end, timeout: 5_000)
  """
  @spec wait_until((-> any()), keyword()) :: boolean()
  def wait_until(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 1_000)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, interval, deadline)
  end

  defp do_wait_until(fun, interval, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(interval)
        do_wait_until(fun, interval, deadline)
      end
    end
  end

  @doc """
  Basic conversion of a Message to a DisplayMessage like data map.
  """
  def message_to_display_data(%LangChain.Message{} = message) do
    %{
      content_type: "text",
      role: to_string(message.role),
      content: LangChain.Message.ContentPart.parts_to_string(message.content)
    }
  end

  # Helper to create a mock model
  def mock_model do
    ChatAnthropic.new!(%{
      model: "claude-sonnet-4-6",
      api_key: "test_key"
    })
  end

  # Helper to create a simple agent
  def create_test_agent(opts \\ []) do
    Agent.new!(
      Map.merge(
        %{
          agent_id: generate_test_agent_id(),
          model: mock_model(),
          base_system_prompt: "Test agent",
          replace_default_middleware: true,
          middleware: []
        },
        Enum.into(opts, %{})
      )
    )
  end

  @doc """
  Start a test agent with proper configuration for testing.

  This helper follows the same pattern as Coordinator.do_start_session to ensure
  agents are properly initialized and ready before tests interact with them.

  ## Options

  - `:agent_id` - (required) Unique identifier for the agent
  - `:pubsub` - (required) Tuple of {module, name} for PubSub
  - `:conversation_id` - (optional) Conversation ID for message persistence
  - `:display_message_persistence` - (optional) Module implementing `Sagents.DisplayMessagePersistence`
  - `:initial_state` - (optional) Initial agent state (defaults to empty state)

  ## Returns

  `{:ok, %{agent_id: agent_id, pid: pid}}` on success, or `{:error, reason}` on failure.

  ## Example

      {:ok, %{agent_id: agent_id, pid: pid}} = start_test_agent(
        agent_id: "test-123",
        pubsub: {Phoenix.PubSub, :test_pubsub},
        conversation_id: "conv-123",
        display_message_persistence: MyApp.DisplayMessagePersistence
      )
  """
  def start_test_agent(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    {pubsub_module, pubsub_name} = Keyword.fetch!(opts, :pubsub)

    # Optional callback configuration
    conversation_id = Keyword.get(opts, :conversation_id)
    display_message_persistence = Keyword.get(opts, :display_message_persistence)
    initial_state = Keyword.get(opts, :initial_state)

    # Subscribe to agent's PubSub topic so test can receive events
    # AgentServer broadcasts to "agent_server:#{agent_id}"
    topic = "agent_server:#{agent_id}"
    Sagents.PubSub.raw_subscribe(pubsub_module, pubsub_name, topic)

    # Create a minimal test agent
    model =
      ChatAnthropic.new!(%{
        model: "claude-sonnet-4-6",
        api_key: "test_key"
      })

    agent =
      Agent.new!(%{
        agent_id: agent_id,
        model: model,
        base_system_prompt: "Test agent",
        replace_default_middleware: true,
        middleware: []
      })

    # Build supervisor configuration (similar to Coordinator pattern)
    supervisor_name = AgentSupervisor.get_name(agent_id)

    supervisor_config = [
      name: supervisor_name,
      agent: agent,
      pubsub: {pubsub_module, pubsub_name}
    ]

    # Add initial_state if provided
    supervisor_config =
      if initial_state,
        do: Keyword.put(supervisor_config, :initial_state, initial_state),
        else: supervisor_config

    # Add callback configuration if provided
    supervisor_config =
      if conversation_id,
        do: Keyword.put(supervisor_config, :conversation_id, conversation_id),
        else: supervisor_config

    supervisor_config =
      if display_message_persistence,
        do:
          Keyword.put(
            supervisor_config,
            :display_message_persistence,
            display_message_persistence
          ),
        else: supervisor_config

    # Start supervisor synchronously to ensure agent is ready
    case AgentSupervisor.start_link_sync(supervisor_config) do
      {:ok, _supervisor_pid} ->
        pid = AgentServer.get_pid(agent_id)
        {:ok, %{agent_id: agent_id, pid: pid}}

      {:error, {:already_started, _supervisor_pid}} ->
        # Already started - return existing pid
        pid = AgentServer.get_pid(agent_id)
        {:ok, %{agent_id: agent_id, pid: pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stop a test agent and clean up resources.

  ## Parameters

  - `agent_id` - The agent identifier

  ## Example

      stop_test_agent("test-123")
  """
  def stop_test_agent(agent_id) do
    AgentServer.stop(agent_id)
  end
end
