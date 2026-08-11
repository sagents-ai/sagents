defmodule Sagents.RegistryUnavailableError do
  @moduledoc """
  Raised when `Sagents.Registry` cannot answer on this node.

  This is a **lifecycle condition, not a bug**. The registry is unavailable in
  two normal situations:

  - the node has not finished starting `Sagents.Supervisor` yet, or
  - `Sagents.Supervisor` has already shut down while the BEAM is still running,
    which is the drain window of a rolling deploy.

  During that second window the node is still reachable by a load balancer while
  being unable to host or route agent sessions. See `Sagents.ready?/0` and
  `docs/deployment.md`.

  ## Why an exception here

  Functions whose return shape can express the condition report
  `{:error, :registry_unavailable}` rather than raising. This exception covers
  the ones whose shape cannot, such as `Sagents.AgentServer.get_pid/1`
  (`pid() | nil`) and `Sagents.ProcessRegistry.select/1` (a list).

  Those functions raise rather than answering `nil` or `[]`, because a caller
  reads "nothing is registered" as "nothing is running" and responds by starting
  an agent. On a draining node that produces a duplicate for a conversation that
  already has one elsewhere, silently. A loud, named error is the safer answer.

  ## Handling it

  Prefer the tuple-returning APIs on request paths:

      case Sagents.Session.ensure_running(config, assigns, opts) do
        {:ok, changes} -> ...
        {:error, :registry_unavailable} -> send_resp(conn, 503, "draining")
        {:error, reason} -> ...
      end
  """

  defexception [:operation, :registry]

  @type t :: %__MODULE__{operation: atom() | nil, registry: atom() | nil}

  @impl true
  def exception(opts) when is_list(opts) do
    %__MODULE__{
      operation: Keyword.get(opts, :operation),
      registry: Keyword.get(opts, :registry, Sagents.ProcessRegistry.registry_name())
    }
  end

  @impl true
  def message(%__MODULE__{operation: operation, registry: registry}) do
    """
    #{inspect(registry)} is not available on this node#{operation_suffix(operation)}.

    The registry process is not running, so lookups cannot be answered. This
    happens while the node is still starting up, and after Sagents.Supervisor
    has shut down while the BEAM drains during a rolling deploy.

    If this surfaced from a web request, the node was still receiving traffic
    after it stopped being able to serve it. Wire Sagents.ready?/0 into your
    readiness check so the load balancer stops routing here first. See
    docs/deployment.md.
    """
  end

  defp operation_suffix(nil), do: ""
  defp operation_suffix(operation), do: " (called from #{operation})"
end
