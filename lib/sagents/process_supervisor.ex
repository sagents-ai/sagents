defmodule Sagents.ProcessSupervisor do
  @moduledoc """
  Abstraction over dynamic supervisor implementations.

  Supports two backends:

  - `:local` — Elixir's `DynamicSupervisor` (single-node)
  - `:horde` — `Horde.DynamicSupervisor` (distributed cluster)

  ## Configuration

      # Single-node (default — no config needed)
      config :sagents, :distribution, :local

      # Distributed cluster
      config :sagents, :distribution, :horde

      # Horde options (optional)
      config :sagents, :horde,
        members: :auto,
        distribution_strategy: Horde.UniformDistribution
  """

  @agent_supervisor_name Sagents.AgentsDynamicSupervisor
  @filesystem_supervisor_name Sagents.FileSystem.FileSystemSupervisor

  # ---------------------------------------------------------------------------
  # Child Specs for Supervision Tree
  # ---------------------------------------------------------------------------

  @doc """
  Returns the child spec for the agents dynamic supervisor.

  Used in `Sagents.Application` supervision tree.
  """
  def agents_supervisor_child_spec(opts \\ []) do
    case distribution_type() do
      :local ->
        {DynamicSupervisor,
         Keyword.merge([name: @agent_supervisor_name, strategy: :one_for_one], opts)}

      :horde ->
        assert_horde_available!()
        Sagents.Horde.AgentsSupervisorImpl.child_spec(opts)
    end
  end

  @doc """
  Returns the child spec for the filesystem dynamic supervisor.

  Used in `Sagents.Application` supervision tree.
  """
  def filesystem_supervisor_child_spec(opts \\ []) do
    case distribution_type() do
      :local ->
        {DynamicSupervisor,
         Keyword.merge([name: @filesystem_supervisor_name, strategy: :one_for_one], opts)}

      :horde ->
        assert_horde_available!()
        Sagents.Horde.FileSystemSupervisorImpl.child_spec(opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Public API - Delegated Operations
  # ---------------------------------------------------------------------------

  @doc """
  Start a child process under the specified supervisor.
  """
  def start_child(supervisor_name, child_spec) do
    supervisor_module().start_child(supervisor_name, child_spec)
  end

  @doc """
  Terminate a child process.
  """
  def terminate_child(supervisor_name, pid) do
    supervisor_module().terminate_child(supervisor_name, pid)
  end

  @doc """
  List all children of the specified supervisor.
  """
  def which_children(supervisor_name) do
    supervisor_module().which_children(supervisor_name)
  end

  @doc """
  Count children of the specified supervisor.
  """
  def count_children(supervisor_name) do
    supervisor_module().count_children(supervisor_name)
  end

  @doc """
  Returns the supervisor module (`DynamicSupervisor` or `Horde.DynamicSupervisor`).
  """
  def supervisor_module do
    case distribution_type() do
      :local -> DynamicSupervisor
      :horde -> Horde.DynamicSupervisor
    end
  end

  @doc """
  Returns the configured distribution type (`:local` or `:horde`).
  """
  def distribution_type do
    Application.get_env(:sagents, :distribution, :local)
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp assert_horde_available! do
    unless Code.ensure_loaded?(Horde.DynamicSupervisor) do
      raise """
      Sagents is configured to use Horde (config :sagents, :distribution, :horde)
      but the :horde dependency is not available.

      Add it to your mix.exs:

          {:horde, "~> 0.10"}
      """
    end
  end
end
