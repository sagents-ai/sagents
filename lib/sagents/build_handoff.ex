defmodule Sagents.BuildHandoff do
  @moduledoc false
  # Carries an agent built in the calling process to the AgentSupervisor that
  # starts it, when both are on the same node.
  #
  # Under `:horde`, the start options become a child spec that Horde replicates
  # to every member and resends on each sync, so `Sagents.Session` keeps the
  # built `%Agent{}` and its state out of them. When Horde places the agent on
  # the calling node, the whole start is one synchronous call chain on that
  # node: the caller waits inside `start_child` until `AgentSupervisor.init/1`
  # returns. The caller puts its build in this node-local table, the start
  # options carry only the key, and `init/1` takes the build back out. The agent
  # is then built once, in the caller, with the caller's process context.
  #
  # An entry is never required. When it is missing, because Horde placed the
  # agent on another node, a supervisor restart already consumed it, the sweep
  # removed it, or this table is restarting, the AgentSupervisor runs its
  # `:builder` instead. That is why every function here treats a missing table
  # as an absent entry rather than an error.
  #
  # The caller deletes its entry once the start returns. A caller killed in
  # between cannot, so the owner sweeps entries older than `@max_age_ms`.

  use GenServer

  @table __MODULE__
  @max_age_ms 60_000
  @sweep_interval_ms 60_000

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  # Stores `build` and returns the key for the start options, or `nil` when the
  # table is not running.
  @spec put(keyword()) :: reference() | nil
  def put(build) when is_list(build) do
    ref = make_ref()
    :ets.insert(@table, {ref, build, now()})
    ref
  rescue
    ArgumentError -> nil
  end

  @doc false
  # Removes and returns the build stored under `ref`, so it is used at most once.
  @spec take(reference()) :: {:ok, keyword()} | :error
  def take(ref) when is_reference(ref) do
    case :ets.take(@table, ref) do
      [{^ref, build, _inserted_at}] -> {:ok, build}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def take(_other), do: :error

  @doc false
  @spec delete(reference() | nil) :: :ok
  def delete(nil), do: :ok

  def delete(ref) when is_reference(ref) do
    :ets.delete(@table, ref)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Removes entries inserted more than `max_age_ms` ago. Returns how many.
  @spec sweep(non_neg_integer()) :: non_neg_integer()
  def sweep(max_age_ms \\ @max_age_ms) do
    cutoff = now() - max_age_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    schedule_sweep(interval)
    {:ok, %{sweep_interval_ms: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp now, do: System.monotonic_time(:millisecond)
end
