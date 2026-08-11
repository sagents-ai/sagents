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
  `Sagents.Registry` belongs to `Horde.RegistryImpl`, a child of Horde's own
  supervisor, which restarts it internally — `Sagents.Supervisor` never sees a
  failed child there, which is why `Sagents.RegistryWatcher` exists.
  """

  @retries 5
  @exit_timeout 5_000

  @doc """
  Start `Registry` with `opts`, retrying past a name still held by the previous
  registry's terminating partition.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    start_link(opts, @retries)
  end

  defp start_link(opts, retries_left) do
    case Registry.start_link(opts) do
      {:error, {:shutdown, {:failed_to_start_child, _id, {:already_started, pid}}}}
      when retries_left > 0 ->
        await_exit(pid)
        start_link(opts, retries_left - 1)

      other ->
        other
    end
  end

  # The collision is a process that is already terminating, so waiting on its
  # exit is precise. The timeout only guards against the name being held by
  # something that is not going away, in which case retrying is pointless and
  # the caller should see the real error.
  defp await_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @exit_timeout ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end
end
