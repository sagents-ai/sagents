defmodule Sagents.ClusterTestHelper do
  @moduledoc """
  Helper module for LocalCluster tests.

  Functions in this module are called via :rpc.call on remote nodes.
  They must be in a compiled module (not anonymous functions) because
  anonymous functions are not available across node boundaries.
  """

  @doc """
  Start the Sagents.Supervisor on the current node and unlink it from the caller.

  This is needed because :rpc.call creates a temporary process that exits
  after the call returns. If the supervisor is linked to it (via start_link),
  the supervisor would die too. Unlinking prevents this.
  """
  def start_supervisor do
    {:ok, pid} = Sagents.Supervisor.start_link(name: Sagents.Supervisor)
    Process.unlink(pid)
    {:ok, pid}
  end
end
