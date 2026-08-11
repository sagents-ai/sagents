defmodule Sagents.ClusterTestHelper do
  @moduledoc """
  Helper module for LocalCluster tests.

  Functions in this module are called via :rpc.call on remote nodes.
  They must be in a compiled module (not anonymous functions) because
  anonymous functions are not available across node boundaries.
  """

  alias LangChain.ChatModels.ChatAnthropic

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

  @doc """
  Stop the Sagents supervision tree on this node, the way OTP does during an
  orderly application shutdown (SIGTERM on a rolling deploy).

  The node itself stays up, which is the whole point: on a real deploy the BEAM
  lingers for the drain period after its supervision tree has come down, and
  in-flight web requests keep arriving during that window.
  """
  def stop_supervisor(reason \\ :shutdown) do
    Supervisor.stop(Sagents.Supervisor, reason)
  end

  @doc """
  Brutally kill the local Horde registry process, leaving `Sagents.Supervisor`
  to restart it. Simulates a registry crash rather than a clean shutdown.
  """
  def kill_registry do
    case Process.whereis(Sagents.Registry) do
      nil ->
        {:error, :not_running}

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> {:ok, pid}
        after
          5_000 -> {:error, :timeout}
        end
    end
  end

  @doc "Whether the named process is registered and alive on this node."
  def registered?(name), do: Process.whereis(name) != nil

  @doc "The AgentSupervisor pid for `agent_id`, as seen from this node."
  def agent_supervisor_pid(agent_id), do: Sagents.AgentSupervisor.get_pid(agent_id)

  @doc """
  Whether the local Horde registry's `keys` ETS table exists.

  This is the precondition `Horde.Registry.lookup/2` requires, and the same
  thing `Sagents.ProcessRegistry.available?/0` checks. `:ets.whereis/1` answers
  `:undefined` rather than raising, which is what makes it usable as a guard.
  """
  def registry_table_present? do
    :ets.whereis(:"keys_#{Sagents.ProcessRegistry.registry_name()}") != :undefined
  end

  @doc """
  Whether `horde` on this node currently sees `other_node` as an `:alive` member.

  Horde only hands a departed node's processes to a survivor when the survivor's
  `members_info` entry for that node says `status: :dead`, and `mark_dead/2` can
  only mark an entry that is already there. A node removed before its member
  entry has converged on the survivor therefore takes its processes with it
  instead of handing them over.

  Reads Horde's internal GenServer state, so this is a test-only probe.
  """
  def member_alive?(horde, other_node) do
    case :sys.get_state(horde) do
      %{members_info: members_info} ->
        Enum.any?(members_info, fn {{_name, member_node}, member} ->
          member_node == other_node and member.status == :alive
        end)

      _other ->
        false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @doc """
  The `node()`s in `horde`'s member set as seen from this node.
  """
  def member_nodes(horde) do
    Horde.Cluster.members(horde)
    |> Enum.map(fn {_name, member_node} -> member_node end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # Lookup probes
  # ---------------------------------------------------------------------------

  @doc """
  Call `Sagents.AgentServer.get_pid/1`, capturing a raise instead of letting it
  propagate.

  `get_pid/1` raises `Sagents.RegistryUnavailableError` on a draining node,
  since its `pid() | nil` shape cannot report the condition. Use `fetch_probe/1`
  for the tuple-returning form.

  Returns one of:

  - `{:ok, pid | nil}`: the registry answered
  - `{:raised, module, message, formatted_stacktrace}`
  - `{:caught, kind, reason}`
  """
  def probe_once(agent_id) do
    {:ok, Sagents.AgentServer.get_pid(agent_id)}
  rescue
    error ->
      {:raised, error.__struct__, Exception.message(error),
       Exception.format_stacktrace(__STACKTRACE__)}
  catch
    kind, reason ->
      {:caught, kind, reason}
  end

  @doc """
  A lookup that bypasses the guard: `GenServer.whereis/1` on the registry's
  `:via` tuple with no availability check.

  Exercises Horde's own behaviour directly, which is what
  `Sagents.ProcessRegistry` wraps rather than replaces. Use it to assert what
  the guard is protecting against.

  Same return shape as `probe_once/1`.
  """
  def raw_whereis_probe(agent_id) do
    name =
      {:via, Horde.Registry, {Sagents.ProcessRegistry.registry_name(), {:agent_server, agent_id}}}

    {:ok, GenServer.whereis(name)}
  rescue
    error ->
      {:raised, error.__struct__, Exception.message(error),
       Exception.format_stacktrace(__STACKTRACE__)}
  catch
    kind, reason ->
      {:caught, kind, reason}
  end

  @doc """
  The guarded lookup, called the way a request path should call it.

  Unlike `probe_once/1` this does not raise: a draining node answers
  `{:error, :registry_unavailable}`. The rescue is here so a test failure
  reports the raise rather than crashing the probe.
  """
  def fetch_probe(agent_id) do
    Sagents.AgentServer.fetch_pid(agent_id)
  rescue
    error ->
      {:raised, error.__struct__, Exception.message(error)}
  end

  @doc "Whether this node reports itself ready to host agent sessions."
  def ready?, do: Sagents.ready?()

  @doc """
  Reduce any probe result to a comparable tag, for frequency counting.
  """
  def classify({:ok, nil}), do: :not_registered
  def classify({:ok, pid}) when is_pid(pid), do: :found
  def classify({:ok, {name, node}}) when is_atom(name) and is_atom(node), do: :found
  def classify({:error, :not_running}), do: :not_registered
  def classify({:error, reason}), do: {:error, reason}
  def classify({:raised, module, _message}), do: {:raised, module}
  def classify({:raised, module, _message, _stacktrace}), do: {:raised, module}
  def classify({:caught, kind, _reason}), do: {:caught, kind}

  @doc """
  Spawn a process on this node that polls a lookup in a loop, the way a web
  front end keeps serving requests while the node drains.

  Deliberately spawned *outside* the Sagents supervision tree. That is where a
  Phoenix Endpoint or Absinthe resolver lives, and it is why the probe survives
  `stop_supervisor/1` and keeps observing.

  `probe_fun` selects which lookup to poll: `:fetch_probe` for the guarded API a
  request path should use, `:probe_once` or `:raw_whereis_probe` for the
  unguarded ones.

  Send `{:report, pid}` to the returned pid to receive
  `{:probe_report, [tag]}` in call order.
  """
  def start_probe(agent_id, interval_ms \\ 2, probe_fun \\ :fetch_probe) do
    spawn(__MODULE__, :probe_loop, [agent_id, interval_ms, probe_fun, []])
  end

  @doc false
  def probe_loop(agent_id, interval_ms, probe_fun, acc) do
    receive do
      {:report, from} ->
        send(from, {:probe_report, Enum.reverse(acc)})
        probe_loop(agent_id, interval_ms, probe_fun, acc)
    after
      interval_ms ->
        tag = classify(apply(__MODULE__, probe_fun, [agent_id]))
        probe_loop(agent_id, interval_ms, probe_fun, [tag | acc])
    end
  end

  # ---------------------------------------------------------------------------
  # Agent placement
  # ---------------------------------------------------------------------------

  @doc """
  Start a minimal agent on this node through the real supervisor path.

  Uses a stub chat model config; nothing here makes an API call.
  """
  def start_agent(agent_id) do
    agent =
      Sagents.Agent.new!(%{
        agent_id: agent_id,
        model:
          ChatAnthropic.new!(%{
            model: "claude-sonnet-4-5-20250929",
            api_key: "test_key"
          }),
        base_system_prompt: "Rolling deploy test agent",
        replace_default_middleware: true,
        middleware: []
      })

    Sagents.AgentsDynamicSupervisor.start_agent_sync(
      agent_id: agent_id,
      agent: agent,
      initial_state: Sagents.State.new!(%{})
    )
  end
end
