# Changelog

## v0.8.0-rc.1

Replaces `Phoenix.PubSub` with direct, monitored point-to-point delivery for agent and file-system events, renames the SubAgent middleware's external `subagent_type` argument to `task_name` (with automatic v1→v2 state migration), adds an optional `debug_summary/1` middleware callback so the live debugger can render large configs without hanging, and ships a friendlier UI message for malformed streaming deltas.

**Breaking changes** — see Upgrading section below.

### Upgrading from v0.7.0 to v0.8.0-rc.1

**Transport change (PR [#79](https://github.com/sagents-ai/sagents/pull/79)):** `Sagents.PubSub` is removed. Subscriptions to per-agent and per-filesystem events now go through `Sagents.Subscriber` and the producer's own subscriber tracking. Phoenix.Presence (for discovery) is unchanged.

To migrate a host application:
1. Remove any direct calls to `Sagents.PubSub.subscribe/1` / `broadcast/2`. Replace with `use Sagents.Subscriber` in your LiveViews/GenServers and call the generated `subscribe/2` helper, or pass `:initial_subscribers` when starting servers to enroll the caller inside `init/1` and avoid the start/subscribe race.
2. Re-run `mix sagents.setup` (or the relevant generators) on a clean, committed workspace and merge customizations back in. The generator now emits a new `agent_subscriber_session.ex` template; `coordinator.ex` and `agent_live_helpers.ex` are substantially trimmed.
3. Existing `handle_info/2` clauses keep matching — event payload shapes (`{:agent, _}`, `{:file_system, _}`, `{:status_changed, _, _}`, `{:llm_deltas, _}`, etc.) are unchanged.

**SubAgent argument rename (PR [#78](https://github.com/sagents-ai/sagents/pull/78)):** The `task` and `get_task_instructions` tools now take `task_name` instead of `subagent_type`. The available-tasks listing moved out of the `task` tool's description into an `## Available Tasks` system-prompt section (suppressible via the new `:include_task_list` option).

To migrate:
1. **Persisted state:** No action needed if you use `Sagents.Persistence.StateSerializer.deserialize_server_state/2`. The serializer bumps the on-disk format to v2 and auto-rewrites `"subagent_type"` → `"task_name"` on stored `task` / `get_task_instructions` tool-call arguments.
2. **Pattern matches on interrupt data:** Rename the key in any match like `%{type: :subagent_hitl, subagent_type: type, sub_agent_id: id}` to `task_name`. Shape is otherwise unchanged.
3. **Resume-info maps:** Callers building `context.resume_info` for sub-agent resume must use `:task_name` instead of `:subagent_type`.
4. **Custom prompts:** Update any prompt or doc referencing the old `subagent_type` argument or "Available SubAgents" wording — the new section is `## Available Tasks` and the argument is `task_name`. `get_task_instructions` is now `async: false`, so the model blocks until the usage guide is returned.

### Added
- Optional `debug_summary/1` callback on the `Sagents.Middleware` behaviour — middleware authors can return a small map or string for the live debugger to render instead of `inspect/2` on the full config. Implemented for `SubAgent` middleware to drop the heavy `agent_map` from the debugger's Middleware tab [#80](https://github.com/sagents-ai/sagents/pull/80)
- `:include_task_list` option on `SubAgent` middleware (default `true`) — opt out of rendering the auto-generated task menu when integrators want to drive task selection externally [#78](https://github.com/sagents-ai/sagents/pull/78)
- `Sagents.Publisher` and `Sagents.Subscriber` modules — new direct-delivery transport replacing Phoenix.PubSub, with `:initial_subscribers` start option to enroll subscribers inside `init/1` and a Presence-based recovery loop for crash-restart and Horde migration [#79](https://github.com/sagents-ai/sagents/pull/79)
- New `agent_subscriber_session.ex` generator template — captures the LiveView subscribe/recovery lifecycle in one place [#79](https://github.com/sagents-ai/sagents/pull/79)
- `docs/subscriptions_and_presence.md` — documents the Publisher/Subscriber model, `:initial_subscribers`, and the five lifecycle scenarios [#79](https://github.com/sagents-ai/sagents/pull/79)

### Changed
- **BREAKING:** SubAgent middleware tools (`task`, `get_task_instructions`) now take `task_name` instead of `subagent_type`. Interrupt-data and resume-info maps use `:task_name`. Persisted v1 state is migrated to v2 automatically by `StateSerializer` [#78](https://github.com/sagents-ai/sagents/pull/78)
- **BREAKING:** `Sagents.PubSub` removed. Agent and FileSystem events now flow over `Sagents.Publisher` / `Sagents.Subscriber` instead of `Phoenix.PubSub`. Generator templates (`coordinator.ex`, `agent_live_helpers.ex`) updated [#79](https://github.com/sagents-ai/sagents/pull/79)
- `get_task_instructions` is now `async: false` — the model waits for the usage guide before calling `task` [#78](https://github.com/sagents-ai/sagents/pull/78)
- Available sub-agents now rendered as an `## Available Tasks` section in the middleware system prompt instead of being inlined into the `task` tool description [#78](https://github.com/sagents-ai/sagents/pull/78)
- Bumped `langchain` dependency to `>= 0.8.4` to pick up the stabilized `delta_conversion_failed` error type [#77](https://github.com/sagents-ai/sagents/pull/77)

### Fixed
- Friendlier user-facing message when the LLM returns a malformed streaming delta — `delta_conversion_failed` errors now render a short "please try again" message instead of leaking internal jargon. Applied in both `AgentServer` and the generated `agent_live_helpers.ex` template [#77](https://github.com/sagents-ai/sagents/pull/77)
- Doc-generation warning resolved [#75](https://github.com/sagents-ai/sagents/pull/75)

## v0.7.0

Introduces first-class scope propagation across all integration boundaries — persistence, file system callbacks, and message preprocessing — so multi-tenant and authorization-aware applications can stop threading scope through `tool_context` workarounds. Also adds a configurable `max_run` guard on agents and sub-agents, fixes a bug where `on_server_start` state updates were silently discarded, hardens the FileSystem line-number semantics, and patches several generator template issues.

**Breaking changes** — see Upgrading section below.

### Upgrading from v0.6.0 to v0.7.0

A `MIGRATION_PROMPT_v0.6.0_TO_v0.7.0.md` file is included in the repository root. Give it to your coding assistant — it contains exact before/after signatures, step-by-step instructions, and coverage of non-obvious call sites (tests, direct calls, tool functions that previously used the `tool_context` scope workaround).

The four affected behaviour modules are `AgentPersistence`, `DisplayMessagePersistence`, `FileSystemCallbacks`, and `MessagePreprocessor` — every callback in each gains `scope` as a new first positional argument. The `AgentPersistence` context argument also changed from a bare atom/string to a typed map. The Coordinator call site gains a `scope:` option that must be threaded through from the caller.

For generated files, re-run `mix sagents.setup` with the same options on a clean, committed workspace, accept the overwrites, and merge your customizations back in with a diff tool.

### Added
- First-class `scope` field on `Agent` — an integrator-defined scope struct (e.g., `%MyApp.Accounts.Scope{}`) that is propagated as the first positional argument to all persistence callbacks and auto-merged into tool-call `custom_context` under the `:scope` key. Not serialized — scope is session/runtime state from the caller, not stored state. [#72](https://github.com/sagents-ai/sagents/pull/72)
- `max_run` configuration option on `Agent` and `SubAgent` — limits the maximum number of LLM rounds before the agent stops with a user-friendly error message. Catches exception cases and provides clearer log messages when the limit is exceeded [#69](https://github.com/sagents-ai/sagents/pull/69)
- `AgentPersistence` typed context maps — `persist_context` (`%{agent_id, conversation_id, lifecycle}`) and `load_context` (`%{agent_id, conversation_id}`) replace the old bare `agent_id` string, providing conversation identity and lifecycle reason at every persistence call site [#72](https://github.com/sagents-ai/sagents/pull/72)
- `DisplayMessagePersistence` typed `callback_context` map — `%{agent_id, conversation_id}` replaces the ad-hoc context previously passed to callbacks [#72](https://github.com/sagents-ai/sagents/pull/72)
- Line-number rules section in the `FileSystem` middleware system prompt — emitted only when at least one line-aware edit tool (`replace_file_text`, `replace_file_lines`) is enabled, explaining `cat -n` prefix semantics, 1-based numbering, line-shift after edits, and trailing-newline behavior [#71](https://github.com/sagents-ai/sagents/pull/71)
- Post-edit preview returned by `replace_file_text` and `replace_file_lines` — the updated file content is returned immediately after an edit, eliminating the follow-up `read_file` call the agent previously needed [#71](https://github.com/sagents-ai/sagents/pull/71)

### Changed
- **BREAKING:** `AgentPersistence` callbacks `persist_state/3` and `load_state/1` now take `scope` as their first positional argument and use typed context maps instead of a bare `agent_id` string [#72](https://github.com/sagents-ai/sagents/pull/72)
- **BREAKING:** `DisplayMessagePersistence` callbacks (`save_message`, `update_tool_status`, `resolve_tool_result`) now take `scope` as their first positional argument [#72](https://github.com/sagents-ai/sagents/pull/72)
- **BREAKING:** `FileSystemCallbacks` callbacks (`on_write`, `on_read`, `on_delete`, `on_list`) now take `scope` as their first positional argument; optional callback arity for each updated accordingly [#72](https://github.com/sagents-ai/sagents/pull/72)
- **BREAKING:** `MessagePreprocessor.preprocess/2` is now `preprocess/3` with `scope` as the first positional argument [#72](https://github.com/sagents-ai/sagents/pull/72)
- Generator templates updated across the board for scope-first callbacks — `coordinator.ex.eex`, `factory.ex.eex`, `agent_persistence.ex.eex`, `display_message_persistence.ex.eex`, `agent_live_helpers.ex.eex`, and the persistence context template [#72](https://github.com/sagents-ai/sagents/pull/72) [#73](https://github.com/sagents-ai/sagents/pull/73)
- `SubAgent.task_subagent_boilerplate/0` made public with full documentation — previously undocumented despite being referenced in module docs [#66](https://github.com/sagents-ai/sagents/pull/66)
- `docs/persistence.md` and `docs/tool_context_and_state.md` rewritten to reflect the scope-first contract, updated callback signatures, and the new Coordinator integration pattern [#73](https://github.com/sagents-ai/sagents/pull/73)
- Updated LangChain dependency to `>= 0.8.2` [#71](https://github.com/sagents-ai/sagents/pull/71)

### Fixed
- `AgentServer` now threads `on_server_start/2` return values through the middleware chain and applies the accumulated state — previously the state returned by each middleware was silently discarded and middleware couldn't observe each other's startup changes [#67](https://github.com/sagents-ai/sagents/pull/67)
- Generated `load_display_messages` context function no longer applies a result-count limit by default, preventing longer conversations from losing new messages on reload [#68](https://github.com/sagents-ai/sagents/pull/68)
- `FileSystemServer` now handles `{:EXIT, port, reason}` in `handle_info/2` when `trap_exit` is enabled — port exits from `System.cmd` during persistence callbacks were crashing the server [#70](https://github.com/sagents-ai/sagents/pull/70)
- FileSystem `replace_file_text` and `replace_file_lines` line-number semantics corrected to be consistently 1-based across `read_file`, `replace_file_lines`, and `find_in_file` [#71](https://github.com/sagents-ai/sagents/pull/71)

## v0.6.0

Brings task-style sub-agents with dramatically improved cancellation handling, parent→sub-agent context propagation, a trimmer and more focused FileSystem middleware, and a handful of middleware configurability improvements. Also hardens CI against supply-chain risks.

**Breaking changes** — see Upgrading section below.

### Upgrading from v0.5.1

**FileSystem tool renames:** Three tools on the `FileSystem` middleware were renamed to namespace them away from app-/domain-specific tools and to clarify their scope. If you list tools explicitly via `:enabled_tools`, or reference these names elsewhere, update them:

- `replace_text` → `replace_file_text`
- `replace_lines` → `replace_file_lines`
- `search_text` → `find_in_file` (also now searches a single file, not across the whole filesystem)

**FileSystem tool config is now validated:** `:enabled_tools` and `:custom_tool_descriptions` now reject unknown tool names at `init/1` instead of silently ignoring them. Any lingering typos or references to retired tool names will now raise at agent startup. This is the most likely place you'll hit the renames above.

**Display-message persistence adds `:cancelled` tool status:** If you have generated display-message persistence templates (via `mix sagents.gen.persistence`), re-run the generator (after committing your current code) and merge the new `update_tool_status(:cancelled, ...)` clause and `cancel_tool_call/1` context function. Existing persistence modules without these will crash when the new AgentServer cancel path fires.

### Added
- Task-style sub-agent interface — new `instructions`, `system_prompt_override`, `use_instructions`, and `display_text` fields on `SubAgent.Config`, composed into the child's system prompt by `compose_child_system_prompt/1`. The built-in `task_subagent_boilerplate/0` encodes the "no user, complete-or-fail, no clarifying questions" framing universally so authors can focus on task specifics [#60](https://github.com/sagents-ai/sagents/pull/60)
- `Sagents.SubAgent.Task` behaviour — formal contract for task modules (`task_name/0`, `description/0`, `instructions/0`, plus optional `use_instructions/0`, `display_text/0`, `model_override/0`) that host applications compile into `SubAgent.Compiled` entries [#60](https://github.com/sagents-ai/sagents/pull/60)
- `get_task_instructions(subagent_type)` tool on the SubAgent middleware — surfaced automatically when any configured sub-agent declares `use_instructions`. Lets the parent LLM lazy-load full usage docs on demand so the parent's context window stays light [#60](https://github.com/sagents-ai/sagents/pull/60)
- Dynamic `display_text` for SubAgent tool calls — when a sub-agent config declares `display_text`, the middleware re-fires the `on_tool_call_identified` event once `subagent_type` is known so the UI shows something meaningful (e.g. "Drafting KB article") instead of the generic "Running task" [#60](https://github.com/sagents-ai/sagents/pull/60)
- Parent-agent context propagation to SubAgents — `tool_context` and `state.metadata` from the parent now flow automatically into spawned sub-agents, so data like `user_id`, `current_scope`, tenant identifiers, and `conversation_title` is visible to tools running inside a SubAgent without manual wiring. New `:parent_tool_context` and `:parent_metadata` options on both `SubAgent.new_from_config` and `new_from_compiled` make the inheritance explicit and testable [#59](https://github.com/sagents-ai/sagents/pull/59)
- `:tool_context` key on `custom_context` — `Agent.build_chain` now preserves the original caller-supplied `tool_context` map as an explicit key (in addition to the existing flat merge) so nested extraction is unambiguous [#59](https://github.com/sagents-ai/sagents/pull/59)
- `docs/tool_context_and_state.md` — new guide explaining the two context channels, how each propagates, and when to use which [#59](https://github.com/sagents-ai/sagents/pull/59)
- Proper sub-agent unwinding on main-agent cancel — `AgentServer.cancel/1` now kills in-flight sub-agents first, does a two-phase Task shutdown (2s graceful, then brutal-kill), drains pending turn casts so the rolling state captures every completed turn, and persists the cancellation display message from AgentServer as the single authoritative writer [#60](https://github.com/sagents-ai/sagents/pull/60)
- `:on_cancel` persistence context on `Sagents.AgentPersistence` — new lifecycle hook so apps can snapshot state when a main agent is cancelled, enabling page-reload recovery of partial progress [#60](https://github.com/sagents-ai/sagents/pull/60)
- `:cancelled` tool-status variant on `Sagents.DisplayMessagePersistence` and the generator templates — the cancelled state is now a first-class tool-call terminal status alongside `:completed` and `:error` [#60](https://github.com/sagents-ai/sagents/pull/60)
- Sub-agent failure and cancellation broadcasts now carry `final_messages` and `turn_count` — the debugger and UI can render "last N messages before failure" alongside the error. When a sub-agent is blocked mid-LLM-call and can't respond within 300ms, a minimal fallback broadcast is fired so observability is preserved either way [#60](https://github.com/sagents-ai/sagents/pull/60)
- `execution_seq` counter on SubAgent `ServerState` — guards the rolling-state `handle_cast` against late messages from a cancelled or superseded run [#60](https://github.com/sagents-ai/sagents/pull/60)
- `Sagents.TextLines` module — extracted from the FileSystem middleware, provides reusable 1-indexed line-number splitting, rendering (right-aligned 6-char numbers + tab separator), and range operations for any tool that needs consistent line-numbered text handling [#58](https://github.com/sagents-ai/sagents/pull/58)
- `:custom_display_texts` option on the `FileSystem` middleware — per-tool UI label overrides [#58](https://github.com/sagents-ai/sagents/pull/58)
- `:display_text` option on the `TodoList` middleware — customizes the UI label on the `write_todos` tool (defaults to "Updating task list"). Useful when todos are used internally by an agent and the default label would leak implementation detail to end users [#52](https://github.com/sagents-ai/sagents/pull/52)
- `:enabled` option on the `DebugLog` middleware (default: `true`) — when `false`, every callback is a noop via pattern-matching function heads, so the middleware stays in the stack for easy re-enablement but performs zero I/O and registers no LLM event callbacks. Recommended for production via `Application.compile_env` [#53](https://github.com/sagents-ai/sagents/pull/53)
- Anthropic cache control enabled in the generated `factory.ex` template — new factories created by `mix sagents.setup` now turn on automatic Anthropic prompt caching on the main orchestrator agent out of the box [#64](https://github.com/sagents-ai/sagents/pull/64)
- `wait_until/2` helper in `Sagents.TestingHelpers` — general-purpose polling helper (10ms interval, 1s timeout) for synchronizing tests against async state changes like registry cleanups and ETS writes. Intended call pattern: `assert wait_until(fn -> condition end)` [#57](https://github.com/sagents-ai/sagents/pull/57)
- SHA-pinned GitHub Actions in `.github/workflows/elixir.yml` with `persist-credentials: false` on checkout, and a new `.github/dependabot.yml` for weekly action updates with a 7-day cooldown — addresses zizmor's unpinned-action and credential-persistence recommendations [#60](https://github.com/sagents-ai/sagents/pull/60)

### Changed
- **BREAKING:** `FileSystem` middleware tools renamed: `replace_text` → `replace_file_text`, `replace_lines` → `replace_file_lines`, `search_text` → `find_in_file` (now operates on a single file instead of scanning the whole filesystem) [#55](https://github.com/sagents-ai/sagents/pull/55), [#58](https://github.com/sagents-ai/sagents/pull/58)
- **BREAKING:** `FileSystem` middleware now validates `:enabled_tools` and `:custom_tool_descriptions` at `init/1` and raises on unknown tool names. Previously invalid entries were silently ignored [#55](https://github.com/sagents-ai/sagents/pull/55)
- `FileSystem` middleware system prompt is trimmed to only describe the tools actually enabled via `:enabled_tools` — no more describing tools the LLM can't call [#58](https://github.com/sagents-ai/sagents/pull/58)
- Cancellation display message is now persisted by `AgentServer` instead of the LiveView — avoids duplicate rows when multiple tabs are subscribed to the same conversation. Generator templates updated accordingly so `handle_status_cancelled/1` no longer inserts the message itself [#60](https://github.com/sagents-ai/sagents/pull/60)
- SubAgent construction paths (`new_from_config` and `new_from_compiled`) collapsed into a shared `build_subagent/3` helper — a single enforcement point for parent-context propagation and a cleaner extension point for future sub-agent variants [#59](https://github.com/sagents-ai/sagents/pull/59)
- `docs/filesystem_setup.md` rewritten — adds a "What the Filesystem Is For" section explaining what the FileSystem is and, more importantly, what it isn't, with a worked draft-then-commit pattern for splitting content (file) from metadata (domain record) across two tool calls so generated tokens aren't thrown away on metadata validation errors [#58](https://github.com/sagents-ai/sagents/pull/58)
- `mix precommit` now runs `test --include cluster --include slow` so the new slow-tagged sub-agent cancellation integration test runs on every precommit [#60](https://github.com/sagents-ai/sagents/pull/60)

### Fixed
- Flaky `Sagents.SubAgentHitlIntegrationTest` — the race was in `Sagents.ProcessRegistry`'s async `:DOWN` handling, not in `SubAgentServer.stop/1`. Replaced the direct `whereis == nil` assertion with `wait_until`, and replaced a `Process.sleep(50)` workaround elsewhere in the file with `Process.monitor` + `assert_receive {:DOWN, ...}` + `wait_until` for the registry cleanup [#57](https://github.com/sagents-ai/sagents/pull/57)
- `LangChainError` type/message distinctions are now preserved when sub-agent errors surface to the parent LLM (via `format_subagent_error/2`) — previously the structure was flattened [#60](https://github.com/sagents-ai/sagents/pull/60)

## v0.5.0

Adds infrastructure pause/resume support for node draining, a new `DebugLog` middleware for local file-based agent diagnostics, broader LLM error visibility via new callbacks, and updates the LangChain dependency to v0.8.0. No breaking changes at the sagents API level. All sagents-level changes are additive and backward-compatible; users who directly import `LangChain.*` modules should review the LangChain 0.8.0 release notes for any transitive changes. [#50](https://github.com/sagents-ai/sagents/pull/50)

### Added
- `DebugLog` middleware - a new built-in middleware that writes a structured debug log file of agent execution (messages, tool calls, errors, state transitions), useful for post-hoc troubleshooting without wiring up PubSub subscribers
- `{:pause, state}` execution result on `Agent.execute/3` - propagates infrastructure pause signals from the LLMChain (e.g., node draining) without treating them as errors or completions. Returned alongside the existing `{:ok, _}`, `{:interrupt, _, _}`, and `{:error, _}` cases
- `:paused` status on `AgentServer` - added to the `@type status` union (`:idle | :running | :interrupted | :paused | :cancelled | :error`). `AgentServer` handles `{:pause, state}` by persisting state, broadcasting `{:status_changed, :paused, nil}`, updating presence, and resetting the inactivity timer so the agent can be resumed after restart
- `on_llm_error` callback wired into `AgentServer` - broadcasts a debug event `{:llm_error, error}` on the debug PubSub channel for *every* individual LLM API call failure, including transient errors that the chain subsequently recovers from via retry or fallback
- `on_error` callback wired into `AgentServer` - broadcasts `{:chain_error, error}` on the main PubSub channel when the chain hits a terminal error after all retries and fallbacks are exhausted
- Error logging when a middleware's `on_server_start/2` callback returns `{:error, reason}` - the `AgentServer` now logs which middleware failed and the reason, and continues starting the server rather than silently ignoring the failure

### Changed
- Updated LangChain dependency from `>= 0.7.0` to `>= 0.8.0`, which brings expanded and improved error handling and the `on_llm_error` / `on_error` callback hooks that this release surfaces through `AgentServer`

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
