# Changelog

## v0.3.2

Adds file move/rename, metadata-only persistence optimization, and a clearer FileSystem API with separate functions for entry-level fields vs custom metadata. [#38](https://github.com/sagents-ai/sagents/pull/38)

### Added
- `move_file/3` on `FileSystemState` and `FileSystemServer` — atomically moves a file or directory (and its children) to a new path, re-keying entries and transferring debounce timers
- `move_in_storage/3` optional callback on `Persistence` behaviour — persistence backends can implement this to handle path changes efficiently (e.g. database update instead of delete+create). Falls back to marking entries dirty for the next persist cycle.
- `update_entry/4` on `FileSystemState` and `FileSystemServer` — updates entry-level fields (`title`, `id`, `file_type`) via `FileEntry.update_entry_changeset/2`
- `update_custom_metadata/4` on `FileSystemState` and `FileSystemServer` — replaces `update_metadata/4` with a clearer name that reflects it only updates `metadata.custom`
- `FileEntry.update_entry_changeset/2` — changeset that only casts updatable entry-level fields
- `dirty_non_content` flag on `FileEntry` — tracks non-content changes separately from content changes, enabling metadata-only persistence optimization
- `update_metadata_in_storage/2` optional callback on `Persistence` behaviour — persistence backends can implement this for efficient metadata-only updates without rewriting file content
- `persist_file/2` routes to `update_metadata_in_storage` when only non-content fields changed and the backend supports it, falling back to `write_to_storage` otherwise

### Changed
- **BREAKING:** `update_metadata/4` renamed to `update_custom_metadata/4` on both `FileSystemState` and `FileSystemServer`
- **BREAKING:** `FileEntry.dirty` field renamed to `dirty_content` — clarifies it tracks content modifications
- Non-content updates (`update_custom_metadata`, `update_entry`) persist immediately by default. Pass `persist: :debounce` to opt into debounced persistence.

### Fixed
- `FileEntry.update_content/3` now resets `dirty_non_content` to `false`, preventing a data loss scenario where a metadata update followed by a content write (before debounce fires) would incorrectly route to `update_metadata_in_storage` and lose the content change

## v0.3.1

### Fixed
- Horde dependency is now truly optional. Projects using the default `:local` distribution mode no longer require `:horde` to be installed for compilation to succeed. Previously, `use Horde.Registry` and `use Horde.DynamicSupervisor` in the Horde implementation modules caused compile-time failures even when Horde was declared as optional [#27](https://github.com/sagents-ai/sagents/issues/27)

## v0.3.0

Adds structured agent completion (`until_tool`), interruptible tools for improved HITL workflows, middleware-based observability callbacks, and custom execution modes. Requires LangChain `~> 0.6.1`.

### Added
- `until_tool` option for structured agent completion — agents loop until a specific target tool is called, returning the tool result as a 3-tuple `{:ok, state, %ToolResult{}}`. Works with both `Agent.execute/3` and SubAgent, including HITL interrupt/resume cycles [#3](https://github.com/sagents-ai/sagents/pull/3)
- `callbacks/1` optional behaviour callback on `Middleware` — middleware can now declare LangChain-compatible callback handler maps for observability (OpenTelemetry, metrics, etc.), composable and self-contained within middleware [#6](https://github.com/sagents-ai/sagents/pull/6)
- `Middleware.get_callbacks/1` and `Middleware.collect_callbacks/1` for extracting and aggregating middleware callback maps [#6](https://github.com/sagents-ai/sagents/pull/6)
- `mode` field on `Agent` — allows specifying a custom `LLMChain.Mode` implementation instead of the default `Sagents.Modes.AgentExecution` [#17](https://github.com/sagents-ai/sagents/pull/17)
- Tool interruption and resumption at the base Agent level, fixing SubAgent interrupt/resume flows [#24](https://github.com/sagents-ai/sagents/pull/24)
- `Mode.Steps.continue_or_done_safe/4` — enforces the `until_tool` contract by returning an error if the LLM stops without calling the target tool [#3](https://github.com/sagents-ai/sagents/pull/3)
- Observability guide documentation [#19](https://github.com/sagents-ai/sagents/pull/19)
- Middleware documentation [#24](https://github.com/sagents-ai/sagents/pull/24)
- Detection and warning when agents use built-in lower-level LangChain run modes that bypass Sagents HITL/state propagation [#3](https://github.com/sagents-ai/sagents/pull/3)

### Changed
- SubAgent execution refactored from custom `execute_chain_with_hitl/2` to unified `LLMChain.run/2` via `AgentExecution` mode — same pipeline as Agent [#3](https://github.com/sagents-ai/sagents/pull/3)
- `AgentServer.execute_agent/2` and `resume_agent/2` now combine PubSub callbacks with middleware callbacks and handle 3-tuple returns from `Agent.execute/3` [#6](https://github.com/sagents-ai/sagents/pull/6), [#3](https://github.com/sagents-ai/sagents/pull/3)
- `build_llm_callbacks` renamed to `build_pubsub_callbacks` to clarify its purpose [#6](https://github.com/sagents-ai/sagents/pull/6)
- Requires `langchain ~> 0.6.1` (up from `~> 0.5.3`) for interruptible tool support [#24](https://github.com/sagents-ai/sagents/pull/24)
- Updated `mix sagents.setup` template generators for new patterns [#24](https://github.com/sagents-ai/sagents/pull/24)

### Fixed
- `AgentServer.agent_info/1` crashing with `KeyError: key :messages not found` — now uses `get_state/1` instead of `export_state/1` [#25](https://github.com/sagents-ai/sagents/pull/25)

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
