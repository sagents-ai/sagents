# Changelog

## v0.2.1

Agent execution now uses LangChain's new customizable run mode system. The duplicated execution loops in `Agent` (`execute_chain_with_state_updates` and `execute_chain_with_hitl`) have been replaced by a single composable mode — `Sagents.Modes.AgentExecution` — built from pipe-friendly step functions.

### Added
- `Sagents.Modes.AgentExecution` — custom LLMChain execution mode that composes HITL interrupt checking, tool execution, and state propagation into a single pipeline
- `Sagents.Mode.Steps` — reusable pipe-friendly step functions for building custom execution modes:
  - `check_pre_tool_hitl/2` — checks tool calls against HITL policy before execution
  - `propagate_state/2` — merges tool result state deltas into the chain's custom context
- GitHub Actions CI workflow for automated testing on push and PRs [#14](https://github.com/sagents-ai/sagents/pull/14)

### Changed
- `Agent.execute_chain/3` now delegates to `Sagents.Modes.AgentExecution` via `LLMChain.run/2` instead of maintaining separate execution loops for HITL and non-HITL agents — removed ~160 lines of duplicated loop logic from `Agent`
- Requires `langchain ~> 0.5.3` for `LLMChain.execute_step/1` and the `Mode` behaviour

### Fixed
- HITL `process_decisions/3` now validates that each decision is a map, returning a clear error instead of crashing the AgentServer GenServer [#4](https://github.com/sagents-ai/sagents/pull/4)

## v0.2.0

Cluster-aware release with optional Horde-based distribution. Agents can now run across a cluster of nodes with automatic state migration, or continue running locally on a single node (the default).

**Breaking changes:** The Sagents OTP application (`Sagents.Application`) has been removed. Applications must now add `Sagents.Supervisor` to their own supervision tree. PubSub events are now wrapped in `{:agent, event}` tuples. Agent state persistence has moved from the Coordinator to the AgentServer via new behaviour modules.

### Upgrading from v0.1.0 to v0.2.0

**Supervision tree change:** Replace any reliance on the automatic `Sagents.Application` startup with an explicit child in your application's supervision tree:

```elixir
children = [
  # ... your other children (Repo, PubSub, etc.)
  Sagents.Supervisor
]
```

**PubSub event format change:** All PubSub events broadcast by `AgentServer` are now wrapped in `{:agent, event}` tuples. Update your `handle_info` clauses:

```elixir
# Before (v0.1.0)
def handle_info({:status_changed, status, data}, socket), do: ...

# After (v0.2.0)
def handle_info({:agent, {:status_changed, status, data}}, socket), do: ...
```

**Persistence ownership change:** Agent state and display message persistence is now owned by the AgentServer itself via optional behaviour modules (`Sagents.AgentPersistence` and `Sagents.DisplayMessagePersistence`). The Coordinator no longer handles persistence directly.

**Re-run the setup generator:** Commit your current code to version control first, then re-run `mix sagents.setup` to regenerate updated templates for the new supervision tree and persistence modules. Review the diffs to keep any customizations you've made.

### Added
- Cluster-aware distribution with optional Horde support — configure `config :sagents, :distribution, :horde` to enable, defaults to `:local`
- `Sagents.Supervisor` — single-line supervisor for adding Sagents to your application's supervision tree
- `Sagents.ProcessRegistry` — abstraction over `Registry` and `Horde.Registry`, switches backend based on distribution config
- `Sagents.ProcessSupervisor` — abstraction over `DynamicSupervisor` and `Horde.DynamicSupervisor`
- `Sagents.Horde.ClusterConfig` — cluster member discovery, regional clustering for Fly.io, and configuration validation
- `Sagents.AgentPersistence` behaviour — optional callback module for persisting agent state snapshots at key lifecycle points (completion, error, interrupt, shutdown, title generation)
- `Sagents.DisplayMessagePersistence` behaviour — optional callback module for persisting display messages and tool execution status updates
- `AgentServer.agent_info/1` — get detailed info about a running agent (pid, status, state, message count)
- `AgentServer.list_running_agents/0`, `list_agents_matching/1`, `agent_count/0` — agent discovery and enumeration
- `AgentServer.get_metadata/1` — metadata about an agent including node info
- Node transfer events: `{:agent, {:node_transferring, data}}` and `{:agent, {:node_transferred, data}}` broadcast during Horde redistribution
- `AgentSupervisor.start_link_sync/1` — synchronous startup that waits for AgentServer to be registered before returning
- Horde dependency (`~> 0.10`) added for cluster support
- Cluster integration tests for node transfer and redistribution scenarios

### Changed
- **Breaking:** Removed `Sagents.Application` — Sagents no longer starts its own OTP application; applications must add `Sagents.Supervisor` to their supervision tree
- **Breaking:** All PubSub events now wrapped in `{:agent, event}` tuples for easier pattern matching and routing
- **Breaking:** Agent state and display message persistence moved from Coordinator to AgentServer via behaviour modules
- AgentServer tracks `restored` flag to detect Horde migrations and broadcasts transfer events
- AgentServer includes presence tracking with real-time status and node metadata updates
- Updated `mix sagents.setup` generator templates for new supervision tree setup and persistence behaviours
- `mix precommit` now includes cluster integration tests

## v0.1.0

Initial release published to [hex.pm](https://hex.pm).
