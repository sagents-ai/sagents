defmodule Sagents.Publisher do
  @moduledoc """
  Direct, monitored process subscriptions for GenServers that publish events.

  This is the producer side of the Sagents publish/subscribe transport. It
  provides per-server event channels (AgentServer, FileSystemServer) with a
  point-to-point `send/2` between the producer GenServer and a small set of
  subscriber pids it tracks itself.

  ## Why not Phoenix.PubSub?

  `Phoenix.PubSub` is a cluster-aware broadcast bus. With a clustered adapter
  every published message is serialized and shipped to every node, where each
  node's local PubSub server filters by topic. For per-agent event channels this
  is a lot of cross-node noise for what is, at the receiver, almost always a
  single in-node process.

  Direct `send/2` works transparently across nodes when the pid is remote, but
  routes one hop per known subscriber rather than a per-node broadcast.

  ## Producer side

  A producer GenServer embeds a `Sagents.Publisher.State` struct in its own
  state and `use`s this module. The `use` macro installs the `handle_call/3`
  clauses that handle subscribe/unsubscribe.

      defmodule MyServer do
        use GenServer
        use Sagents.Publisher,
          channels: [:main, :debug],
          state_field: :publisher

        defstruct [..., publisher: Sagents.Publisher.State.new([:main, :debug])]

        def init(opts) do
          {:ok, %__MODULE__{publisher: Sagents.Publisher.State.new([:main, :debug])}}
        end

        # Inside any handler that needs to broadcast:
        defp emit(state, event) do
          Sagents.Publisher.broadcast(state.publisher, :main, {:my_server, event})
          state
        end
      end

  ## Consumer side

  Subscribers locate the producer by name (typically via
  `Sagents.ProcessRegistry` via_tuple), call `Sagents.Publisher.subscribe/3`,
  and receive the wrapped events as ordinary process messages. The producer
  monitors each subscriber to clean up on death.

  See `Sagents.Subscriber` for the LiveView/GenServer-side helpers that capture
  the monitor + Presence + auto-resubscribe loop.

  ## Returned subscription handle

  `subscribe/3` returns `{:ok, server_pid, monitor_ref}`. The subscriber is
  expected to `Process.monitor/1` the server pid (or use the included
  `monitor_ref` from this side — the producer's monitor on the subscriber) to
  detect server death and trigger re-subscription via Presence arrival.

  Most consumers should `use Sagents.Subscriber` rather than calling this module
  directly.
  """

  alias Sagents.Publisher.State, as: PubState

  @typedoc "A channel identifier used to partition subscribers within a single producer."
  @type channel :: atom()

  # ---------------------------------------------------------------------------
  # Behaviour: producer-side macro
  # ---------------------------------------------------------------------------

  @doc """
  Inject subscribe/unsubscribe handlers into the host GenServer.

  Options:

    * `:state_field` (required) — the field name on the host's state struct
      that holds the `%Sagents.Publisher.State{}` value.
    * `:channels` (optional) — list of channel atoms the host supports.
      Defaults to `[:main]`. Used only for documentation/validation; the
      runtime data structure is created by `Sagents.Publisher.State.new/1`
      from the host's `init/1`.

  The macro injects two `handle_call/3` clauses that match on
  `{:__publisher__, channel, :subscribe | :unsubscribe, pid}`. These clauses
  must come before any catch-all `handle_call/3` clause in the host.
  """
  defmacro __using__(opts) do
    state_field = Keyword.fetch!(opts, :state_field)

    quote do
      @publisher_state_field unquote(state_field)

      @impl true
      def handle_call({:__publisher__, channel, :subscribe, subscriber_pid}, _from, state)
          when is_atom(channel) and is_pid(subscriber_pid) do
        pub = Map.fetch!(state, @publisher_state_field)
        {ref, new_pub} = Sagents.Publisher.State.add(pub, channel, subscriber_pid)
        new_state = Map.put(state, @publisher_state_field, new_pub)
        {:reply, {:ok, self(), ref}, new_state}
      end

      def handle_call({:__publisher__, channel, :unsubscribe, subscriber_pid}, _from, state)
          when is_atom(channel) and is_pid(subscriber_pid) do
        pub = Map.fetch!(state, @publisher_state_field)
        new_pub = Sagents.Publisher.State.remove_pid(pub, channel, subscriber_pid)
        new_state = Map.put(state, @publisher_state_field, new_pub)
        {:reply, :ok, new_state}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Client API (called from the subscriber's process)
  # ---------------------------------------------------------------------------

  @doc """
  Subscribe a pid to a channel on the named producer.

  `server` may be a pid, a registered name atom, or a `:via` tuple.
  Defaults the subscriber to `self()`.

  Returns `{:ok, server_pid, monitor_ref}` on success, where `monitor_ref`
  is the ref the producer uses to monitor this subscriber. The subscriber
  may also `Process.monitor/1` the returned `server_pid` to detect
  producer death.

  Returns `{:error, :process_not_found}` if the producer is not running.
  """
  @spec subscribe(GenServer.server(), channel(), pid()) ::
          {:ok, pid(), reference()} | {:error, :process_not_found}
  def subscribe(server, channel \\ :main, subscriber_pid \\ nil) do
    pid = subscriber_pid || self()

    try do
      GenServer.call(server, {:__publisher__, channel, :subscribe, pid})
    catch
      :exit, _ -> {:error, :process_not_found}
    end
  end

  @doc """
  Unsubscribe a pid from a channel.

  Returns `:ok`. If the producer is no longer running, returns `:ok`
  (the subscriber would have been cleaned up anyway).
  """
  @spec unsubscribe(GenServer.server(), channel(), pid()) :: :ok
  def unsubscribe(server, channel \\ :main, subscriber_pid \\ nil) do
    pid = subscriber_pid || self()

    try do
      GenServer.call(server, {:__publisher__, channel, :unsubscribe, pid})
    catch
      :exit, _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Server-side helpers (called from inside the producer GenServer)
  # ---------------------------------------------------------------------------

  @doc """
  Broadcast a message to every subscriber of a channel.

  This is a fire-and-forget `send/2` per subscriber. No filtering on
  source pid — the producer is the source by construction.

  Returns the publisher state unchanged.
  """
  @spec broadcast(PubState.t(), channel(), term()) :: PubState.t()
  def broadcast(%PubState{} = pub, channel, message) when is_atom(channel) do
    pub
    |> PubState.subscribers(channel)
    |> Enum.each(fn pid -> send(pid, message) end)

    pub
  end

  @doc """
  Handle a `{:DOWN, ref, :process, pid, reason}` info message.

  If the ref belongs to a tracked subscriber, returns
  `{:matched, new_publisher_state}`. Otherwise returns `:no_match` so the
  host can delegate to its own DOWN handlers (e.g. for Task monitors).
  """
  @spec handle_down(PubState.t(), reference(), pid()) ::
          {:matched, PubState.t()} | :no_match
  def handle_down(%PubState{} = pub, ref, _pid) when is_reference(ref) do
    case PubState.remove_ref(pub, ref) do
      {:ok, new_pub} -> {:matched, new_pub}
      :error -> :no_match
    end
  end
end
