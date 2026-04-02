# Changelog

## v0.4.4

### Changed
- Updated LangChain dependency from `~> 0.6.3` to `>= 0.7.0`, which includes fixes for HITL issues in sagents. The version constraint was relaxed for easier future updates [#49](https://github.com/sagents-ai/sagents/pull/49)

### Fixed
- Fixed documentation with fully qualified module references in middleware docs and code [#47](https://github.com/sagents-ai/sagents/pull/47) [#48](https://github.com/sagents-ai/sagents/pull/48)

## v0.4.3

Introduces a generalized interrupt/resume system via the new `handle_resume/5` middleware callback, replacing the hardcoded HITL resume logic in `Agent.resume/3`. Also adds `AskUserQuestion` middleware for structured user prompts with typed question and response data.

### Added
- `handle_resume/5` optional callback on `Middleware` behaviour -- gives each middleware a chance to claim and resolve interrupts during `Agent.resume/3`, replacing the previous monolithic resume handler [#45](https://github.com/sagents-ai/sagents/pull/45)
- `Middleware.apply_handle_resume/5` helper -- safely invokes `handle_resume/5` with `UndefinedFunctionError` rescue for middleware that don't implement it [#45](https://github.com/sagents-ai/sagents/pull/45)
- `AskUserQuestion` middleware -- provides an `ask_user` tool for structured questions with typed response formats (`:single_select`, `:multi_select`, `:freeform`), option lists, `allow_other`, and `allow_cancel` fields [#45](https://github.com/sagents-ai/sagents/pull/45)
- `handle_resume/5` implementation on `HumanInTheLoop` -- moves existing HITL decision processing (approve/reject/edit, tool execution, sub-agent forwarding) into the middleware callback pattern [#45](https://github.com/sagents-ai/sagents/pull/45)
- `handle_resume/5` implementation on `SubAgent` -- handles sub-agent HITL interrupt forwarding and resolution [#45](https://github.com/sagents-ai/sagents/pull/45)
- Re-scan mechanism in `Agent.resume/3` -- when a middleware returns `{:cont}` with new `interrupt_data` on state, the middleware stack is re-scanned with `resume_data = nil` so the owning middleware can claim it [#45](https://github.com/sagents-ai/sagents/pull/45)
- `Agent.build_chain/4` exposed as public for middleware that need to rebuild the LLMChain during resume (e.g., HITL tool execution) [#45](https://github.com/sagents-ai/sagents/pull/45)
- Display message handling for `ask_user` interrupts in `AgentServer` -- broadcasts `:interrupted`/`:completed` tool events for UI updates [#45](https://github.com/sagents-ai/sagents/pull/45)
- AskUserQuestion added to default middleware stack in generator template (`factory.ex.eex`) [#45](https://github.com/sagents-ai/sagents/pull/45)
- LiveView helper template (`agent_live_helpers.ex.eex`) updated with question response handling, `agent_id` nil-guards, and interrupt type dispatch [#45](https://github.com/sagents-ai/sagents/pull/45)
- Documentation for `handle_resume/5`, tool-level interrupts, claim vs resolve pattern, re-scan mechanism, and middleware ordering in `docs/middleware.md` [#45](https://github.com/sagents-ai/sagents/pull/45)

### Changed
- `Agent.resume/3` replaced ~230 lines of hardcoded HITL/sub-agent resume logic with a generic middleware cycle via `apply_handle_resume_hooks/5` [#45](https://github.com/sagents-ai/sagents/pull/45)
- `AgentServer.resume/2` accepts polymorphic `resume_data` instead of requiring a `list(map())` of decisions [#45](https://github.com/sagents-ai/sagents/pull/45)
- `AgentServer` renamed `maybe_update_subagent_tool_display/3` to `maybe_update_interrupt_tool_display/3` to reflect support for multiple interrupt types [#45](https://github.com/sagents-ai/sagents/pull/45)

## v0.4.2

### Added
- `move_in_storage/3` implementation on `Persistence.Disk` -- files and directories are now renamed on the host filesystem via `File.rename/2` when `move_file` is used, with automatic parent directory creation [#43](https://github.com/sagents-ai/sagents/pull/43)
- Cross-persistence backend validation on `move_file/3` -- moves between different storage backends (e.g., disk to database) are rejected with an error message that includes the source `base_directory` so the agent knows the valid move scope [#43](https://github.com/sagents-ai/sagents/pull/43)
- Read-only destination check on `move_file/3` -- moving files into a read-only directory now returns an error (previously only the source was checked) [#43](https://github.com/sagents-ai/sagents/pull/43)

### Fixed
- `FileSystemState.list_files/1` now filters out directory entries, returning only file paths. Previously, directory `FileEntry` items were included in the result, causing downstream callers to treat directories as files [#43](https://github.com/sagents-ai/sagents/pull/43)

## v0.4.1

### Added
- `move_file` tool on FileSystem middleware, allowing agents to move or rename files and directories through the tool interface. Delegates to `FileSystemServer.move_file/3`. [#41](https://github.com/sagents-ai/sagents/pull/41)

## v0.4.0

Major FileSystem API expansion with directory entries, richer FileEntry struct, file move/rename, metadata-only persistence optimization, and a clearer API surface. Also adds `tool_context` for caller-supplied data in tools, `MessagePreprocessor` for display/LLM message splitting, and improved middleware messaging.

**Breaking changes** — see Upgrading section below.

### Upgrading from v0.3.1

**FileEntry field renames:**
- `FileEntry.dirty` → `FileEntry.dirty_content`
- `FileEntry.dirty_metadata` → `FileEntry.dirty_non_content`

**API renames:**
- `FileSystemState.update_metadata/4` → `update_custom_metadata/4` (no longer accepts `:title` opt — use `update_entry/4` for title changes)
- `FileSystemServer.update_metadata/4` → `update_custom_metadata/4`
- `Persistence.list_persisted_files/2` → `list_persisted_entries/2` (now returns `[%FileEntry{}]` instead of `[path_string]`)

**Return type changes:**
- `FileSystemServer.write_file/4` returns `{:ok, %FileEntry{}}` instead of `:ok`
- `FileSystemServer.read_file/2` returns `{:ok, %FileEntry{}}` instead of `{:ok, content_string}`
- `FileSystemState.write_file/4` returns `{:ok, entry, state}` instead of `{:ok, state}`

### Added
- Directory entries as first-class `FileEntry` with `entry_type: :directory`, automatic `mkdir -p` ancestor creation, and `new_directory/2` constructor [#34](https://github.com/sagents-ai/sagents/pull/34)
- `title`, `id`, and `file_type` fields on `FileEntry` for richer file metadata [#34](https://github.com/sagents-ai/sagents/pull/34)
- `FileEntry.update_entry_changeset/2` — changeset for safe entry-level field updates (title, id, file_type) [#39](https://github.com/sagents-ai/sagents/pull/39)
- `update_entry/4` on `FileSystemState` and `FileSystemServer` — updates entry-level fields via changeset [#39](https://github.com/sagents-ai/sagents/pull/39)
- `update_custom_metadata/4` on `FileSystemState` and `FileSystemServer` — replaces `update_metadata/4` with a clearer name scoped to `metadata.custom` [#39](https://github.com/sagents-ai/sagents/pull/39)
- `list_entries/1` on `FileSystemState` and `FileSystemServer` — returns all entries with synthesized directories for tree UIs [#34](https://github.com/sagents-ai/sagents/pull/34)
- `create_directory/3` on `FileSystemState` and `FileSystemServer` [#34](https://github.com/sagents-ai/sagents/pull/34)
- `move_file/3` on `FileSystemState` and `FileSystemServer` — atomically moves a file or directory (and its children) to a new path, re-keying entries and transferring debounce timers [#39](https://github.com/sagents-ai/sagents/pull/39)
- `move_in_storage/3` optional callback on `Persistence` behaviour — persistence backends can implement this to handle path changes efficiently [#39](https://github.com/sagents-ai/sagents/pull/39)
- `update_metadata_in_storage/2` optional callback on `Persistence` behaviour — efficient metadata-only updates without rewriting file content [#38](https://github.com/sagents-ai/sagents/pull/38)
- `dirty_non_content` flag on `FileEntry` — tracks non-content changes separately from content changes, enabling metadata-only persistence optimization [#38](https://github.com/sagents-ai/sagents/pull/38), [#39](https://github.com/sagents-ai/sagents/pull/39)
- `persist_file/2` routes to `update_metadata_in_storage` when only non-content fields changed and the backend supports it, falling back to `write_to_storage` otherwise [#38](https://github.com/sagents-ai/sagents/pull/38)
- `default: true` option on `FileSystemConfig` — catch-all config for path-agnostic persistence backends (e.g. database), specific configs take priority [#33](https://github.com/sagents-ai/sagents/pull/33)
- Configurable `entry_to_map` option on FileSystem middleware — controls how entries are serialized to JSON for LLM tool results, with `default_entry_to_map/1` fallback [#34](https://github.com/sagents-ai/sagents/pull/34)
- `tool_context` field on `Agent` — caller-supplied map (user IDs, tenant info, scopes) merged into `LLMChain.custom_context` for tool functions [#35](https://github.com/sagents-ai/sagents/pull/35)
- `Sagents.MessagePreprocessor` behaviour — intercepts messages in AgentServer to produce separate display and LLM versions, enabling rich reference expansion (e.g. `@ProjectBrief` → full content for LLM, styled chip for UI) [#37](https://github.com/sagents-ai/sagents/pull/37)
- `notify_middleware/3` on `AgentServer` — renamed from `send_middleware_message/3` to better reflect its general-purpose notification role (deprecated wrapper retained for backwards compatibility) [#36](https://github.com/sagents-ai/sagents/pull/36)
- FileSystem setup guide documentation [#32](https://github.com/sagents-ai/sagents/pull/32)
- Middleware messaging documentation rewrite covering external notification and async task patterns [#36](https://github.com/sagents-ai/sagents/pull/36)

### Changed
- **BREAKING:** `FileEntry.dirty` field renamed to `dirty_content` [#39](https://github.com/sagents-ai/sagents/pull/39)
- **BREAKING:** `update_metadata/4` renamed to `update_custom_metadata/4` on both `FileSystemState` and `FileSystemServer` [#39](https://github.com/sagents-ai/sagents/pull/39)
- **BREAKING:** `FileSystemServer.write_file/4` returns `{:ok, %FileEntry{}}` instead of `:ok` [#34](https://github.com/sagents-ai/sagents/pull/34)
- **BREAKING:** `FileSystemServer.read_file/2` returns `{:ok, %FileEntry{}}` instead of `{:ok, content_string}` [#34](https://github.com/sagents-ai/sagents/pull/34)
- **BREAKING:** `FileSystemState.write_file/4` returns `{:ok, entry, state}` instead of `{:ok, state}` [#34](https://github.com/sagents-ai/sagents/pull/34)
- **BREAKING:** `Persistence.list_persisted_files/2` renamed to `list_persisted_entries/2`, returns `[%FileEntry{}]` instead of `[path_string]` [#34](https://github.com/sagents-ai/sagents/pull/34)
- Non-content updates (`update_custom_metadata`, `update_entry`) persist immediately by default; pass `persist: :debounce` to opt into debounced persistence [#39](https://github.com/sagents-ai/sagents/pull/39)
- New persisted files persist immediately on creation; only subsequent content updates are debounced [#34](https://github.com/sagents-ai/sagents/pull/34)
- FileSystem middleware `ls` tool now returns JSON array of entry maps instead of path strings [#34](https://github.com/sagents-ai/sagents/pull/34)
- Updated code generator templates to thread `tool_context` and `message_preprocessor` through Coordinator and Factory [#35](https://github.com/sagents-ai/sagents/pull/35), [#37](https://github.com/sagents-ai/sagents/pull/37)
- Documentation examples updated to use latest Anthropic model names [#32](https://github.com/sagents-ai/sagents/pull/32)

### Fixed
- `FileEntry.update_content/3` now resets `dirty_non_content` to `false`, preventing a data loss scenario where a metadata update followed by a content write would incorrectly route to `update_metadata_in_storage` and lose the content change [#38](https://github.com/sagents-ai/sagents/pull/38)

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
