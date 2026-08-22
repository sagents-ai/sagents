defmodule Sagents.AgentServer do
  @moduledoc """
  GenServer that wraps a DeepAgent and its State, managing execution lifecycle
  and broadcasting events via PubSub.

  The AgentServer provides:
  - Asynchronous agent execution
  - State management and tracking
  - Event broadcasting for UI updates
  - Human-in-the-loop interrupt handling

  ## Understanding agent_id

  The `agent_id` is a **runtime identifier** used for process management and
  inter-process communication. It serves several critical purposes:

  ### Process Registration
  The `agent_id` is used to construct a Registry key via `get_name(agent_id)`,
  which returns a `:via` tuple for GenServer registration:
  - Format: `{:via, Registry, {Sagents.Registry, {:agent_server,
    agent_id}}}`
  - Ensures only one AgentServer process exists per agent_id
  - Enables process lookup without maintaining PIDs

  ### PubSub Topics
  The `agent_id` forms the basis for PubSub topic construction:
  - Topic format: `"agent_server:\#{agent_id}"`
  - External clients subscribe using: `AgentServer.subscribe(agent_id)`
  - Events broadcast include: status changes, LLM deltas, todos updates

  ### Middleware Context
  The `agent_id` is passed to middleware during initialization, enabling:
  - Coordination with agent-specific services (FileSystemServer,
    SubAgentsDynamicSupervisor)
  - Parent-child relationship establishment in SubAgent hierarchies
  - Per-agent resource isolation (virtual filesystems, etc.)

  ### Supervision Tree Coordination
  The `agent_id` flows through the entire supervision tree via AgentSupervisor,
  ensuring all child processes (FileSystemServer, AgentServer,
  SubAgentsDynamicSupervisor) are coordinated under the same agent context.

  ### What agent_id IS NOT

  **Not Part of Conversation State**: The `agent_id` is NOT included in
  serialized state (via `export_state/1`). It's a runtime identifier, not
  conversation data. This separation provides important benefits:

  - **Flexibility**: Restore the same conversation state under a different
    `agent_id`
  - **State Cloning**: Clone conversations for testing or forking scenarios
  - **Clean Architecture**: Clear separation between runtime identity and data

  When restoring state via `start_link_from_state/2`, you must provide the
  `agent_id` as a parameter. This enables use cases like:

      # Restore with same agent_id
      AgentServer.start_link_from_state(saved_state, agent_id: "conversation-123")

      # Clone conversation with different agent_id
      AgentServer.start_link_from_state(saved_state, agent_id: "conversation-123-fork")

  The `agent_id` can be any value that makes sense for your application:
  - Database conversation IDs: `"conv_a1b2c3d4"`
  - User-scoped identifiers: `"user-\#{user_id}-session-\#{session_id}"`
  - Randomly generated GUIDs: `UUID.uuid4()`
  - Application-defined values: `"demo-agent-001"`

  ## Events

  The server broadcasts events on the topic `"agent_server:\#{agent_id}"`.

  **All events are wrapped in an `{:agent, event}` tuple** to help consumers
  identify and route events from AgentServer. This is similar to how
  `FileSystemServer` wraps its events in `{:file_system, event}`.

  ### Event Format

  Events are received in the format `{:agent, event}` where `event` is one of:

  ### Todo Events
  - `{:agent, {:todos_updated, todos}}` - Complete snapshot of current TODO list

  ### Status Events
  - `{:agent, {:status_changed, :idle, nil}}` - Server ready for work (also broadcast after successful execution completion)
  - `{:agent, {:status_changed, :running, nil}}` - Agent executing
  - `{:agent, {:status_changed, :interrupted, interrupt_data}}` - Awaiting human decision
  - `{:agent, {:status_changed, :paused, pause_reason}}` - Infrastructure pause; the payload
    is the cause the mode attached (nil when it attached none)
  - `{:agent, {:status_changed, :cancelled, nil}}` - Execution was cancelled by user
  - `{:agent, {:status_changed, :error, reason}}` - Execution failed

  ### Node Transfer Events
  - `{:agent, {:node_transferring, data}}` - Agent is about to leave this node (broadcast during terminate/2)
    - `data.from_node` - The node the agent is leaving
  - `{:agent, {:node_transferred, data}}` - Agent has been restored on a new node (broadcast on startup after restore)
    - `data.to_node` - The node the agent has been restored to

  ### Shutdown Events
  - `{:agent, {:agent_shutdown, shutdown_data}}` - Agent is shutting down

    A single shutdown delivers this event more than once (the trigger handler
    fires it, then `terminate/2` fires it again). Every site emits the same
    map shape, so consumers can handle it with one idempotent clause:

    - `shutdown_data.agent_id` - The agent identifier
    - `shutdown_data.reason` - Shutdown reason (`:inactivity` | `:no_viewers`
      | the `terminate/2` reason term)
    - `shutdown_data.status` - The server's status at shutdown
    - `shutdown_data.interrupt_restorable` - `true` when the server is
      shutting down `:interrupted` **and** the pending interrupt can be
      rebuilt on the next boot (see `Sagents.State.interrupt_restorable?/2`).
      A host showing an interrupt prompt can keep it on screen when this is
      `true`, because answering it will wake an agent that boots straight
      back into `:interrupted`. `false` whenever there is no interrupt, or
      the interrupt is process-bound (e.g. a sub-agent approval). See
      `Sagents.AgentUtils.shutdown_session_changes/2`.
    - `shutdown_data.last_activity_at` - DateTime of last activity
    - `shutdown_data.shutdown_at` - DateTime when shutdown was initiated

  ### Tool Execution Events (consolidated)
  - `{:agent, {:tool_execution_update, status, tool_info}}` - Tool execution lifecycle update
    - `status` is one of: `:executing`, `:completed`, `:failed`
    - `:executing` → `tool_info` contains `:call_id`, `:name`, `:display_text`, `:arguments`
    - `:completed` → `tool_info` contains `:call_id`, `:name`, `:result`
    - `:failed` → `tool_info` contains `:call_id`, `:name`, `:error`

  - `{:agent, {:display_message_updated, display_msg}}` - Tool status updated in DB
    (only when `display_message_persistence` is configured)

  ### LLM Streaming Events
  - `{:agent, {:llm_deltas, [%MessageDelta{}]}}` - Streaming tokens/deltas received (list
    of deltas)
  - `{:agent, {:llm_message, %Message{}}}` - Complete message received and processed
  - `{:agent, {:llm_token_usage, %TokenUsage{}}}` - Token usage information

  ### Message Persistence Events
  - `{:agent, {:display_message_saved, display_message}}` - Broadcast after message is
    persisted via `display_message_persistence` behaviour.
    The `{:llm_message, ...}` event is also broadcast alongside this event

    Rows the framework originates rather than the model — the cancellation
    notice, the error notice, and middleware-emitted rows such as a todo
    snapshot — are the exception: they broadcast only
    `{:display_message_saved, _}`, because there is no `%Message{}` to carry.
    Render these from this event. `{:llm_message, _}` is the live channel for
    model output alone, and it carries the full struct, `status` included, for a
    host wanting to react to a message that stopped early before the display row
    lands.

  ### Queued Message Events
  - `{:agent, {:message_queued, %Message{}}}` - A message arrived while a run was
    in flight and is being held for delivery at the next run boundary. See
    `add_message/3` and `queue_message_from_tool/3`. Subscribe to this rather than
    reading a "queued" signal off `add_message/2`'s return value, which stays
    `:ok` deliberately.

  **Note**: File events are NOT broadcast by AgentServer. Files are managed by
  `FileSystemServer` which provides its own event handling mechanism.

  ## Debug Events

  When debug PubSub is configured, additional debug events are broadcast on the
  topic `"agent_server:debug:\#{agent_id}"`. These events provide deeper insight
  into agent execution for debugging and monitoring purposes.

  **Debug events are also wrapped in `{:agent, {:debug, event}}`** for consistent
  routing with regular events.

  ### Middleware Debug Events
  - `{:agent, {:debug, {:agent_state_update, state}}}` - Middleware state update with
    full state snapshot

  ### Queued Message Debug Events
  - `{:agent, {:debug, {:messages_drained, count}}}` - A queued message was
    delivered and a follow-up run started. Note that **no** `:idle` status is
    broadcast between the two runs; this is the event for observers who need to
    know the extra run happened.
  - `{:agent, {:debug, {:pending_message_held, :error}}}` - A run failed while a
    message was queued. The message is kept, not delivered.
  - `{:agent, {:debug, {:auto_execution_limit_reached, limit}}}` - Too many
    consecutive runs were started by queued messages with no human input in
    between. The message was added to the conversation but no further run was
    started.

  ## Usage

      # Start a server
      {:ok, agent} = Agent.new(
        agent_id: "my-agent-1",
        model: model,
        base_system_prompt: "You are a helpful assistant."
      )

      initial_state = State.new!(%{
        messages: [Message.new_user!("Write a hello world program")]
      })

      {:ok, _pid} = AgentServer.start_link(
        agent: agent,
        initial_state: initial_state,
        name: AgentServer.get_name("my-agent-1")
      )

      # Subscribe to events
      AgentServer.subscribe("my-agent-1")

      # Execute the agent
      :ok = AgentServer.execute("my-agent-1")

      # Cancel execution if needed
      :ok = AgentServer.cancel("my-agent-1")

      # Listen for events
      receive do
        {:todos_updated, todos} -> IO.inspect(todos, label: "Current TODOs")
        {:status_changed, :idle, nil} -> IO.puts("Done!")
      end

  ## Human-in-the-Loop Example

      # Configure agent with interrupts
      {:ok, agent} = Agent.new(
        agent_id: "my-agent-1",
        model: model,
        interrupt_on: %{"write_file" => true}
      )

      {:ok, _pid} = AgentServer.start_link(
        agent: agent,
        initial_state: state,
        name: AgentServer.get_name("my-agent-1")
      )

      AgentServer.subscribe("my-agent-1")

      # Execute
      AgentServer.execute("my-agent-1")

      # Wait for interrupt
      receive do
        {:status_changed, :interrupted, interrupt_data} ->
          # Display interrupt_data.action_requests to user
          decisions = get_user_decisions(interrupt_data)
          AgentServer.resume("my-agent-1", decisions)
      end

      # Wait for completion
      receive do
        {:status_changed, :idle, nil} -> :ok
      end
  """

  use GenServer
  use Sagents.Publisher, state_field: :publisher
  require Logger

  alias Sagents.Agent
  alias Sagents.State
  alias Sagents.AgentSupervisor
  alias Sagents.Message.DisplayHelpers
  alias Sagents.Middleware
  alias Sagents.MiddlewareEntry
  alias Sagents.Persistence.StateSerializer
  alias Sagents.ProcessRegistry
  alias Sagents.Publisher
  alias LangChain.Message
  alias LangChain.Message.ContentPart

  @typedoc "Status of the agent server"
  @type status :: :idle | :running | :interrupted | :paused | :cancelled | :error

  @presence_check_delay 1_000

  # Hard ceiling on runs started by a drain with no human input in between.
  # Not configurable on purpose: ten consecutive machine-initiated runs is likely never
  # intentional, so a knob would imply a tuning decision nobody actually has to
  # make. This is a stop on a newly built engine, not a loop detector. It will
  # not stop a badly designed playbook from wasting the nine runs before it,
  # which is a playbook concern.
  @max_consecutive_auto_executions 10

  # Topic for agent presence tracking - enables discovery of running agents
  @agent_presence_topic "agent_server:presence"

  defmodule ServerState do
    @moduledoc false
    defstruct [
      :agent,
      :state,
      :status,
      # %Sagents.Publisher.State{} — tracks subscribers on :main and :debug channels
      :publisher,
      # Phoenix.PubSub server name (atom) used only for presence wiring (subscribing
      # to presence_diff broadcasts). Per-agent events go directly to subscribers.
      :pubsub_name,
      :interrupt_data,
      :error,
      :inactivity_timeout,
      :inactivity_timer_ref,
      :last_activity_at,
      :shutdown_delay,
      :task,
      :middleware_registry,
      :presence_config,
      :conversation_id,
      # Module implementing Sagents.AgentPersistence, or nil
      :agent_persistence,
      # Module implementing Sagents.DisplayMessagePersistence, or nil
      :display_message_persistence,
      # Module implementing Sagents.MessagePreprocessor, or nil
      :message_preprocessor,
      # Presence module for agent discovery (e.g., MyApp.Presence)
      # When set, agent tracks presence on "agent_server:presence" topic
      :presence_module,
      # Monotonic counter bumped on each execute/resume. Turn casts carry their seq
      # so late messages from a cancelled or superseded run are rejected.
      execution_seq: 0,
      # A single `%LangChain.Message{role: :user}` waiting for the current run to
      # finish, or nil. Deliberately on ServerState and NOT on State: the `{:ok,
      # new_state}` clause of handle_execution_result/2 replaces `state` wholesale
      # so middleware after_model transformations win, which would destroy a queue
      # kept inside it. Multiple arrivals merge their content parts into this one
      # message rather than growing a list. The GenServer already serializes every
      # write, so the merge needs no coordination.
      pending_message: nil,
      # Consecutive executions started by a drain rather than by a human. Reset by
      # handle_call({:add_message, ...}) (the human door), never by
      # handle_cast({:queue_message, ...}) (the tool door). Bounds the one new
      # thing this feature introduces: the framework's ability to start a run on
      # its own. NOT redundant with `:max_runs`, which counts LLM calls *within*
      # one execution and resets to 0 on every fresh chain.
      consecutive_auto_executions: 0,
      # Whether this server was restored from persisted state (vs fresh start)
      # Used to broadcast :node_transferred event on startup after Horde migration
      restored: false,
      # Mirrors the durable interrupt flag exposed via
      # Sagents.AgentPersistence.set_interrupted/3. `true` means we have
      # written the flag as `true` and not yet cleared it; `false` means
      # the flag is clear (or we have never written it). Used to suppress
      # redundant callback invocations.
      interrupt_persisted: false,
      # A user's answer to a pending interrupt, submitted while this agent was
      # asleep, waiting to be applied at boot.
      #
      # Holds whatever `resume/2` accepts. That term is middleware-owned, so the
      # shape depends on what asked the question:
      #
      #     AskUserQuestion  %{type: :answer, tool_call_id: "call_1", selected: ["pg"]}
      #                      (a list of those when several questions are pending)
      #     HumanInTheLoop   [%{type: :approve}, %{type: :reject}]
      #
      # Set only by `Sagents.Session.resume/4`, and only after `resume/2` returned
      # `{:error, :agent_not_running}`. Read exactly once, in
      # handle_continue(:broadcast_initial_state, _): applied if we booted
      # `:interrupted`, dropped with a warning otherwise, and nil'd either way. So
      # no handle_call/handle_info ever sees it set. Consuming it before the first
      # broadcast is what lets a woken agent announce `:running` rather than an
      # `:interrupted` snapshot it is about to leave. Never persisted.
      pending_resume: nil
    ]

    @type t :: %__MODULE__{
            agent: Agent.t(),
            state: State.t(),
            status: :idle | :running | :interrupted | :cancelled | :error,
            publisher: Sagents.Publisher.State.t(),
            pubsub_name: atom() | nil,
            interrupt_data: map() | nil,
            error: term() | nil,
            inactivity_timeout: pos_integer() | nil | :infinity,
            inactivity_timer_ref: reference() | nil,
            last_activity_at: DateTime.t() | nil,
            shutdown_delay: pos_integer() | nil,
            task: Task.t() | nil,
            middleware_registry: %{(atom() | String.t()) => MiddlewareEntry.t()},
            presence_config:
              %{
                enabled: boolean(),
                presence_module: module(),
                topic: String.t(),
                check_delay: pos_integer()
              }
              | nil,
            conversation_id: String.t() | nil,
            agent_persistence: module() | nil,
            display_message_persistence: module() | nil,
            message_preprocessor: module() | nil,
            presence_module: module() | nil,
            restored: boolean(),
            interrupt_persisted: boolean(),
            pending_message: LangChain.Message.t() | nil,
            pending_resume: term() | nil,
            consecutive_auto_executions: non_neg_integer()
          }
  end

  ## Client API

  @doc """
  Start an AgentServer.

  ## Options

  - `:agent` - The Agent struct (required)
  - `:initial_state` - Initial State (default: empty state)
  - `:initial_subscribers` - List of `{channel, pid}` tuples to enroll as
    subscribers before `init/1` returns. Use this to atomically start the
    server and subscribe — every event broadcast (including the initial
    `{:status_changed, :idle, nil}` and any `{:node_transferred, _}`
    after a Horde restore) is delivered to listed pids. Channels are
    `:main` and `:debug`. Default: `[]`.
  - `:pubsub` - PubSub configuration as `{module(), atom()}` tuple or `nil` (default: nil).
    Used **only** for presence wiring (subscribing to `Phoenix.Presence`
    diff broadcasts). Per-agent events are delivered directly to
    subscribers via `Sagents.Publisher`, no PubSub required.
  - `:name` - Server name registration (optional, defaults to `get_name(agent.agent_id)`)
  - `:inactivity_timeout` - Timeout in milliseconds for automatic shutdown due to inactivity (default: 300_000 - 5 minutes)
    Set to `nil` or `:infinity` to disable automatic shutdown
  - `:shutdown_delay` - Delay in milliseconds to allow the supervisor to gracefully stop all children (default: 5000)
  - `:conversation_id` - Optional conversation identifier for message persistence (default: nil)
  - `:agent_persistence` - Module implementing `Sagents.AgentPersistence` for state snapshots (default: nil)
  - `:display_message_persistence` - Module implementing `Sagents.DisplayMessagePersistence` for display messages (default: nil)
  - `:pending_resume` - A resume payload to apply during boot, for an answer
    submitted while no process was alive to take it. Applied in
    `handle_continue/2` **before** the initial status broadcast, so a server
    that boots `:interrupted` and consumes this announces `:running` once,
    rather than announcing an `:interrupted` snapshot it is about to leave.
    Discarded with a warning if the server boots into any other status (the
    interrupt was demoted as non-restorable, or answered elsewhere first).
    Prefer `Sagents.Session.resume/4`, which sets this for you and handles
    the live-agent and already-woken cases. Default: `nil`.

    Note it lives in the child spec, so a supervisor restart re-evaluates it
    against freshly loaded persisted state. If the resume already completed,
    that state no longer carries an interrupt and the payload is discarded;
    if the run died before completing, re-applying it is the correct
    recovery. The supervisor's restart intensity bounds a pathological loop.

  ## Examples

      # Start with automatic name (recommended)
      {:ok, pid} = AgentServer.start_link(
        agent: agent,
        initial_state: state
      )

      # With PubSub enabled
      {:ok, pid} = AgentServer.start_link(
        agent: agent,
        initial_state: state,
        pubsub: {Phoenix.PubSub, :my_app_pubsub}
      )

      # Start with explicit name (advanced use cases)
      {:ok, pid} = AgentServer.start_link(
        agent: agent,
        initial_state: state,
        name: :my_custom_name
      )

      # With custom inactivity timeout
      {:ok, pid} = AgentServer.start_link(
        agent: agent,
        inactivity_timeout: 600_000  # 10 minutes
      )

      # Disable automatic shutdown
      {:ok, pid} = AgentServer.start_link(
        agent: agent,
        inactivity_timeout: nil
      )
  """
  def start_link(opts) do
    # Determine default name from agent or restore_agent_id
    default_name =
      cond do
        # When restoring from state, use restore_agent_id
        Keyword.has_key?(opts, :restore_agent_id) ->
          get_name(Keyword.get(opts, :restore_agent_id))

        # When starting fresh, use agent's agent_id
        agent = Keyword.get(opts, :agent) ->
          get_name(agent.agent_id)

        # Fallback
        true ->
          __MODULE__
      end

    {name, opts} = Keyword.pop(opts, :name, default_name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      # Allow 30s for graceful shutdown (including waiting for active LLM connections)
      shutdown: 30_000
    }
  end

  @doc """
  Get the name of the AgentServer process for a specific agent.

  ## Examples

      name = AgentServer.get_name("my-agent-1")
      GenServer.call(name, :get_status)
  """
  @spec get_name(String.t()) :: GenServer.name()
  def get_name(agent_id) when is_binary(agent_id) do
    ProcessRegistry.via_tuple({:agent_server, agent_id})
  end

  @doc """
  Get the pid of the AgentServer process for a specific agent.

  Returns `nil` when no AgentServer is registered for `agent_id`.

  Raises `Sagents.RegistryUnavailableError` when this node's registry cannot
  answer at all, which happens while the node is starting and while it drains
  during a rolling deploy. Returning `nil` there would be indistinguishable from
  "not running", and callers act on that by starting a duplicate agent. Use
  `fetch_pid/1` on request paths, where the condition is a value rather than a
  raise.

  ## Examples

      pid = AgentServer.get_pid("my-agent-1")
      send(pid, message)
  """
  @spec get_pid(String.t()) :: pid() | nil
  def get_pid(agent_id) when is_binary(agent_id) do
    case fetch_pid(agent_id) do
      {:ok, pid} ->
        pid

      {:error, :not_running} ->
        nil

      {:error, :registry_unavailable} ->
        raise Sagents.RegistryUnavailableError, operation: :"AgentServer.get_pid/1"
    end
  end

  @doc """
  Get the pid of the AgentServer for `agent_id`, without raising.

  The three outcomes are kept distinct on purpose:

  - `{:ok, pid}` - an AgentServer is running
  - `{:error, :not_running}` - the registry answered, no AgentServer is registered
  - `{:error, :registry_unavailable}` - this node's registry could not answer

  Prefer this over `get_pid/1` anywhere a web request can reach, and map
  `:registry_unavailable` to a retryable response (503) rather than a 500. The
  cluster can serve the request, just not on this node. See `docs/deployment.md`.

  ## Examples

      case AgentServer.fetch_pid("my-agent-1") do
        {:ok, pid} -> send(pid, message)
        {:error, :not_running} -> start_it()
        {:error, :registry_unavailable} -> {:error, :draining}
      end
  """
  @spec fetch_pid(String.t()) :: {:ok, pid()} | {:error, :not_running | :registry_unavailable}
  def fetch_pid(agent_id) when is_binary(agent_id) do
    case ProcessRegistry.fetch({:agent_server, agent_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_registered} -> {:error, :not_running}
      {:error, :registry_unavailable} = error -> error
    end
  end

  @doc """
  Send a targeted message to a specific middleware in a running AgentServer.

  The message is routed through the middleware registry and delivered to the
  middleware's `handle_message/3` callback. The middleware is identified by its
  ID (module name by default, or a custom string if configured via `:id` option).

  This is a fire-and-forget operation — the caller does not wait for a response.
  If the AgentServer is not running, the message is silently dropped.

  ## Use Cases

  There are two primary use cases for this function:

  ### 1. External notifications (LiveViews, controllers, other processes)

  Send context updates or configuration changes to a middleware from outside the
  agent system. The middleware decides how to handle the message — typically by
  updating state metadata that `before_model/2` reads on the next LLM call.

      # LiveView: user switched to editing a different blog post
      AgentServer.notify_middleware(agent_id, MyApp.UserContext, {:post_changed, %{
        slug: "/blog/getting-started-with-elixir",
        title: "Getting Started with Elixir"
      }})

      # Controller: user changed a preference
      AgentServer.notify_middleware(agent_id, MyApp.Preferences, {:preference_changed, :verbose, true})

  ### 2. Async task results (middleware sending messages to itself)

  Middleware that spawns background tasks (e.g., title generation, embedding
  computation) uses this to send results back to the AgentServer for state updates.

      # Inside an async task spawned by the middleware
      AgentServer.notify_middleware(agent_id, middleware_id, {:title_generated, title})

  ## Parameters

  - `agent_id` - The agent identifier (used to locate the AgentServer process)
  - `middleware_id` - The middleware ID to route the message to (module name or custom string)
  - `message` - Any term to be delivered to the middleware's `handle_message/3` callback

  ## Returns

  `:ok` in every case, including the two where the message is not delivered:
  no AgentServer is running for `agent_id`, and this node's registry cannot
  answer (it is draining during a rolling deploy). Delivery is fire-and-forget
  by design, so there is no queue to fall back to and no retry that helps on
  this node. The undelivered cases are logged rather than returned, because a
  caller cannot act on them and a silently dropped push is invisible.

  ## Examples

      # Notify by module name (default middleware ID)
      AgentServer.notify_middleware("conv-123", MyApp.Middleware.UserContext, {:post_changed, post})

      # Notify by custom ID (when middleware was configured with `id: "english_title"`)
      AgentServer.notify_middleware("conv-123", "english_title", {:regenerate, %{}})

  """
  @spec notify_middleware(String.t(), term(), term()) :: :ok
  def notify_middleware(agent_id, middleware_id, message) do
    case fetch_pid(agent_id) do
      {:ok, pid} ->
        send(pid, {:middleware_message, middleware_id, message})

      {:error, :not_running} ->
        :ok

      {:error, :registry_unavailable} ->
        Logger.warning(
          "notify_middleware(#{agent_id}, #{inspect(middleware_id)}): " <>
            "registry unavailable on this node, message dropped"
        )
    end

    :ok
  end

  @doc """
  Subscribe a process to events from this AgentServer.

  Events on the `:main` channel are delivered as `{:agent, event}` messages;
  events on the `:debug` channel are delivered as `{:agent, {:debug, event}}`
  and provide additional insight into middleware state, sub-agent activity,
  and similar diagnostic data not surfaced on the main channel.

  Delivery is via direct `send/2`. The producer monitors the subscriber so
  departure is cleaned up automatically — but subscribers should also
  `Process.monitor/1` the returned `server_pid` to detect server death.

  ## Arguments

  - `agent_id` — the agent's id.
  - `channel` — `:main` (default) or `:debug`.
  - `subscriber_pid` — the pid to receive events. Defaults to `self()` when
    `nil`.

  Returns `{:ok, server_pid, monitor_ref}` on success,
  `{:error, :process_not_found}` if no AgentServer is running for `agent_id`,
  or `{:error, :registry_unavailable}` if this node's registry cannot answer.

  The third answer is distinct because it is not a statement about the agent.
  See `docs/deployment.md`.

  ## Examples

      # Most common: subscribe self() to the main channel.
      {:ok, _pid, _ref} = AgentServer.subscribe("my-agent-1")

      # Subscribe to debug events (used by sagents_live_debugger and similar).
      {:ok, _pid, _ref} = AgentServer.subscribe("my-agent-1", :debug)

      # Subscribe a foreign pid (e.g. a bridge GenServer that proxies events).
      {:ok, _pid, _ref} = AgentServer.subscribe("my-agent-1", :main, bridge_pid)
  """
  @spec subscribe(String.t(), :main | :debug, pid() | nil) ::
          {:ok, pid(), reference()} | {:error, :process_not_found | :registry_unavailable}
  def subscribe(agent_id, channel \\ :main, subscriber_pid \\ nil)
      when is_binary(agent_id) and channel in [:main, :debug] do
    # Resolves the pid rather than handing Publisher a `:via` tuple.
    # `Publisher.subscribe/3` is a `GenServer.call`, which resolves a via name
    # itself, and that resolution raises `ArgumentError` from inside `:ets`
    # while this node's registry is unavailable. Publisher's `catch :exit`
    # guard does not catch a raise, so the error would escape a function whose
    # whole visible structure claims to have handled it.
    case fetch_pid(agent_id) do
      {:ok, pid} -> Publisher.subscribe(pid, channel, subscriber_pid)
      {:error, :not_running} -> {:error, :process_not_found}
      {:error, :registry_unavailable} = error -> error
    end
  end

  @doc """
  Unsubscribe a process from events on the given channel.

  Mirrors `subscribe/3`. Defaults `channel` to `:main` and `subscriber_pid`
  to `self()` (when `nil`). Always returns `:ok`.

  An unavailable registry is `:ok` rather than an error: the subscription lives
  on a process this node cannot reach, the producer's own monitor cleans up the
  entry when the subscriber goes away, and there is nothing for a caller to do
  with the distinction.
  """
  @spec unsubscribe(String.t(), :main | :debug, pid() | nil) :: :ok
  def unsubscribe(agent_id, channel \\ :main, subscriber_pid \\ nil)
      when is_binary(agent_id) and channel in [:main, :debug] do
    case fetch_pid(agent_id) do
      {:ok, pid} -> Publisher.unsubscribe(pid, channel, subscriber_pid)
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Request the AgentServer to publish an specific PubSub message or event.

  Designed to make it easier for a middleware desiring to publish messages to
  the Agent's PubSub.

  A PubSub message is only broadcast if the AgentServer is configured with
  PubSub.
  """
  @spec publish_event_from(String.t(), term()) :: :ok
  def publish_event_from(agent_id, event) do
    GenServer.cast(get_name(agent_id), {:publish_event, event})
  end

  @doc """
  Persist a synthetic display message and broadcast it to subscribers.

  Designed for middleware that needs to record user-facing transcript entries
  that do not correspond to an LLM message (for example, a user's answer to an
  `ask_user` question, or a "user cancelled" notification).

  The attrs map should contain at minimum `:message_type`, `:content_type`, and
  `:content`. AgentServer routes the request to the configured
  `Sagents.DisplayMessagePersistence` implementation and broadcasts the saved
  record via `{:display_message_saved, msg}`.

  No-op if the AgentServer was not configured with both
  `display_message_persistence` and `conversation_id`, or if the configured
  persistence module does not implement `save_synthetic_message/3`.
  """
  @spec save_synthetic_message_from(String.t(), map()) :: :ok
  def save_synthetic_message_from(agent_id, attrs) when is_map(attrs) do
    GenServer.cast(get_name(agent_id), {:save_synthetic_message, attrs})
  end

  @doc """
  Request the AgentServer to publish a specific debug PubSub message or event.

  Designed to make it easier for middleware to publish debug messages to the
  Agent's debug PubSub. Debug events are useful for development and debugging
  but separate from user-facing events.

  ## Standardized Middleware Action Pattern

  Middleware should use the `:middleware_action` tuple pattern to avoid event
  proliferation:

      {:middleware_action, middleware_module, action_data}

  Where:
  - `middleware_module` - The middleware module (atom) that generated the event
  - `action_data` - Middleware-specific action tuple or data

  This pattern allows the debug UI to handle all middleware events generically
  without needing to know about every possible middleware-specific event type.

  ## Examples

      # From ConversationTitle middleware
      AgentServer.publish_debug_event_from(
        agent_id,
        {:middleware_action, Sagents.Middleware.ConversationTitle, {:title_generation_started, user_text}}
      )

      AgentServer.publish_debug_event_from(
        agent_id,
        {:middleware_action, Sagents.Middleware.ConversationTitle, {:title_generation_completed, title}}
      )

      # From custom middleware
      AgentServer.publish_debug_event_from(
        agent_id,
        {:middleware_action, MyApp.CustomMiddleware, {:validation_started, params}}
      )
  """
  @spec publish_debug_event_from(String.t(), term()) :: :ok
  def publish_debug_event_from(agent_id, event) do
    GenServer.cast(get_name(agent_id), {:publish_debug_event, event})
  end

  @doc """
  Lists all currently running agent processes.

  Returns a list of agent_ids for all running AgentServer processes registered
  in the Sagents.Registry.

  ## Examples

      AgentServer.list_running_agents()
      # => ["conversation-1", "conversation-2", "user-123"]
  """
  @spec list_running_agents() :: [String.t()]
  def list_running_agents do
    # Query the Registry for agent_server entries only (not supervisors)
    # Registry stores entries as {key, pid, value}
    # We only want {:agent_server, agent_id} entries
    ProcessRegistry.select([
      {{{:agent_server, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
  end

  @doc """
  Gets all running agents matching a glob pattern.

  Supports wildcard patterns using `*` which matches any sequence of characters.

  ## Examples

      # Get all conversation agents
      AgentServer.list_agents_matching("conversation-*")
      # => ["conversation-1", "conversation-2", "conversation-123"]

      # Get all user agents
      AgentServer.list_agents_matching("user-*")
      # => ["user-42", "user-99"]

      # Get specific prefix
      AgentServer.list_agents_matching("demo-*")
      # => ["demo-agent-001"]
  """
  @spec list_agents_matching(String.t()) :: [String.t()]
  def list_agents_matching(pattern) do
    regex = pattern_to_regex(pattern)

    list_running_agents()
    |> Enum.filter(&Regex.match?(regex, &1))
  end

  @doc """
  Gets count of currently running agents.

  Returns the total number of AgentServer processes registered in the
  Sagents.Registry.

  ## Examples

      AgentServer.agent_count()
      # => 5
  """
  @spec agent_count() :: non_neg_integer()
  def agent_count do
    ProcessRegistry.count()
  end

  @doc """
  Gets detailed information about a running agent.

  Returns a map with agent status and state information, or `nil` if the agent
  is not running.

  ## Return Value

  If the agent is running, returns a map containing:
  - `:agent_id` - The agent identifier
  - `:pid` - The process ID
  - `:status` - Current execution status (`:idle`, `:running`, `:interrupted`, etc.)
  - `:state` - Exported state snapshot
  - `:message_count` - Number of messages in the state
  - `:has_interrupt` - Boolean indicating if there's pending interrupt data

  ## Examples

      AgentServer.agent_info("conversation-1")
      # => %{
      #   agent_id: "conversation-1",
      #   pid: #PID<0.1234.0>,
      #   status: :idle,
      #   state: %State{...},
      #   message_count: 5,
      #   has_interrupt: false
      # }

      AgentServer.agent_info("nonexistent")
      # => nil
  """
  @spec agent_info(String.t()) :: map() | nil
  def agent_info(agent_id) do
    case get_pid(agent_id) do
      nil ->
        nil

      pid ->
        state = get_state(agent_id)
        status = get_status(agent_id)

        %{
          agent_id: agent_id,
          pid: pid,
          status: status,
          state: state,
          message_count: length(state.messages),
          has_interrupt: state.interrupt_data != nil
        }
    end
  end

  # Convert glob pattern to regex
  # "conversation-*" -> ~r/^conversation-.*$/
  defp pattern_to_regex(pattern) do
    escaped = Regex.escape(pattern)
    regex_str = String.replace(escaped, "\\*", ".*")
    Regex.compile!("^#{regex_str}$")
  end

  @doc """
  Execute the agent.

  Starts agent execution asynchronously. The server will broadcast events as the
  agent runs. Returns `:ok` immediately.

  Returns `{:error, reason}` if the server is not idle (already running, interrupted, etc.).

  ## Examples

      :ok = AgentServer.execute("my-agent-1")
  """
  @spec execute(String.t()) :: :ok | {:error, term()}
  def execute(agent_id) do
    safe_call(agent_id, :execute, :infinity)
  end

  @doc """
  Cancel a running LLM task.

  Stops the currently executing agent task and transitions the server to completed status.
  Returns `{:error, reason}` if the server is not running (no task to cancel).

  ## Examples

      :ok = AgentServer.cancel("my-agent-1")
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(agent_id) do
    safe_call(agent_id, :cancel)
  end

  @doc """
  Dismiss a terminal `:halt` interrupt and transition the server back to `:idle`.

  Used to acknowledge a halt (e.g., user clicked "Dismiss" on the halt panel)
  without sending a new message. Clears `interrupt_data`, calls
  `State.cancel_pending_interrupts/1`, transitions status to `:idle`, and
  broadcasts the status change.

  Only valid when status is `:interrupted` and the pending interrupt is a
  halt (or a `:multiple_interrupts` batch containing a halt). Other interrupt
  types — HITL approvals, `ask_user_question` — require an explicit response
  via `resume/2` (which the relevant middleware interprets), so this function
  returns `{:error, "interrupt requires explicit response (use resume)"}`
  for those.

  ## Examples

      :ok = AgentServer.dismiss_interrupt("my-agent-1")
  """
  @spec dismiss_interrupt(String.t()) :: :ok | {:error, term()}
  def dismiss_interrupt(agent_id) do
    safe_call(agent_id, :dismiss_interrupt)
  end

  @doc """
  Resume agent execution after an interrupt.

  ## Parameters

  - `agent_id` - The agent identifier
  - `resume_data` - Data to resume with (polymorphic per middleware).
    For HITL: list of decision maps. For AskUserQuestion: response map.

  ## Examples

      # HITL resume
      decisions = [
        %{type: :approve},
        %{type: :edit, arguments: %{"path" => "safe.txt"}},
        %{type: :reject}
      ]
      :ok = AgentServer.resume("my-agent-1", decisions)

      # AskUserQuestion resume
      :ok = AgentServer.resume("my-agent-1", %{type: :answer, selected: ["PostgreSQL"]})
  """
  @spec resume(String.t(), term()) :: :ok | {:error, term()}
  def resume(agent_id, resume_data) do
    safe_call(agent_id, {:resume, resume_data}, :infinity)
  end

  # The `get_state/1` function is available to aid in testing and not intended as a general public API.
  @doc false
  @spec get_state(String.t()) :: State.t()
  def get_state(agent_id) do
    call!(agent_id, :get_state)
  end

  @doc """
  Get the current status of the server.

  Returns one of:
  - `:idle` - Server ready for work
  - `:running` - Agent executing
  - `:interrupted` - Awaiting human decision
  - `:cancelled` - Execution was cancelled
  - `:error` - Execution failed
  - `:not_running` - Agent process does not exist

  ## Examples

      :idle = AgentServer.get_status("my-agent-1")
      :not_running = AgentServer.get_status("non-existent-agent")
  """
  @spec get_status(String.t()) :: status() | :not_running
  def get_status(agent_id) do
    try do
      call!(agent_id, :get_status)
    catch
      :exit, _reason ->
        :not_running
    end
  end

  @doc """
  Get server info including status, state, and any error or interrupt data.

  Returns a map with:
  - `:status` - Current status
  - `:state` - Current State
  - `:interrupt_data` - Interrupt data if status is `:interrupted`
  - `:error` - Error reason if status is `:error`

  ## Examples

      info = AgentServer.get_info("my-agent-1")
  """
  @spec get_info(String.t()) :: map()
  def get_info(agent_id) do
    call!(agent_id, :get_info)
  end

  @doc """
  Gets metadata about the agent server including status and last activity.

  ## Returns
    - `{:ok, metadata}` - Map with agent metadata
    - `{:error, :not_found}` - Agent not found

  ## Metadata Fields
    - `:status` - Current status atom (:idle, :running, :interrupted, :error, :cancelled)
    - `:last_activity_at` - DateTime of last activity (may be nil)
    - `:conversation_id` - Conversation ID (may be nil)
    - `:node` - The Erlang node where this agent is running

  ## Examples

      {:ok, metadata} = AgentServer.get_metadata("my-agent-1")
      # => {:ok, %{status: :idle, last_activity_at: ~U[2024-01-01 12:00:00Z], conversation_id: "conv-123"}}
  """
  @spec get_metadata(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_metadata(agent_id) do
    case get_pid(agent_id) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, :get_metadata, 5000)
        catch
          :exit, _reason -> {:error, :not_found}
        end
    end
  end

  @doc """
  Gets the agent configuration for the given agent.

  ## Returns
    - `{:ok, Agent.t()}` - The agent struct
    - `{:error, :not_found}` - Agent not found

  ## Examples

      {:ok, agent} = AgentServer.get_agent("my-agent-1")
      # => {:ok, %Agent{agent_id: "my-agent-1", model: %ChatModel{...}, ...}}
  """
  @spec get_agent(String.t()) :: {:ok, Agent.t()} | {:error, :not_found}
  def get_agent(agent_id) do
    case get_pid(agent_id) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, :get_agent, 5000)
        catch
          :exit, _reason -> {:error, :not_found}
        end
    end
  end

  @doc """
  Add a message to the agent's state and transition to idle if completed.

  This is useful for conversational interfaces where you want to add a new user
  message after the agent has completed a previous execution.

  Returns `:ok` on success.

  ## Adding a message while the agent is running

  A `:user` message that arrives while the agent is `:running` is **queued**,
  not rejected. It is delivered at the next run boundary: appended to the
  conversation once the in-flight run completes successfully, which then starts
  a follow-up run. `add_message/2` still returns `:ok` in that case.

  This is deliberate and load-bearing: previously the message was written into
  the rolling state and then silently destroyed when the canonical state from
  `Sagents.Agent.execute/3` replaced it wholesale, while the caller got a misleading
  `{:error, "Cannot execute, server is in state: running"}` despite the message
  having been accepted. Returning `:ok` is both more truthful and non-breaking
  for consumers that match only on `:ok` and `{:error, reason}`.

  A consumer that wants to render a "queued" affordance should subscribe to the
  `{:message_queued, message}` event rather than read it off the return value.

  Messages that arrive with a non-`:user` role while running are still
  rejected. Injecting an assistant turn mid-run is not a supported operation.

  ## Options

  - `:display` - controls the transcript half of the message, independently of
    what the model sees. Three values:

    - **absent** (default) - existing behavior. The configured
      `Sagents.MessagePreprocessor` runs if one is set; with none, the display
      and LLM halves are the same message.
    - **a `%LangChain.Message{}`** - the caller supplies both halves directly.
      The configured preprocessor is **not** run; the caller has already made
      the decision the preprocessor exists to make.
    - **`:none`** - model-visible, display-invisible. Nothing reaches the
      transcript.

  The two halves are independent messages, **including their role**. Because
  `c:Sagents.DisplayMessagePersistence.save_message/3` derives the transcript
  entry's attribution from `message.role`, a message that is `:user` to the
  model can be `:assistant` in the transcript. That is the shape a
  tool-initiated injection needs: nobody typed it, so attributing it to the
  author would put words in their mouth.

  ## Examples

      # After agent completes
      :ok = AgentServer.add_message("my-agent-1", Message.new_user!("What's next?"))
      :ok = AgentServer.execute("my-agent-1")

      # The author typed a shorthand; the model receives the expansion.
      :ok = AgentServer.add_message("my-agent-1", Message.new_user!(expanded),
              display: Message.new_user!("/changelog for the latest release"))

      # Model-visible, transcript-invisible.
      :ok = AgentServer.add_message("my-agent-1", Message.new_user!(playbook),
              display: :none)
  """
  @spec add_message(String.t(), LangChain.Message.t(), keyword()) :: :ok | {:error, term()}
  def add_message(agent_id, message, opts \\ [])

  def add_message(agent_id, %LangChain.Message{} = message, opts) when is_list(opts) do
    case safe_call(agent_id, {:add_message, message, opts}) do
      :ok ->
        execute(agent_id)

      # Accepted into the queue while a run is in flight. Do NOT call execute/1:
      # the server is busy and the drain will start the follow-up run itself.
      :queued ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Queue a message into the conversation from inside a running tool or middleware.

  This is the tool-facing door to the same queue `add_message/3` uses. The
  message is held for the duration of the current run and delivered at the run
  boundary, arriving as an ordinary `:user` message at the head of a follow-up
  run. Nothing downstream needs to distinguish it from a message the user typed,
  because there is nothing to distinguish: it *is* an ordinary user message.

  Use this when a tool needs to hand the model **instructions** rather than
  data. Models are trained to treat a tool result as data and a user turn as
  instruction, so returning a playbook as tool-result text is a functional
  downgrade, not a stylistic one.

  ## Why this is a cast

  `handle_call(:cancel, ...)` blocks the AgentServer in `Task.shutdown(task,
  2_000)`. Tool code runs inside that Task. A tool blocked in a `GenServer.call`
  back to its own server during a cancel is a mutual wait that only resolves
  when the 2s grace expires and the task is brutal-killed. Both existing
  tool-to-server helpers (`publish_event_from/2`, `save_synthetic_message_from/2`)
  are casts for the same reason.

  The cost is that the caller cannot learn whether the queue accepted the
  message. The `GenServer.whereis` guard below covers the dominant failure mode:
  no server at all, which is unit tests and bare `Sagents.Agent.execute/3`. It returns
  `{:error, :no_server}` so a tool can fall back to inline content rather than
  silently doing nothing.

  ## Options

  Same `:display` option as `add_message/3`, with one difference: a configured
  `Sagents.MessagePreprocessor` is **never** run for a queued message. The
  behaviour is scoped to messages a human submitted; a tool-generated playbook
  is machine-generated and there is nothing coherent for a preprocessor to do
  with it.

  **Prefer `display: :none`.** The model emits a narration turn after the tool
  result anyway, and that turn becomes its own display message. Supplying a
  `display:` acknowledgement *as well* produces two acknowledgements back to
  back. Reach for an explicit `display:` only when the wording, role, or
  guaranteed presence of the acknowledgement has to be deterministic.

  ## Returns

  - `:ok` - the cast was sent
  - `{:error, :no_server}` - no AgentServer is running for this `agent_id`

  ## Limitations

  Sub-agents register under `{:sub_agent, id}`, not `{:agent_server, id}`, and
  block their own process for the whole of `SubAgentServer.execute/1`. A tool
  running inside a sub-agent therefore gets `{:error, :no_server}` and should
  take its fallback path. Queueing into the *parent* conversation is
  deliberately not offered.

  ## Examples

      def activate_command(%{"command" => name} = args, context) do
        playbook = render_playbook(name, args)

        case AgentServer.queue_message_from_tool(context.state.agent_id,
               Message.new_user!(playbook),
               display: :none
             ) do
          :ok ->
            {:ok, "The \#{name} command has been initiated. Its instructions " <>
                  "will arrive as the next message. Acknowledge briefly and stop."}

          {:error, :no_server} ->
            # Degraded path: no AgentServer (unit test, one-shot Agent.execute).
            # Return the playbook inline rather than silently doing nothing.
            {:ok, playbook}
        end
      end
  """
  @spec queue_message_from_tool(String.t(), LangChain.Message.t(), keyword()) ::
          :ok | {:error, :no_server}
  def queue_message_from_tool(agent_id, message, opts \\ [])

  def queue_message_from_tool(agent_id, %LangChain.Message{} = message, opts)
      when is_binary(agent_id) and is_list(opts) do
    # Cheap, non-blocking guard. Mirrors TodoList.save_todo_snapshot/2 so unit
    # tests and serverless Agent.execute/3 degrade to a reportable no-op rather
    # than raising out of a tool body. A draining node folds into the same
    # no-server answer: this runs inside tool code, which has no better move
    # than its fallback path, and raising out of a tool body is exactly what
    # the guard exists to prevent.
    case fetch_pid(agent_id) do
      {:ok, pid} -> GenServer.cast(pid, {:queue_message, message, opts})
      {:error, _reason} -> {:error, :no_server}
    end
  end

  @doc """
  Reset the agent's state and filesystem to start fresh.

  This clears:
  - All messages
  - All TODOs
  - Middleware state
  - Memory-only files (completely removed)
  - In-memory modifications to persisted files (discarded)

  This preserves:
  - Metadata (configuration)
  - Persisted files (reverted to pristine state from storage)

  Status transitions:
  - `:completed`, `:error`, or `:cancelled` → `:idle` (ready for new execution)
  - Other statuses remain unchanged

  Returns `:ok` on success.

  ## Examples

      # After agent completes or encounters error
      :ok = AgentServer.reset("my-agent-1")
      # Now you can execute again with clean state
      :ok = AgentServer.execute("my-agent-1")
  """
  @spec reset(String.t()) :: :ok | {:error, term()}
  def reset(agent_id) do
    safe_call(agent_id, :reset)
  end

  @doc """
  Get the current inactivity status of an agent.

  Returns a map with:
  - `:inactivity_timeout` - Configured timeout in milliseconds (or nil/:infinity)
  - `:last_activity_at` - DateTime of last activity
  - `:timer_active` - Boolean indicating if timer is currently running
  - `:time_since_activity` - Milliseconds since last activity (or nil if no activity yet)

  ## Examples

      status = AgentServer.get_inactivity_status("my-agent-1")
      # => %{
      #   inactivity_timeout: 300_000,
      #   last_activity_at: ~U[2025-11-06 10:15:30.123Z],
      #   timer_active: true,
      #   time_since_activity: 45_000
      # }
  """
  @spec get_inactivity_status(String.t()) :: map()
  def get_inactivity_status(agent_id) do
    call!(agent_id, :get_inactivity_status)
  end

  @doc """
  Touch the agent to indicate activity and reset the inactivity timer.

  This is useful when external events indicate activity (e.g., user viewing
  the agent in the UI, clicking tabs, etc.) to keep the agent alive and
  prevent automatic shutdown due to inactivity.

  Returns `:ok` immediately (non-blocking).

  ## Examples

      :ok = AgentServer.touch("my-agent-1")
  """
  @spec touch(String.t()) :: :ok
  def touch(agent_id) do
    GenServer.cast(get_name(agent_id), :touch)
  end

  @doc """
  Check if an agent is running.

  **Raises `Sagents.RegistryUnavailableError`** when this node's registry
  cannot answer, which covers the drain window of a rolling deploy. A boolean
  has no room for "cannot tell", and `false` reads as "nothing is running",
  which a caller responds to by starting a duplicate agent for an agent that
  already has a process elsewhere.

  Use `fetch_pid/1` anywhere a web request can reach: it reports the condition
  as `{:error, :registry_unavailable}` instead.
  """
  def running?(agent_id) do
    case get_pid(agent_id) do
      nil -> false
      _pid -> true
    end
  end

  @doc """
  Stop the AgentServer.

  ## Examples

      :ok = AgentServer.stop("my-agent-1")
  """
  @spec stop(String.t()) :: :ok
  def stop(agent_id) do
    ProcessRegistry.ensure_available!(:"AgentServer.stop/1")
    GenServer.stop(get_name(agent_id))
  end

  @doc """
  Export the current conversation state to a serializable format.

  This can be persisted to a database and later used to restore the conversation
  state. The exported state uses string keys (not atoms) for compatibility
  with JSON/JSONB storage.

  Returns a map with string keys containing:
  - `"version"` - Serialization format version
  - `"state"` - The conversation state (messages, todos, metadata)
  - `"serialized_at"` - ISO8601 timestamp

  **What is NOT included**:
  - Agent configuration (middleware, tools, model) - must come from application code
  - `agent_id` - runtime identifier provided when restoring

  This design allows you to restore the same conversation state under a different
  agent_id, enabling use cases like state cloning and conversation forking.

  ## Examples

      state = AgentServer.export_state("my-agent-1")
      # Save to database
      MyApp.Conversations.save_agent_state(conversation_id, state)
  """
  @spec export_state(String.t()) :: map()
  def export_state(agent_id) do
    call!(agent_id, :export_state)
  end

  @doc """
  Restore agent state from a previously exported state.

  This updates an already-running agent to restore its state from a
  previously serialized format. The state should be a map with string
  keys (as returned by `export_state/1`).

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Examples

      # Load from database
      {:ok, persisted_state} = MyApp.Conversations.load_agent_state(conversation_id)

      # Restore into existing agent
      :ok = AgentServer.restore_state("my-agent-1", persisted_state)
  """
  @spec restore_state(String.t(), map()) :: :ok | {:error, term()}
  def restore_state(agent_id, persisted_state) when is_map(persisted_state) do
    call!(agent_id, {:restore_state, persisted_state})
  end

  @doc """
  Updates both the agent configuration and state.

  This is the recommended way to restore a conversation:
  1. Create agent from current code using your agent factory
  2. Load state from database
  3. Call this function to update the running AgentServer

  ## Parameters

  - `agent_id` - The agent server's identifier
  - `agent` - The new agent configuration (from current code)
  - `state` - The restored state (from database)

  ## Examples

      # Restore conversation
      {:ok, agent} = MyApp.Agents.create_demo_agent(agent_id: "demo-123")
      {:ok, state_data} = MyApp.Conversations.load_state(conversation_id)
      {:ok, state} = Sagents.State.from_serialized(state_data["state"])

      :ok = AgentServer.update_agent_and_state("demo-123", agent, state)

  ## Returns

  - `:ok` - Agent and state updated successfully
  - `{:error, reason}` - If agent server is not running or update fails
  """
  def update_agent_and_state(agent_id, agent, state) do
    call!(agent_id, {:update_agent_and_state, agent, state})
  end

  @doc """
  Start a new AgentServer with restored state.

  This is the preferred way to resume a conversation from persisted state.
  The persisted_state should be a map with string keys (as returned by
  `export_state/1`).

  The `agent_id` will be used as the runtime identifier for this agent,
  enabling process registration and PubSub topic setup. You can restore
  the same conversation state under a different agent_id, which is useful
  for state cloning or conversation forking.

  ## Agent Configuration from Code

  **REQUIRED**: You MUST provide the agent from your application code using the
  `:agent` option. The persisted state contains ONLY conversation state (messages,
  todos, metadata). Agent configuration (middleware, tools, model) comes from your
  application code.

  This design ensures:
  - Library upgrades automatically benefit all conversations
  - Code changes automatically apply to all conversations
  - Per-user capabilities can be controlled via application logic

  ## Options

  - `:agent_id` - The runtime identifier for this agent (required)
  - `:agent` - Agent struct from code (REQUIRED)
  - `:pubsub` - PubSub configuration as `{module(), atom()}` tuple or `nil` (default: nil)
  - `:name` - Server name registration (optional, defaults to `get_name(agent_id)`)
  - `:inactivity_timeout` - Timeout in milliseconds (default: 300_000)
  - `:shutdown_delay` - Delay in milliseconds (default: 5000)

  ## Examples

      # Standard restoration pattern
      {:ok, persisted_state} = MyApp.Conversations.load_agent_state(conversation_id)

      # Agent from code (ALWAYS required)
      {:ok, agent} = MyApp.Agents.create_agent(
        agent_id: "my-agent-1",
        model: model,
        middleware: [TodoList, FileSystem, SubAgent]
      )

      # Start with restored state
      {:ok, pid} = AgentServer.start_link_from_state(
        persisted_state,
        agent: agent,
        agent_id: "my-agent-1",
        pubsub: {Phoenix.PubSub, :my_app_pubsub}
      )

      # Clone conversation with a different agent_id
      {:ok, pid} = AgentServer.start_link_from_state(
        persisted_state,
        agent: agent,
        agent_id: "my-agent-clone",
        pubsub: {Phoenix.PubSub, :my_app_pubsub}
      )
  """
  @spec start_link_from_state(map(), keyword()) :: GenServer.on_start()
  def start_link_from_state(persisted_state, opts \\ []) when is_map(persisted_state) do
    # agent_id is required in opts
    agent_id = Keyword.fetch!(opts, :agent_id)

    # Add a marker to opts to indicate this is a restore operation
    opts =
      opts
      |> Keyword.put(:restore_from, persisted_state)
      |> Keyword.put(:restore_agent_id, agent_id)

    start_link(opts)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    # Trap exits to ensure terminate/2 is called for graceful shutdown
    Process.flag(:trap_exit, true)

    # Check if we're restoring from persisted state
    case Keyword.get(opts, :restore_from) do
      nil ->
        # Normal initialization
        init_fresh(opts)

      persisted_state ->
        # Restore from persisted state
        init_from_persisted(persisted_state, opts)
    end
  end

  defp init_fresh(opts) do
    agent = Keyword.fetch!(opts, :agent)
    initial_state = Keyword.get(opts, :initial_state) || State.new!()

    build_server_state(agent, initial_state, opts)
  end

  defp init_from_persisted(persisted_state, opts) do
    # Get the agent_id from opts (required)
    agent_id = Keyword.fetch!(opts, :restore_agent_id)
    agent = Keyword.fetch!(opts, :agent)

    # deserialize only conversation state
    # agent_id is not serialized, so we provide it when deserializing
    case StateSerializer.deserialize_state(agent_id, persisted_state["state"]) do
      {:ok, state} ->
        # Update agent_id to match the runtime identifier
        agent = %{agent | agent_id: agent_id}
        # Apply stale-interrupt sweep with the agent's middleware so
        # restorable interrupts (e.g. ask_user) survive cold start while
        # process-bound interrupts (e.g. sub-agent HITL) get demoted.
        # `agent.middleware` is already initialized to MiddlewareEntry structs.
        state = State.clean_stale_interrupts(state, agent.middleware)

        opts =
          opts
          |> Keyword.put(:restored, true)
          |> Keyword.put(
            :pending_message,
            StateSerializer.deserialize_pending_message(persisted_state)
          )

        build_server_state(agent, state, opts)

      {:error, reason} ->
        {:stop, {:restore_failed, reason}}
    end
  end

  # Build ServerState from agent, state, and opts
  # This is the shared logic used by both init_fresh/1 and init_from_persisted/2
  defp build_server_state(agent, state, opts) do
    # Ensure agent_id is set in the state
    state = %{state | agent_id: agent.agent_id}

    # Detect a surviving (restorable) interrupt on the trailing tool result
    # so the ServerState boots in :interrupted status and broadcasts it.
    # Also repopulates the virtual state.interrupt_data field for middleware
    # resume callbacks (HITL.process_decisions, AskUserQuestion.handle_resume)
    # that read it.
    {boot_status, boot_interrupt_data, state} = derive_boot_status(state)

    # The :pubsub option is only used for presence wiring (subscribing
    # to presence_diff broadcasts from Phoenix.Presence). Per-agent events are
    # delivered directly to subscriber pids via Sagents.Publisher.
    # Accepted shapes: nil | {module(), atom()} (the module is unused).
    pubsub_name =
      case Keyword.get(opts, :pubsub) do
        {_module, name} when is_atom(name) -> name
        nil -> nil
      end

    # allow a nil value to disable the timeout
    inactivity_timeout = Keyword.get(opts, :inactivity_timeout, 300_000)
    shutdown_delay = Keyword.get(opts, :shutdown_delay, 5_000)

    # Extract presence configuration
    presence_opts = Keyword.get(opts, :presence_tracking)

    presence_config =
      if presence_opts do
        %{
          enabled: Keyword.get(presence_opts, :enabled, true),
          presence_module: Keyword.fetch!(presence_opts, :presence_module),
          topic: Keyword.fetch!(presence_opts, :topic),
          check_delay: Keyword.get(presence_opts, :check_delay, @presence_check_delay)
        }
      else
        nil
      end

    # Build list of MiddlewareEntry structs
    middleware_entries = build_middleware_entries(agent.middleware)

    # Build registry map for O(1) message routing
    middleware_registry = Map.new(middleware_entries, fn entry -> {entry.id, entry} end)

    # Update agent with middleware entries
    updated_agent = %{agent | middleware: middleware_entries}

    # Extract conversation_id from opts
    conversation_id = Keyword.get(opts, :conversation_id)

    # Extract persistence behaviour modules
    agent_persistence = Keyword.get(opts, :agent_persistence)
    display_message_persistence = Keyword.get(opts, :display_message_persistence)

    # Extract message preprocessor module
    message_preprocessor = Keyword.get(opts, :message_preprocessor)

    # Extract presence module for agent discovery
    # When set, agent will track presence on "agent_server:presence" topic
    presence_module = Keyword.get(opts, :presence_module)

    # Subscribers seeded at start time. Enrolled before init/1 returns, so
    # they receive every event broadcast from handle_continue (notably
    # :status_changed :idle and :node_transferred after a Horde restore).
    # This eliminates the race that PubSub's detached topics used to mask.
    initial_subscribers = Keyword.get(opts, :initial_subscribers, [])

    publisher_state =
      Publisher.State.new([:main, :debug])
      |> Publisher.State.seed(initial_subscribers)

    server_state = %ServerState{
      agent: updated_agent,
      state: state,
      status: boot_status,
      publisher: publisher_state,
      pubsub_name: pubsub_name,
      interrupt_data: boot_interrupt_data,
      error: nil,
      inactivity_timeout: inactivity_timeout,
      inactivity_timer_ref: nil,
      last_activity_at: DateTime.utc_now(),
      shutdown_delay: shutdown_delay,
      middleware_registry: middleware_registry,
      presence_config: presence_config,
      conversation_id: conversation_id,
      agent_persistence: agent_persistence,
      display_message_persistence: display_message_persistence,
      message_preprocessor: message_preprocessor,
      presence_module: presence_module,
      restored: Keyword.get(opts, :restored, false),
      # If we boot in :interrupted, the integrator's durable flag is (or
      # should be) `true`. Seed the tracker so the next clearing lifecycle
      # transitions through and fires set_interrupted(false) once.
      interrupt_persisted: boot_status == :interrupted,
      # A message that was queued when the previous incarnation of this server
      # died. It drains at the next clean run boundary, exactly as if it had
      # been queued a moment ago.
      pending_message: Keyword.get(opts, :pending_message),
      # An interrupt response submitted while no process was alive to take it.
      # Applied in handle_continue/2 before the first broadcast.
      pending_resume: Keyword.get(opts, :pending_resume)
    }

    # Start the inactivity timer
    server_state = reset_inactivity_timer(server_state)

    # Use continue to broadcast initial state after init completes
    # This ensures subscribers are ready before we broadcast
    {:ok, server_state, {:continue, :broadcast_initial_state}}
  end

  # Inspect the trailing tool message for surviving (restorable) interrupt
  # placeholders. If found, build the same enriched interrupt_data shape that
  # `LangChain.Chains.LLMChain.Mode.Steps.extract_interrupt_data/1` produces
  # in the live path — i.e. with `:tool_call_id` injected from the surrounding
  # ToolResult, and a `:multiple_interrupts` wrapper when more than one tool
  # result is interrupted in the same turn.
  #
  # Repopulates the virtual `state.interrupt_data` field so middleware resume
  # callbacks (HITL.process_decisions, AskUserQuestion.handle_resume) and UI
  # consumers (which read `interrupt_data.tool_call_id`) see the same shape
  # as a freshly-fired live interrupt. For a fresh state with no messages
  # this is a no-op.
  defp derive_boot_status(%State{messages: messages} = state) do
    case List.last(messages) do
      %LangChain.Message{role: :tool, tool_results: results} when is_list(results) ->
        case Enum.filter(results, &live_interrupt?/1) do
          [] ->
            {:idle, nil, state}

          interrupted ->
            data = restore_interrupt_data(interrupted)
            {:interrupted, data, %{state | interrupt_data: data}}
        end

      _other ->
        {:idle, nil, state}
    end
  end

  defp live_interrupt?(%LangChain.Message.ToolResult{is_interrupt: true, interrupt_data: data})
       when not is_nil(data),
       do: true

  defp live_interrupt?(_other), do: false

  # Transition an :interrupted server into a running resume: bump execution_seq
  # so callbacks from the prior run can't pollute the rolling state, clear the
  # interrupt, reset the activity timer, and spawn the resume task.
  #
  # Deliberately does NOT broadcast. The two callers disagree on when the status
  # event should go out: the {:resume, _} handle_call emits it immediately,
  # while the boot path folds it into the single initial broadcast so a waking
  # agent never announces an :interrupted status it is about to leave.
  defp start_resume(%ServerState{status: :interrupted} = server_state, resume_data) do
    # Capture interrupt_data before clearing -- resume_agent needs it for
    # display message updates (e.g., marking ask_user tools as completed).
    resolved_interrupt_data = server_state.interrupt_data

    new_state = %{
      server_state
      | status: :running,
        interrupt_data: nil,
        execution_seq: server_state.execution_seq + 1
    }

    new_state = reset_inactivity_timer(new_state)

    # Resume execution async (callbacks are built in resume_agent)
    task =
      Task.async(fn ->
        resume_agent(new_state, resume_data, resolved_interrupt_data)
      end)

    Map.put(new_state, :task, task)
  end

  # Consume a resume handed to us at start time by `Sagents.Session.resume/4`.
  #
  # The answer was submitted against a conversation whose agent had gone to
  # sleep. The interrupt itself is durable, so this boot has already rebuilt it
  # via derive_boot_status/1 and we can take the answer immediately.
  defp apply_pending_resume(%ServerState{pending_resume: nil} = server_state), do: server_state

  defp apply_pending_resume(
         %ServerState{pending_resume: resume_data, status: :interrupted} = server_state
       ) do
    Logger.info(
      "Agent #{server_state.agent.agent_id} applying a resume submitted while it was not running"
    )

    %{server_state | pending_resume: nil}
    |> start_resume(resume_data)
  end

  # Booted into some other status: the interrupt was demoted as non-restorable
  # by clean_stale_interrupts/2, or it was answered elsewhere (another tab, the
  # admin view) before this boot. Drop the answer and let the honest boot status
  # go out — the host's ordinary non-interrupted status handler clears the
  # prompt, which is the correct outcome. Never silently apply it to whatever
  # the agent is doing now.
  defp apply_pending_resume(%ServerState{} = server_state) do
    Logger.warning(
      "Agent #{server_state.agent.agent_id} was given a pending resume but booted " <>
        ":#{server_state.status}, not :interrupted. Discarding the resume: the interrupt " <>
        "was either answered elsewhere or could not be restored."
    )

    %{server_state | pending_resume: nil}
  end

  # Mirror of LangChain's `extract_interrupt_data/1` — keep these in lockstep
  # so restored and freshly-fired interrupts surface identically.
  defp restore_interrupt_data([single]) do
    Map.put(single.interrupt_data, :tool_call_id, single.tool_call_id)
  end

  defp restore_interrupt_data(multiple) do
    %{
      type: :multiple_interrupts,
      interrupts:
        Enum.map(multiple, fn result ->
          Map.merge(result.interrupt_data, %{tool_call_id: result.tool_call_id})
        end)
    }
  end

  @impl true
  def handle_continue(:broadcast_initial_state, server_state) do
    # Call on_server_start for each middleware, threading the returned state
    # through subsequent middleware and persisting it on the server.
    # This allows middleware to broadcast initial state, set up subscriptions,
    # and also seed state (e.g., TodoList broadcasts initial todos, other
    # middleware may populate metadata for the first before_model call).
    updated_state =
      Enum.reduce(server_state.agent.middleware, server_state.state, fn entry, state_acc ->
        case Middleware.apply_on_server_start(state_acc, entry) do
          {:ok, new_state} ->
            new_state

          {:error, reason} ->
            Logger.error(
              "Middleware #{inspect(entry.module)} on_server_start failed: #{inspect(reason)}"
            )

            state_acc
        end
      end)

    server_state = %{server_state | state: updated_state}

    # If this server was restored from persisted state (e.g., Horde migration),
    # broadcast a node_transferred event so observers know it landed here
    if server_state.restored do
      broadcast_event(server_state, {:node_transferred, %{to_node: node()}})
    end

    # Apply a resume that was submitted while no process was alive to take it,
    # BEFORE the initial status broadcast. This is deliberately ordered: the
    # boot broadcast is how every subscriber learns current state, so it must
    # fire, unconditionally, exactly once — but it should report the status
    # this server genuinely has once it has consumed everything it was handed.
    # Broadcasting :interrupted here and :running a microsecond later would
    # make every subscriber re-present a question that is already answered.
    server_state = apply_pending_resume(server_state)

    # Broadcast initial status so UI knows agent is ready. When restored from
    # persisted state with a surviving (restorable) interrupt, this fires
    # {:status_changed, :interrupted, interrupt_data} — matching the live
    # interrupt broadcast shape — so subscribers and mount-time get_status
    # callers re-surface the question UI without any extra plumbing.
    broadcast_event(
      server_state,
      {:status_changed, server_state.status, server_state.interrupt_data}
    )

    update_presence_status(server_state, server_state.status)

    # Track presence for agent discovery (unconditional when configured)
    server_state = track_presence(server_state)

    # Subscribe to presence topic to detect when viewers leave
    # This enables smart shutdown when agent is idle and all viewers leave
    subscribe_to_presence_topic(server_state)

    {:noreply, server_state}
  end

  @impl true
  def handle_call(:execute, _from, %ServerState{status: :idle} = server_state) do
    {:reply, :ok, start_execution(server_state)}
  end

  @impl true
  def handle_call(:execute, _from, server_state) do
    {:reply, {:error, "Cannot execute, server is in state: #{server_state.status}"}, server_state}
  end

  @impl true
  def handle_call(:cancel, _from, %ServerState{status: :running, task: task} = server_state)
      when not is_nil(task) do
    Logger.info("Cancelling agent execution for agent: #{server_state.agent.agent_id}")

    # Kill any running sub-agents FIRST. The main Task may be blocked in a
    # synchronous GenServer.call to a SubAgentServer -- without this, Task.shutdown
    # would spend its full 2s grace waiting on a call that can never return.
    # Sub-agents emit a :subagent_cancelled broadcast before terminating so
    # observability is preserved.
    cancel_all_subagents(server_state)

    # Two-phase shutdown: give the chain up to 2s to flush the in-progress turn
    # through callbacks (which top up the rolling state). If it doesn't return
    # in time, brutal-kill. Either way, the rolling state in `server_state.state`
    # already reflects every fully-processed turn up to this point.
    _result = Task.shutdown(task, :timer.seconds(2)) || Task.shutdown(task, :brutal_kill)

    # Drain any final turn casts the task may have emitted before exit so the
    # rolling state captures as much as possible before we snapshot it.
    server_state = drain_turn_casts(server_state)

    new_state = %{server_state | status: :cancelled, task: nil}

    # Persist the rolling state — the database now reflects messages produced
    # up to the cancel point, so page reload recovers them.
    new_state = maybe_persist_state(new_state, :on_cancel)

    # Persist an assistant display message for the cancellation so it survives
    # page reload. Persisting here (not in the LiveView) avoids duplicate rows
    # when multiple LiveViews are subscribed to the same agent. Mirrors the
    # :error path's persist_error_as_display_message.
    persist_cancel_as_display_message(new_state)

    # Reset inactivity timer after cancellation
    new_state = reset_inactivity_timer(new_state)

    # Broadcast in-flight state so the debugger shows what actually happened.
    broadcast_debug_event(new_state, {:agent_state_update, new_state.state})
    broadcast_event(new_state, {:status_changed, :cancelled, nil})
    update_presence_status(new_state, :cancelled)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:cancel, _from, server_state) do
    {:reply, {:error, "Cannot cancel, server is not running (status: #{server_state.status})"},
     server_state}
  end

  @impl true
  def handle_call(
        {:resume, resume_data},
        _from,
        %ServerState{status: :interrupted} = server_state
      ) do
    new_state = start_resume(server_state, resume_data)

    broadcast_event(new_state, {:status_changed, :running, nil})
    update_presence_status(new_state, :running)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:resume, _resume_data}, _from, server_state) do
    {:reply, {:error, "Cannot resume, server is not interrupted"}, server_state}
  end

  @impl true
  def handle_call(
        :dismiss_interrupt,
        _from,
        %ServerState{status: :interrupted, interrupt_data: interrupt_data} = server_state
      ) do
    if halt_interrupt?(interrupt_data) do
      new_state = State.cancel_pending_interrupts(server_state.state)

      updated_server_state = %{
        server_state
        | state: new_state,
          status: :idle,
          interrupt_data: nil,
          execution_seq: server_state.execution_seq + 1,
          error: nil
      }

      broadcast_event(updated_server_state, {:status_changed, :idle, nil})
      update_presence_status(updated_server_state, :idle)

      {:reply, :ok, updated_server_state}
    else
      {:reply, {:error, "interrupt requires explicit response (use resume)"}, server_state}
    end
  end

  @impl true
  def handle_call(:dismiss_interrupt, _from, server_state) do
    {:reply,
     {:error, "Cannot dismiss, server is not interrupted (status: #{server_state.status})"},
     server_state}
  end

  @impl true
  def handle_call(:get_state, _from, server_state) do
    {:reply, server_state.state, server_state}
  end

  @impl true
  def handle_call(:get_status, _from, server_state) do
    {:reply, server_state.status, server_state}
  end

  @impl true
  def handle_call(:get_info, _from, server_state) do
    info = %{
      status: server_state.status,
      state: server_state.state,
      interrupt_data: server_state.interrupt_data,
      error: server_state.error
    }

    {:reply, info, server_state}
  end

  @impl true
  def handle_call(:get_metadata, _from, server_state) do
    metadata = %{
      status: server_state.status,
      last_activity_at: server_state.last_activity_at,
      conversation_id: server_state.conversation_id,
      node: node()
    }

    {:reply, {:ok, metadata}, server_state}
  end

  @impl true
  def handle_call(:get_agent, _from, server_state) do
    {:reply, {:ok, server_state.agent}, server_state}
  end

  # Backwards-compatible 2-tuple form. The internal protocol gained an options
  # list; callers that predate it keep working.
  @impl true
  def handle_call({:add_message, message}, from, server_state) do
    handle_call({:add_message, message, []}, from, server_state)
  end

  # A run is in flight. Queue rather than reject: writing into `server_state.state`
  # here is what the old code did, and the canonical state from Agent.execute
  # replaced it wholesale a moment later, silently destroying the message.
  @impl true
  def handle_call(
        {:add_message, message, opts},
        _from,
        %ServerState{status: :running} = server_state
      ) do
    case queue_incoming_message(server_state, message, opts, true) do
      {:ok, updated_server_state} ->
        # A human just spoke, so this run is no longer part of an unbroken chain
        # of machine-initiated runs. Resetting here, and never in the tool door,
        # is the whole of the breaker's source distinction. It costs nothing
        # because it is already encoded in *which function clause ran*.
        {:reply, :queued, %{updated_server_state | consecutive_auto_executions: 0}}

      {:error, reason} ->
        {:reply, {:error, reason}, server_state}
    end
  end

  @impl true
  def handle_call({:add_message, message, opts}, _from, server_state) do
    # Resolve the display/LLM split. With no `:display` option this runs the
    # configured message preprocessor, exactly as before.
    case resolve_message_halves(server_state, message, opts, true) do
      {:ok, display_message, llm_message} ->
        # Add LLM message to the state
        new_state = State.add_message(server_state.state, llm_message)

        # Transition to idle if we were completed/error/cancelled to allow new
        # execution. If interrupted, the user has chosen to send a new message
        # instead of resuming — demote the pending interrupt so the trailing
        # tool-result placeholder doesn't malform the next LLM call.
        {new_state, new_status, new_interrupt_data} =
          case server_state.status do
            :interrupted ->
              {State.cancel_pending_interrupts(new_state), :idle, nil}

            s when s in [:completed, :error, :cancelled] ->
              {new_state, :idle, server_state.interrupt_data}

            _other ->
              {new_state, server_state.status, server_state.interrupt_data}
          end

        updated_server_state = %{
          server_state
          | state: new_state,
            status: new_status,
            interrupt_data: new_interrupt_data,
            error: nil,
            # A human just spoke. See the :running clause above for why this
            # reset lives on the human door and only on the human door.
            consecutive_auto_executions: 0
        }

        # Reset inactivity timer on user message
        updated_server_state = reset_inactivity_timer(updated_server_state)

        # If the prior status was :interrupted, broadcast the cancellation so
        # subscribers (LiveViews) clear any pending interrupt UI before the new
        # user message arrives.
        if server_state.status == :interrupted do
          broadcast_event(updated_server_state, {:status_changed, :idle, nil})
          update_presence_status(updated_server_state, :idle)
        end

        # Save and broadcast the display message. `:none` skips the transcript
        # entirely (model-visible, display-invisible).
        # Note: During LLM execution, assistant messages are also saved via on_message_processed callback
        # But if manually adding assistant messages, we should also save them here
        save_display_half(updated_server_state, display_message)

        # Note: Debug event for user messages is NOT broadcast here.
        # The authoritative state (with potential middleware modifications)
        # will be broadcast via on_after_middleware callback when Agent.execute runs.

        {:reply, :ok, updated_server_state}

      {:error, reason} ->
        {:reply, {:error, reason}, server_state}
    end
  end

  @impl true
  def handle_call(:reset, _from, server_state) do
    # Reset the filesystem first (clears memory files, unloads persisted files)
    agent_id = server_state.agent.agent_id
    :ok = Sagents.FileSystemServer.reset(agent_id)

    # Reset the agent state (clears messages, todos)
    reset_state = State.reset(server_state.state)

    # Transition to idle if we were completed/error/cancelled
    new_status =
      case server_state.status do
        :completed -> :idle
        :error -> :idle
        :cancelled -> :idle
        status -> status
      end

    updated_server_state = %{
      server_state
      | state: reset_state,
        status: new_status,
        error: nil,
        interrupt_data: nil
    }

    # Broadcast status change if status changed
    if new_status != server_state.status do
      broadcast_event(server_state, {:status_changed, new_status, nil})
    end

    broadcast_state_changes(server_state, reset_state)

    # Reset activity timer
    updated_server_state = reset_inactivity_timer(updated_server_state)

    {:reply, :ok, updated_server_state}
  end

  @impl true
  def handle_call(:get_inactivity_status, _from, server_state) do
    status = %{
      inactivity_timeout: server_state.inactivity_timeout,
      last_activity_at: server_state.last_activity_at,
      timer_active: !is_nil(server_state.inactivity_timer_ref),
      time_since_activity: time_since(server_state.last_activity_at)
    }

    {:reply, status, server_state}
  end

  @impl true
  def handle_call(:export_state, _from, server_state) do
    # Serialize the current state using StateSerializer
    serialized =
      StateSerializer.serialize_server_state(
        server_state.agent,
        server_state.state,
        pending_message: server_state.pending_message
      )

    {:reply, serialized, server_state}
  end

  @impl true
  def handle_call({:restore_state, persisted_state}, _from, server_state) do
    # Deserialize only conversation state (not agent config)
    # Get agent_id from the running agent
    agent_id = server_state.agent.agent_id

    case StateSerializer.deserialize_state(agent_id, persisted_state["state"]) do
      {:ok, state} ->
        # Sweep stale interrupts using the running agent's middleware.
        state = State.clean_stale_interrupts(state, server_state.agent.middleware)

        # Update only the state, keep existing agent from code
        # This function is for updating state in a running agent server
        updated_server_state = %{
          server_state
          | state: state,
            status: :idle,
            error: nil,
            interrupt_data: nil
        }

        # Broadcast state changes to subscribers
        broadcast_state_changes(server_state, state)

        # Reset inactivity timer after restore
        updated_server_state = reset_inactivity_timer(updated_server_state)

        {:reply, :ok, updated_server_state}

      {:error, reason} ->
        {:reply, {:error, reason}, server_state}
    end
  end

  @impl true
  def handle_call({:update_agent_and_state, new_agent, new_state}, _from, server_state) do
    Logger.info("Updating agent configuration and state for #{new_agent.agent_id}")

    # Validate that state has agent_id set (critical for middleware functionality)
    if new_state.agent_id do
      # Update both agent and state atomically
      updated_state = %{server_state | agent: new_agent, state: new_state}

      # Broadcast state change event
      broadcast_event(updated_state, {:state_restored, new_state})

      {:reply, :ok, updated_state}
    else
      error_msg =
        "State.agent_id is nil. When deserializing state, you must provide agent_id: State.from_serialized(agent_id, data)"

      Logger.error(error_msg)
      {:reply, {:error, error_msg}, server_state}
    end
  end

  # The tool door. Unlike the human door this never resets
  # `consecutive_auto_executions`. A tool queueing a message is exactly the
  # thing the breaker is counting.
  @impl true
  def handle_cast({:queue_message, message, opts}, server_state) do
    case queue_incoming_message(server_state, message, opts, false) do
      {:ok, %ServerState{status: :idle} = updated_server_state} ->
        # No run is in flight, so there is no boundary to wait for. The
        # boundary is now. Without this, a message queued from outside a run
        # would sit in the queue until some unrelated future run happened to
        # finish, which is the same class of silent loss this queue exists to
        # fix. (Tools normally run only while :running, so this is the
        # defensive path, not the common one.)
        {_outcome, drained_server_state} = drain_pending_message(updated_server_state)
        {:noreply, drained_server_state}

      {:ok, updated_server_state} ->
        {:noreply, updated_server_state}

      {:error, reason} ->
        Logger.error(
          "Rejected queued message for agent #{server_state.agent.agent_id}: #{inspect(reason)}"
        )

        {:noreply, server_state}
    end
  end

  @impl true
  def handle_cast({:publish_event, event}, server_state) do
    broadcast_event(server_state, event)

    # Persist state when conversation title is generated
    server_state =
      case event do
        {:conversation_title_generated, _title, _agent_id} ->
          maybe_persist_state(server_state, :on_title_generated)

        _other ->
          server_state
      end

    {:noreply, server_state}
  end

  @impl true
  def handle_cast({:publish_debug_event, event}, server_state) do
    broadcast_debug_event(server_state, event)
    {:noreply, server_state}
  end

  @impl true
  def handle_cast({:save_synthetic_message, attrs}, server_state) do
    maybe_save_synthetic_and_broadcast(server_state, attrs)
    {:noreply, server_state}
  end

  # Rolling-state turn update: append the completed message to the live state so
  # `get_state/1`, debuggers, and persistence all observe turn-level progress
  # before Agent.execute/3 returns. Out-of-order casts (from a cancelled or
  # superseded run) are silently dropped.
  @impl true
  def handle_cast({:turn_state_update, exec_seq, %LangChain.Message{} = message}, server_state) do
    if exec_seq == server_state.execution_seq and server_state.status == :running do
      updated_messages = server_state.state.messages ++ [message]
      updated_state = %{server_state.state | messages: updated_messages}
      new_server_state = %{server_state | state: updated_state}

      # Incremental broadcast: observers append to their local copy rather than
      # rebuilding from the full state on every turn.
      broadcast_debug_event(
        new_server_state,
        {:agent_state_messages_appended, [message]}
      )

      {:noreply, new_server_state}
    else
      {:noreply, server_state}
    end
  end

  # Sync `server_state.state` to the post-middleware state and broadcast it.
  # Makes middleware-injected messages visible mid-turn via `get_state/1`.
  # Dropped if the run was superseded or cancelled.
  @impl true
  def handle_cast({:after_middleware_broadcast, exec_seq, prepared_state}, server_state) do
    if exec_seq == server_state.execution_seq and server_state.status == :running do
      new_server_state = %{server_state | state: prepared_state}
      broadcast_debug_event(new_server_state, {:after_middleware_state, prepared_state})
      {:noreply, new_server_state}
    else
      {:noreply, server_state}
    end
  end

  @impl true
  def handle_cast(:touch, server_state) do
    # Reset the inactivity timer to keep the agent alive
    # Also update presence activity for real-time discovery
    update_presence_activity(server_state)
    {:noreply, reset_inactivity_timer(server_state)}
  end

  @impl true
  def handle_info({ref, result}, server_state) when is_reference(ref) do
    # Task completed
    Process.demonitor(ref, [:flush])

    # If we're already cancelled, ignore the task result (race condition)
    if server_state.status == :cancelled do
      {:noreply, Map.delete(server_state, :task)}
    else
      handle_execution_result(result, server_state)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, server_state) do
    case Publisher.handle_down(server_state.publisher, ref, pid) do
      {:matched, new_pub} ->
        # A subscriber pid went away; clean it up.
        {:noreply, %{server_state | publisher: new_pub}}

      :no_match ->
        handle_task_down(reason, server_state)
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, :normal}, server_state) do
    # Process exited normally (we trap exits), this is expected when shutting
    # down for inactivity
    {:noreply, server_state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, server_state) do
    # Task.async/1 both links and monitors, so a crashing execution task
    # delivers both {:EXIT, pid, reason} (via link, because we trap exits)
    # and {:DOWN, ref, :process, pid, reason} (via monitor). The DOWN path
    # already routes to handle_task_down/2 and transitions the agent to
    # :error. If for some reason that path didn't run yet (race), make sure
    # the EXIT also drives the same transition so the agent never gets
    # stuck in :running with a dead task.
    case server_state.task do
      %Task{pid: ^pid} ->
        if server_state.status in [:error, :cancelled] do
          {:noreply, server_state}
        else
          handle_task_down(reason, server_state)
        end

      _other ->
        # Some other linked process exited; nothing for us to do here.
        {:noreply, server_state}
    end
  end

  @impl true
  def handle_info({:llm_deltas, _deltas}, server_state) do
    # Deltas are broadcast via on_llm_new_delta callback in build_pubsub_callbacks
    # No need to process them here - the client (chat_live.ex) will handle merging
    {:noreply, server_state}
  end

  @impl true
  def handle_info(:inactivity_timeout, server_state) do
    agent_id = server_state.agent.agent_id
    Logger.info("Agent #{agent_id} shutting down due to inactivity")

    # Broadcast shutdown event
    broadcast_event(server_state, {:agent_shutdown, shutdown_payload(server_state, :inactivity)})

    {:noreply, stop_supervisor(server_state)}
  end

  @impl true
  def handle_info(:shutdown_no_viewers, server_state) do
    agent_id = server_state.agent.agent_id

    # The decision to stop was made `check_delay` ago, against a viewer list
    # that was empty and a status that was `:idle`. Both can have changed since,
    # and neither the schedule nor the timer is revocable: a viewer re-enters
    # when the user switches away from a conversation and back inside the delay,
    # and an inbound message puts the agent back to work. So the decision is
    # re-made here rather than trusted from when it was made.
    #
    # Re-reading is also what makes a duplicate timer harmless. Every leave
    # broadcast that finds an idle agent with no viewers schedules another one.
    if server_state.status == :idle and no_viewers?(server_state) do
      Logger.info("Agent #{agent_id} shutting down - idle with no viewers")

      # Broadcast shutdown event
      broadcast_event(
        server_state,
        {:agent_shutdown, shutdown_payload(server_state, :no_viewers)}
      )

      {:noreply, stop_supervisor(server_state)}
    else
      Logger.debug(
        "Agent #{agent_id} no-viewers shutdown cancelled - " <>
          "status #{inspect(server_state.status)}, viewers returned or work resumed"
      )

      {:noreply, server_state}
    end
  end

  # Handle presence_diff broadcasts from Phoenix.Presence
  # When viewers leave and the agent is idle, check if we should shutdown
  # Match on the broadcast struct fields without requiring the struct definition
  @impl true
  def handle_info(
        %{__struct__: Phoenix.Socket.Broadcast, event: "presence_diff", payload: diff},
        server_state
      ) do
    # Only act on leaves when agent is idle
    if server_state.status == :idle and map_size(diff.leaves) > 0 do
      maybe_shutdown_if_no_viewers(server_state)
    end

    {:noreply, server_state}
  end

  @impl true
  def handle_info({:middleware_message, middleware_id, message}, server_state) do
    # Emit telemetry event
    :telemetry.execute(
      [:sagents, :middleware, :message, :received],
      %{count: 1},
      %{middleware_id: middleware_id, agent_id: server_state.agent.agent_id}
    )

    # Look up middleware from registry
    case Map.get(server_state.middleware_registry, middleware_id) do
      nil ->
        Logger.warning("Received message for unknown middleware: #{inspect(middleware_id)}")
        {:noreply, server_state}

      entry ->
        # Call handle_message on the middleware
        case Middleware.apply_handle_message(message, server_state.state, entry) do
          {:ok, updated_state} ->
            # Update server state
            new_server_state = %{server_state | state: updated_state}
            # if debug pubsub is enabled, it will be notified.
            broadcast_debug_event(
              new_server_state,
              {:agent_state_update, middleware_id, updated_state}
            )

            {:noreply, new_server_state}

          {:error, reason} ->
            Logger.error(
              "Error handling middleware message for #{inspect(middleware_id)}: #{inspect(reason)}"
            )

            {:noreply, server_state}
        end
    end
  end

  @impl true
  def handle_info(msg, server_state) do
    # Catch-all for unexpected messages (log at debug level to avoid noise)
    Logger.debug("AgentServer received unexpected message: #{inspect(msg)}")
    {:noreply, server_state}
  end

  @impl true
  def terminate(reason, server_state) do
    agent_id = server_state.agent.agent_id

    # If agent is actively running (has an LLM connection), wait for it to finish
    # This prevents corrupting conversations by killing TCP connections mid-stream
    if server_state.status == :running and server_state.task != nil do
      Logger.warning(
        "AgentServer #{agent_id} terminating while status is :running. " <>
          "Waiting for active task to complete. Reason: #{inspect(reason)}"
      )

      # Wait up to 25 seconds for the task to complete naturally
      # (must be less than the 30s shutdown timeout in child_spec)
      wait_for_task_completion(server_state.task, 25_000)
    end

    # Cancel timer if present
    server_state = cancel_inactivity_timer(server_state)

    # Best-effort persistence on shutdown — DB may also be shutting down
    try do
      maybe_persist_state(server_state, :on_shutdown)
    catch
      _kind, _reason -> :ok
    end

    # Explicitly untrack from presence before exiting.
    # This is a synchronous call to the Tracker, ensuring the presence_diff
    # is broadcast before this process exits. Without this, the Tracker only
    # learns about the exit via async :DOWN messages, which may not be processed
    # before the Presence supervisor itself is terminated during shutdown.
    try do
      untrack_presence(server_state)
    catch
      _kind, _reason -> :ok
    end

    # Broadcast node transfer and shutdown events.
    # PubSub may already be shut down if the application is stopping,
    # so we rescue any errors from broadcasting.
    try do
      broadcast_event(server_state, {:node_transferring, %{from_node: node()}})

      broadcast_event(server_state, {:agent_shutdown, shutdown_payload(server_state, reason)})
    rescue
      _error -> :ok
    end

    # FileSystemServer traps exits and will flush_all in its own terminate/2
    # SubAgentsDynamicSupervisor will be stopped by AgentSupervisor
    # due to rest_for_one strategy

    :ok
  end

  # Build the `{:agent_shutdown, payload}` map. Every emit site (the two
  # timer-driven handlers and terminate/2) uses this, so a single shutdown
  # delivers the same shape more than once and consumers need exactly one
  # idempotent clause.
  #
  # `:interrupt_restorable` is the whole reason this is centralized. It is the
  # only moment the question "can this pending interrupt survive the process
  # dying?" is worth asking, and it is the only moment when both the
  # interrupt_data and the agent's middleware are still in scope to answer it.
  # A host that keeps an interrupt prompt on screen past shutdown must not
  # guess: a mirrored predicate silently drifts the day the middleware rules
  # change, and the failure mode is offering the user a prompt no agent can
  # ever accept.
  defp shutdown_payload(%ServerState{} = server_state, reason) do
    %{
      agent_id: server_state.agent.agent_id,
      reason: reason,
      status: server_state.status,
      interrupt_restorable: interrupt_restorable?(server_state),
      last_activity_at: server_state.last_activity_at,
      shutdown_at: DateTime.utc_now()
    }
  end

  defp interrupt_restorable?(%ServerState{status: :interrupted} = server_state) do
    State.interrupt_restorable?(server_state.interrupt_data, server_state.agent.middleware)
  end

  defp interrupt_restorable?(%ServerState{}), do: false

  # Wait for an active Task to complete, with a timeout
  defp wait_for_task_completion(%Task{ref: ref}, max_wait_ms) do
    receive do
      {^ref, _result} ->
        # Task completed, clean up the DOWN message
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _pid, _reason} ->
        # Task process died
        :ok
    after
      max_wait_ms ->
        Logger.warning("Timed out waiting for active task during shutdown")
        :ok
    end
  end

  ## Private Functions

  # A halt interrupt is dismissable via dismiss_interrupt/1. Other interrupt
  # types (HITL, ask_user_question) require explicit responses via resume/2.
  # A :multiple_interrupts batch containing a halt is dismissable because the
  # halt-wins policy makes the whole batch terminal.
  defp halt_interrupt?(%{type: :halt}), do: true

  defp halt_interrupt?(%{type: :multiple_interrupts, interrupts: subs}) when is_list(subs) do
    Enum.any?(subs, &(&1.type == :halt))
  end

  defp halt_interrupt?(_other), do: false

  defp handle_task_down(:normal, server_state) do
    # Task process exited normally, already handled by the {ref, result} clause.
    {:noreply, server_state}
  end

  defp handle_task_down(reason, server_state) do
    # Task crashed or was killed.
    # If status is already :cancelled, this is expected (brutal_kill side effect).
    if server_state.status == :cancelled do
      {:noreply, Map.delete(server_state, :task)}
    else
      Logger.error("Agent execution task crashed: #{inspect(reason)}")

      new_state = %{server_state | status: :error, error: reason}
      broadcast_event(new_state, {:status_changed, :error, reason})

      {:noreply, Map.delete(new_state, :task)}
    end
  end

  # Stop the parent AgentSupervisor asynchronously to avoid deadlock.
  # We can't call it synchronously because the supervisor would try to stop us
  # while we're waiting for the stop call to return.
  defp stop_supervisor(server_state) do
    agent_id = server_state.agent.agent_id
    shutdown_delay = server_state.shutdown_delay

    spawn(fn ->
      case AgentSupervisor.stop(agent_id, shutdown_delay) do
        :ok -> :ok
        {:error, :not_found} -> Logger.debug("AgentSupervisor for #{agent_id} already stopped")
      end
    end)

    # return the server_state to make it pipe-friendly
    server_state
  end

  @doc false
  # Build PubSub callback handlers that forward LLM events to subscribers.
  #
  # Returns a single map containing:
  # - LangChain-native keys (on_llm_new_delta, on_message_processed, etc.)
  #   that are added to the LLMChain and fired by LLMChain.run/2
  # - on_after_middleware: a Sagents-specific key fired by Agent.fire_callback/3
  #   after before_model hooks complete (NOT a LangChain key, ignored by LLMChain)
  #
  # This map is combined with middleware callback maps into a list
  # in execute_agent/2 and resume_agent/2 before being passed to Agent.execute/3.
  defp build_pubsub_callbacks(%ServerState{} = server_state) do
    agent_id = server_state.agent.agent_id
    exec_seq = server_state.execution_seq
    server_name = get_name(agent_id)

    %{
      # Sagents-only callback. Fires after before_model hooks, before the LLM call.
      # Casts to the GenServer so the broadcast uses the live publisher state
      # (subscribers that joined mid-turn) instead of the closure's snapshot.
      on_after_middleware: fn prepared_state ->
        safe_cast(server_name, {:after_middleware_broadcast, exec_seq, prepared_state})
      end,

      # Callback for streaming deltas (tokens as they arrive)
      # display_text is set on tool calls at the library level by
      # Utils.rewrap_callbacks_for_model before this callback is invoked.
      on_llm_new_delta: fn _chain, deltas ->
        broadcast_event(server_state, {:llm_deltas, deltas})
      end,

      # Callback for complete message (either through delta or non-streamed messages)
      on_message_processed: fn _chain, message ->
        # Save and broadcast message (if callback configured)
        maybe_save_and_broadcast_message(server_state, message)
        # Append to the rolling state so every observer (debugger, persistence,
        # get_state) sees turn-level progress before Agent.execute/3 returns.
        safe_cast(server_name, {:turn_state_update, exec_seq, message})
      end,

      # Callback for token usage information
      on_llm_token_usage: fn _chain, usage ->
        broadcast_event(server_state, {:llm_token_usage, usage})
      end,

      # Tool identification callback - fires early when tool name detected during streaming
      on_tool_call_identified: fn _chain, tool_call, _function ->
        tool_info = %{
          # May be nil during early streaming
          call_id: tool_call.call_id,
          name: tool_call.name,
          display_text: tool_call.display_text,
          arguments: tool_call.arguments || %{},
          status: :identified
        }

        broadcast_event(server_state, {:tool_call_identified, tool_info})
      end,

      # Tool execution lifecycle callbacks
      # Note: This fires when tool execution actually begins (not during detection)
      # The :on_tool_call_identified callback already fired earlier during streaming
      on_tool_execution_started: fn _chain, tool_call, _function ->
        tool_info = %{
          call_id: tool_call.call_id,
          name: tool_call.name,
          display_text: tool_call.display_text,
          arguments: tool_call.arguments
        }

        broadcast_tool_event(server_state, :executing, tool_info)
      end,
      on_tool_execution_completed: fn _chain, tool_call, tool_result ->
        tool_info = %{
          call_id: tool_call.call_id,
          name: tool_call.name,
          result: inspect(tool_result)
        }

        broadcast_tool_event(server_state, :completed, tool_info)
      end,
      on_tool_execution_failed: fn _chain, tool_call, error ->
        error_msg =
          case error do
            %{message: msg} -> msg
            msg when is_binary(msg) -> msg
            parts when is_list(parts) -> ContentPart.parts_to_string(parts) || inspect(parts)
            _other -> inspect(error)
          end

        tool_info = %{
          call_id: tool_call.call_id,
          name: tool_call.name,
          error: error_msg
        }

        broadcast_tool_event(server_state, :failed, tool_info)
      end,

      # LLM error callbacks for visibility into transient and terminal failures.
      #
      # :on_llm_error fires on EVERY individual LLM API call failure, including
      # transient errors during retries and fallback attempts. This is the
      # diagnostic callback -- it fires even when the chain recovers.
      on_llm_error: fn _chain, error ->
        broadcast_debug_event(server_state, {:llm_error, error})
      end,

      # :on_error fires ONCE when the chain encounters a terminal error and is
      # returning it to the caller. This fires after all recovery options
      # (retries, fallbacks) are exhausted.
      on_error: fn _chain, error ->
        broadcast_event(server_state, {:chain_error, error})
      end,

      # Sub-agent HITL resolution callback
      # Fired from Agent.resume_subagent_hitl after the sub-agent completes/fails,
      # BEFORE the main agent continues execution. This ensures the UI updates
      # the tool call status in real-time rather than waiting for the full LLM cycle.
      on_subagent_resolved: fn interrupt_data, status ->
        maybe_update_interrupt_tool_display(server_state, interrupt_data, status)
      end
    }
  end

  # Stamp the server's conversation id onto the state handed to Agent.execute/3 and
  # Agent.resume/4, which forwards it into `LLMChain.custom_context` for tools and
  # for `gen_ai.conversation.id` on the trace.
  #
  # Applied here, per execution, rather than once at init: `ServerState` is the
  # source of truth, and `State` is replaced wholesale by each `Agent.execute/3`
  # result (see `handle_execution_result/2`), so a value written once would be
  # dropped on the first turn. The field is virtual for the same reason — persisting
  # it would let a restored state disagree with the server that restored it.
  defp with_conversation_id(%ServerState{state: %State{} = state} = server_state) do
    %State{state | conversation_id: server_state.conversation_id}
  end

  defp execute_agent(%ServerState{} = server_state, pubsub_callbacks) do
    # Pass only the PubSub broadcasting callbacks. Agent.execute self-collects
    # this agent's middleware callbacks and merges them on top, so collecting
    # them here too would fire each middleware handler twice.
    callbacks = [pubsub_callbacks]

    # Execute agent with callbacks
    case Agent.execute(server_state.agent, with_conversation_id(server_state),
           callbacks: callbacks
         ) do
      {:ok, new_state} ->
        # Broadcast state changes
        broadcast_state_changes(server_state, new_state)
        {:ok, new_state}

      {:ok, new_state, extra} ->
        # until_tool structured completion - broadcast state changes and pass through extra
        broadcast_state_changes(server_state, new_state)
        {:ok, new_state, extra}

      {:interrupt, %State{} = interrupted_state, interrupt_data} ->
        # Broadcast state changes up to interrupt point
        broadcast_state_changes(server_state, interrupted_state)
        {:interrupt, interrupted_state, interrupt_data}

      {:pause, %State{} = paused_state} ->
        # Infrastructure pause (e.g., node draining) - broadcast state and propagate
        broadcast_state_changes(server_state, paused_state)
        {:pause, paused_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_agent(server_state, resume_data, resolved_interrupt_data) do
    # For interrupt types that resolve via State.replace_tool_result (not LLMChain
    # re-execution), fire the display update explicitly here. HITL tools get their
    # completion callbacks through LLMChain.execute_tool_calls_with_decisions, so
    # they are NOT included here to avoid double-updating.
    maybe_resolve_interrupt_display_on_resume(server_state, resolved_interrupt_data)

    # Same callback assembly as execute_agent/2: pass only PubSub callbacks;
    # Agent.resume self-collects middleware callbacks.
    pubsub_callbacks = build_pubsub_callbacks(server_state)
    callbacks = [pubsub_callbacks]

    case Agent.resume(
           server_state.agent,
           with_conversation_id(server_state),
           resume_data,
           callbacks: callbacks
         ) do
      {:ok, new_state} ->
        broadcast_state_changes(server_state, new_state)
        {:ok, new_state}

      {:ok, new_state, extra} ->
        # until_tool structured completion after resume - broadcast and pass through extra
        broadcast_state_changes(server_state, new_state)
        {:ok, new_state, extra}

      {:interrupt, interrupted_state, interrupt_data} ->
        broadcast_state_changes(server_state, interrupted_state)
        {:interrupt, interrupted_state, interrupt_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_execution_result({:ok, new_state, _extra}, server_state) do
    # until_tool structured completion - the extra data (tool result) is available
    # in the state's messages. For AgentServer (async/PubSub-driven), the important
    # signal is that execution completed successfully. The extra structured data
    # flows through PubSub events or can be retrieved from state.
    handle_execution_result({:ok, new_state}, server_state)
  end

  defp handle_execution_result({:ok, new_state}, server_state) do
    # Reconcile: the canonical state from Agent.execute replaces the rolling
    # state wholesale. The rolling state is a best-effort live view; middleware
    # after_model hooks may have transformed the state in ways our per-turn
    # appender doesn't capture.
    #
    # This wholesale replacement is exactly why `pending_message` lives on
    # ServerState rather than on State. A queue kept inside `new_state` would
    # be destroyed right here, by the mechanism it exists to survive.
    updated_state = %{
      server_state
      | status: :idle,
        state: new_state,
        error: nil
    }

    # A clean finish is the safe boundary for delivering a queued message.
    # Note the `:task` key is dropped on the :idle branch only, matching what
    # this clause did before. On the drained branch `start_execution/1`
    # overwrites it with the new task anyway.
    case drain_pending_message(updated_state) do
      {:drained, drained_state} ->
        # Deliberately NO {:status_changed, :idle, nil} broadcast, no presence
        # update to :idle, and no shutdown/inactivity check. Every UI treats
        # :idle as "done, re-enable the input"; flickering it here would clear
        # the loading state a beat before the agent resumes. The agent is not
        # idle. It has more to do. Observers who care about the extra run get
        # {:messages_drained, count} on the debug channel.
        broadcast_debug_event(drained_state, {:agent_state_update, drained_state.state})

        {:noreply, drained_state}

      {:idle, idle_state} ->
        # Persist agent state on completion
        idle_state = maybe_persist_state(idle_state, :on_completion)

        broadcast_event(idle_state, {:status_changed, :idle, nil})
        update_presence_status(idle_state, :idle)

        # Check if we should shutdown based on presence
        maybe_shutdown_if_no_viewers(idle_state)

        # Reset activity timer after completion
        idle_state = reset_inactivity_timer(idle_state)

        # Broadcast debug event for state update
        broadcast_debug_event(idle_state, {:agent_state_update, idle_state.state})

        {:noreply, Map.delete(idle_state, :task)}
    end
  end

  # Queue policy: HOLD. The user is answering a question, not extending the
  # conversation. Delivering a queued message here would land it between an
  # interrupt's placeholder tool result and the resume path's real results.
  # The held message drains when the resume completes as {:ok, _}; if the user
  # sends a new message instead of resuming, handle_call({:add_message, ...})
  # demotes the interrupt and the message takes the ordinary path.
  defp handle_execution_result({:interrupt, interrupted_state, interrupt_data}, server_state) do
    updated_state = %{
      server_state
      | status: :interrupted,
        state: interrupted_state,
        interrupt_data: interrupt_data
    }

    # Update sub-agent tool call display message to "interrupted"
    maybe_update_interrupt_tool_display(updated_state, interrupt_data, :interrupted)

    # Halts represent gate decisions — higher signal than ordinary pauses,
    # so they get their own telemetry event in addition to the generic
    # :status_changed broadcast. Fires for direct halts and for
    # :multiple_interrupts wrappers that contain a halt.
    maybe_emit_halt_telemetry(updated_state, interrupt_data)

    # Persist the halt's message as a synthetic assistant transcript
    # entry so the user's recommended-actions text survives dismissal
    # and page reload. Broadcasts {:display_message_saved, _} before the
    # :status_changed broadcast below so the transcript renders ahead
    # of the halt banner.
    maybe_persist_halt_messages(updated_state, interrupt_data)

    # Persist agent state on interrupt
    updated_state = maybe_persist_state(updated_state, :on_interrupt)

    broadcast_event(updated_state, {:status_changed, :interrupted, interrupt_data})
    update_presence_status(updated_state, :interrupted)

    # Reset activity timer after interrupt
    updated_state = reset_inactivity_timer(updated_state)

    # Broadcast debug event for state update
    broadcast_debug_event(updated_state, {:agent_state_update, interrupted_state})

    {:noreply, Map.delete(updated_state, :task)}
  end

  # Queue policy: HOLD. An infrastructure pause (node draining) is not a
  # conversation boundary. The queue survives in ServerState and drains when the
  # resumed run finishes cleanly.
  defp handle_execution_result({:pause, paused_state}, server_state) do
    updated_state = %{
      server_state
      | status: :paused,
        state: paused_state,
        error: nil
    }

    # Persist agent state so it can be resumed after restart
    updated_state = maybe_persist_state(updated_state, :on_completion)

    # The paused state carries the cause the mode attached (nil when it
    # attached none) — deliver it the way :interrupted delivers interrupt_data.
    broadcast_event(updated_state, {:status_changed, :paused, paused_state.pause_reason})
    update_presence_status(updated_state, :paused)

    # Reset activity timer -- agent is paused, not done
    updated_state = reset_inactivity_timer(updated_state)

    # Broadcast debug event for state update
    broadcast_debug_event(updated_state, {:agent_state_update, paused_state})

    {:noreply, Map.delete(updated_state, :task)}
  end

  # Queue policy: HOLD, and surface. Delivering a queued message into a failed
  # run compounds the failure, so the queue is kept and a debug event announces
  # that something is waiting, so a host can decide whether to retry, drop
  # it, or tell the user.
  defp handle_execution_result({:error, reason}, server_state) do
    updated_state = %{
      server_state
      | status: :error,
        error: reason
    }

    if updated_state.pending_message do
      broadcast_debug_event(updated_state, {:pending_message_held, :error})
    end

    # Persist agent state on error
    updated_state = maybe_persist_state(updated_state, :on_error)

    # Persist an assistant message describing the error so it survives page reloads
    maybe_persist_error_as_display_message(updated_state, reason)

    broadcast_event(updated_state, {:status_changed, :error, reason})
    update_presence_status(updated_state, :error)

    # Reset activity timer after error
    updated_state = reset_inactivity_timer(updated_state)

    {:noreply, Map.delete(updated_state, :task)}
  end

  # Broadcast state changes - broadcasts todos and debug state update
  defp broadcast_state_changes(%ServerState{} = server_state, %State{} = new_state) do
    # Debug broadcast that state changed (for debugging/monitoring tools)
    broadcast_debug_event(server_state, {:agent_state_update, new_state})
  end

  defp maybe_shutdown_if_no_viewers(server_state) do
    case server_state.presence_config do
      %{enabled: true, presence_module: presence_mod, topic: topic, check_delay: delay} ->
        # Check who's viewing this agent's conversation
        viewers = presence_mod.list(topic)

        if map_size(viewers) == 0 do
          Logger.info(
            "Agent #{server_state.agent.agent_id} idle with no viewers, " <>
              "scheduling shutdown to free resources"
          )

          # Schedule shutdown after brief delay (let final events propagate)
          Process.send_after(self(), :shutdown_no_viewers, delay)
        else
          Logger.debug(
            "Agent #{server_state.agent.agent_id} idle but has #{map_size(viewers)} " <>
              "viewers, keeping alive"
          )
        end

      _other ->
        # Presence tracking disabled, use standard inactivity timeout
        :ok
    end
  end

  # Whether the conversation this agent backs is currently unwatched.
  #
  # Answers `false` when presence tracking is off. Callers read a `true` here as
  # grounds to stop the agent, and "nobody is watching" is only a meaningful
  # answer when somebody could have been watching.
  defp no_viewers?(server_state) do
    case server_state.presence_config do
      %{enabled: true, presence_module: presence_mod, topic: topic} ->
        map_size(presence_mod.list(topic)) == 0

      _other ->
        false
    end
  end

  # Subscribe to the presence topic to receive presence_diff broadcasts
  # This allows the agent to detect when viewers leave while idle
  defp subscribe_to_presence_topic(%ServerState{presence_config: nil}), do: :ok

  defp subscribe_to_presence_topic(%ServerState{presence_config: %{enabled: false}}), do: :ok

  defp subscribe_to_presence_topic(%ServerState{} = server_state) do
    case {server_state.pubsub_name, server_state.presence_config} do
      {pubsub_name, %{topic: topic}} when is_atom(pubsub_name) and not is_nil(pubsub_name) ->
        Phoenix.PubSub.subscribe(pubsub_name, topic)

        Logger.debug(
          "Agent #{server_state.agent.agent_id} subscribed to presence topic: #{topic}"
        )

      _other ->
        :ok
    end
  end

  # Cancel every running sub-agent for this main agent. Called from the main
  # agent's :cancel handler so that sub-agents don't outlive their parent.
  #
  # Two broadcast paths:
  #   1. If the sub-agent can respond to :prepare_cancel within 300ms, IT
  #      broadcasts the event (rich context with its final_messages).
  #   2. If it is blocked (e.g. in-flight LLM call), the PARENT broadcasts a
  #      minimal :subagent_cancelled event directly from this process.
  # Either way, observers see a terminal event before the sub-agent is killed.
  defp cancel_all_subagents(%ServerState{} = server_state) do
    agent_id = server_state.agent.agent_id

    case Sagents.SubAgentsDynamicSupervisor.whereis(agent_id) do
      nil ->
        :ok

      sup_pid ->
        children = DynamicSupervisor.which_children(sup_pid)

        Enum.each(children, fn
          {_id, child_pid, :worker, _mods} when is_pid(child_pid) ->
            cancel_subagent_child(server_state, child_pid, sup_pid)

          _other ->
            :ok
        end)

        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp cancel_subagent_child(server_state, child_pid, sup_pid) do
    # Snapshot the tool_call_id from the sub-agent's process dictionary BEFORE
    # we terminate it -- Process.info doesn't go through the message queue, so
    # it works even when the process is blocked in an LLM call.
    tool_call_id = read_tool_call_id(child_pid)

    broadcast_ok =
      try do
        GenServer.call(child_pid, :prepare_cancel, 300) == :ok
      catch
        :exit, _reason -> false
      end

    unless broadcast_ok do
      # Sub-agent was blocked and couldn't self-broadcast. Fire a minimal
      # :subagent_cancelled event from the parent so observability still works.
      broadcast_fallback_subagent_cancel(server_state, child_pid)
    end

    # Update the main agent's "task" tool-call display message to :cancelled
    # so the chat UI stops showing a spinner for work that was abandoned.
    # Fires the :tool_execution_update broadcast AND persists via
    # DisplayMessagePersistence (if configured), mirroring the normal tool
    # completion path.
    if is_binary(tool_call_id) do
      broadcast_tool_event(server_state, :cancelled, %{
        call_id: tool_call_id,
        name: "task"
      })
    end

    case DynamicSupervisor.terminate_child(sup_pid, child_pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp read_tool_call_id(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :tool_call_id)
      _other -> nil
    end
  end

  defp broadcast_fallback_subagent_cancel(%ServerState{} = server_state, child_pid) do
    sub_agent_id = lookup_sub_agent_id(child_pid)

    if sub_agent_id do
      # Use the same wire format as SubAgentServer.broadcast_subagent_event/2.
      # NB: no final_messages/turn_count in this payload -- the sub-agent was
      # blocked in an LLM call and we can't query its current chain. Observers
      # (the debugger) already have every :subagent_llm_message they received
      # in their own state, so shipping empty placeholders here would only
      # overwrite their real data.
      broadcast_debug_event(
        server_state,
        {:subagent, sub_agent_id, {:subagent_status_changed, :cancelled}}
      )

      broadcast_debug_event(
        server_state,
        {:subagent, sub_agent_id, {:subagent_cancelled, %{}}}
      )
    end

    :ok
  end

  # Best-effort: the caller only broadcasts a cancellation event when this
  # answers, so `nil` is an acceptable outcome and a raise is not. This runs
  # during sub-agent teardown, where an escaping error would take the
  # AgentServer down mid-cleanup.
  #
  # The two handlers do not cover each other: `keys/1` raises rather than
  # exiting when this node's registry is gone, and a `catch :exit` clause does
  # not catch a raise. Only the registry-unavailable raise is swallowed, so a
  # genuine ArgumentError against a live registry still escapes.
  defp lookup_sub_agent_id(child_pid) do
    Sagents.ProcessRegistry.keys(child_pid)
    |> Enum.find_value(fn
      {:sub_agent, id} -> id
      _other -> nil
    end)
  rescue
    Sagents.RegistryUnavailableError -> nil
  catch
    :exit, _reason -> nil
  end

  # Drain any pending turn-update casts from the mailbox so the rolling state
  # captures every turn the task managed to emit before shutdown. Bounded loop:
  # each iteration either appends a valid turn or returns immediately.
  defp drain_turn_casts(%ServerState{} = server_state) do
    receive do
      {:"$gen_cast", {:turn_state_update, exec_seq, %LangChain.Message{} = message}}
      when exec_seq == server_state.execution_seq ->
        updated_messages = server_state.state.messages ++ [message]
        updated_state = %{server_state.state | messages: updated_messages}
        drain_turn_casts(%{server_state | state: updated_state})
    after
      0 -> server_state
    end
  end

  # safe_cast is used from callback closures that run in the Task process. If
  # the GenServer is no longer registered (crashed, shut down) the cast is a
  # silent no-op rather than crashing the Task.
  defp safe_cast(server_name, message) do
    try do
      GenServer.cast(server_name, message)
    catch
      :exit, _reason -> :ok
    end
  end

  # Extract the integrator-defined scope from the Agent struct. Source of truth
  # for all scope-bearing callback invocations below.
  defp current_scope(%ServerState{agent: %{scope: scope}}), do: scope

  # Build the shared callback context map — agent_id + conversation_id. Scope is
  # passed separately as the first positional argument to each callback.
  defp callback_context(%ServerState{} = s) do
    %{
      agent_id: s.agent.agent_id,
      conversation_id: s.conversation_id
    }
  end

  # Persist agent state via the AgentPersistence behaviour (if configured),
  # then fire set_interrupted/3 if (and only if) the durable interrupt flag
  # should transition. Returns the (possibly-updated) server_state so the
  # caller can rebind `interrupt_persisted`.
  defp maybe_persist_state(%ServerState{} = server_state, lifecycle) do
    case server_state.agent_persistence do
      nil ->
        server_state

      module ->
        state_data =
          StateSerializer.serialize_server_state(
            server_state.agent,
            server_state.state,
            pending_message: server_state.pending_message
          )

        scope = current_scope(server_state)
        context = Map.put(callback_context(server_state), :lifecycle, lifecycle)

        case module.persist_state(scope, state_data, context) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Agent persistence failed for #{server_state.agent.agent_id} (#{lifecycle}): #{inspect(reason)}"
            )

            :ok
        end

        maybe_update_interrupt_flag(server_state, module, lifecycle)
    end
  end

  # Fire set_interrupted/3 only on actual transitions of the durable flag.
  # The tracker (`server_state.interrupt_persisted`) reflects the last
  # value we wrote — so steady-state lifecycles (every successful turn,
  # title generation, shutdown) become no-ops.
  defp maybe_update_interrupt_flag(%ServerState{} = server_state, module, lifecycle) do
    case interrupt_flag_for(lifecycle) do
      :leave_alone ->
        server_state

      desired when desired == server_state.interrupt_persisted ->
        server_state

      desired ->
        if function_exported?(module, :set_interrupted, 3) do
          scope = current_scope(server_state)
          context = callback_context(server_state)

          case module.set_interrupted(scope, context, desired) do
            :ok ->
              %{server_state | interrupt_persisted: desired}

            {:error, reason} ->
              Logger.error(
                "set_interrupted failed for #{server_state.agent.agent_id} (#{lifecycle}): #{inspect(reason)}"
              )

              # Don't update the tracker on failure so we retry on the
              # next transition rather than permanently desyncing.
              server_state
          end
        else
          server_state
        end
    end
  end

  defp interrupt_flag_for(:on_interrupt), do: true
  defp interrupt_flag_for(:on_completion), do: false
  defp interrupt_flag_for(:on_cancel), do: false
  defp interrupt_flag_for(:on_error), do: false
  defp interrupt_flag_for(_other), do: :leave_alone

  # Broadcast tool event and persist via DisplayMessagePersistence (if configured)
  defp broadcast_tool_event(%ServerState{} = server_state, status, tool_info) do
    # Broadcast consolidated event
    broadcast_event(server_state, {:tool_execution_update, status, tool_info})

    # Persist if configured
    if server_state.display_message_persistence do
      scope = current_scope(server_state)
      context = callback_context(server_state)

      case server_state.display_message_persistence.update_tool_status(
             scope,
             status,
             tool_info,
             context
           ) do
        {:ok, updated_msg} ->
          broadcast_event(server_state, {:display_message_updated, updated_msg})

        {:error, _reason} ->
          :ok
      end
    end
  end

  # Update the display message for interrupted tool calls on interrupt/resume.
  # Handles subagent HITL, ask_user questions, and multiple_interrupts.

  # --- SubAgent HITL ---
  defp maybe_update_interrupt_tool_display(
         server_state,
         %{type: :subagent_hitl, tool_call_id: tool_call_id},
         :interrupted
       ) do
    broadcast_tool_event(server_state, :interrupted, %{
      call_id: tool_call_id,
      display_text: "Task awaiting approval"
    })
  end

  defp maybe_update_interrupt_tool_display(
         server_state,
         %{type: :subagent_hitl, tool_call_id: tool_call_id},
         :completed
       ) do
    broadcast_tool_event(server_state, :completed, %{
      call_id: tool_call_id,
      name: "task",
      result: "Task completed",
      display_text: "Task completed"
    })

    maybe_resolve_tool_result(server_state, tool_call_id, "Task completed")
  end

  defp maybe_update_interrupt_tool_display(
         server_state,
         %{type: :subagent_hitl, tool_call_id: tool_call_id},
         :failed
       ) do
    broadcast_tool_event(server_state, :failed, %{
      call_id: tool_call_id,
      name: "task",
      error: "Task failed"
    })

    maybe_resolve_tool_result(server_state, tool_call_id, "Task failed")
  end

  # --- AskUserQuestion ---
  defp maybe_update_interrupt_tool_display(
         server_state,
         %{type: :ask_user_question, tool_call_id: tool_call_id},
         :interrupted
       ) do
    broadcast_tool_event(server_state, :interrupted, %{
      call_id: tool_call_id,
      display_text: "Waiting for user response"
    })
  end

  defp maybe_update_interrupt_tool_display(
         server_state,
         %{type: :ask_user_question, tool_call_id: tool_call_id},
         :completed
       ) do
    broadcast_tool_event(server_state, :completed, %{
      call_id: tool_call_id,
      name: "ask_user",
      result: "Question answered"
    })

    maybe_resolve_tool_result(server_state, tool_call_id, "Question answered")
  end

  # --- Halt ---
  # A halt is terminal: there is no :completed/:failed transition because
  # the tool call is never re-executed. The user's next message demotes
  # the interrupted tool result via State.cancel_pending_interrupts/1.
  defp maybe_update_interrupt_tool_display(
         server_state,
         %{type: :halt, tool_call_id: tool_call_id},
         :interrupted
       )
       when is_binary(tool_call_id) do
    broadcast_tool_event(server_state, :interrupted, %{
      call_id: tool_call_id,
      display_text: "Workflow halted"
    })
  end

  defp maybe_update_interrupt_tool_display(_server_state, %{type: :halt}, _status), do: :ok

  # --- Multiple interrupts: update each inner interrupt ---
  defp maybe_update_interrupt_tool_display(
         server_state,
         %{type: :multiple_interrupts, interrupts: interrupts},
         status
       ) do
    Enum.each(interrupts, fn interrupt ->
      maybe_update_interrupt_tool_display(server_state, interrupt, status)
    end)
  end

  # Not a recognized interrupt type -- no tool display update needed
  defp maybe_update_interrupt_tool_display(_server_state, _interrupt_data, _status), do: :ok

  # Emit `[:sagents, :agent, :halt]` telemetry for halt-typed interrupts.
  # Halts are gate decisions, so observability tooling typically wants to
  # treat them differently from ordinary `:interrupted` transitions.
  defp maybe_emit_halt_telemetry(%ServerState{} = server_state, %{type: :halt} = data) do
    emit_halt_telemetry(server_state, data)
  end

  defp maybe_emit_halt_telemetry(
         %ServerState{} = server_state,
         %{type: :multiple_interrupts, interrupts: subs}
       )
       when is_list(subs) do
    Enum.each(subs, fn
      %{type: :halt} = halt -> emit_halt_telemetry(server_state, halt)
      _other -> :ok
    end)
  end

  defp maybe_emit_halt_telemetry(_server_state, _interrupt_data), do: :ok

  defp emit_halt_telemetry(%ServerState{} = server_state, %{type: :halt} = data) do
    :telemetry.execute(
      [:sagents, :agent, :halt],
      %{count: 1},
      %{
        agent_id: server_state.agent.agent_id,
        source_tool: Map.get(data, :source_tool) || Map.get(data, :source),
        tool_call_id: Map.get(data, :tool_call_id),
        message: Map.get(data, :message)
      }
    )

    :ok
  end

  # Persist the halt's :message text as a synthetic assistant display
  # message so it survives dismissal, page reload, and any later turn.
  # The interrupt UI (:pending_halt) is transient; this transcript entry
  # is the user's permanent record of the halt's recommended actions.
  #
  # Fires only at the original halt-emit moment in
  # handle_execution_result/2. Cold-start re-surface (Haltable.handle_resume/5
  # with resume_data == nil) does NOT re-persist — the original emit's
  # display message is already in the persisted log.
  defp maybe_persist_halt_messages(%ServerState{} = server_state, %{type: :halt} = data) do
    persist_halt_message(server_state, data)
  end

  defp maybe_persist_halt_messages(
         %ServerState{} = server_state,
         %{type: :multiple_interrupts, interrupts: subs}
       )
       when is_list(subs) do
    Enum.each(subs, fn
      %{type: :halt} = halt -> persist_halt_message(server_state, halt)
      _other -> :ok
    end)
  end

  defp maybe_persist_halt_messages(_server_state, _interrupt_data), do: :ok

  defp persist_halt_message(%ServerState{} = server_state, %{type: :halt} = halt) do
    case Map.get(halt, :message) do
      msg when is_binary(msg) and byte_size(msg) > 0 ->
        maybe_save_synthetic_and_broadcast(server_state, %{
          message_type: "assistant",
          content_type: "text",
          content: %{"text" => msg}
        })

      _empty_or_nil ->
        :ok
    end
  end

  # Fire display updates on resume for interrupt types that DON'T go through
  # LLMChain tool re-execution (and thus don't fire on_tool_execution_completed).
  defp maybe_resolve_interrupt_display_on_resume(server_state, %{type: :ask_user_question} = data) do
    maybe_update_interrupt_tool_display(server_state, data, :completed)
  end

  defp maybe_resolve_interrupt_display_on_resume(server_state, %{
         type: :multiple_interrupts,
         interrupts: interrupts
       }) do
    Enum.each(interrupts, fn interrupt ->
      maybe_resolve_interrupt_display_on_resume(server_state, interrupt)
    end)
  end

  defp maybe_resolve_interrupt_display_on_resume(_server_state, _interrupt_data), do: :ok

  # Resolve the interrupted tool result display message if the persistence module supports it
  defp maybe_resolve_tool_result(%ServerState{} = server_state, tool_call_id, result_content) do
    module = server_state.display_message_persistence

    if module && function_exported?(module, :resolve_tool_result, 4) do
      scope = current_scope(server_state)
      context = callback_context(server_state)

      case module.resolve_tool_result(scope, tool_call_id, result_content, context) do
        {:ok, updated_msg} ->
          broadcast_event(server_state, {:display_message_updated, updated_msg})

        {:error, _reason} ->
          :ok
      end
    end
  end

  # ── The pending-message queue ───────────────────────────────────
  #
  # Shared by the human door (handle_call({:add_message, ...}) while :running)
  # and the tool door (handle_cast({:queue_message, ...})). Resolves the
  # display/LLM split, saves the display half *immediately*, and merges the LLM
  # half into `pending_message`.
  #
  # The split resolving entirely at queue time is what lets the queue be a bare
  # `%Message{}`: nothing display-related ever waits in it. A user who typed
  # while the agent was busy sees their words right away, and a tool's
  # acknowledgement lands when the tool ran rather than a turn later.
  defp queue_incoming_message(
         server_state,
         %LangChain.Message{role: :user} = message,
         opts,
         preprocess?
       ) do
    case resolve_message_halves(server_state, message, opts, preprocess?) do
      {:ok, display_message, llm_message} ->
        save_display_half(server_state, display_message)

        updated_server_state =
          %{
            server_state
            | pending_message: merge_pending(server_state.pending_message, llm_message)
          }
          |> reset_inactivity_timer()

        broadcast_event(updated_server_state, {:message_queued, llm_message})

        {:ok, updated_server_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Constraining the queue to :user is what lets merge_pending/2 be
  # unconditional: no role comparison, no mixed-role fallback, no list needed
  # for the odd case. Rejecting a non-:user message while running is not a
  # regression: today *every* message is rejected in that state.
  defp queue_incoming_message(
         _server_state,
         %LangChain.Message{role: role} = _message,
         _opts,
         _preprocess?
       ) do
    {:error, "Cannot queue a #{inspect(role)} message. Only :user messages can be queued."}
  end

  # Merge on arrival rather than growing a list. The GenServer already
  # serializes every write, so this is a plain function over two values with no
  # coordination and no race. Two queued messages are one user turn, not two,
  # and merging here makes that shape provider-independent instead of
  # inheriting it from Anthropic's message combiner.
  defp merge_pending(nil, %LangChain.Message{} = incoming), do: incoming

  defp merge_pending(%LangChain.Message{} = pending, %LangChain.Message{} = incoming) do
    %LangChain.Message{pending | content: pending.content ++ incoming.content}
  end

  # Resolve the (display, llm) pair for an incoming message.
  #
  # `:display` absent  -> preprocessor when allowed, else display == llm
  # `:display` message -> caller supplied both halves; preprocessor is skipped
  #                       because the caller already made its decision
  # `:display` :none   -> model-visible, display-invisible
  defp resolve_message_halves(server_state, message, opts, preprocess?) do
    case Keyword.fetch(opts, :display) do
      :error when preprocess? ->
        run_message_preprocessor(server_state, message)

      :error ->
        {:ok, message, message}

      {:ok, :none} ->
        {:ok, :none, message}

      {:ok, %LangChain.Message{} = display_message} ->
        {:ok, display_message, message}

      {:ok, other} ->
        {:error,
         "Invalid :display option. Expected a %LangChain.Message{} or :none, got: #{inspect(other)}"}
    end
  end

  defp save_display_half(_server_state, :none), do: :ok

  defp save_display_half(server_state, %LangChain.Message{} = display_message) do
    maybe_save_and_broadcast_message(server_state, display_message)
  end

  # Called from the {:ok, _} terminal clause once the canonical state is
  # installed. Returns {:drained, server_state} when a follow-up run was
  # started, {:idle, server_state} when the caller should take the ordinary
  # completion path.
  defp drain_pending_message(%ServerState{pending_message: nil} = server_state) do
    {:idle, server_state}
  end

  defp drain_pending_message(%ServerState{pending_message: pending} = server_state) do
    # The message is real conversation either way, so it lands in state.messages
    # before the breaker is consulted. A tripped breaker declines to *run*; it
    # does not discard what the user or tool said.
    appended = %{
      server_state
      | state: State.add_message(server_state.state, pending),
        pending_message: nil
    }

    if appended.consecutive_auto_executions >= @max_consecutive_auto_executions do
      Logger.error(
        "Agent #{appended.agent.agent_id} reached the auto-execution ceiling " <>
          "(#{@max_consecutive_auto_executions} consecutive runs started by a queued " <>
          "message with no human input). Refusing to start another run. The queued " <>
          "message was added to the conversation but will not be acted on until a " <>
          "human sends one. Last queued content: " <>
          inspect(
            String.slice(
              LangChain.Message.ContentPart.content_to_string(pending.content) || "",
              0,
              200
            )
          )
      )

      broadcast_debug_event(
        appended,
        {:auto_execution_limit_reached, @max_consecutive_auto_executions}
      )

      {:idle, %{appended | consecutive_auto_executions: 0}}
    else
      # Persist before the follow-up run starts so the drained message is
      # durable even if that run dies.
      persisted = maybe_persist_state(appended, :on_completion)

      broadcast_debug_event(persisted, {:messages_drained, 1})

      {:drained,
       start_execution(%{
         persisted
         | consecutive_auto_executions: persisted.consecutive_auto_executions + 1
       })}
    end
  end

  # Start an async agent run. Extracted from handle_call(:execute, ...) so the
  # drain can start a run without going back through the call, which it cannot
  # do from inside handle_info/2.
  defp start_execution(%ServerState{} = server_state) do
    # Bump execution sequence so late callbacks from any prior run are rejected.
    # Build callbacks AFTER bumping so the closure captures the current seq.
    new_state = %{
      server_state
      | execution_seq: server_state.execution_seq + 1,
        status: :running
    }

    pubsub_callbacks = build_pubsub_callbacks(new_state)

    broadcast_event(new_state, {:status_changed, :running, nil})
    update_presence_status(new_state, :running)

    # Reset inactivity timer on execution start
    new_state = reset_inactivity_timer(new_state)

    task =
      Task.async(fn ->
        execute_agent(new_state, pubsub_callbacks)
      end)

    Map.put(new_state, :task, task)
  end

  # Run message preprocessor if configured, splitting message into display and LLM versions.
  # Returns {:ok, display_message, llm_message} or {:error, reason}.
  defp run_message_preprocessor(%ServerState{message_preprocessor: nil}, message) do
    {:ok, message, message}
  end

  defp run_message_preprocessor(%ServerState{} = server_state, message) do
    scope = current_scope(server_state)

    context = %{
      agent_id: server_state.agent.agent_id,
      conversation_id: server_state.conversation_id,
      tool_context: server_state.agent.tool_context || %{},
      state: server_state.state
    }

    try do
      server_state.message_preprocessor.preprocess(scope, message, context)
    rescue
      exception ->
        Logger.error(
          "Message preprocessor raised exception: #{inspect(exception)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        {:error, {:preprocessor_error, exception}}
    end
  end

  # Save message via DisplayMessagePersistence behaviour and broadcast display messages
  defp maybe_save_and_broadcast_message(server_state, message) do
    # Give middleware a chance to shape the message into its display
    # representation (annotate metadata for the UI, or rewrite content) before it
    # is persisted or broadcast. The message in agent state is untouched; this
    # only affects the display/transcript. See
    # Sagents.Middleware.transform_display_message/2.
    message = apply_display_transforms(server_state, message)

    if server_state.display_message_persistence && server_state.conversation_id do
      module = server_state.display_message_persistence
      scope = current_scope(server_state)
      context = callback_context(server_state)

      try do
        case module.save_message(scope, message, context) do
          {:ok, display_messages} when is_list(display_messages) ->
            Enum.each(display_messages, fn display_msg ->
              broadcast_event(server_state, {:display_message_saved, display_msg})
            end)

            broadcast_event(server_state, {:llm_message, message})

          {:error, reason} ->
            Logger.error("Display message persistence failed: #{inspect(reason)}")
        end
      rescue
        exception ->
          Logger.error("Display message persistence raised exception: #{inspect(exception)}")
      end
    else
      # No persistence configured — just broadcast the message event
      broadcast_event(server_state, {:llm_message, message})
    end
  end

  # Fold an outbound message through each middleware's transform_display_message
  # hook, in order. Middleware that doesn't implement it passes the message
  # through unchanged. An {:error, _} from a middleware is logged and the
  # untransformed message continues down the chain.
  defp apply_display_transforms(server_state, message) do
    Enum.reduce(server_state.agent.middleware, message, fn entry, msg ->
      case Middleware.apply_transform_display_message(msg, entry) do
        {:ok, transformed} ->
          transformed

        {:error, reason} ->
          Logger.error(
            "transform_display_message failed in #{inspect(entry.module)}: #{inspect(reason)}"
          )

          msg
      end
    end)
  end

  # Persist a middleware-originated synthetic display message via the configured
  # DisplayMessagePersistence module and broadcast the saved record. Skipped
  # silently if persistence is unconfigured or the optional callback isn't
  # implemented.
  defp maybe_save_synthetic_and_broadcast(server_state, attrs) do
    cond do
      is_nil(server_state.display_message_persistence) or is_nil(server_state.conversation_id) ->
        :ok

      not function_exported?(
        server_state.display_message_persistence,
        :save_synthetic_message,
        3
      ) ->
        Logger.warning(
          "Synthetic display message requested but #{inspect(server_state.display_message_persistence)} does not implement save_synthetic_message/3"
        )

      true ->
        module = server_state.display_message_persistence
        scope = current_scope(server_state)
        context = callback_context(server_state)

        try do
          case module.save_synthetic_message(scope, attrs, context) do
            {:ok, display_msg} ->
              broadcast_event(server_state, {:display_message_saved, display_msg})

            {:error, reason} ->
              Logger.error("Synthetic display message persistence failed: #{inspect(reason)}")
          end
        rescue
          exception ->
            Logger.error("Synthetic display message persistence raised: #{inspect(exception)}")
        end
    end
  end

  # A dead stream puts the partial message the model produced into the
  # transcript, carrying `content["stop_reason"] = "stream_error"`, so the reader
  # already sees both the text and the fact that it stopped. Adding a fabricated
  # row underneath would say the same thing again, less precisely and in prose a
  # host can neither style nor translate.
  #
  # Every other error still writes one. An error that produced no partial — a
  # request rejected before the stream opened, a tool blowing up, a delta that
  # would not convert — leaves the reader nothing at all otherwise.
  defp maybe_persist_error_as_display_message(server_state, reason) do
    if stream_error_partial_shown?(server_state) do
      :ok
    else
      persist_error_as_display_message(server_state, reason)
    end
  end

  # `Sagents.Agent` announces the partial through `:on_message_processed`, whose
  # handler both persists the display row and casts `{:turn_state_update, ...}`.
  # The cast and the task's result are sent by the same process, so the rolling
  # state has already absorbed the partial by the time the error is handled, and
  # its presence here is what says the transcript got it.
  #
  # A partial that produced nothing displayable is never announced, so it is
  # absent here too and the error row is written, which is what should happen.
  defp stream_error_partial_shown?(%ServerState{state: %State{messages: messages}}) do
    case List.last(messages) do
      %Message{} = message -> DisplayHelpers.stop_reason(message) == :stream_error
      _other -> false
    end
  end

  defp stream_error_partial_shown?(_server_state), do: false

  # Persist a row describing the error so it survives page reload.
  #
  # `content_type: "error"` is the classification; a host styles and translates
  # from that rather than from the prose. `content["error_type"]` carries the
  # `LangChain.LangChainError` type when there is one, which is the useful
  # discriminator here — "overloaded" and "exceeded_max_runs" want different
  # words, and neither is a message that stopped early.
  #
  # Deliberately not `content["stop_reason"]`. That vocabulary describes a
  # message the model began and did not finish, and after the dead-stream partial
  # is persisted no such case reaches this row. Reusing the key would make a
  # host's stop-reason branch mean two different things.
  defp persist_error_as_display_message(server_state, reason) do
    text = format_error_for_display(reason)

    persist_framework_row(server_state, text, %{
      message_type: "system",
      content_type: "error",
      content: put_error_type(%{"text" => text}, reason)
    })
  end

  # Persist a row on cancellation so it survives page reload and reaches every
  # subscribed LiveView. Persisting here (single authoritative writer) avoids
  # duplicate inserts when multiple LiveViews are subscribed to the same agent.
  #
  # `content["stop_reason"] = "cancelled"` is the same key and the same value
  # `Sagents.Message.DisplayHelpers` writes for a model message the caller
  # stopped, so a host renders both from one branch. There is no partial to mark
  # on this path: cancelling kills the task outright.
  defp persist_cancel_as_display_message(server_state) do
    text = "Agent execution cancelled."

    persist_framework_row(server_state, text, %{
      message_type: "system",
      content_type: "notification",
      content: %{"text" => text, "stop_reason" => "cancelled"}
    })
  end

  # Write a row the framework originated rather than the model.
  #
  # `save_synthetic_message/3` is optional, and a host generated before it
  # existed does not export it. Routing there unconditionally would delete these
  # rows outright for those hosts, so the prose message remains the fallback and
  # every host keeps a transcript entry.
  #
  # The two paths do not broadcast alike. `maybe_save_and_broadcast_message/2`
  # emits both `{:display_message_saved, _}` and `{:llm_message, _}`; the
  # synthetic path emits only the former, because there is no `%Message{}` to
  # put in the latter and fabricating one is the misattribution this row exists
  # to stop making. A host rendering these live from `{:llm_message, _}` reads
  # `{:display_message_saved, _}` instead, which it already handles if it
  # implements the callback at all.
  defp persist_framework_row(server_state, fallback_text, attrs) do
    if synthetic_message_supported?(server_state) do
      maybe_save_synthetic_and_broadcast(server_state, attrs)
    else
      maybe_save_and_broadcast_message(server_state, Message.new_assistant!(fallback_text))
    end
  end

  defp synthetic_message_supported?(%ServerState{display_message_persistence: nil}), do: false

  defp synthetic_message_supported?(%ServerState{display_message_persistence: module}) do
    Code.ensure_loaded?(module) and function_exported?(module, :save_synthetic_message, 3)
  end

  # Absent rather than nil when the failure carried no type, matching how the
  # framework writes every other optional content key.
  defp put_error_type(content, %LangChain.LangChainError{type: type}) when is_binary(type),
    do: Map.put(content, "error_type", type)

  defp put_error_type(content, _reason), do: content

  defp format_error_for_display(%LangChain.LangChainError{type: "delta_conversion_failed"}) do
    "The assistant returned an invalid response. Please try again."
  end

  defp format_error_for_display(%LangChain.LangChainError{message: message})
       when is_binary(message) do
    "Sorry, I encountered an error: #{message}"
  end

  defp format_error_for_display(reason) do
    "Sorry, I encountered an error: #{inspect(reason)}"
  end

  # Direct send/2 fan-out to main-channel subscribers. Wraps events in
  # `{:agent, event}` so consumers can pattern-match on origin.
  defp broadcast_event(%ServerState{} = server_state, event) do
    Publisher.broadcast(server_state.publisher, :main, main_envelope(event))
    :ok
  end

  # Direct send/2 fan-out to debug-channel subscribers. The outer `:agent` tag
  # identifies the producer; the inner `:debug` tag distinguishes the channel.
  defp broadcast_debug_event(%ServerState{} = server_state, event) do
    Publisher.broadcast(server_state.publisher, :debug, debug_envelope(event))
    :ok
  end

  # Single-pid send used by on_subscribed/3 to deliver a snapshot to a newly
  # registered subscriber. Same envelope as broadcast_event so consumers can
  # treat snapshot and live events identically.
  defp send_main_event_to(pid, event) when is_pid(pid) do
    send(pid, main_envelope(event))
    :ok
  end

  defp main_envelope(event), do: {:agent, event}
  defp debug_envelope(event), do: {:agent, {:debug, event}}

  # Sync a newly registered :main-channel subscriber to the current state by
  # sending it a status snapshot. Without this, a subscriber that joins after
  # the boot broadcast (e.g. a LiveView reloading mid-conversation) would never
  # learn that the agent is :interrupted with a pending question.
  #
  # Snapshots use the same envelope as live events; consumers don't need a
  # special handler. The snapshot fires inside the subscribe handle_call,
  # before the reply, so it's guaranteed to arrive at the subscriber before
  # any later broadcasts on the same channel.
  def on_subscribed(:main, subscriber_pid, %ServerState{} = server_state) do
    send_main_event_to(
      subscriber_pid,
      {:status_changed, server_state.status, server_state.interrupt_data}
    )

    server_state
  end

  def on_subscribed(_channel, _subscriber_pid, server_state), do: server_state

  ## Inactivity Timer Management

  # Reset the inactivity timer
  defp reset_inactivity_timer(state) do
    # Cancel existing timer if present
    state = cancel_inactivity_timer(state)

    # Don't schedule if timeout is nil or :infinity
    case state.inactivity_timeout do
      nil ->
        state

      :infinity ->
        state

      timeout when is_integer(timeout) and timeout > 0 ->
        timer_ref = Process.send_after(self(), :inactivity_timeout, timeout)

        %{state | inactivity_timer_ref: timer_ref, last_activity_at: DateTime.utc_now()}

      _other ->
        state
    end
  end

  # Cancel the current timer
  defp cancel_inactivity_timer(%ServerState{inactivity_timer_ref: nil} = state), do: state

  defp cancel_inactivity_timer(%ServerState{inactivity_timer_ref: ref} = state) do
    Process.cancel_timer(ref)

    # Flush the message if it was already sent
    receive do
      :inactivity_timeout -> :ok
    after
      0 -> :ok
    end

    %{state | inactivity_timer_ref: nil}
  end

  # Calculate time since last activity in milliseconds
  defp time_since(nil), do: nil

  defp time_since(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :millisecond)
  end

  # Returns the middleware entries list as-is.
  #
  # The agent's middleware list already contains MiddlewareEntry structs
  # that were initialized by Middleware.init_middleware/1 during Agent.new/2.
  #
  # The list preserves order (needed for before_model/after_model hooks)
  # A registry map can be built from this list for O(1) message routing
  defp build_middleware_entries(middleware_list) when is_list(middleware_list) do
    # Middleware entries are already properly initialized by Middleware.init_middleware/1
    # Just return them as-is
    middleware_list
  end

  defp build_middleware_entries(_other), do: []

  ## Agent Presence Tracking
  #
  # These functions enable discovery of running agents in real-time
  # via Phoenix.Presence. When presence_module is configured,
  # the agent tracks its presence on the "agent_server:presence" topic.

  # Track presence for agent discovery
  # Called in handle_continue(:broadcast_initial_state, ...)
  defp track_presence(%ServerState{presence_module: nil} = server_state) do
    # No presence module configured, skip tracking
    server_state
  end

  defp track_presence(%ServerState{} = server_state) do
    presence_mod = server_state.presence_module
    agent_id = server_state.agent.agent_id
    now = DateTime.utc_now()

    # Build base metadata with started_at AND last_activity_at
    base_metadata = %{
      started_at: now,
      last_activity_at: now,
      status: server_state.status,
      conversation_id: server_state.conversation_id,
      node: node()
    }

    # Add filesystem_scope tuple as a map entry for filtering (e.g., {:project_id, "UUID"})
    # This comes from the Agent's configuration and enables filtered discovery
    metadata =
      case server_state.agent.filesystem_scope do
        {key, value} -> Map.put(base_metadata, key, value)
        nil -> base_metadata
      end

    case Sagents.Presence.track(
           presence_mod,
           @agent_presence_topic,
           agent_id,
           metadata
         ) do
      {:ok, _ref} ->
        Logger.debug("Agent #{agent_id} tracked for presence discovery")
        server_state

      {:error, reason} ->
        Logger.warning(
          "Failed to track agent #{agent_id} for presence discovery: #{inspect(reason)}"
        )

        server_state
    end
  end

  # Update presence metadata when status changes
  # Called whenever status changes (execute, complete, interrupt, error, etc.)
  defp update_presence_status(%ServerState{presence_module: nil}, _new_status) do
    # No presence module configured, skip update
    :ok
  end

  defp update_presence_status(%ServerState{} = server_state, new_status) do
    presence_mod = server_state.presence_module
    agent_id = server_state.agent.agent_id

    # Update status, last_activity_at, and node together
    # Node is always included to ensure correct metadata after Horde migration
    case Sagents.Presence.update(
           presence_mod,
           @agent_presence_topic,
           agent_id,
           %{status: new_status, last_activity_at: DateTime.utc_now(), node: node()}
         ) do
      {:ok, _ref} ->
        :ok

      {:error, :not_tracked} ->
        # Agent not tracked, this can happen in race conditions during shutdown
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update presence status for #{agent_id}: #{inspect(reason)}")
        :ok
    end
  end

  # Update last_activity_at without status change (e.g., on touch)
  # Called from touch handler to update presence metadata for activity tracking
  defp update_presence_activity(%ServerState{presence_module: nil}), do: :ok

  defp update_presence_activity(%ServerState{} = server_state) do
    presence_mod = server_state.presence_module
    agent_id = server_state.agent.agent_id

    # Node is always included to ensure correct metadata after Horde migration
    case Sagents.Presence.update(
           presence_mod,
           @agent_presence_topic,
           agent_id,
           %{last_activity_at: DateTime.utc_now(), node: node()}
         ) do
      {:ok, _ref} ->
        :ok

      {:error, :not_tracked} ->
        # Agent not tracked, this can happen in race conditions during shutdown
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update presence activity for #{agent_id}: #{inspect(reason)}")
        :ok
    end
  end

  # Explicitly untrack presence during terminate/2.
  # This is synchronous, ensuring the presence_diff is broadcast before the process exits.
  defp untrack_presence(%ServerState{presence_module: nil}), do: :ok

  defp untrack_presence(%ServerState{} = server_state) do
    presence_mod = server_state.presence_module
    agent_id = server_state.agent.agent_id

    Sagents.Presence.untrack(presence_mod, @agent_presence_topic, agent_id)
  end

  # Wrap GenServer.call against an agent with try/catch so callers get a clear
  # {:error, :agent_not_running} tuple when the AgentServer has shut down
  # (inactivity timeout, supervisor restart, Horde migration in flight) instead
  # of a raw `(EXIT) no process` signal.
  #
  # Same intent as the existing pattern in `get_metadata/1` and `get_agent/1`,
  # but routed through the registry so a single helper covers every
  # lifecycle-action callsite (execute/1, cancel/1, resume/2, add_message/2,
  # reset/1).
  #
  # Resolves the pid through fetch_pid/1 rather than handing GenServer.call a
  # via-tuple. GenServer.call resolves a via name itself, and that resolution
  # raises out of :ets while this node's registry is unavailable, which covers
  # the whole drain window of a rolling deploy. fetch_pid/1 makes it a value the
  # caller can act on, so this helper is the single guard point for the
  # lifecycle API.
  defp safe_call(agent_id, request, timeout \\ 5000) do
    case fetch_pid(agent_id) do
      {:ok, pid} -> GenServer.call(pid, request, timeout)
      {:error, :not_running} -> {:error, :agent_not_running}
      {:error, :registry_unavailable} = error -> error
    end
  catch
    :exit, _reason -> {:error, :agent_not_running}
  end

  # For calls whose return shape has no room for an error tuple. Raises a named
  # Sagents.RegistryUnavailableError when the registry cannot answer, so the
  # condition is diagnosable and is never reported as a plausible-looking
  # default value.
  defp call!(agent_id, request, timeout \\ 5000) do
    ProcessRegistry.ensure_available!(:"AgentServer.#{elem_name(request)}")
    GenServer.call(get_name(agent_id), request, timeout)
  end

  # Every call!/3 request is either a bare atom or a tagged tuple, so these two
  # clauses are exhaustive. No catch-all: dialyzer proves it unreachable.
  defp elem_name(request) when is_atom(request), do: request
  defp elem_name(request) when is_tuple(request), do: elem(request, 0)
end
