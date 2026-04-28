defmodule Sagents.Subscriber do
  @moduledoc """
  Consumer-side helpers for `Sagents.Publisher` producers.

  Captures the boilerplate of:

    1. Subscribing to a producer by *id* rather than pid.
    2. Monitoring the producer so we know when it dies.
    3. Watching `Phoenix.Presence` arrivals for that id (to handle crash-restart
       with a new pid, or Horde migration to a new node).
    4. Re-subscribing automatically when the producer reappears.
    5. Cleaning up on caller exit (best-effort — the producer's monitor on the
       caller will clean us up anyway).

  Targets two consumer shapes:

    * **Plain GenServer / process** — call `subscribe_to_agent/2` and friends
      directly; pair with `handle_publisher_down/3` and `handle_presence_diff/3`
      from your `handle_info/2`.
    * **LiveView (or anything with a socket)** — `use Sagents.Subscriber`
      injects `handle_info/2` clauses for `:DOWN` and Phoenix presence diffs
      that delegate to those helpers.

  ## Subscription handle

  Each active subscription is tracked in the caller's local `subs` map (kept on
  the LiveView socket under `socket.private.sagents_subs`, or threaded through
  manually for plain-process callers).

  Map shape:

      %{
        {:agent, agent_id} => %{
          channel: :main | :debug,
          server_pid: pid() | nil,
          monitor_ref: reference() | nil,
          state: :subscribed | :pending
        },
        {:filesystem, scope_key} => %{...}
      }

  States:

    * `:subscribed` — we have a live subscription on `server_pid`, monitored.
    * `:pending` — we want to subscribe but the producer isn't running. Will
      retry on the next presence arrival.

  ## Departure vs arrival

  Monitors are reliable for departure (`:DOWN` fires within a scheduler tick of
  process death, even cross-node when the connection drops). Phoenix.Presence is
  reliable for arrival (`presence_diff` with `joins`). We never depend on
  `presence_diff.leaves` — if it's delayed, we keep the `:subscribed` state
  until `:DOWN` fires, which it will.
  """

  alias Sagents.AgentServer
  alias Sagents.FileSystemServer
  alias Sagents.Publisher

  @type sub_key :: {:agent, String.t()} | {:filesystem, term()}
  @type sub_entry :: %{
          channel: atom(),
          server_pid: pid() | nil,
          monitor_ref: reference() | nil,
          state: :subscribed | :pending
        }
  @type subs :: %{sub_key() => sub_entry()}

  @presence_topic "agent_server:presence"

  # ---------------------------------------------------------------------------
  # __using__ — LiveView / GenServer consumer
  # ---------------------------------------------------------------------------

  defmacro __using__(_opts) do
    quote do
      import Sagents.Subscriber,
        only: [
          subscribe_to_agent: 3,
          subscribe_to_agent: 4,
          subscribe_to_filesystem: 3,
          unsubscribe_from_agent: 2,
          unsubscribe_from_filesystem: 2
        ]

      # No handle_info clauses are auto-injected — call
      # Sagents.Subscriber.handle_info/3 from the host's handle_info clauses
      # explicitly. This avoids `defoverridable` collisions with LiveView's
      # generated handle_info/2 and keeps routing predictable for the host.
    end
  end

  # ---------------------------------------------------------------------------
  # Subscribe / unsubscribe (caller-side)
  # ---------------------------------------------------------------------------

  @doc """
  Subscribe the calling process to an agent's main channel, threading the
  subscription map through.

  Returns the updated subs map. If the agent is not currently running, the
  subscription is recorded in `:pending` state and will become live as soon
  as the agent appears in Phoenix.Presence on the agent presence topic.
  """
  @spec subscribe_to_agent(subs(), String.t(), :main | :debug) :: subs()
  def subscribe_to_agent(subs, agent_id, channel \\ :main) do
    subscribe_to_agent(subs, agent_id, channel, _subscriber_pid = self())
  end

  @doc false
  def subscribe_to_agent(subs, agent_id, channel, subscriber_pid)
      when channel in [:main, :debug] do
    key = {:agent, agent_id}

    do_subscribe(subs, key, channel, fn ->
      Publisher.subscribe(AgentServer.get_name(agent_id), channel, subscriber_pid)
    end)
  end

  @doc """
  Subscribe the calling process to filesystem change events for `scope_key`.
  """
  @spec subscribe_to_filesystem(subs(), term(), :main) :: subs()
  def subscribe_to_filesystem(subs, scope_key, channel \\ :main) do
    key = {:filesystem, scope_key}

    do_subscribe(subs, key, channel, fn ->
      Publisher.subscribe(FileSystemServer.get_name(scope_key), channel)
    end)
  end

  @doc """
  Unsubscribe from an agent. Tears down monitor and pending state.
  """
  @spec unsubscribe_from_agent(subs(), String.t()) :: subs()
  def unsubscribe_from_agent(subs, agent_id) do
    do_unsubscribe(subs, {:agent, agent_id}, fn channel ->
      Publisher.unsubscribe(AgentServer.get_name(agent_id), channel)
    end)
  end

  @doc """
  Unsubscribe from a filesystem.
  """
  @spec unsubscribe_from_filesystem(subs(), term()) :: subs()
  def unsubscribe_from_filesystem(subs, scope_key) do
    do_unsubscribe(subs, {:filesystem, scope_key}, fn channel ->
      Publisher.unsubscribe(FileSystemServer.get_name(scope_key), channel)
    end)
  end

  defp do_subscribe(subs, key, channel, subscribe_fun) do
    case subscribe_fun.() do
      {:ok, server_pid, monitor_ref} ->
        # Also monitor the server pid from our side so we get a :DOWN if the
        # producer crashes — even if the producer's own monitor on us was
        # already cleaned up before the crash propagated.
        client_ref = Process.monitor(server_pid)

        Map.put(subs, key, %{
          channel: channel,
          server_pid: server_pid,
          monitor_ref: monitor_ref,
          client_ref: client_ref,
          state: :subscribed
        })

      {:error, :process_not_found} ->
        Map.put(subs, key, %{
          channel: channel,
          server_pid: nil,
          monitor_ref: nil,
          client_ref: nil,
          state: :pending
        })
    end
  end

  defp do_unsubscribe(subs, key, unsubscribe_fun) do
    case Map.get(subs, key) do
      nil ->
        subs

      %{channel: channel, client_ref: client_ref} ->
        if client_ref, do: Process.demonitor(client_ref, [:flush])
        unsubscribe_fun.(channel)
        Map.delete(subs, key)
    end
  end

  # ---------------------------------------------------------------------------
  # Inbound message handlers (call from host's handle_info)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the `Phoenix.Presence` topic string the agent presence layer uses.

  Subscribe to this topic with `Phoenix.PubSub.subscribe/2` to receive
  `presence_diff` broadcasts that drive auto-resubscription.
  """
  @spec presence_topic() :: String.t()
  def presence_topic, do: @presence_topic

  @doc """
  Handle a `:DOWN` from one of the producer pids we subscribed to.

  Returns `{:matched, new_subs}` if the ref belonged to a tracked subscription
  (now flipped to `:pending`), otherwise `:no_match`.
  """
  @spec handle_publisher_down(subs(), reference(), term()) ::
          {:matched, subs()} | :no_match
  def handle_publisher_down(subs, ref, _reason) when is_reference(ref) do
    Enum.find_value(subs, :no_match, fn {key, entry} ->
      if entry[:client_ref] == ref do
        new_entry = %{entry | server_pid: nil, monitor_ref: nil, client_ref: nil, state: :pending}
        {:matched, Map.put(subs, key, new_entry)}
      else
        nil
      end
    end)
  end

  @doc """
  Handle a `Phoenix.Presence` diff for the agent presence topic.

  `joins` whose key matches a `:pending` agent subscription triggers a
  re-subscribe. Returns the (possibly updated) subs map.
  """
  @spec handle_presence_diff(subs(), String.t(), map()) :: subs()
  def handle_presence_diff(subs, @presence_topic, %{joins: joins}) when is_map(joins) do
    Enum.reduce(Map.keys(joins), subs, fn agent_id, acc ->
      key = {:agent, agent_id}

      case Map.get(acc, key) do
        %{state: :pending, channel: channel} ->
          subscribe_to_agent(acc, agent_id, channel)

        _ ->
          acc
      end
    end)
  end

  def handle_presence_diff(subs, _topic, _payload), do: subs
end
