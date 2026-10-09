defmodule Sagents.PresenceWriter do
  @moduledoc """
  Makes presence writes on behalf of agent processes, so an agent never waits
  on `Phoenix.Tracker`.

  Every `Phoenix.Tracker` write (`track`, `update`, `untrack`) is a
  `GenServer.call` to a tracker shard with a 5 second timeout, and `list` is
  one too. A shard falls behind under load, and all agents share one shard for
  the `"agent_server:presence"` discovery topic, because the tracker shards by
  topic. An agent that made those calls itself would stall for 5 seconds per
  status change while the shard is backed up, and the timeout exit would
  terminate it.

  Agents instead hand their writes to this process with a cast, and it makes
  the tracker call for them. The tracker accepts any pid as the tracked
  process and links to it, so an entry is still removed when its agent exits.

  ## Semantics

  - **Desired state, not commands.** `put/5` says "this entry should exist with
    exactly this metadata", and `remove/4` says "this entry should not exist".
    A `put/5` updates the entry, and tracks it if the tracker does not have it
    (`{:error, :nopresence}`). An entry lost to a failed call is therefore
    recreated by the agent's next status change.
  - **Coalesced.** Each entry (presence module, topic, key, pid) holds at most
    one pending write, and a newer write replaces an older one that has not
    been applied yet. While the tracker is slow, the backlog is bounded by the
    number of entries, not by the number of status changes.
  - **Ordered per entry.** Writes for one entry are applied in the order they
    were made.
  - **Never fatal.** A write that exits or raises is logged and dropped. A
    `put/5` for a local pid that is no longer alive is skipped.

  ## Supervision

  `Sagents.Supervisor` starts this process before anything that hosts agents.
  Children stop in reverse start order, so it stops after the agents, and it
  applies the writes still pending when it stops, which includes the
  `remove/4` each agent makes on an orderly shutdown. A host that starts its
  `Phoenix.Presence` before `Sagents.Supervisor` (the usual order) keeps the
  tracker available for that.

  When this process is not running, as in a test that starts an
  `Sagents.AgentServer` without `Sagents.Supervisor`, a write is applied
  directly in the caller, with the same error handling.
  """

  use GenServer

  require Logger

  @type entry :: {presence_module :: module(), topic :: String.t(), key :: String.t(), pid()}

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Room to apply pending writes on the way down.
      shutdown: 5_000
    }
  end

  @doc """
  Start the writer. `Sagents.Supervisor` starts it; hosts do not.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Ensure `pid` is present on `topic` under `key` with exactly `meta`.

  Returns immediately.
  """
  @spec put(module(), pid(), String.t(), String.t(), map()) :: :ok
  def put(presence_module, pid, topic, key, meta) when is_pid(pid) and is_map(meta) do
    write({presence_module, topic, key, pid}, {:put, meta})
  end

  @doc """
  Ensure `pid` is not present on `topic` under `key`.

  Returns immediately.
  """
  @spec remove(module(), pid(), String.t(), String.t()) :: :ok
  def remove(presence_module, pid, topic, key) when is_pid(pid) do
    write({presence_module, topic, key, pid}, :remove)
  end

  @doc """
  Apply every pending write before returning.

  For tests that need to observe a write: a write cast before this call is
  applied by the time it returns. Returns `:ok` when the writer is not running.
  """
  @spec flush() :: :ok
  def flush do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      writer -> GenServer.call(writer, :flush, :infinity)
    end
  end

  defp write(entry, op) do
    case GenServer.whereis(__MODULE__) do
      nil -> apply_write(entry, op)
      writer -> GenServer.cast(writer, {:write, entry, op})
    end

    :ok
  end

  ## GenServer

  @impl true
  def init(_opts) do
    # Trap exits so terminate/2 runs on shutdown and applies what is pending.
    Process.flag(:trap_exit, true)
    {:ok, %{pending: %{}, queue: :queue.new()}}
  end

  @impl true
  def handle_cast({:write, entry, op}, state) do
    state =
      if Map.has_key?(state.pending, entry) do
        # Already queued: the newer write replaces it and keeps its place.
        put_in(state.pending[entry], op)
      else
        # Applying runs from a message to self rather than inside this
        # callback, so writes that arrive while a tracker call is blocked
        # are folded into the pending set before the next one is applied.
        if :queue.is_empty(state.queue), do: send(self(), :apply_next)

        %{
          state
          | pending: Map.put(state.pending, entry, op),
            queue: :queue.in(entry, state.queue)
        }
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    apply_all(state)
    {:reply, :ok, %{state | pending: %{}, queue: :queue.new()}}
  end

  @impl true
  def handle_info(:apply_next, state) do
    case :queue.out(state.queue) do
      {{:value, entry}, queue} ->
        {op, pending} = Map.pop(state.pending, entry)
        apply_write(entry, op)
        unless :queue.is_empty(queue), do: send(self(), :apply_next)
        {:noreply, %{state | pending: pending, queue: queue}}

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: apply_all(state)

  defp apply_all(state) do
    state.queue
    |> :queue.to_list()
    |> Enum.each(fn entry -> apply_write(entry, Map.fetch!(state.pending, entry)) end)
  end

  ## Applying a write

  defp apply_write({_module, _topic, _key, pid} = entry, {:put, meta}) do
    if node(pid) == node() and not Process.alive?(pid) do
      :ok
    else
      guarded(entry, :put, fn -> put_entry(entry, meta) end)
    end
  end

  defp apply_write({module, topic, key, pid} = entry, :remove) do
    guarded(entry, :remove, fn -> module.untrack(pid, topic, key) end)
  end

  defp put_entry({module, topic, key, pid} = entry, meta) do
    case module.update(pid, topic, key, meta) do
      {:ok, _ref} ->
        :ok

      {:error, :nopresence} ->
        case module.track(pid, topic, key, meta) do
          {:ok, _ref} -> :ok
          {:error, reason} -> log_failure(entry, :track, reason)
        end

      {:error, reason} ->
        log_failure(entry, :update, reason)
    end
  end

  defp guarded(entry, action, fun) do
    fun.()
  rescue
    error -> log_failure(entry, action, error)
  catch
    :exit, reason -> log_failure(entry, action, {:exit, reason})
  end

  defp log_failure({module, topic, key, _pid}, action, reason) do
    Logger.warning(
      "Presence #{action} for #{inspect(key)} on #{inspect(topic)} via #{inspect(module)} " <>
        "failed and was dropped: #{inspect(reason, limit: 5)}"
    )

    :ok
  end
end
