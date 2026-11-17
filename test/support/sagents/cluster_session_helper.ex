defmodule Sagents.ClusterSessionHelper do
  @moduledoc """
  Router, factory, and persistence doubles for starting agents through
  `Sagents.Session` on LocalCluster nodes, plus the probes those tests call over
  `:rpc`.

  Everything here is a compiled module so it can run on any node: `Session`'s
  builder runs the router and factory on whichever node hosts the agent.
  """

  alias LangChain.ChatModels.ChatAnthropic

  # Large enough that an agent carried in the child spec is unmistakable.
  @prompt_bytes 50_000

  defmodule Router do
    @moduledoc false
    @behaviour Sagents.FactoryRouter

    @impl true
    def resolve(_scope, _conversation_id, request_opts) do
      {:ok, Sagents.ClusterSessionHelper.Factory, %{request_opts: request_opts}}
    end
  end

  defmodule Factory do
    @moduledoc false
    @behaviour Sagents.Factory

    # With `report_to: {name, node}` in the request options, reports each run:
    # the node and process it ran in, and the caller marker it found there.
    @impl true
    def create_agent(agent_id, %{request_opts: request_opts}) do
      case Keyword.get(request_opts, :report_to) do
        nil ->
          :ok

        report_to ->
          send(
            report_to,
            {:factory_ran, agent_id, node(), self(),
             Process.get(Sagents.ClusterSessionHelper.marker_key())}
          )
      end

      {:ok, Sagents.ClusterSessionHelper.build_agent(agent_id), []}
    end
  end

  defmodule Persistence do
    @moduledoc false
    @behaviour Sagents.AgentPersistence

    @impl true
    def persist_state(_scope, _state, _ctx), do: :ok

    # Every conversation has the same saved state: one todo, so a test can
    # tell a loaded state from a fresh one.
    @impl true
    def load_state(_scope, _ctx) do
      state = Sagents.State.new!(%{todos: [Sagents.ClusterSessionHelper.saved_todo()]})
      {:ok, %{"state" => Sagents.Persistence.StateSerializer.serialize_state(state)}}
    end
  end

  defmodule DisplayPersistence do
    @moduledoc false
    @behaviour Sagents.DisplayMessagePersistence

    @impl true
    def save_message(_scope, _message, _ctx), do: {:ok, []}
    @impl true
    def update_tool_status(_scope, _status, _tool_info, _ctx), do: {:ok, %{}}
    @impl true
    def resolve_tool_result(_scope, _tool_call_id, _result_content, _ctx), do: {:ok, %{}}
    @impl true
    def save_synthetic_message(_scope, _attrs, _ctx), do: {:ok, %{}}
  end

  @doc false
  def build_agent(agent_id) do
    Sagents.Agent.new!(
      %{
        agent_id: agent_id,
        model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929", api_key: "test_key"}),
        base_system_prompt: String.duplicate("x", @prompt_bytes),
        middleware: [{Sagents.Middleware.ProcessContext, keys: [marker_key()]}]
      },
      replace_default_middleware: true
    )
  end

  @doc "The process-dictionary key a caller marks itself with."
  def marker_key, do: :cluster_session_caller_marker

  @doc false
  def saved_todo, do: %Sagents.Todo{content: "from persistence", status: :pending}

  @doc """
  Start the PubSub `start_session/1` configures, unlinked from the `:rpc`
  caller so it outlives the call.
  """
  def start_pubsub do
    {:ok, pid} = Phoenix.PubSub.Supervisor.start_link(name: :cluster_session_pubsub)
    Process.unlink(pid)
    {:ok, pid}
  end

  @doc """
  Start the agent for `conversation_id` through `Sagents.Session.start/3` on
  this node.
  """
  def start_session(conversation_id, request_opts \\ [], marker \\ nil) do
    if marker, do: Process.put(marker_key(), marker)

    config = %{
      factory_router: Router,
      agent_persistence: Persistence,
      display_message_persistence: DisplayPersistence,
      pubsub: {Phoenix.PubSub, :cluster_session_pubsub},
      presence_module: nil,
      inactivity_timeout: :timer.minutes(10),
      agent_id_fun: &"cluster-session-#{&1}"
    }

    Sagents.Session.start(config, conversation_id,
      scope: :cluster_scope,
      request_opts: request_opts
    )
  end

  @doc """
  The start options this node's replica of the agents supervisor CRDT holds for
  `agent_id`, or `nil` when the replica has none.
  """
  def replicated_start_opts(agent_id) do
    Sagents.AgentsDynamicSupervisor
    |> then(&:"#{&1}.Crdt")
    |> DeltaCrdt.to_map()
    |> Enum.find_value(fn
      {{:process, _id}, {_member, %{start: {_mod, _fun, [opts]}}, _pid}} when is_list(opts) ->
        if Keyword.get(opts, :agent_id) == agent_id, do: opts

      _other ->
        nil
    end)
  end

  @doc "The caller marker in the running AgentServer's process dictionary."
  def agent_server_marker(agent_id) do
    {:ok, pid} = Sagents.AgentServer.fetch_pid(agent_id)
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    Keyword.get(dictionary, marker_key())
  end

  @doc "The number of builds waiting in this node's build handoff table."
  def handoff_entries, do: :ets.info(Sagents.BuildHandoff, :size)

  @doc "The running agent's system prompt size and todos, read on this node."
  def running_agent_summary(agent_id) do
    {:ok, agent} = Sagents.AgentServer.get_agent(agent_id)
    state = Sagents.AgentServer.get_state(agent_id)
    %{prompt_bytes: byte_size(agent.base_system_prompt), todos: state.todos}
  end
end
