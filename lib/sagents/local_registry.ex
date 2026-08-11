defmodule Sagents.LocalRegistry do
  @moduledoc """
  Starts Elixir's `Registry` for the `:local` backend, tolerating a restart that
  races the previous registry's own shutdown.

  ## Why this exists

  `Registry.start_link/1` starts a `Registry.Supervisor` registered under the
  given name, and that supervisor's children are `Registry.Partition` processes
  registered under derived names such as `Sagents.Registry.PIDPartition0`.

  `Registry.Partition` traps exits, because it links to every registered
  process. So when `Sagents.Registry` dies abnormally, the partition does *not*
  die with it: it receives the exit signal as a message and terminates
  asynchronously, holding its registered name for a few milliseconds longer.

  `Sagents.Supervisor` restarts its failed child immediately, well inside that
  window. `Registry.Supervisor.init/1` then tries to start a partition under a
  name the outgoing one still holds and gets `{:already_started, pid}`. The
  restart fails, and because a failed restart is not something a supervisor
  retries its way out of, `Sagents.Supervisor` gives up and exits `:shutdown` —
  taking the registry, both dynamic supervisors and every running agent with it,
  permanently. Nothing below it comes back until the host application's own
  supervisor restarts the whole subtree.

  This module closes that window: on an `:already_started` collision it waits
  for the straggler to actually exit, then retries. The wait is a monitor, not a
  sleep, so it costs exactly as long as the collision lasts.

  Only the `:local` backend needs this. Under `:horde` the name
  `Sagents.Registry` belongs to `Horde.RegistryImpl`, which Horde's own
  supervisor restarts internally, so there is no name for a restart to collide
  with.

  This covers the case where `Registry.Supervisor` itself dies. The other
  `:local` failure mode, where the supervisor survives and its partition is
  replaced with empty tables, produces no failed child at all and is handled by
  `Sagents.RegistryWatcher`.
  """

  @retries 5

  # The collision is measured in single-digit milliseconds, so this is three
  # orders of magnitude of headroom. It is a bound on the pathological case, not
  # a duration anything is expected to wait: past it, the name is held by
  # something that is not going away and retrying cannot help.
  @exit_timeout 1_000

  @doc """
  Start `Registry` with `opts`, retrying past a name still held by the previous
  registry's terminating partition.

  Every retry is gated on observing the straggler actually exit, so the retry
  count bounds how many distinct collisions are tolerated rather than how long
  this blocks. If a straggler does not exit within #{@exit_timeout}ms, the
  underlying error is returned instead of retrying against it.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    start_link(opts, @retries)
  end

  defp start_link(opts, retries_left) do
    case Registry.start_link(opts) do
      {:error, {:shutdown, {:failed_to_start_child, _id, {:already_started, pid}}}} = error
      when retries_left > 0 ->
        case await_exit(pid) do
          :ok -> start_link(opts, retries_left - 1)
          :timeout -> error
        end

      other ->
        other
    end
  end

  # Runs in the caller, which is the supervisor starting this child, so it
  # blocks that supervisor for as long as it waits. The collision is a process
  # that is already terminating, which is why waiting on its exit is both
  # precise and short. A timeout means the assumption does not hold, and the
  # caller is told rather than made to wait again.
  @spec await_exit(pid()) :: :ok | :timeout
  defp await_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @exit_timeout ->
        Process.demonitor(ref, [:flush])
        :timeout
    end
  end
end
