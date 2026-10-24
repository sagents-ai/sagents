# Migration Guide: v0.18.x → v0.19.0

v0.19.0 adds provider tool search. An existing app keeps working after the
dependency bump, but three things need attention:

- **[Search display rows](#1-accept-the-tool_search-content-type).** New
  `"tool_search"` display messages show each search in the transcript. Your
  generated persistence files are your own copies, so they need the template
  changes by hand. Opt-in.
- **[Custom middleware ids in dynamic sub-agents](#5-check-middleware-with-custom-ids-in-dynamic-sub-agents).**
  The one behavior change. Search for the code it reaches.
- **[Turning tool search on](#6-turn-on-tool-search-optional).** Adding the
  middleware and declaring namespaces. Opt-in.

Nothing here is caught by the compiler. The steps are search-driven.

## What changed and why

An agent with many tools pays for every tool definition in the model's
context on every request, which costs accuracy and tokens. Removing tools
between requests changes the cached prompt prefix, and on current Anthropic
models it invalidates the signed thinking that came before the change.

Anthropic and the OpenAI Responses API offer **provider tool search** instead.
Every tool is declared on every request, most are marked deferred and kept out
of the model's context, and the model loads the ones it needs by searching.
The tool list and system prompt stay the same for the life of a conversation.

In Sagents:

- `Sagents.Middleware.ToolSearch` turns it on. It adds the provider's search
  tool.
- A middleware declares its tools as one **namespace** with the new optional
  `tool_search/1` callback. Its tools go out deferred and grouped.
- The system prompt carries a short **catalog** of the namespaces, because
  Anthropic shows the model nothing about deferred tools.
- A chat model without tool search leaves the search tool out and sends every
  tool normally, so the same agent runs on any chat model.

A search leaves provider items in the assistant message (an Anthropic
`server_tool_use` and `tool_search_tool_result`, or OpenAI `tool_search_call`
and `tool_search_output`). They are replayed unchanged on every later request,
and persist with the agent state with no change on your side.

To show a search in the transcript,
`Sagents.Message.DisplayHelpers.extract_display_items/2` takes a
`tool_search: true` option that adds a `:tool_search` display item for each
search. It is opt-in **at the extraction call** so that a persistence module
generated before v0.19.0 never produces a content type its schema would
reject. The v0.19.0 templates pass the option and accept the type. An existing
install gets none of that from the dependency bump.

| What | Where it lands | Required? |
| --- | --- | --- |
| `"tool_search"` content type and its validation | Your `DisplayMessage` schema | Only for search display rows |
| `extract_display_items(message, tool_search: true)` | Your `DisplayMessagePersistence` | Only for search display rows |
| `tool_search` in the trailing-answer scan | Your conversations context | Only for search display rows |
| A renderer for `"tool_search"` rows | Your UI | Only for search display rows |
| Custom `:id` middleware in dynamic sub-agents | Your host code and tests | **Check, if you have any** |

## Read this before you start

**There is no database migration.** `content_type` is a string column. The
new rows use the existing table and indexes.

**Order matters for the display steps.** Do step 1 before step 2. The generated
persistence module saves a message's rows one at a time with `reduce_while`
and stops at the first insert that fails. If it emits a `"tool_search"` row
before your schema accepts that type, the search row fails validation, and
every row after it in that message is lost too, including the answer text.
AgentServer logs `Failed to persist DisplayMessage (tool_search)` and carries
on, so the agent keeps working while the transcript drops content.

**Nothing changes until you opt in.** An app that does not add
`Sagents.Middleware.ToolSearch` sends the same requests as before, and an app
that does not pass `tool_search: true` produces the same display rows as
before.

**The compiler will not help you.** The generated modules are your copies, and
the custom-id change alters a runtime value. Work the steps in order and run
the searches.

---

## Prerequisites

1. Start from a clean, committed workspace.
2. Update the dependency to `~> 0.19.0` and run `mix deps.get`. v0.19.0
   requires `langchain` `>= 0.15.5`; run `mix deps.update langchain` if your
   lock holds an older one. If your app uses `LangChain.ChatModels.ChatReqLLM`,
   langchain 0.15.5 requires `req_llm` `>= 1.29.0`.
3. Run `mix compile`. It will be clean. That is expected, not evidence that
   there is nothing to do.
4. Find your generated persistence modules. The defaults are
   `MyApp.Conversations`, `MyApp.Conversations.DisplayMessage`, and
   `MyApp.Agents.DisplayMessagePersistence`:

   ```
   grep -rln "@behaviour Sagents.DisplayMessagePersistence" lib/
   grep -rln "@content_types ~w(" lib/
   grep -rn "def trailing_answer_row_ids" lib/
   ```

---

## Migration Steps

Steps 1 through 4 add search display rows. Skip them if you do not want
searches in the transcript; tool search works without them. Steps 5 and 7
apply to every app.

### 1. Accept the `"tool_search"` content type

In your `DisplayMessage` schema, add the type to the list it validates
against:

```elixir
# Before
@content_types ~w(text thinking image file_reference structured_data notification error tool_call tool_result todo_snapshot)

# After
@content_types ~w(text thinking image file_reference structured_data notification error tool_call tool_result todo_snapshot tool_search)
```

Then add a clause for its content shape. It goes among the other
`validate_content/2` clauses, before the catch-all that returns
`{:error, "invalid structure for content_type ..."}`:

```elixir
defp validate_content("tool_search", %{"tools" => tools, "namespaces" => namespaces})
     when is_list(tools) and is_list(namespaces),
     do: :ok
```

Both keys are always present and always lists, possibly empty. Without this
clause the row fails with `invalid structure for content_type tool_search`.

Optionally, document the type in the schema's moduledoc beside the others, as
the template does:

```
- `"tool_search"` - A provider tool search, or tools loaded by a tool's
  `:tool_reference` result. See `Sagents.Middleware.ToolSearch`
```

```
- Tool search: `%{"tools" => ["devices_list"], "namespaces" => ["devices"], "provider" => "openai", "query" => "devices"}`.
  `"provider"` and `"query"` are absent for a load made by a tool result, which
  carries `"tool_call_id"` instead. `"error" => true` marks a failed search.
```

---

### 2. Pass `tool_search: true` when extracting display items

In your `DisplayMessagePersistence` module's `save_message/3`:

```elixir
# Before
display_items = DisplayHelpers.extract_display_items(message)

# After
# `tool_search: true` adds a "tool_search" row for each provider tool
# search. The DisplayMessage schema accepts that content type.
display_items = DisplayHelpers.extract_display_items(message, tool_search: true)
```

Nothing else in `save_message/3` changes. In particular, **do not** copy a
`tool_search` row's `"tool_call_id"` into the `tool_call_id` column. A row for
tools loaded by a tool result carries the id of the call that loaded them in
its content, but the tool lifecycle queries find the tool call's row by that
column, and a second row with the same id there confuses them. The generated
`case` that fills the column matches only `:tool_call` and `:tool_result`
items, which is correct as it is.

The items come out in display order. A provider search sits between the text
and thinking items around it, and a load made by a tool result follows that
result's `:tool_result` item. The generated code numbers them with
`Enum.with_index/1`, so `sequence` keeps that order.

---

### 3. Keep search rows inside a final answer

`trailing_answer_row_ids/3` in your conversations context finds a user
request's final answer when its rows were not reported, by walking back over
the request's trailing assistant rows. A final answer can contain a search:
the model searched, found nothing useful, and answered. A `tool_search` row
from the answer's own message should not end that walk.

```elixir
# Before
|> Enum.take_while(
  &(&1.message_type == "assistant" and &1.content_type in ~w(text thinking))
)

# After
|> Enum.take_while(
  &(&1.message_type == "assistant" and &1.content_type in ~w(text thinking tool_search))
)
```

The `Enum.filter(&(&1.content_type == "text"))` after it is unchanged, so only
the text rows are returned. A row for a load made by a tool result has
`message_type: "tool"`, and still ends the walk.

---

### 4. Render `"tool_search"` rows in your UI

Find where your UI picks a renderer by content type:

```
grep -rn "content_type: \"todo_snapshot\"\|content_type == \"todo_snapshot\"" lib/ --include="*.ex"
grep -rn "\"todo_snapshot\" ->" lib/ --include="*.ex"
```

If it falls through to a text renderer for unknown types, a `"tool_search"`
row has no `"text"` key and renders as an empty bubble, or nothing. Add a
clause for it. The content:

| Key | Present | Value |
| --- | --- | --- |
| `"tools"` | Always | Tool names the search loaded, possibly `[]` |
| `"namespaces"` | Always | Namespaces it loaded, possibly `[]`. Only OpenAI names them, so an Anthropic search has `[]` |
| `"provider"` | Provider searches | `"anthropic"` or `"openai"` |
| `"query"` | When the provider reports one | What the model searched for |
| `"error"` | Failed searches | `true` |
| `"tool_call_id"` | Loads made by a tool result | The call whose result loaded the tools |
| `"stop_reason"` | When it is the last item of an unfinished message | As on every other row |

A minimal LiveView clause and component:

```elixir
defp message_body(%{message: %{content_type: "tool_search"}} = assigns) do
  ~H"""
  <.tool_search_row message={@message} />
  """
end

defp tool_search_row(assigns) do
  content = assigns.message.content || %{}

  assigns =
    assign(assigns,
      tools: Map.get(content, "tools", []),
      namespaces: Map.get(content, "namespaces", []),
      query: Map.get(content, "query"),
      error?: Map.get(content, "error") == true,
      by_tool?: Map.has_key?(content, "tool_call_id")
    )

  ~H"""
  <div id={"tool-search-#{@message.id}"} data-content-type="tool_search">
    <span>
      <%= cond do %>
        <% @error? -> %>
          Tool search failed
        <% @by_tool? -> %>
          Loaded tools
        <% true -> %>
          Searched tools
      <% end %>
    </span>
    <span :if={@query}>for "{@query}"</span>
    <span :if={!@error? and @tools == [] and @namespaces == []}>· nothing found</span>
    <span :for={namespace <- @namespaces} class="namespace-chip">{namespace}</span>
    <span :for={tool <- @tools} class="tool-chip">{tool}</span>
  </div>
  """
end
```

A search is the model working rather than replying, so a status-line style
reads better than a chat bubble. The `agents_demo` project's
`ChatComponents.tool_search_display/1` is a styled version. Show "nothing
found" and the failure case: a search that came back empty explains the
answer that follows it.

---

### 5. Check middleware with custom ids in dynamic sub-agents

`Sagents.MiddlewareEntry.to_raw_spec/1` now keeps a custom `:id`. It drops
only an `:id` equal to the module, which is the default. Dynamic
(general-purpose) sub-agents rebuild their middleware from the parent's with
`to_raw_spec/1`, so:

- **Before:** a middleware given a custom `:id` came back in a dynamic
  sub-agent under its module name. Two instances of one module shared that one
  id there.
- **Now:** it keeps its custom id in the sub-agent, as in the parent.

Find middleware with a custom id:

```
grep -rn "id: \"" lib/ --include="*.ex" | grep -v "agent_id\|call_id\|conversation_id"
grep -rn "{Sagents.Middleware.\w*, \[*id:" lib/ --include="*.ex"
```

For each one that a dynamic sub-agent inherits (it is not in the
`SubAgent` middleware's `block_middleware` list), check code that finds or
addresses it **inside a sub-agent** by its module:

```
grep -rn "notify_middleware" lib/ test/ --include="*.ex*"
grep -rn "\.id == \|id: Sagents.Middleware\.\|&1.id ==" lib/ test/ --include="*.ex*"
```

- `Sagents.AgentServer.notify_middleware/3` and middleware messaging route by
  the entry id. A message addressed to a sub-agent's copy by module name now
  needs the custom id.
- Code or tests that look a sub-agent's middleware up by
  `entry.id == SomeModule` now find it under the custom id.

Middleware that addresses itself through its own config (for example
`Map.get(config, :id, __MODULE__)`) needs no change: its config and its entry
agree, as they always did.

The change also fixes two things you may have worked around:

- Two instances of one middleware module with different ids now stay distinct
  in a sub-agent. Workarounds that blocked one of them from sub-agents can go.
- A `Sagents.Middleware.ToolSearch` `:namespaces` override keyed by a custom
  id applies in a dynamic sub-agent.

---

### 6. Turn on tool search (optional)

Add `Sagents.Middleware.ToolSearch` to the stack and declare a namespace on a
domain middleware:

```elixir
defmodule MyApp.Middleware.Devices do
  @behaviour Sagents.Middleware

  @impl true
  def tool_search(_config) do
    [
      namespace: "devices",
      description: "List, inspect, and restart the managed devices at a site."
    ]
  end

  # tools/1, system_prompt/1, ... as before
end

Agent.new(%{
  model: model,
  middleware: [
    Sagents.Middleware.ToolSearch,
    MyApp.Middleware.Devices
  ]
})
```

To make a third-party middleware a namespace, or to rename or turn off a
namespace, use the switch's `:namespaces` option, keyed by entry id:

```elixir
{Sagents.Middleware.ToolSearch,
 namespaces: %{
   ThirdParty.Middleware.Billing => [namespace: "billing", description: "Invoices and balances."],
   MyApp.Middleware.Devices => false
 }}
```

Things to know before turning it on:

- **It must be outside every ability set.** `Agent.new/2` rejects
  `ToolSearch` inside one. A middleware inside an ability set may still declare
  a namespace.
- **A namespaced middleware's system prompt fragment is always sent,** and it
  cannot change when the namespace loads, because that would change the
  cached prompt. Write it for tools the model has not loaded yet ("To restart
  a device that is not responding, load the devices tools."), or return none.
- **`Agent.new/2` validates namespaces.** A name must match
  `^[a-z][a-z0-9_]{0,63}$` and have a description. Ten or more functions in one
  namespace log a warning; OpenAI recommends fewer.
- **The catalog** (a system prompt fragment listing the namespaces) is on by
  default. Anthropic needs it. On OpenAI it costs a few cached tokens per
  request; `catalog: false` turns it off.
- **Supported chat models:** `ChatAnthropic`, `ChatOpenAIResponses`, and
  `ChatReqLLM` on `anthropic:` or `openai:` models. Every other chat model
  leaves the search tool out and sends every tool, so a fallback model or a
  model swap keeps working. See `LangChain.NativeTool` for the table.

To observe it: `Sagents.ToolSearch.loaded(state, agent.tools)` returns the
namespaces and tools a conversation has loaded, and each message holding
search results emits `[:sagents, :tool_search, :loaded]` telemetry with
`%{count: n}` and `%{agent_id:, namespaces:, tools:}`.

See the `Sagents.Middleware.ToolSearch` and `Sagents.ToolSearch` moduledocs.

---

### 7. Behavior changes that need no code

**`tools/1` may return native tools.** The `c:Sagents.Middleware.tools/1`
callback's type now allows `LangChain.NativeTool` as well as
`LangChain.Function`. Code that walks an agent's tools and assumes every one
is a `%LangChain.Function{}` (reading `.function`, `.parameters_schema`, or
`.options`) sees the search tool once `ToolSearch` is in the stack:

```
grep -rn "%LangChain.Function{\|%Function{" lib/ --include="*.ex" | grep -i "tools"
```

Match on `%LangChain.Function{}` or skip `%LangChain.NativeTool{}` there. Every
tool has a `.name`.

**`MiddlewareEntry` has a `tool_search` field.** It is `nil` unless the stack
holds `ToolSearch`. Tests that build `%MiddlewareEntry{}` with all fields, or
compare entries with `==`, see it.

**Search items in saved state** round-trip with the existing serializer, as
`:provider_item` content parts. Nothing to do. A display layer that reads
message content parts directly, rather than through
`DisplayHelpers.extract_display_items/2`, should skip parts of type
`:provider_item` and `:tool_reference`.

---

## Verifying the migration

A green suite does not prove search rows are saved. Check the data.

### Check 1: a search is saved and shown

With steps 1 through 4 done and `ToolSearch` plus a namespaced middleware in
your stack, send a message that needs a deferred tool, wait for the answer,
then in `iex -S mix`:

```elixir
scope = # your scope for that user
conversation_id = # the conversation

MyApp.Conversations.load_display_messages(scope, conversation_id)
|> Enum.map(&{&1.sequence, &1.message_type, &1.content_type, &1.content})
```

Expect a `"tool_search"` row with `"tools"` naming the loaded tools, ahead of
the `"tool_call"` row for the tool the model then called, and the answer's
text row after them.

| What you see | Cause |
| --- | --- |
| No `"tool_search"` row | Step 2 not done, or the model did not search |
| `Failed to persist DisplayMessage (tool_search)` in the log, and missing rows after it | Step 1 not done, or done after step 2 |
| `invalid structure for content_type tool_search` | Step 1's `validate_content/2` clause is missing or after the catch-all |
| An empty bubble where the search should be | Step 4 |

### Check 2: an answer that searched still collapses

If your UI folds a finished request's work behind its answer, send a message
the model answers after a search, and confirm only the work is folded and the
answer text stays visible. If the answer is folded away or nothing collapses,
check step 3.

### Check 3: read the inventory back

```
grep -rn "tool_search" lib/ --include="*.ex"
```

It finds the schema's `@content_types` and `validate_content/2` clause, the
`extract_display_items/2` call, the trailing-answer scan, your renderer, and,
if you turned it on, `ToolSearch` in your stack and your `tool_search/1`
callbacks.

---

## Recommended approach for generated files

Steps 1 through 3 are template changes. Steps 4 through 7 are host code, which
no template covers.

**If your generated modules are close to stock,** start from a clean
workspace, re-run `mix sagents.setup` with the same options used originally,
accept the overwrites, and diff your customizations back in. The v0.19.0
templates contain steps 1 through 3. **Then delete any migration the generator
just wrote.** It creates every persistence table from scratch and fails
against an existing database. v0.19.0 needs no migration.

**If they have drifted,** apply the steps by hand. They are small.

**Either way, the templates are the authority.** They ship inside the package,
so the exact upstream delta is two commands away:

```
# Use the version you are upgrading from.
mix hex.package fetch sagents 0.18.1 --unpack --output /tmp/sagents-old
diff -u /tmp/sagents-old/priv/templates/display_message_persistence.ex.eex \
        deps/sagents/priv/templates/display_message_persistence.ex.eex
```

Repeat for `sagents.gen.persistence/display_message.ex.eex` and
`sagents.gen.persistence/context.ex.eex`.

**Either way, do step 5 and Check 1.** The custom-id change is the one place
this upgrade changes behavior without your opting in, and the data check is
the only evidence the display steps are wired.

For details on the design, see the `Sagents.Middleware.ToolSearch`,
`Sagents.ToolSearch`, and `Sagents.Message.DisplayHelpers` moduledocs.
