# Changelog

## v0.8.0-rc.11

No breaking changes from `v0.8.0-rc.10`. See the `v0.8.0-rc.9` entry below for upgrading from `v0.8.0-rc.8`, the `v0.8.0-rc.5` entry for upgrading from `v0.8.0-rc.4`, and the `v0.8.0-rc.1` entry for upgrading from `v0.7.0`.

Headline: middleware callbacks now fire on every agent entry point, not just the server paths.

### Added
- `Sagents.AgentUtils.resolve_callbacks/2` as the single source of truth for the callback merge policy (always self-collect middleware callbacks for the given middleware list, then merge any caller-supplied callbacks on top). `Sagents.Extract.run/3` gains a `:callbacks` option that flows through the same path. [#121](https://github.com/sagents-ai/sagents/pull/121)

### Changed
- Middleware callbacks are now self-collected on every entry point. `Agent.execute/3`, `SubAgent.execute`, and `Sagents.Extract` collect their own (or inherited) middleware callbacks and merge caller-supplied `:callbacks` on top rather than substituting them, so middleware hooks no longer go dark on direct (non-server) execution paths. `AgentServer`/`SubAgentServer` now pass only their PubSub callbacks, eliminating the previous double-collection. [#121](https://github.com/sagents-ai/sagents/pull/121)
- Upgraded to Elixir 1.20 and cleaned up the resulting compiler warnings and dead code. [#122](https://github.com/sagents-ai/sagents/pull/122)

## v0.8.0-rc.10

No breaking changes from `v0.8.0-rc.9`. See the `v0.8.0-rc.5` entry below for upgrading from `v0.8.0-rc.4`, and the `v0.8.0-rc.1` entry for upgrading from `v0.7.0`.

Headline: fixes a stale-interrupt bug where a dismissed or superseded interrupt's derived host state (e.g. a `:pending_halt` from the `v0.8.0-rc.9` halt feature) could survive invisibly behind a `status == :interrupted` render guard and re-appear on the next transition back into `:interrupted`.

### Recommended for host apps using `Sagents.Middleware.Haltable`

This release is not a hard breaking change — existing generated modules keep compiling and running. But the fix lives in the generated templates, so host apps that previously ran `mix sagents.gen.persistence` or generated the subscriber session **will not pick it up automatically**. This matters most if you use (or intend to use) the `Sagents.Middleware.Haltable` middleware introduced in `v0.8.0-rc.9`, since the stale `:pending_halt` state is exactly what leaks across transitions.

To get the fix, regenerate your sagents scaffolding and merge in the changes from [#119](https://github.com/sagents-ai/sagents/pull/119): merge `Sagents.AgentUtils.cleared_interrupt_changes/0` into every non-interrupted status handler in your `agent_subscriber_session.ex`, and route `load_todos/2` through `Sagents.Todo.list_from_maps/1` in your persistence context.

### Added
- `Sagents.AgentUtils.cleared_interrupt_changes/0` — the single source of truth for the complete set of interrupt-derived `pending_*` keys a host carries (`pending_tools`, `pending_question`, `pending_halt`, `remaining_questions`, `question_responses`, `hitl_decisions`, `interrupt_data`). Merge it into any status transition that lands on a non-interrupted status (`:running`, `:idle`, `:cancelled`, `:error`, `:not_running`) to enforce the invariant that any status other than `:interrupted` means there is no pending interrupt UI. [#119](https://github.com/sagents-ai/sagents/pull/119)

### Fixed
- A dismissed or superseded interrupt's derived host state could persist behind a `status == :interrupted` render guard and re-surface on the next transition back into `:interrupted`. `Sagents.AgentUtils.interrupt_session_changes/1` now explicitly clears `pending_halt` when deriving both `:ask_user_question` and HITL-tool session changes, and the generated subscriber-session status handlers (`handle_status_running/0`, `handle_status_idle/0`, `handle_status_cancelled/0`, `handle_status_error/1`, `handle_agent_shutdown/2`) merge `cleared_interrupt_changes/0` so stale `pending_*` keys never leak across transitions. [#119](https://github.com/sagents-ai/sagents/pull/119)
- The generated persistence context's `load_todos/2` now routes restored todo maps through `Sagents.Todo.list_from_maps/1` instead of mapping each through `Todo.from_map/1`, so legacy and partial snapshots rehydrate with positional id defaults rather than being silently dropped. [#119](https://github.com/sagents-ai/sagents/pull/119)
- Corrected `@doc`/`@typedoc` cross-references in `Sagents.AgentResult`, `Sagents.Extract`, and `Sagents.Middleware.Haltable` (e.g. `Agent.execute/3` → `Sagents.Agent.execute/3`) so they resolve and no longer emit ExDoc warnings. [#118](https://github.com/sagents-ai/sagents/pull/118)

## v0.8.0-rc.9

**Breaking change** in PR [#116](https://github.com/sagents-ai/sagents/pull/116) — `Sagents.Todo` IDs are now integers instead of strings. See the upgrading section below, and the v0.8.0-rc.5 entry for upgrading from `v0.8.0-rc.4`, and the `v0.8.0-rc.1` entry for upgrading from `v0.7.0`.

Headline: a new terminal `:halt` interrupt type via `Sagents.Middleware.Haltable` lets tools hard-stop an agent workflow instead of pausing for a response, and `Sagents.Todo` IDs become integers to fix lexicographic sort ordering on long Todo lists.

### Upgrading from v0.8.0-rc.8 to v0.8.0-rc.9

This is a breaking change for any host app that has already generated the persistence scaffolding via `mix sagents.gen.persistence`. The template change only affects new generations; existing generated modules will reject every `todo_snapshot` insert with `"todo_snapshot has invalid todo entries"` until patched.

In your generated `DisplayMessage` schema module (e.g. `MyApp.Conversations.DisplayMessage`), update the `valid_todo_entry?/1` clause:

```elixir
# Before
defp valid_todo_entry?(%{"id" => id, "content" => content, "status" => status})
     when is_binary(id) and is_binary(content) and is_binary(status) do
  status in @todo_statuses
end

# After
defp valid_todo_entry?(%{"id" => id, "content" => content, "status" => status})
     when is_integer(id) and is_binary(content) and is_binary(status) do
  status in @todo_statuses
end
```

**CHANGE:** Change the guard clause from `is_binary(id)` to `is_integer(id)`.

Host-app callers of `Sagents.Todo.new/1`, `State.get_todo/2`, or `State.delete_todo/2` that pass string ids will also need to switch to integers. Code that builds todos from incoming maps should migrate to `Todo.list_from_maps/1`, which handles missing/non-numeric ids via positional defaults (1..N) and coerces stringified integers (`"5"`) for JSON tool-call payloads. Persisted snapshots with legacy base64 string ids rehydrate cleanly via the updated `StateSerializer` — those ids are replaced with positional defaults on load rather than failing the changeset.

### Added
- `:halt` as a first-class terminal interrupt type, owned by the new `Sagents.Middleware.Haltable`. Tools can hard-stop a workflow (e.g. a gating validation tool) without giving the LLM a chance to plow ahead. The halt is dead on emit (no resume payload, no LLM re-invocation), its `:message` persists as a synthetic assistant transcript entry, and the user's next free-text message demotes it via `State.cancel_pending_interrupts/1`. A new `AgentServer.dismiss_interrupt/1` lets UIs acknowledge the halt without sending a message. A `[:sagents, :agent, :halt]` telemetry event fires on emit. "Halt wins" is enforced inside `:multiple_interrupts` wrappers at restore, render, and demotion time. Cold-start re-surface re-emits the interrupt without double-persisting the transcript. [#115](https://github.com/sagents-ai/sagents/pull/115)
- `Sagents.Todo.list_from_maps/1` as the canonical ingest point for any list of incoming todo data (tool calls, persisted state, rehydrate). Assigns positional id defaults for missing/non-numeric ids, coerces numeric-string ids, and preserves valid integer ids. [#116](https://github.com/sagents-ai/sagents/pull/116)

### Changed
- `Sagents.Todo.id` is now an `:integer` field instead of `:string`. Long todo lists (10+ items) used to sort incorrectly because `"10"` sorted before `"2"`. `Todo.new/1` now requires a positive integer id and validates `greater_than: 0`. `State.get_todo/2` and `State.delete_todo/2` switch their guards from `is_binary` to `is_integer`. The `write_todos` tool schema declares `id` as `integer`, and inline-mode `todo_snapshot` content emits integer ids. The `mix sagents.gen.persistence` template's `valid_todo_entry?/1` guard is updated in lockstep. [#116](https://github.com/sagents-ai/sagents/pull/116)
- `StateSerializer.deserialize/1` routes the `todos` array through `Todo.list_from_maps/1` so legacy snapshots with random base64 string ids rehydrate with positional ids instead of crashing the changeset. In-list order is preserved; original legacy identity is lost. [#116](https://github.com/sagents-ai/sagents/pull/116)
- `Sagents.Middleware` documents the full interrupt-data catalog (`:ask_user_question`, `:halt`, `:subagent_hitl`, HITL action-request map, `:multiple_interrupts`) and the halt-wins policy. The generated `agent_subscriber_session.ex.eex` template adds `pending_halt: nil` to subscriber session assigns so new projects get the field for free. [#115](https://github.com/sagents-ai/sagents/pull/115)

## v0.8.0-rc.8

No breaking changes from `v0.8.0-rc.7`. See the v0.8.0-rc.5 entry below for upgrading from `v0.8.0-rc.4`, and the `v0.8.0-rc.1` entry for upgrading from `v0.7.0`.

This RC fixes a `FunctionClauseError` in `Sagents.StreamingSession` when a tool call pauses for human input, and surfaces middleware-initialization failures through an explicit error log.

### Changed
- `Sagents.Agent.new/2` now emits `Logger.error/1` when a middleware's `init/1` returns `{:error, reason}`, alongside the existing changeset error. The changeset error contract is unchanged, so host apps keep their current behavior, but those that don't introspect the changeset (or that wrap `Agent.new/2` behind layers that swallow the result) now get a grep-able signal that middleware init failed and why. [#113](https://github.com/sagents-ai/sagents/pull/113)

### Fixed
- `Sagents.StreamingSession.handle_tool_execution_update/3` now recognizes `:interrupted` as a first-class lifecycle status (paused, not terminal). Previously, when the LLM emitted a tool that pauses for input (e.g. `ask_user` or a HITL-gated sub-agent tool), `Sagents.AgentServer` broadcast `{:tool_execution_update, :interrupted, …}` and any host forwarding it into `StreamingSession` crashed with `FunctionClauseError`. The interrupted call now writes `"interrupted"` into `execution_status`, forwards `tool_info[:display_text]` (so callers can render labels like "Waiting for user"), and preserves `:streaming_delta` so the interrupted call and its siblings keep their UI state until the call resumes and reaches a terminal status. The `@type lifecycle_status` union and moduledoc were extended accordingly. [#112](https://github.com/sagents-ai/sagents/pull/112)

## v0.8.0-rc.7

**Breaking change** in PR [#110](https://github.com/sagents-ai/sagents/pull/110) — the `replace_file_lines` tool is removed from `Sagents.Middleware.FileSystem`. See the v0.8.0-rc.5 entry below for upgrading from `v0.8.0-rc.4`, and the v0.8.0-rc.1 entry for upgrading from `v0.7.0`.

Headline: structured data extraction through the full agent middleware stack via the new `Sagents.Extract` module, with `Sagents.AgentResult` as the supporting reader for `Agent.execute/3` return shapes.

### Upgrading from v0.8.0-rc.6 to v0.8.0-rc.7

If your project's agents rely on `replace_file_lines` (e.g. it appears in your `FileSystem` middleware config, prompts, or evals), you have two options:

1. Drop it — `replace_file_text` covers the same use cases for most agents.
2. Re-add it as a project-local tool. The previous implementation lives in the PR [#110](https://github.com/sagents-ai/sagents/pull/110) diff and can be lifted into your own middleware or `Function`.

If your config passes `tools:` or `tool_descriptions:` to `Sagents.Middleware.FileSystem` and includes `"replace_file_lines"`, remove that entry.

### Added
- `Sagents.Extract` — structured extraction that flows through the agent's middleware stack. [#108](https://github.com/sagents-ai/sagents/pull/108)
- `Sagents.AgentResult` — read helpers for pulling tool results, arguments, processed content, or final text out of `Agent.execute/3` return values. [#107](https://github.com/sagents-ai/sagents/pull/107)
- `Sagents.FileSystemServer.get_state/1` introspection helper. [#109](https://github.com/sagents-ai/sagents/pull/109)
- `sobelow` and `mix_audit` wired into `mix precommit`. [#106](https://github.com/sagents-ai/sagents/pull/106)

### Changed
- Trimmed the default `FileSystem` middleware tool set: `replace_file_lines` (and the `TextLines.replace_range/4` helper) removed in favor of letting projects add specialized editors as needed. [#110](https://github.com/sagents-ai/sagents/pull/110)
- Bumped `langchain` floor to `>= 0.8.11` and updated lock past the vulnerable `decimal` version. [#106](https://github.com/sagents-ai/sagents/pull/106)

### Fixed
- Flaky CI test `"subscriber crash auto-cleans subscription"`. [#109](https://github.com/sagents-ai/sagents/pull/109)

## v0.8.0-rc.6

No breaking changes from `v0.8.0-rc.5`. See the v0.8.0-rc.5 entry below for upgrading from `v0.8.0-rc.4`, and the v0.8.0-rc.1 entry for upgrading from `v0.7.0`.

This RC focuses on inline todo snapshots in the chat transcript, per-call sub-agent message seeding, and hardening lifecycle calls against races (server shutdown, Horde registry propagation, sibling tool calls in flight).

### Added
- Optional `:initial_messages` config on `Sagents.Middleware.SubAgent.start_subagent/5` for slotting per-call `%LangChain.Message{}` structs between the sub-agent's system messages and its user instruction. Supported uniformly across compiled, config-based, and dynamic general-purpose branches. [#100](https://github.com/sagents-ai/sagents/pull/100)
- `:inline` option on `Sagents.Middleware.TodoList` (default `false`). When enabled, each successful `write_todos` additionally persists a `content_type: "todo_snapshot"` synthetic display message into the transcript via `AgentServer.save_synthetic_message_from/2` — alongside, not in place of, the existing `{:todos_updated, _}` broadcast. [#101](https://github.com/sagents-ai/sagents/pull/101)
- `todo_snapshot` content type in the generated `DisplayMessage` persistence template, with structural validation against `Sagents.Todo` statuses and a `to_text/1` clause for search/indexing. Pairs with the new TodoList inline mode. [#102](https://github.com/sagents-ai/sagents/pull/102)
- New `Sagents.StreamingSession` module — host-agnostic helpers (`handle_tool_call_identified/2`, `handle_tool_execution_update/3`) extracted from the `agent_subscriber_session.ex.eex` template. Returns *changes maps* the host merges however it wants. The generated template now `defdelegate`s to it, so hosts inherit multi-tool-safe delta semantics automatically. [#104](https://github.com/sagents-ai/sagents/pull/104)

### Changed
- `Sagents.AgentServer` lifecycle action functions (`execute/1`, `cancel/1`, `resume/2`, `add_message/2`, `reset/1`) route through a new `safe_call/3` wrapper that returns `{:error, :agent_not_running}` instead of crashing the caller when the target server has shut down. Specs for `add_message/2` and `reset/1` widened to `:ok | {:error, term()}` accordingly. [#104](https://github.com/sagents-ai/sagents/pull/104)
- `:streaming_delta` is now only cleared once **every** tool call in the delta has reached a terminal status, so sibling tool calls still in flight keep their UI state. Behavioural change inherited by any host using the regenerated subscriber-session template. [#104](https://github.com/sagents-ai/sagents/pull/104)

### Fixed
- `FileSystemSupervisor.start_filesystem/3` now explicitly matches `{:error, {:already_started, pid}}` from `start_child/2` and surfaces the tuple verbatim after awaiting registry propagation, so the eventually-consistent Horde lookup-miss race resolves into a clean idempotent return instead of falling through to the generic error logger. [#104](https://github.com/sagents-ai/sagents/pull/104)
- `Sagents.Middleware.SubAgent` matches `{:error, {:already_started, _pid}}` in both `start_pre_configured_subagent` and the general-purpose path with a loud, distinct error — guards against the "shouldn't happen" duplicate-`subagent.id` case rather than failing silently. [#104](https://github.com/sagents-ai/sagents/pull/104)

## v0.8.0-rc.5

Headline feature: **interrupted agents now resume cleanly across process restart**. An agent that shut down (inactivity timeout, deploy, crash) while waiting on an `ask_user` question or a HITL approval now boots back into `:interrupted` status with the original question/approval intact, rather than silently demoting it to an error. This drove a public-API refactor (`Session` / `Factory` / `FactoryRouter`) that consolidates session-start mechanics into the library and gives per-request data a clean path through the factory.

**Breaking changes** in PRs [#94](https://github.com/sagents-ai/sagents/pull/94) and [#97](https://github.com/sagents-ai/sagents/pull/97). See Upgrading section below.

### Upgrading from v0.8.0-rc.4 to v0.8.0-rc.5

The breaking changes are concentrated in two PRs. The recommended migration path:

**1. Re-run the generators (PR [#97](https://github.com/sagents-ai/sagents/pull/97)).** On a clean, committed workspace, run `mix sagents.setup` with the same options you used originally and merge customizations back in. The setup task now generates a paired `Factory` + `FactoryConfig` + `FactoryRouter` triad in place of the single `factory.ex`, and the generated `coordinator.ex` shrinks from ~390 lines to a thin bridge over the new `Sagents.Session` module.

**2. Convert factory helpers to take `%FactoryConfig{}`.** Helpers that were `get_model/0` / `get_middleware/0` become `build_model/1` / `build_middleware/1` and branch on the config struct directly. Per-request data (timezone, tool_context, project records) flows through `request_opts → FactoryRouter.resolve/3 → %FactoryConfig{} → Factory.create_agent/2` instead of being threaded as positional args.

**3. Rename `ensure_session_running/1` → `ensure_agent_session_running/1`** at every call site (LiveViews, controllers, tests).

**4. Update `subscribe_debug` / `unsubscribe_debug` calls (PR [#94](https://github.com/sagents-ai/sagents/pull/94)).** Replace `AgentServer.subscribe_debug(agent_id)` with `AgentServer.subscribe(agent_id, :debug)`, and likewise for unsubscribe. The single-arg `subscribe(agent_id)` form keeps working unchanged.

**5. Opt middleware into restoration where appropriate (PR [#96](https://github.com/sagents-ai/sagents/pull/96)).** Existing built-in middleware are already configured: `AskUserQuestion` and `HumanInTheLoop` opt in, `SubAgent` deliberately does not (its interrupt holds a dead PID after restart). Custom middleware that produce restorable, data-only `interrupt_data` should implement `restorable_interrupt?/1` returning `true` for matching shapes. The default of `false` means existing custom middleware keeps the old (safe) demote-on-load behaviour with no code changes.

**6. Implement `set_interrupted/3` in your `AgentPersistence` module (PR [#96](https://github.com/sagents-ai/sagents/pull/96)).** The freshly-regenerated `agent_persistence.ex.eex` template includes a default implementation that mirrors the flag onto `conversation.metadata["interrupted"]`. If you hand-wrote your persistence module, add the callback so the cheap "is this conversation pending?" read works on mount without deserializing full state.

### Added
- Restorable interrupts: an agent that shut down with a pending `ask_user` question or HITL approval boots back into `:interrupted` status on restart, preserving the original `interrupt_data` instead of demoting it to an error. New optional `Sagents.Middleware.restorable_interrupt?/1` callback lets each middleware opt in (default `false` is the safe floor). [#96](https://github.com/sagents-ai/sagents/pull/96)
- `Sagents.Session` module owns session-start lifecycle (router consult, factory invocation, state seeding, supervisor wiring, subscribers). Idempotent on resume. [#97](https://github.com/sagents-ai/sagents/pull/97)
- `Sagents.Factory` and `Sagents.FactoryRouter` behaviours, plus `Sagents.Routers.Single` for one-factory apps. Per-request data flows through a typed `%FactoryConfig{}` struct. [#97](https://github.com/sagents-ai/sagents/pull/97)
- `Sagents.State.load_or_new/3,4` centralizes the load-or-fresh-state decision (lifted from generated coordinator); `:fresh_state_attrs` option seeds initial state on first run only, ignored on resume. [#96](https://github.com/sagents-ai/sagents/pull/96) [#97](https://github.com/sagents-ai/sagents/pull/97)
- Optional `set_interrupted/3` callback on `Sagents.AgentPersistence`, fired only on actual transitions of the durable interrupt flag. New `interrupted?/1` / `set_interrupt_status/3` in the generated persistence context provide a cheap pre-deserialization read. [#96](https://github.com/sagents-ai/sagents/pull/96)
- `Publisher.on_subscribed/3` overridable hook delivers a status snapshot the moment a `:main` subscriber registers, so a late-mounting LiveView surfaces a pending question without polling. [#96](https://github.com/sagents-ai/sagents/pull/96)
- `Sagents.AgentUtils` module lifts `interrupt_session_changes/1` and `advance_hitl_decisions/3` out of generated templates so generated code stays thin. [#96](https://github.com/sagents-ai/sagents/pull/96)
- Credo wired into `mix precommit` and the CI lint job; `.credo.exs` config with tuned complexity (`max_complexity: 12`) and nesting (`max_nesting: 3`) thresholds. [#93](https://github.com/sagents-ai/sagents/pull/93)

### Changed
- **BREAKING:** Public API restructured around the `Session` / `Factory` / `FactoryRouter` triad. Generated `coordinator.ex` collapses from ~390 lines of lifecycle ownership to a thin bridge; `factory.ex` becomes a `@behaviour Sagents.Factory` with `build_*` helpers taking the `%FactoryConfig{}` struct. `Coordinator.ensure_session_running/1` is renamed to `ensure_agent_session_running/1`. [#97](https://github.com/sagents-ai/sagents/pull/97)
- **BREAKING:** `AgentServer.subscribe_debug/1` and `unsubscribe_debug/1` removed in favor of parameterized `subscribe/3` and `unsubscribe/3` (channel and subscriber pid both optional). The single-arg form is unchanged; `:debug` channel and foreign-pid subscriptions now flow through one entry point. [#94](https://github.com/sagents-ai/sagents/pull/94)
- `StateSerializer` now round-trips `interrupt_data` (Base64-wrapped `term_to_binary` with `[:safe]` decoding); the higher-level cleaner with middleware context owns demotion decisions. Malformed payloads / unknown atoms collapse to `nil`, then through the standard demotion path. [#96](https://github.com/sagents-ai/sagents/pull/96)
- `Sagents.State.clean_stale_interrupts/2` takes a middleware list and consults each middleware's `restorable_interrupt?/1` per result. Empty middleware list still demotes everything (safe floor preserved). [#96](https://github.com/sagents-ai/sagents/pull/96)
- `AgentServer` boots in `:interrupted` status when the trailing tool-result placeholder survives the restorable-interrupt sweep, with `interrupt_data` rebuilt to look identical to a freshly-fired interrupt. Free-text user messages while `:interrupted` demote pending placeholders so the next LLM call is well-formed. Crashed-task `{:EXIT, ...}` now drives the agent to `:error` instead of leaving it stuck in `:running`. [#96](https://github.com/sagents-ai/sagents/pull/96)
- `Sagents.Subscriber` routes through `AgentServer.subscribe/3` instead of building via-tuples by hand, keeping resolution in one place. [#94](https://github.com/sagents-ai/sagents/pull/94)
- Documentation updates in `sagents.ex` moduledoc — replaced examples to reflect the new public API. [#92](https://github.com/sagents-ai/sagents/pull/92) [#95](https://github.com/sagents-ai/sagents/pull/95)
- New `docs/middleware.md` "Restorable Interrupts (After Process Restart)" section covering opt-in, the data-only restriction, and `:multiple_interrupts` semantics. [#96](https://github.com/sagents-ai/sagents/pull/96)
- Mechanical refactors across `lib/` and `test/` to satisfy Credo's tuned ruleset; no behavior changes. [#93](https://github.com/sagents-ai/sagents/pull/93)

## v0.8.0-rc.4

No breaking changes from `v0.8.0-rc.3`. See the v0.8.0-rc.1 entry below for upgrading from `v0.7.0`.

### Added
- `agent_id` is now a top-level key on tool execution context (`context.agent_id`), so tools can publish events back through the running `AgentServer` without reaching into `state`. Sub-agent tools receive the **parent** agent id (where subscribers actually live). [#86](https://github.com/sagents-ai/sagents/pull/86)
- `Sagents.AgentServer.save_synthetic_message_from/2` lets middleware persist user-facing transcript entries (e.g. an `ask_user` answer or a "User cancelled" note) through the same display-message pipeline LLM messages use, broadcast as `{:display_message_saved, msg}`. New optional `save_synthetic_message/3` callback on `DisplayMessagePersistence` plus a default generator template implementation. [#88](https://github.com/sagents-ai/sagents/pull/88)
- `AskUserQuestion` middleware now records the user's answer (selected option labels, freeform text, or cancellation) as a synthetic display message via the new hook, so reloading a conversation shows the answer alongside the question. [#89](https://github.com/sagents-ai/sagents/pull/89)
- Dialyzer is wired up via `dialyxir` and runs in CI on the lint matrix entry, with cached PLTs split across separate save/restore steps. New `.dialyzer_ignore.exs` file. [#90](https://github.com/sagents-ai/sagents/pull/90)

### Changed
- `Sagents.new/1` and `new!/1` are now explicit clauses with `@spec`s instead of `defdelegate`, so callers' Dialyzer runs see the public API's types. [#90](https://github.com/sagents-ai/sagents/pull/90)
- `StateSerializer.deserialize_state/2` unconditionally applies `State.clean_stale_interrupts/1`; the duplicate call in `State.from_serialized/2` was removed so there is one source of truth. [#89](https://github.com/sagents-ai/sagents/pull/89)
- Bumped `langchain` dependency floor to `>= 0.8.6`. [#90](https://github.com/sagents-ai/sagents/pull/90)

### Fixed
- Middleware-injected synthetic messages (e.g. a foundation-document preamble added in `before_model`) are now visible to debug subscribers that join mid-turn, and a mid-turn `get_state/1` reflects the post-middleware messages. The `on_after_middleware` callback now routes through the `AgentServer` GenServer instead of broadcasting from a frozen-snapshot closure. [#87](https://github.com/sagents-ai/sagents/pull/87)
- Recover cleanly from stale interrupt state on restart. A serialized `ToolResult` with `is_interrupt: true` is sanitized into an error result on deserialize (the `interrupt_data` virtual field cannot survive serialization), and a crashed execution `Task` in `AgentServer` now drives the agent to `:error` via a new `handle_info({:EXIT, ...})` clause instead of leaving it stuck in `:running`. The generated `agent_subscriber_session.ex.eex` template gains a `handle_status_interrupted(nil)` clause so subscribers can apply the result unconditionally. [#89](https://github.com/sagents-ai/sagents/pull/89)
- Several Dialyzer-surfaced issues: removed unreachable error branches in `Agent`, `HumanInTheLoop`, `state_serializer`, and `sub_agent_server`; corrected `Publisher.subscribe/3` and `unsubscribe/3` typespecs to allow a `nil` subscriber pid; `FileSystem.state_schema/0` returns `nil` instead of `[]`. [#90](https://github.com/sagents-ai/sagents/pull/90)

## v0.8.0-rc.3

No breaking changes from `v0.8.0-rc.2`. See the v0.8.0-rc.1 entry below for upgrading from `v0.7.0`.

### Added
- `Sagents.State.runtime` virtual field for middleware to stash process-local values that must never be persisted. Includes `merge_runtime/2` for shallow, module-namespaced merges. Sub-agent state inherits parent `runtime` so inherited middleware can re-apply propagators across the sub-agent process boundary. [#84](https://github.com/sagents-ai/sagents/pull/84)

### Changed
- `Sagents.Middleware.ProcessContext` now stores its snapshot under `state.runtime[ProcessContext]` instead of `state.metadata[ProcessContext]`. After a process restart the snapshot is gone and `on_server_start/2` re-captures from the new caller — the correct semantic, since stale OTel/tenant tokens from a dead process should not be re-applied. [#84](https://github.com/sagents-ai/sagents/pull/84)

## v0.8.0-rc.2

Adds a new `ProcessContext` middleware that propagates caller-process state (OpenTelemetry trace context, Sentry context, request-scoped Logger metadata, tenant scope, etc.) across the three Erlang process boundaries an agent invocation crosses: Caller → AgentServer GenServer, AgentServer → chain Task, and chain Task → per-tool async Task. Bumps the `langchain` floor to `>= 0.8.5` to pick up the new `:on_tool_pre_execution` callback the middleware depends on.

No breaking changes from `v0.8.0-rc.1`. See the v0.8.0-rc.1 entry below for upgrading from `v0.7.0`.

### Added
- `Sagents.Middleware.ProcessContext` middleware. Captures caller-process state once at `init/1` time and re-applies it on the receiving side of every process boundary. Two complementary configuration shapes that combine freely: `:keys` (list of process-dictionary keys for plain `Process.get` / `Process.put` propagation, e.g. `:sentry_context`) and `:propagators` (list of `{capture_fn, apply_fn}` pairs for state that lives behind a getter/setter API, e.g. `{&OpenTelemetry.get_current/0, &OpenTelemetry.attach/1}`). For long-lived conversation-scoped `AgentServer` processes, `ProcessContext.update/1` refreshes the snapshot between `add_message` calls without interleaving contexts inside a single execute loop. [#82](https://github.com/sagents-ai/sagents/pull/82)
- `docs/observability.md` "Propagating Caller Context Across Process Boundaries" section. Explains the three-boundary problem, both configuration shapes, the `update/1` refresh pattern, the within-execute consistency rule, and sub-agent inheritance. Also adds the new `:on_tool_pre_execution` callback to the LangChain callback reference table. [#82](https://github.com/sagents-ai/sagents/pull/82)
- `ProcessContext` row in the README built-in middleware table. [#82](https://github.com/sagents-ai/sagents/pull/82)

### Changed
- Bumped `langchain` dependency to `>= 0.8.5`. The new `ProcessContext` middleware relies on the `:on_tool_pre_execution` callback added in that release (it is the only callback that fires *inside* the per-tool async process, which is what makes propagation across boundary 3 correct). [#82](https://github.com/sagents-ai/sagents/pull/82)

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
