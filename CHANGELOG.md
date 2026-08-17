# Changelog

## v0.13.0

A stream that dies mid-flight now keeps the text the model already produced, and
the two transcript rows the framework writes itself — cancellation and error —
are classified rather than fabricated as assistant prose.

**Breaking for hosts that implement `save_synthetic_message/3`.** Those two rows
now take that callback instead of `save_message/3`, which changes their shape and
the event they broadcast. See
[#173](https://github.com/sagents-ai/sagents/pull/173) for the reasoning.

### Upgrading from v0.12.1 - v0.13.0

**If your persistence module does not implement `save_synthetic_message/3`**,
you keep the prose rows. Only the cancellation wording changed, to
"Agent execution cancelled." — the previous text claimed the partial response was
discarded, which overstated it.

**If it does**, three things change and need attention:

- Cancellation arrives as `content_type: "notification"` carrying
  `content["stop_reason"] = "cancelled"`; a failed turn as `content_type:
  "error"` carrying `content["error_type"]`. Both use `message_type: "system"`.
  Add renderers for them, or read `content["text"]`, which still carries readable
  English.
- These rows broadcast `{:display_message_saved, _}` **only**, not
  `{:llm_message, _}`. If you render cancellations live from the latter, switch.
- If you already render `content["stop_reason"]`, the cancellation row reuses the
  same key and value as a model message the caller stopped, so one branch covers
  both.

No migration. `"notification"` and `"error"` are already in the generated
`@content_types` and validate on `%{"text" => _}`, so the extra keys pass.

The dead-stream fix needs no host action at all.

### Added

- `content["error_type"]` on error rows, carrying the `LangChainError` type
  behind the failure (`"overloaded"`, `"exceeded_max_runs"`). Absent when the
  failure named none. [#173](https://github.com/sagents-ai/sagents/pull/173)
- `Sagents.Persistence.StateSerializer` carries a narrow projection of
  `LangChain.Message.metadata`, so `DisplayHelpers.streaming_error/1` and
  `stop_details/1` answer for restored history. The error's `:original` is not
  projected. Additive and unversioned — nothing to migrate.
  [#173](https://github.com/sagents-ai/sagents/pull/173)

### Changed

- **Cancellation and error rows are persisted via `save_synthetic_message/3`
  when the host implements it**, classified rather than written as assistant
  prose a host can neither style nor translate. A host without the callback keeps
  the previous behaviour. [#173](https://github.com/sagents-ai/sagents/pull/173)
- Those rows use `message_type: "system"`. They previously claimed
  `"assistant"`, asserting the model said something it did not.
  [#173](https://github.com/sagents-ai/sagents/pull/173)

### Fixed

- **A stream that died discarded the text the model had already produced.** The
  partial reaches the transcript marked
  `content["stop_reason"] = "stream_error"`, and `AgentServer`'s rolling state
  matches the chain. No host change needed.
  [#173](https://github.com/sagents-ai/sagents/pull/173)
- **A dead stream no longer also writes "Sorry, I encountered an error".** That
  row is written only when there was no partial to show.
  [#173](https://github.com/sagents-ai/sagents/pull/173)
- **A restored message classified as `:cancelled` when the stream had actually
  died.** LangChain below v0.10.0 records a dead stream as `:cancelled` plus
  `metadata[:streaming_error]`, where metadata was the only discriminator and did
  not survive persistence, so restored history reported a caller-initiated stop.
  [#173](https://github.com/sagents-ai/sagents/pull/173)

## v0.12.1

A message the model did not finish now leaves a trace in the display transcript.

Hitting the output token cap, a provider content filter, and a stream that dies
mid-flight all end a turn early without raising. The chain proceeds, nothing is
broadcast as an error, and the conversation stays usable. Nothing marked the
message, so a response truncated inside a collapsed thinking block was
indistinguishable from a hung agent: no error, no status change, and text simply
stopped arriving.

The information was never missing, it was dropped.
`DisplayHelpers.extract_display_items/1` narrowed a `LangChain.Message` to
three-key maps, and neither `status` nor `metadata` crossed that boundary. It now
stamps `content["stop_reason"]` onto the **last** item a message produces, as one
of `"length"`, `"cancelled"`, `"content_filtered"` or `"stream_error"`. A
finished message carries no such key, so render on presence.

No breaking changes and no migration. Hosts get the persisted mark with no code
change, because the generated `save_message/3` copies `item.content` verbatim
into the JSONB column and the schema's `validate_content/2` is pattern matched,
so the extra keys pass. Rendering it is opt-in, and the data is captured either
way — a host that upgrades today and adds rendering next month loses nothing in
between.

### Upgrading from v0.12.0 - v0.12.1

Nothing is required. Two things are worth doing.

**Render the mark.** Read `content["stop_reason"]` and show a note when it is
present. Place it as a **sibling** of the message body rather than inside it: the
reported case is a thinking block, whose body sits in a collapsed container until
expanded, so a note nested there is invisible to exactly the reader wondering why
nothing is moving.

**Apply the `sequence` fix**, a one-line update to generated code you own.
`mix deps.update` cannot reach it. Without it, the rows of a multi-item message
are all inserted at the schema default `0` and ordered by microsecond
`inserted_at` ties. In your `save_message/3`:

```elixir
display_items
|> Enum.with_index()
|> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
  attrs = %{
    "message_type" => Atom.to_string(item.message_type),
    "content_type" => Atom.to_string(item.type),
    "content" => item.content,
    "sequence" => index
  }
```

Prefer the hand edit to regenerating: host copies of
`display_message_persistence.ex` are routinely hand-edited and drift from the
template, so regenerating risks overwriting local changes for the sake of one
line. There is no migration and no backfill, and existing rows stay at `0` and
keep sorting exactly as they do today.

To classify `:content_filtered` and `:stream_error`, and to receive
`content["stop_details"]`, you also need LangChain v0.10.0. The floor stays at
`>= 0.8.11` and older releases keep working — `stop_reason/1` handles both shapes
the supported range records a dead stream in, so hosts see no difference.

### Added

- `Sagents.Message.DisplayHelpers.stop_reason/1`, classifying why a message
  stopped as `nil | :length | :cancelled | :content_filtered | :stream_error`,
  normalized across the supported LangChain range.
  [#172](https://github.com/sagents-ai/sagents/pull/172)
- `DisplayHelpers.streaming_error/1`, returning the `LangChainError` that killed
  a stream. `Sagents.Agent` delegates to it, so the `metadata[:streaming_error]`
  convention is known in one place.
  [#172](https://github.com/sagents-ai/sagents/pull/172)
- `DisplayHelpers.stop_details/1`, returning the provider's own description of
  the cause. Anthropic sends this on a refusal as
  `%{"type" => "refusal", "category" => ..., "explanation" => ...}`. Being plain
  JSON rather than a struct, it is carried into `content["stop_details"]` and
  survives persistence. Absent when the provider named no cause.
  [#172](https://github.com/sagents-ai/sagents/pull/172)
- `content["stop_reason"]` and `content["stop_details"]` on the last item
  `extract_display_items/1` produces. The last-item rule is the framework's
  decision, documented so hosts render it identically.
  [#172](https://github.com/sagents-ai/sagents/pull/172)
- The generated `display_message.ex` moduledoc gains "Content Keys Written By The
  Framework" and "Metadata Keys" inventories, so a host reading the schema can
  learn which keys exist. [#172](https://github.com/sagents-ai/sagents/pull/172)

### Changed

- **`Agent.execute/3` now returns `{:error, error}` rather than
  `{:ok, state, tool_result}` when a run producing the three-element result
  (`until_tool` and friends) had its stream die.** Only the two-element clause
  checked for a dead stream, so those callers were handed a silently truncated
  turn as a success. This surfaces a failure that was already happening.
  [#172](https://github.com/sagents-ai/sagents/pull/172)
- `Sagents.DisplayMessagePersistence.save_message/3`'s docs now state that
  `content` must be stored verbatim, since the framework writes keys of its own
  that an implementation rebuilding the map key by key would drop.
  [#172](https://github.com/sagents-ai/sagents/pull/172)
- The `langchain` lock moved to 0.10.0 so CI exercises the new statuses against
  a real release. The dependency floor is unchanged.
  [#172](https://github.com/sagents-ai/sagents/pull/172)

### Fixed

- **A message the model did not finish left no trace in the display transcript.**
  The reported case was a response cut off inside a collapsed thinking block,
  which from the author's seat was indistinguishable from a hung agent.
  [#172](https://github.com/sagents-ai/sagents/pull/172)
- **The generated persistence module never assigned `sequence`.** Every row of a
  multi-item message was inserted with the schema default `0` while
  `load_display_messages/3` ordered by `[asc: :inserted_at, asc: :sequence]`, so
  the order of thinking against text within one message came down to microsecond
  timestamp ties. The library documented a contract its own template broke.
  [#172](https://github.com/sagents-ai/sagents/pull/172)
- **Dead-stream detection survives the LangChain upgrade.**
  `check_for_streaming_error/1` keyed on `status: :cancelled`, which LangChain
  v0.10.0 no longer uses for a dead stream. It now reads the metadata, so
  upgrading LangChain does not silently stop the detection.
  [#172](https://github.com/sagents-ai/sagents/pull/172)

## v0.12.0

A node stops being able to serve agent requests the moment `Sagents.Supervisor`
shuts down, and it keeps accepting connections for the rest of the platform's
grace period. That is every rolling deploy, every scale-down, every machine
migration. `Sagents.Registry` lives in ETS tables owned by a local process, so
when that process stops no lookup on the node can succeed and no retry helps.

Before this release that condition had no name. Neither registry backend reports
it: both raise `ArgumentError` from inside `:ets`, and where Sagents caught that
or never triggered it, the answer came back as `nil`, `[]`, `false`, or `0`. A
caller reads that as "nothing is running" and responds by starting an agent,
which on a draining node silently produces a second `AgentServer` for a
conversation that already has one elsewhere, both holding and persisting its
state.

v0.12.0 makes the condition a first-class answer: `Sagents.ready?/0` for your
readiness check, `{:error, :registry_unavailable}` from every API whose return
shape can carry it, and `Sagents.RegistryUnavailableError` raised by the APIs
whose shape cannot, rather than answering with a plausible-looking default.

**No compile-time breakage, and two behaviour changes that arrive with no action
on your part.** Functions you use today can now raise, though only on a node
whose Sagents tree is down, so your tests pass and local development never sees
it. And a registry crash now restarts that node's agents instead of leaving them
running but unfindable. Every changed return type is *additive*, a new
`{:error, :registry_unavailable}` member in a union, so a `case` that handles the
old answers still compiles and raises `CaseClauseError` at runtime on a draining
node.

### Upgrading from v0.11.x to v0.12.0

Read
[MIGRATION_PROMPT_v0.11.x_TO_v0.12.0.md](https://github.com/sagents-ai/sagents/blob/main/MIGRATION_PROMPT_v0.11.x_TO_v0.12.0.md).
It is written to be handed to a coding agent, and because the compiler gives no
signal here, it is search-driven: every step ships the greps that find the
affected call sites.

Upgrading and changing nothing is safe. Your app behaves as v0.11.1 did, except
that the failures during a drain are now named instead of anonymous. The guide is
what turns that naming into a fix. The four steps that matter most:

1. **Make the platform stop routing to the node before the tree comes down.** One
   mechanism with five parts, most of which do nothing on their own. Note that
   `Sagents.ready?/0` first answers false when the supervision tree stops, which
   is *after* the load balancer needed the signal, so readiness needs a second
   source: a drain flag you set when shutdown begins.
2. **Patch your generated `AgentLiveHelpers`.** Every app generated by
   `mix sagents.setup` ships a `load_conversation/3` that calls
   `AgentServer.get_status/1` inside a `rescue Ecto.NoResultsError`, which does
   not catch the new error. The symptom is a crashed LiveView mount for the whole
   drain window of every deploy.
3. **Audit call sites by how they reach the registry**, not by module. A
   `GenServer.cast` on a `:via` tuple is safe, because Elixir wraps `cast` in a
   `try` that swallows the error; a `GenServer.call` on the same tuple raises,
   and a `catch :exit` clause does not catch a raise.
4. **Answer `:registry_unavailable` as its own thing.** A catch-all that reads it
   as "not running" and starts an agent is the exact failure this release exists
   to prevent.

### Added

- `Sagents.ready?/0`, a boolean answering whether this node can host and route
  agent sessions. Intended for a **readiness** check, never a liveness check.
  [#168](https://github.com/sagents-ai/sagents/pull/168)
- `Sagents.RegistryUnavailableError`, raised by the functions whose return shape
  cannot express the condition.
  [#168](https://github.com/sagents-ai/sagents/pull/168)
- Non-raising siblings for every raising lookup, so request paths have something
  to call: `Sagents.ProcessRegistry.fetch/1` and
  `Sagents.AgentServer.fetch_pid/1`
  ([#168](https://github.com/sagents-ai/sagents/pull/168)), plus
  `Sagents.Session.fetch_running/2`,
  `Sagents.FileSystem.fetch_filesystem_running/1` and
  `Sagents.FileSystemServer.fetch_pid/1`
  ([#170](https://github.com/sagents-ai/sagents/pull/170)).
- `Sagents.RegistryWatcher`, which monitors the process owning the registry's ETS
  tables and fails in its place. Both backends restart that process internally,
  so a registry failure never surfaces as a failed child of `Sagents.Supervisor`.
  [#168](https://github.com/sagents-ai/sagents/pull/168)
  [#169](https://github.com/sagents-ai/sagents/pull/169)
- `Sagents.LocalRegistry` and `Sagents.ProcessRegistry.watched_name/0`, covering
  the `:local` backend's restart race and the fact that the watched process is
  not always the one registered as `Sagents.Registry`.
  [#169](https://github.com/sagents-ai/sagents/pull/169)
- The generated `AgentLiveHelpers` gains `flash_session_error/3`, a single funnel
  that gives a draining node its own product copy and logs it at `:warning`
  rather than `:error`, plus a `draining_message/0` accessor so host tests can
  assert which message a path produced without hardcoding the string. The
  generated `Coordinator` gains `fetch_session_running/1`.
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- [Deployment guide](https://github.com/sagents-ai/sagents/blob/main/docs/deployment.md),
  covering the drain sequence, a complete drain process, why only SIGTERM runs
  `terminate/2` at all, and the silent misconfigurations that make the whole
  mechanism a no-op: `force_ssl` redirecting the probe, `Plug.SSL` matching paths
  by equality rather than prefix, and Fly's `checks` / `http_checks` sub-keys
  decoding into no check whatsoever.
  [#168](https://github.com/sagents-ai/sagents/pull/168)
  [#169](https://github.com/sagents-ai/sagents/pull/169)
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- Expanded architecture and clustering docs on registry ownership, membership,
  and what Horde does and does not guarantee during a handoff.
  [#169](https://github.com/sagents-ai/sagents/pull/169)

### Changed

- **A registry crash now restarts that node's agents.** `Sagents.Supervisor`
  supervises `:rest_for_one` with the registry first, so a registry failure
  restarts the agent and filesystem dynamic supervisors under it. Running agents
  on that node stop and are re-created from persisted state on the next request,
  which costs the in-flight LLM turns. That is deliberate: an `AgentServer`
  registers its `:via` name once, at start, and nothing re-registers it, so a
  registry that comes back empty would otherwise leave agents running but
  invisible to every lookup, and the next request would start a duplicate.
  Restarting is recoverable; a silent duplicate is not.
  [#168](https://github.com/sagents-ai/sagents/pull/168)
  [#169](https://github.com/sagents-ai/sagents/pull/169)
- **Functions whose return shape cannot carry the condition now raise**
  `Sagents.RegistryUnavailableError` rather than answering with a default that
  reads as "nothing is running". The two most easily met by accident are
  `Sagents.Session.running?/2` and `Sagents.FileSystem.filesystem_running?/1`,
  because a name ending in `?` is the last thing a reader suspects of raising.
  `Sagents.AgentServer.get_status/1` is the next one: it wraps its call in
  `try/catch :exit`, so every call site reads as though it cannot fail, while the
  raise happens before reaching the call that `catch` guards. Full list in the
  migration guide. [#168](https://github.com/sagents-ai/sagents/pull/168)
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- **`{:error, :registry_unavailable}` is now a possible return** from
  `Sagents.Session` (`start/3`, `ensure_running/3`, `resume/4`, `dismiss/3`,
  `stop/2`), the `Sagents.AgentServer` lifecycle calls (`execute/1`, `cancel/1`,
  `resume/2`, `add_message/3`, `reset/1`, `dismiss_interrupt/1`, `subscribe/3`),
  the `Sagents.FileSystem` layer (`ensure_filesystem/3`, `stop_filesystem/2`,
  `get_filesystem_pid/1`), and `Sagents.AgentSupervisor` (`get_pid/1`, `stop/2`).
  Note that the not-found atom differs by layer while `:registry_unavailable` is
  spelled the same everywhere, so copying a `case` shape across layers gives a
  `CaseClauseError` on the drain path.
  [#168](https://github.com/sagents-ai/sagents/pull/168)
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- `ensure_filesystem/3` deliberately does not start a filesystem it could not
  first check for, because a draining node cannot see whether one already exists
  elsewhere. A caller that reads any error as "start failed, carry on degraded"
  is making a different decision than the one reported.
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- Three functions swallow the condition rather than reporting it, because the
  caller has no possible response: `AgentServer.notify_middleware/3` logs and
  returns `:ok`, `AgentServer.unsubscribe/3` returns `:ok`, and
  `AgentServer.queue_message_from_tool/3` folds it into its existing
  `{:error, :no_server}`. `Sagents.Subscriber` records a subscription it cannot
  make as `:pending` and waits for the next presence diff, which is safe here
  specifically because nothing starts a producer off the back of a pending entry.
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- **Horde redistribution is documented as not a guarantee.** Horde hands a
  departed node's processes to a survivor only once that survivor has converged
  on the departure. An agent placed immediately before its node departs is
  dropped in roughly one departure in four, cleanly, with the next
  `Session.ensure_running/3` starting it from persisted state. Anything that must
  happen needs a driver that survives the node.
  [#169](https://github.com/sagents-ai/sagents/pull/169)

### Fixed

- `Sagents.Middleware.Summarization` no longer picks a cutoff that orphans a tool
  result. Keeping a `:tool` message whose originating assistant tool call was
  summarized away is rejected outright by providers, OpenAI with "No tool call
  found for function call output", so a long conversation could start failing
  every turn after its first compaction. Cuts landing between consecutive results
  from parallel tool calls hit the same way. The middleware is now slightly more
  willing to summarize nothing rather than produce an invalid transcript, so if
  you tuned `messages_to_keep` against the old behaviour, check that compaction
  still triggers where you expect. The two safe-cutoff tests passed a `nil` model
  and asserted `{:ok, _result}`, which held for any cutoff including none at all;
  they now assert the post-compaction message shape.
  [#167](https://github.com/sagents-ai/sagents/pull/167)
- A `:local` registry restart that raced the outgoing registry's own shutdown
  took `Sagents.Supervisor` down permanently. `Registry.Partition` traps exits,
  so it holds its registered name for a few milliseconds after the registry
  itself is gone, and a restart landing in that window failed with
  `{:already_started, pid}`. A failed restart is not something a supervisor
  retries its way out of, so it gave up and exited `:shutdown`, taking both
  dynamic supervisors and every running agent with it.
  [#169](https://github.com/sagents-ai/sagents/pull/169)
- The generated `AgentLiveHelpers` crashed its LiveView mount for the entire
  drain window of every deploy. `load_conversation/3` now guards on
  `Sagents.ready?/0`, since everything in its body needs the registry and there
  is nothing worth half-rendering on a node that is going away.
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- `AgentServer.subscribe/3`, `AgentServer.unsubscribe/3` and the `Subscriber`
  filesystem paths resolve a pid rather than handing `Sagents.Publisher` a `:via`
  tuple. `Publisher.subscribe/3` is a `GenServer.call`, so the via resolution
  raised out of `:ets` past its own `catch :exit` guard.
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- The `Sagents.FileSystem` public API kept raising on a draining node because its
  registry key had two independent readers and only one was guarded.
  `FileSystemSupervisor.get_filesystem/1` now delegates to the single guarded
  reader. [#170](https://github.com/sagents-ai/sagents/pull/170)
- `AgentSupervisor.stop/2` matched only the two answers `get_pid/1` used to give,
  turning a drain into a `CaseClauseError` that looks unrelated to deploying.
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- Cancelling a main agent no longer risks taking the `AgentServer` down mid
  teardown. Resolving a sub-agent's id for the parent's fallback broadcast reads
  the registry, and an error escaping there ran inside the `:cancel`
  `handle_call`. The best-effort observability event is dropped instead.
  [#170](https://github.com/sagents-ai/sagents/pull/170)
- `Subscriber.handle_presence_diff/3` no longer probes a dead registry once per
  joining agent per broadcast for the length of a drain. The presence topic is
  cluster-wide, so it fires for agents booting anywhere in the cluster.
  [#170](https://github.com/sagents-ai/sagents/pull/170)

## v0.11.1

A bug fix release. `Sagents.Middleware.Summarization` crashed at the one moment
it was supposed to work: when a conversation crossed the token threshold and the
middleware tried to summarize. It built its `SummarizeConversationChain` with
`threshold_count: 0`, but LangChain validates `threshold_count >= 2`, so
`new!/1` raised on every summarization attempt. If you have the Summarization
middleware in your stack, upgrade.

Also adds a guide for driving Sagents from a React front end, covering the
"subscription bridge" pattern: a long-lived GenServer that holds the
subscription and session state a LiveView would otherwise hold in `assigns`, and
republishes serialized events onto a transport the browser can consume.

No breaking changes and no migration required.

### Added

- [Using Sagents with a React Front End](https://github.com/sagents-ai/sagents/blob/main/docs/using_with_a_react_front_end.md)
  guide. Examples use Absinthe GraphQL subscriptions, but the bridge pattern is
  transport agnostic and the guide covers the alternatives.
  [#163](https://github.com/sagents-ai/sagents/pull/163)

### Fixed

- `Sagents.Middleware.Summarization` no longer raises when it actually
  summarizes. The `threshold_count` passed to the summarizer chain is now `2`,
  LangChain's minimum. The value is behaviorally irrelevant here since Sagents
  partitions the messages itself and only uses the chain to summarize
  pre-partitioned text, but it has to satisfy validation. Test coverage now
  exercises a full summarization run and the summarizer-failure fallback.
  [#164](https://github.com/sagents-ai/sagents/pull/164)

## v0.11.0

An open `ask_user` question no longer disappears when the agent goes to sleep.

The interrupt was always durable — it is persisted with the state, and a fresh
boot rebuilds it and comes up `:interrupted`. The loss was in the host UI, which
treated "the process went away" as a status change and cleared the prompt. This
release separates the two facts hosts were conflating: `agent_status` is what the
conversation is waiting on, `agent_alive?` is whether a process is backing it
right now. Answering an interrupt now goes through `Sagents.Session.resume/4`,
which wakes a sleeping agent and hands it the answer at boot.

The same is true of any other restorable interrupt, including a `:halt` panel,
whose Dismiss button goes through the matching `Sagents.Session.dismiss/3`. **If
your app renders a halt panel, read step 6 of the migration guide**, since the
button has to be routed through the new path to work on a dormant conversation.

**No compile-time breakage**, and upgrading without touching host code is safe:
everything behaves as v0.10.1 did, bug included. The fix is opt-in, because the
affected modules were generated into your app. See
[MIGRATION_PROMPT_v0.10.x_TO_v0.11.0.md](MIGRATION_PROMPT_v0.10.x_TO_v0.11.0.md)
— it is written to be handed to a coding agent.

Full write-up in [#159](https://github.com/sagents-ai/sagents/pull/159).

### Added

- `Sagents.Session.resume/4` — answer an interrupt, waking the agent if needed.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- `Sagents.Session.dismiss/3` — acknowledge a terminal `:halt`, waking the agent
  if needed. The mirror of `resume/4` for the interrupt type that is dismissed
  rather than answered. A halt is restorable, so its panel now survives a nap,
  and `AgentServer.dismiss_interrupt/1` alone cannot clear one on a dormant
  conversation. An interrupt that needs a real response is passed through as an
  error rather than woken. The generated Coordinator gains
  `dismiss_agent_session/2` and the generated `AgentLiveHelpers` gains
  `handle_halt_dismissal/1`.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- `:pending_resume`, a start option applied during boot before the initial status
  broadcast, so a woken agent announces `:running` rather than an `:interrupted`
  snapshot it is about to leave.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- `Sagents.AgentUtils.shutdown_session_changes/2` and the `agent_alive?`
  subscriber-state key.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- `Sagents.State.interrupt_restorable?/2` is now public — the authoritative
  predicate for whether an interrupt survives a cold boot.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- `{:agent_shutdown, _}` payloads carry `:interrupt_restorable`.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- `Sagents.Session.start/3`'s `session_info` gained `:started`.
  [#159](https://github.com/sagents-ai/sagents/pull/159)

### Changed

- **`on_subscribed/3` no longer fires for a pid already subscribed to that
  channel.** It is a *newly registered* subscriber hook, and an already-registered
  pid has nothing to resync. If you relied on re-subscribing to force a refresh,
  use `Sagents.AgentServer.get_info/1`. This is the only non-opt-in behaviour
  change in the release. [#159](https://github.com/sagents-ai/sagents/pull/159)
- **A `:halt` panel now survives a shutdown**, for hosts that adopt
  `AgentUtils.shutdown_session_changes/2`. `Haltable.restorable_interrupt?/1`
  reports `%{type: :halt}` as restorable and the shutdown helper counts
  `:pending_halt` as a pending interrupt, so a halt is preserved on exactly the
  same terms as an open question. Route the panel's Dismiss action through
  `Session.dismiss/3`: `AgentServer.dismiss_interrupt/1` talks to a live process
  and returns `{:error, :agent_not_running}` against a dormant one. See step 6 of
  the migration guide. Previously the generated
  `handle_agent_shutdown/2` cleared the halt on the way out, so this path was
  unreachable. [#159](https://github.com/sagents-ai/sagents/pull/159)
- All three `{:agent_shutdown, _}` emit sites now send the same shape.
  `terminate/2` previously sent only `%{reason:, status:}`, omitting the agent id
  hosts need to correlate the event. Additive for subset map patterns.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- An empty `:multiple_interrupts` wrapper is no longer treated as restorable.
  [#159](https://github.com/sagents-ai/sagents/pull/159)

### Fixed

- A process seeded via `:initial_subscribers` that then called `subscribe/3`
  received the boot status broadcast twice. This is the exact shape
  `Sagents.Session.ensure_running/3` produces.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- The generated `handle_agent_shutdown/2` destroyed the agent subscription rather
  than letting presence-driven recovery restore it, and cleared `agent_id`,
  breaking `handle_conversation_title_generated/3`.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- The generated interrupt handlers crashed on a duplicate question submission and
  could resume with a fabricated HITL decision on a duplicate approval.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- The generated `resume_or_flash/5` built the log line and the user-facing flash
  from a single `error_prefix`, so an internal error term reached the end user
  verbatim (`Failed to submit response: "Cannot resume, server is not
  interrupted"`), in wording that says "agent". It now takes `:log_label` and
  `:user_message` separately, and only the label is paired with the reason.
  [#159](https://github.com/sagents-ai/sagents/pull/159)
- The generated `AgentLiveHelpers` exposes a single public `agent_request_opts/1`
  instead of a private, resume-only `resume_request_opts/1` stub. Every path that
  can start an agent should read it, including the host's own
  `ensure_agent_session_running/2` call sites. Two copies of this decision drift
  silently, and the symptom is an agent configured differently only on the paths
  that had to wake it. [#159](https://github.com/sagents-ai/sagents/pull/159)

## v0.10.2

Adds `:suppress_debug_events` on a sub-agent config. When set, that sub-agent
type publishes none of its events on the parent's `:debug` channel: not the
initial messages, not the inner LLM messages as they arrive, and not the full
inner chain that a failed or cancelled run would otherwise republish.

```elixir
{Sagents.Middleware.SubAgent, [
  model: model,
  subagents: [
    Sagents.SubAgent.Config.new!(%{
      name: "pii-extractor",
      description: "Extract structured fields from a sensitive document",
      tools: [extract_tool],
      suppress_debug_events: true
    })
  ]
]}
```

The parent still receives the run's outcome as the `task` tool result, so only
the observer fan-out is silenced. The setting is per sub-agent type and
all-or-nothing. It does not apply to the general-purpose sub-agent, which is
created dynamically and so has no config to carry the flag.

This covers the `:debug` channel only. If you are reaching for it to keep
sensitive content out of your observability stack, note that OpenTelemetry
content capture is configured separately and globally through
`LangChain.OpenTelemetry.setup/1`, and defaults to off.

Defaults to `false`. Additive only: nothing changed arity or return type, and no
migration is required.

### Added

- `:suppress_debug_events` on `Sagents.SubAgent.Config` and `Sagents.SubAgent`,
  silencing every event that sub-agent would publish on the parent's `:debug`
  channel.
  [#158](https://github.com/sagents-ai/sagents/pull/158)

## v0.10.1

Adds `:otel_attributes`, a flat map of your application's context (tenant, user,
feature) that lands on **every** OpenTelemetry span an agent produces: the
`invoke_agent` span, each `chat` span, and each `execute_tool` span, including
tools running in their own process.

```elixir
{:ok, agent} =
  Sagents.Agent.new(%{
    model: model,
    name: "support_agent",
    otel_attributes: %{
      "user.id" => current_user.id,
      "organization.id" => org.id,
      "myapp.plan" => org.plan
    },
    middleware: [...]
  })
```

No middleware, no callbacks, no OpenTelemetry knowledge. Additive only: nothing
changed arity or return type, and no migration is required. Requires `langchain`
0.9.5 or later for the attributes to reach spans.

Full details in the
[Observability guide](https://github.com/sagents-ai/sagents/blob/main/docs/observability.md).

### Added

- `:otel_attributes` on `Sagents.Agent`, plus `Sagents.Agent.put_otel_attributes/2`
  for values that are only known after the agent is built.
  [#155](https://github.com/sagents-ai/sagents/pull/155)
- An `AgentServer` now stamps its `conversation_id` onto the state it executes,
  so `gen_ai.conversation.id` is set with no configuration. Combined with the
  agent's `:name`, traces group by conversation and by agent out of the box.
  Tools can read both from `custom_context`.
  [#155](https://github.com/sagents-ai/sagents/pull/155)
- Sub-agents inherit the parent's `:otel_attributes` and conversation id, and add
  their own lineage: `gen_ai.agent.id` is the sub-agent's id and
  `sagents.parent_agent_id` is the parent's.
  [#155](https://github.com/sagents-ai/sagents/pull/155)
- `Sagents.State.conversation_id`, a virtual field the `AgentServer` supplies on
  each execution. Not persisted; the server remains the source of truth.
  [#155](https://github.com/sagents-ai/sagents/pull/155)

## v0.10.0

Headlined by a **pending-message queue**: a user can now type while the agent is
working without their message being lost, and a tool can hand the model
instructions as a real user turn rather than as tool-result data.

The rest is a correctness pass on sub-agents. Interrupts raised inside a
sub-agent now behave the way their type says they should: a `:halt` reaches the
parent as a halt, a tool-raised interrupt fails cleanly instead of crashing the
caller, and sub-agents no longer receive an `ask_user` tool no one can answer.
Plus two new hooks for host applications: a middleware callback for shaping
display messages, and a way for a mode to report *why* it paused.

**No breaking API changes.** No function changed arity or return type, and no
migration is required. There are four intentional behavior changes worth knowing
about before you upgrade, described below.

### Upgrading from v0.9.0 to v0.10.0

- **`AgentServer.add_message/2` no longer returns an error while a run is in
  flight.** It used to reply
  `{:error, "Cannot execute, server is in state: running"}` and then discard the
  message anyway; it now queues the message and returns `:ok`. The arity and the
  `:ok | {:error, term()}` type are unchanged, so the compiler will not flag
  this. Host code that matched that error tuple to render an "agent is busy"
  notice should drop the branch and instead subscribe to
  `{:agent, {:message_queued, %Message{}}}` if it wants to show queued state.
  [#152](https://github.com/sagents-ai/sagents/pull/152)
- **Sub-agents no longer inherit `Sagents.Middleware.AskUserQuestion`.** If a
  sub-agent genuinely needs it, name it in that sub-agent's own `:middleware`
  list on its `SubAgent.Config`. Explicit configuration still receives it.
  Inherited `ask_user` calls previously produced an empty approval prompt rather
  than a visible question, so there is little working behavior to preserve.
  [#151](https://github.com/sagents-ai/sagents/pull/151)
- **A sub-agent `:halt` now reaches the parent as `:halt`**, not as
  `%{type: :subagent_hitl}`. Parent code matching on `:subagent_hitl` to catch
  halts needs to match `:halt` instead.
  [#150](https://github.com/sagents-ai/sagents/pull/150)
- **A failed `until_tool` termination now returns the tool's own error content**
  as `{:error, content}` instead of a generic extraction failure.
  [#143](https://github.com/sagents-ai/sagents/pull/143)

### Added

- **Pending-message queue on `AgentServer`.** A single-slot queue on
  `ServerState` holds a message that arrives mid-run and delivers it as an
  ordinary `:user` message at the head of a follow-up run, so nothing downstream
  has to know where it came from. Two doors into it:
  [#152](https://github.com/sagents-ai/sagents/pull/152)
  - `add_message/3` (the human door) queues instead of erroring when the server
    is `:running`. Non-`:user` roles are still rejected. Two messages queued
    during one run merge their content parts into one turn.
  - `queue_message_from_tool/3` (the tool door) lets a tool hand the model a
    playbook or slash-command body as instruction rather than as tool-result
    data. It is a `cast` so a tool cannot deadlock against a concurrent
    `:cancel`, and returns `{:error, :no_server}` under a bare `Agent.execute/3`
    or inside a sub-agent so callers can take a fallback path.
  - A `:display` option on both doors splits the transcript half from the
    model-visible half. `:none` is model-visible and transcript-invisible; an
    explicit `%LangChain.Message{}` supplies both halves, which may differ in
    role. Resolution happens at queue time, so a user sees their own words
    immediately rather than a turn later.
  - Drain policy is explicit per terminal clause: `{:ok, _}` drains and starts a
    follow-up run, while `{:interrupt, _, _}`, `{:pause, _}` and `{:error, _}`
    hold. The drained branch deliberately does not broadcast
    `{:status_changed, :idle, nil}`, so a UI never flickers "done" between the
    two runs.
  - A circuit breaker caps the framework at 10 consecutive self-started runs.
    The counter resets on the human door and never on the tool door. This is
    distinct from `:max_runs`, which counts LLM calls within one execution and
    resets on every fresh chain. A tripped breaker still appends the message; it
    only declines to start another run.
  - `pending_message` is serialized alongside state and restored at boot, so a
    node dying mid-run does not lose the user's words. Payloads written before
    this release simply lack the key and read as "nothing queued".
  - New events: `{:agent, {:message_queued, %Message{}}}`, plus
    `{:messages_drained, count}`, `{:pending_message_held, :error}` and
    `{:auto_execution_limit_reached, limit}` on the debug channel.
  - Known scope limit: delivery is at the **run** boundary, not the turn
    boundary. A message typed twenty tool calls into a long job is late, not
    lost. Turn-boundary delivery is deliberately out of scope.
- New optional middleware callback `transform_display_message/2`, the outbound
  mirror of `MessagePreprocessor`. Each middleware gets a chance to annotate
  `metadata` (or rewrite content) on a message before it is persisted as a
  display message and broadcast to subscribers. The message in agent state is
  left untouched, so the LLM never sees the annotation. Passthrough default;
  composes across the stack. [#139](https://github.com/sagents-ai/sagents/pull/139)
- Pause cause on the `:paused` status event. A mode step may now return
  `{:pause, chain, reason}`; `Sagents.Mode.Steps.normalize_pause/1` folds the
  reason into `custom_context.pause_reason`, the agent reads it onto the new
  virtual `State.pause_reason` field, and `AgentServer` broadcasts it as the
  payload of `{:agent, {:status_changed, :paused, pause_reason}}`, which was
  previously always `nil`. `Agent.execute/3` still returns `{:pause, state}`, and
  a pause without a reason broadcasts `nil` as before.
  [#149](https://github.com/sagents-ai/sagents/pull/149)

### Changed

- `AgentServer.add_message/2` returns `:ok` instead of an error when a run is in
  flight, because the message is now queued rather than rejected. See the
  Upgrading section. [#152](https://github.com/sagents-ai/sagents/pull/152)
- `langchain` moves from 0.8.12 to 0.9.4 in `mix.lock`, along with transitive
  bumps to `ecto`, `finch`, `mint`, `hpax`, `plug`, `plug_crypto` and `req`. The
  `mix.exs` requirement is unchanged; `>= 0.8.11` already allowed this.
  [#152](https://github.com/sagents-ai/sagents/pull/152)
- `Sagents.Middleware.AskUserQuestion` is added to a new
  `@never_inherited_middleware` list alongside `Sagents.Middleware.SubAgent`, so
  neither is inherited by a sub-agent from its parent's stack. Explicitly
  configured `additional_middleware` is unaffected.
  [#151](https://github.com/sagents-ai/sagents/pull/151)
- CI workflow dependency bumps: `actions/checkout` 6.0.2 → 7.0.0
  ([#132](https://github.com/sagents-ai/sagents/pull/132)), `actions/cache` and
  its `save`/`restore` variants 5.0.5 → 6.1.0
  ([#136](https://github.com/sagents-ai/sagents/pull/136),
  [#137](https://github.com/sagents-ai/sagents/pull/137),
  [#138](https://github.com/sagents-ai/sagents/pull/138)), and `erlef/setup-beam`
  1.24.0 → 1.24.1 ([#140](https://github.com/sagents-ai/sagents/pull/140)).

### Fixed

- A user message added while the agent was `:running` is no longer silently
  destroyed. It was written into the rolling server state, then wiped moments
  later when `handle_execution_result/2` replaced that state wholesale with the
  canonical state from `Agent.execute/3`, while the caller was told the server
  was busy. The message is now queued and delivered on the next run.
  [#152](https://github.com/sagents-ai/sagents/pull/152)
- A `:halt` raised inside a sub-agent is propagated to the parent as a halt
  instead of being wrapped as `:subagent_hitl`. Previously the wrapper defeated
  every guarantee halt makes: the parent resumed and called the LLM again, the
  interrupt was not restorable across a cold start, and the author's message was
  never shown, so the user saw an empty approval dialog. The sub-agent process is
  now stopped, and the propagated halt preserves `:source_tool` and adds
  `:source_task`. Applies to both the initial run and a post-approval resume.
  [#150](https://github.com/sagents-ai/sagents/pull/150)
- `SubAgent.extract_result/1` now reads the matched terminating tool's result on
  an `until_tool` run. Every `until_tool` termination ends on a tool-result
  message, which the previous `ChainResult.to_string/1` path could not handle, so
  extraction failed on success and failure alike and the parent received a
  generic error. A tool result flagged `is_error` becomes `{:error, content}`;
  runs ending in assistant prose are unchanged. Fixes
  [#141](https://github.com/sagents-ai/sagents/issues/141).
  [#143](https://github.com/sagents-ai/sagents/pull/143)
- `SubAgent.resume/3` no longer crashes with a `KeyError` when the sub-agent's
  interrupt was raised from inside a tool body. Such an interrupt carries neither
  `:action_requests` nor `:hitl_tool_call_ids`, and is not resumable through this
  path; it now returns `{:error, {:unsupported_interrupt, :tool_raised}}`, which
  `Middleware.SubAgent.handle_resume/5` already turns into a clean error tool
  result for the parent. Fixes
  [#142](https://github.com/sagents-ai/sagents/issues/142).
  [#144](https://github.com/sagents-ai/sagents/pull/144)
- Creating a file with empty or whitespace-only content no longer discards it.
  Ecto's default `:empty_values` treated `""`, `"\n"`, `"   "`, and `"\t"` as
  absent and replaced them with `nil` while still reporting a successful write.
  `FileEntry.internal_changeset/2` now passes `empty_values: []` so content is
  stored verbatim. Only the first write to a path was affected; overwrites bypass
  the changeset and always worked.
  [#147](https://github.com/sagents-ai/sagents/pull/147)

## v0.9.0

Reworks the optional `:horde` distribution backend so cluster membership is
correct, dynamic, and scopable. Full write-up in
[#134](https://github.com/sagents-ai/sagents/pull/134).

### `members: :participation` — dynamic, role-scoped membership

    config :sagents, :distribution, :horde
    config :sagents, :horde, members: :participation

Membership becomes exactly the nodes that run `Sagents.Supervisor`, discovered
via an OTP `:pg` group and kept current on `:nodeup`/`:nodedown` by the new
`Sagents.Horde.MembershipManager`. Gate `Sagents.Supervisor` to your
agent-hosting role(s) and membership follows automatically — no node-name
predicate, and dead nodes are pruned for free. Prefer this over `:auto` whenever
the Erlang cluster also contains nodes that should not host agents.

### `:partition` — isolate participation into independent groups

    config :sagents, :horde,
      members: :participation,
      partition: System.get_env("FLY_REGION")

An optional per-node `:partition` (any stable, opaque grouping key) scopes
membership further so a node only clusters with same-partition nodes. The
motivating case is geographic — set it to a Fly.io `FLY_REGION` so an agent for
an Illinois user is never placed on, or routed through, a node in France — but it
works for any per-node grouping. Cross-partition request routing remains an
infra/app concern (e.g. Fly `fly-replay`). See
[`docs/clustering.md`](https://github.com/sagents-ai/sagents/blob/main/docs/clustering.md).

### Also in this release

See [#134](https://github.com/sagents-ai/sagents/pull/134) for details on each:

- **`members: :auto` is now real** — potential behaviour change. It previously
  froze to a one-time node snapshot; it now drives Horde's `NodeListener` for
  genuine dynamic membership with dead-node pruning. The undocumented static
  `:members` forms (list / `function/0` / `{m, f, a}`) are removed; the only
  values are `:auto` (default) and `:participation`.
- **Registration-timeout resilience** — `AgentsDynamicSupervisor.start_agent_sync/1`
  retries on Horde's hardcoded-5s `:via` registration timeout, via new
  `:registration_retries` / `:registration_retry_backoff` options.
- **FileSystem distribution-safety** — dropped `Process.alive?/1` checks on
  potentially-remote pids that could raise.

## v0.8.0

A large release that reworks the runtime foundations of the library: a new direct point-to-point event transport (replacing `Phoenix.PubSub`), session/factory lifecycle ownership moved into the library, interrupts that survive a process restart, a richer interrupt model (`:halt`, configurable `ask_user`), structured data extraction through the full middleware stack, cross-process caller-context propagation, and new tool-driven stop conditions.

This entry consolidates everything relevant to upgrading from the previous public release, **`v0.7.x`**. The `v0.8.0` line went through 13 release candidates; several breaking changes were introduced and then superseded *within* the RC cycle and therefore do not affect anyone moving directly from `v0.7.x` to `v0.8.0`. For the complete, blow-by-blow history of every intermediate change, see the archived [`v0.8.0-rc.13` changelog](https://github.com/sagents-ai/sagents/blob/v0.8.0-rc.13/CHANGELOG.md).

**Breaking changes** — see the Upgrading section below.

### Upgrading from v0.7.x to v0.8.0

The recommended path is to **re-run the generators on a clean, committed workspace and merge your customizations back in**, then apply a handful of host-code renames.

**1. Regenerate scaffolding.** Run `mix sagents.setup` (or the individual `mix sagents.gen.*` tasks) with the same options you used originally, accept the overwrites, and merge your customizations back with a diff tool. This absorbs the structural changes in one step: the new `Session` / `Factory` / `FactoryRouter` triad (replacing the old monolithic `coordinator.ex` + `factory.ex`), the new `agent_subscriber_session.ex` template, integer todo ids in `valid_todo_entry?/1`, the denormalized `tool_call_id` column in the persistence schema/context, and restorable-interrupt support. [#97](https://github.com/sagents-ai/sagents/pull/97) [#79](https://github.com/sagents-ai/sagents/pull/79) [#116](https://github.com/sagents-ai/sagents/pull/116) [#127](https://github.com/sagents-ai/sagents/pull/127) [#96](https://github.com/sagents-ai/sagents/pull/96)

**2. Transport: `Sagents.PubSub` is removed.** Replace any direct `Sagents.PubSub.subscribe/1` / `broadcast/2` calls with `use Sagents.Subscriber` plus the generated `subscribe/2` helper, or pass `:initial_subscribers` when starting servers to enroll the caller inside `init/1` and avoid the start/subscribe race. Existing `handle_info/2` clauses keep matching — event payload shapes (`{:agent, _}`, `{:file_system, _}`, `{:status_changed, _, _}`, `{:llm_deltas, _}`, etc.) are unchanged. [#79](https://github.com/sagents-ai/sagents/pull/79)

**3. SubAgent: `subagent_type` → `task_name`.** The `task` and `get_task_instructions` tools now take `task_name`. Rename the key in any interrupt-data pattern match (`%{type: :subagent_hitl, task_name: type, sub_agent_id: id}`) and in any `context.resume_info` maps you build for sub-agent resume. Persisted v1 state is migrated to v2 automatically by `StateSerializer`. The available-tasks listing moved into an `## Available Tasks` system-prompt section (suppressible via `:include_task_list`); update any custom prompts referencing the old wording. [#78](https://github.com/sagents-ai/sagents/pull/78)

**4. Session API rename.** `Coordinator.ensure_session_running/1` is now `ensure_agent_session_running/1` — update LiveViews, controllers, and tests. Factory helpers that were `get_model/0` / `get_middleware/0` become `build_model/1` / `build_middleware/1`, branching on a `%FactoryConfig{}` struct. Per-request data (timezone, tool_context, project records) now flows through `request_opts → FactoryRouter.resolve/3 → %FactoryConfig{} → Factory.create_agent/2` rather than being threaded as positional args. [#97](https://github.com/sagents-ai/sagents/pull/97)

**5. Debug subscriptions.** `AgentServer.subscribe_debug/1` / `unsubscribe_debug/1` are removed in favor of `AgentServer.subscribe(agent_id, :debug)` / `unsubscribe(agent_id, :debug)`. The single-arg `subscribe(agent_id)` form is unchanged. [#94](https://github.com/sagents-ai/sagents/pull/94)

**6. FileSystem: `replace_file_lines` removed.** If your config, prompts, or evals reference it, either drop it (`replace_file_text` covers the same use cases for most agents) or re-add it as a project-local tool — the previous implementation lives in the [#110](https://github.com/sagents-ai/sagents/pull/110) diff. Configs passing `tools:` / `tool_descriptions:` to `Sagents.Middleware.FileSystem` must remove the `"replace_file_lines"` entry. [#110](https://github.com/sagents-ai/sagents/pull/110)

**7. Todo ids are integers.** Host code calling `Sagents.Todo.new/1`, `State.get_todo/2`, or `State.delete_todo/2` with string ids must switch to integers (`Todo.new/1` now validates `greater_than: 0`). Code that builds todos from incoming maps should migrate to `Sagents.Todo.list_from_maps/1`, which assigns positional defaults for missing/non-numeric ids and coerces stringified integers. Persisted snapshots with legacy base64 string ids rehydrate to positional ids automatically on load. [#116](https://github.com/sagents-ai/sagents/pull/116)

**8. Opt middleware into interrupt restoration (optional).** Custom middleware that produce restorable, data-only `interrupt_data` should implement `Sagents.Middleware.restorable_interrupt?/1` returning `true` for matching shapes. The default of `false` preserves the old safe demote-on-load behaviour with no code changes. Built-in `AskUserQuestion` and `HumanInTheLoop` already opt in; `SubAgent` deliberately does not. [#96](https://github.com/sagents-ai/sagents/pull/96)

### Added

- **Direct-delivery transport** — `Sagents.Publisher` / `Sagents.Subscriber` replace `Phoenix.PubSub` with monitored point-to-point delivery, an `:initial_subscribers` start option, and a Presence-based recovery loop for crash-restart and Horde migration. [#79](https://github.com/sagents-ai/sagents/pull/79)
- **Session/Factory lifecycle in the library** — `Sagents.Session` owns the session-start lifecycle (router consult, factory invocation, state seeding, supervisor wiring, subscribers) and is idempotent on resume. `Sagents.Factory` / `Sagents.FactoryRouter` behaviours, `Sagents.Routers.Single` for one-factory apps, and a typed `%FactoryConfig{}` for per-request data. [#97](https://github.com/sagents-ai/sagents/pull/97)
- **Restorable interrupts** — an agent that shut down (inactivity timeout, deploy, crash) with a pending `ask_user` question or HITL approval now boots back into `:interrupted` status with the original `interrupt_data` intact, rather than silently demoting to an error. New optional `Sagents.Middleware.restorable_interrupt?/1` callback, `set_interrupted/3` persistence callback, and cheap pre-deserialization `interrupted?/1` read. [#96](https://github.com/sagents-ai/sagents/pull/96)
- **`:halt` terminal interrupt** via the new `Sagents.Middleware.Haltable` — tools can hard-stop a workflow (e.g. a gating validation tool) without giving the LLM a chance to continue. Includes `AgentServer.dismiss_interrupt/1` for UIs to acknowledge a halt and a `[:sagents, :agent, :halt]` telemetry event. [#115](https://github.com/sagents-ai/sagents/pull/115)
- **`Sagents.Extract`** — structured data extraction that flows through the agent's full middleware stack. The submit tool is owned by the agent and selected via the `:until_tool` / `:until_tool_success` stop condition; `run/3` returns the tool's `processed_content` when present. [#108](https://github.com/sagents-ai/sagents/pull/108) [#129](https://github.com/sagents-ai/sagents/pull/129) [#128](https://github.com/sagents-ai/sagents/pull/128)
- **`Sagents.AgentResult`** — read helpers for pulling tool results, arguments, processed content, or final text out of `Agent.execute/3` return values. [#107](https://github.com/sagents-ai/sagents/pull/107)
- **`:until_tool` and `:until_tool_success` stop conditions** on `Sagents.Agent.execute/3` and `Sagents.SubAgent` — complete a run when a target tool is called (or, for `:until_tool_success`, returns a non-error result), enabling the validate-and-retry pattern. [#128](https://github.com/sagents-ai/sagents/pull/128)
- **`Sagents.Middleware.ProcessContext`** — propagates caller-process state (OpenTelemetry trace context, Sentry context, request-scoped Logger metadata, tenant scope) across the three process boundaries an agent invocation crosses, via `:keys` and `:propagators` configuration shapes. [#82](https://github.com/sagents-ai/sagents/pull/82)
- **`Sagents.StreamingSession`** — host-agnostic streaming helpers (`handle_tool_call_identified/2`, `handle_tool_execution_update/3`) returning *changes maps* the host merges itself, with multi-tool-safe delta semantics. [#104](https://github.com/sagents-ai/sagents/pull/104)
- **TodoList `:inline` mode** — each successful `write_todos` additionally persists a `todo_snapshot` synthetic display message into the transcript. [#101](https://github.com/sagents-ai/sagents/pull/101) [#102](https://github.com/sagents-ai/sagents/pull/102)
- **`AskUserQuestion` config pinning** — optional `allow_other` / `allow_cancel` init options force those values for every question instead of leaving them to the LLM. [#124](https://github.com/sagents-ai/sagents/pull/124)
- **SubAgent `:initial_messages`** for seeding per-call messages, and **`:include_task_list`** to opt out of the auto-generated task menu. [#100](https://github.com/sagents-ai/sagents/pull/100) [#78](https://github.com/sagents-ai/sagents/pull/78)
- **`Sagents.AgentServer.save_synthetic_message_from/2`** — lets middleware persist user-facing transcript entries through the same display-message pipeline LLM messages use. `AskUserQuestion` records the user's answer this way. [#88](https://github.com/sagents-ai/sagents/pull/88) [#89](https://github.com/sagents-ai/sagents/pull/89)
- **`Sagents.State.runtime`** virtual field for process-local values that must never be persisted, with `merge_runtime/2`. [#84](https://github.com/sagents-ai/sagents/pull/84)
- **`agent_id` on tool execution context** (`context.agent_id`) so tools can publish events without reaching into `state`. [#86](https://github.com/sagents-ai/sagents/pull/86)
- Tooling hardening: Credo, Dialyzer, `sobelow`, and `mix_audit` wired into `mix precommit` and CI. [#93](https://github.com/sagents-ai/sagents/pull/93) [#90](https://github.com/sagents-ai/sagents/pull/90) [#106](https://github.com/sagents-ai/sagents/pull/106)

### Changed

- **BREAKING:** Transport, SubAgent tool arguments, session/factory API, debug subscriptions, the `FileSystem` tool set, and `Sagents.Todo` ids all changed — see the Upgrading section above. [#79](https://github.com/sagents-ai/sagents/pull/79) [#78](https://github.com/sagents-ai/sagents/pull/78) [#97](https://github.com/sagents-ai/sagents/pull/97) [#94](https://github.com/sagents-ai/sagents/pull/94) [#110](https://github.com/sagents-ai/sagents/pull/110) [#116](https://github.com/sagents-ai/sagents/pull/116)
- The generated persistence templates denormalize the tool-call linking id into a dedicated indexed `tool_call_id` column, switching the hot tool-execution queries from a JSONB `fragment(...)` to indexed equality. New generations are clean; existing host apps absorb this by regenerating as described above. [#127](https://github.com/sagents-ai/sagents/pull/127)
- `Sagents.Middleware` documents the full interrupt-data catalog (`:ask_user_question`, `:halt`, `:subagent_hitl`, HITL action-request map, `:multiple_interrupts`) and the "halt wins" policy. [#115](https://github.com/sagents-ai/sagents/pull/115)
- Upgraded to Elixir 1.20 and bumped the `langchain` dependency floor to `>= 0.8.11`. [#122](https://github.com/sagents-ai/sagents/pull/122) [#106](https://github.com/sagents-ai/sagents/pull/106)

For the per-RC `Added` / `Changed` / `Fixed` detail behind this summary — including bug fixes resolved within the RC cycle — see the archived [`v0.8.0-rc.13` changelog](https://github.com/sagents-ai/sagents/blob/v0.8.0-rc.13/CHANGELOG.md).

---

Changelog entries for `v0.1.0` through `v0.7.0` have been removed to give the `v0.8.0` line a clean slate. The full detailed history remains available in git — see the [`v0.8.0-rc.13` changelog](https://github.com/sagents-ai/sagents/blob/v0.8.0-rc.13/CHANGELOG.md), which retains every entry back to the initial release.
