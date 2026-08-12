defmodule Sagents.SubAgentsDynamicSupervisor do
  @moduledoc """
  DynamicSupervisor for managing ephemeral sub-agent processes.

  SubAgentsDynamicSupervisor provides isolated execution environments for
  sub-agents spawned during task delegation. Each sub-agent runs independently
  with its own conversation context while sharing the parent's filesystem.

  ## Purpose

  - **Dynamic spawning**: Creates sub-agent processes on-demand
  - **Isolation**: Each sub-agent runs in its own process
  - **Clean lifecycle**: Sub-agents are automatically cleaned up after completion
  - **Fault tolerance**: Sub-agent crashes don't affect parent agent

  ## Usage

  This supervisor is automatically started by AgentSupervisor and typically
  not used directly. The SubAgent middleware interacts with it to spawn
  sub-agent processes.

  ## Examples

      # Started automatically by AgentSupervisor
      {:ok, sup_pid} = AgentSupervisor.start_link(agent: agent)

      # SubAgent middleware will use this supervisor internally
      # to spawn ephemeral sub-agent processes
  """

  use DynamicSupervisor

  alias Sagents.ProcessRegistry

  @doc """
  Start the SubAgentsDynamicSupervisor.

  ## Options

  - `:agent_id` - The parent agent's ID (required)
  - `:name` - Supervisor name registration (optional)

  ## Examples

      {:ok, pid} = SubAgentsDynamicSupervisor.start_link(agent_id: "agent-123")

      {:ok, pid} = SubAgentsDynamicSupervisor.start_link(
        agent_id: "agent-123",
        name: SubAgentsDynamicSupervisor.get_name("agent-123")
      )
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    {name, _opts} = Keyword.pop(opts, :name, get_name(agent_id))

    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get the SubAgentsDynamicSupervisor PID for an agent.

  Returns the PID if found, nil otherwise.

  ## Examples

      pid = SubAgentsDynamicSupervisor.whereis("agent-123")

  Raises `Sagents.RegistryUnavailableError` when this node's registry cannot
  answer, for the same reason `Sagents.AgentServer.get_pid/1` does: `nil` would
  be indistinguishable from "not running".

  In practice this is unreachable. Every caller runs inside an agent turn, and
  the agent itself is registered, so a registry that cannot answer would have
  taken the caller down first. The raise is the correct answer to a question
  that should not arise here.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(agent_id) do
    case ProcessRegistry.lookup({:sub_agents_supervisor, agent_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Get the name of the SubAgentsDynamicSupervisor process for a specific agent.

  ## Examples

      name = SubAgentsDynamicSupervisor.get_name("agent-123")
      # => {:via, Registry, {Sagents.Registry, {:sub_agents_supervisor, "agent-123"}}}
  """
  def get_name(agent_id) do
    ProcessRegistry.via_tuple({:sub_agents_supervisor, agent_id})
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
