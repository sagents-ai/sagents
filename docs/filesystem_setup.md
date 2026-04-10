# FileSystem Setup Guide

This guide covers how to set up, configure, and populate the `FileSystemServer` so agents can read and write files. It explains the relationship between the filesystem process, the `FileSystem` middleware, and your application code.

## Overview

The `FileSystem` middleware gives agents tools like `list_files`, `read_file`, `create_file`, `replace_text`, `replace_lines`, `update_file_attrs`, and `delete_file`. But the middleware itself holds no file data — it is a thin client that delegates every operation to a `FileSystemServer` GenServer, identified by a **scope key** like `{:user, 123}`.

This means:

- **`FileSystemServer` must be started before the agent runs.** The middleware will look up the server by scope key and fail if it isn't running.
- **`FileSystemServer` outlives individual agent sessions.** It runs under its own supervisor (`FileSystemSupervisor`), independent of agent lifecycles.
- **Multiple conversations can share one filesystem.** Any agent configured with `filesystem_scope: {:user, 123}` talks to the same server and sees the same files.

```
Your Application
  └── FileSystemSupervisor (DynamicSupervisor)
        └── FileSystemServer {:user, 1}   ← started by your app, not by the agent
        └── FileSystemServer {:user, 2}
        └── FileSystemServer {:project, 42}

  └── AgentsDynamicSupervisor
        └── AgentSupervisor (conversation-101)
              └── AgentServer   ← uses FileSystemServer {:user, 1} via scope key
        └── AgentSupervisor (conversation-102)
              └── AgentServer   ← also uses FileSystemServer {:user, 1}
```

## The Three Steps

### 1. Start the FileSystemServer

Call `FileSystem.ensure_filesystem/3` before starting any agent session. This is idempotent — safe to call on every page load or connection.

```elixir
alias Sagents.FileSystem
alias Sagents.FileSystem.FileSystemConfig
alias Sagents.FileSystem.Persistence.Disk

scope_key = {:user, user_id}

{:ok, fs_config} = FileSystemConfig.new(%{
  base_directory: "Memories",
  persistence_module: Disk,
  debounce_ms: 5_000,
  storage_opts: [path: "/var/lib/myapp/user_files/#{user_id}"]
})

{:ok, _pid} = FileSystem.ensure_filesystem(scope_key, [fs_config])
```

On startup, the `Disk` persistence module calls `list_persisted_files/2` to discover all existing files in the storage path and registers them in the server with `loaded: false`. Files are then loaded lazily on first access — the server only reads the actual content from disk when the agent calls `read_file`.

### 2. Pass the scope to the agent

Pass the same scope key to your `Factory` when creating the agent:

```elixir
{:ok, agent} = MyApp.Agents.Factory.create_agent(
  agent_id: agent_id,
  filesystem_scope: {:user, user_id}
)
```

In your `Factory`, this is forwarded to the `FileSystem` middleware:

```elixir
defp build_middleware(filesystem_scope, ...) do
  [
    {Sagents.Middleware.FileSystem, [filesystem_scope: filesystem_scope]},
    ...
  ]
end
```

### 3. Start the agent session

The agent connects to the already-running `FileSystemServer` automatically through the scope key. No further setup is needed.

```elixir
{:ok, session} = MyApp.Agents.Coordinator.start_conversation_session(
  conversation_id,
  filesystem_scope: {:user, user_id}
)
```

## Where to Start the Filesystem

The filesystem must be started before the agent, so the right place is wherever your application first needs it — typically the LiveView `mount/3`.

```elixir
# In your LiveView
def mount(_params, _session, socket) do
  user_id = socket.assigns.current_scope.user.id

  filesystem_scope =
    case MyApp.Agents.Setup.ensure_user_filesystem(user_id) do
      {:ok, scope} -> scope
      {:error, reason} ->
        Logger.warning("Failed to start filesystem: #{inspect(reason)}")
        nil
    end

  {:ok, assign(socket, filesystem_scope: filesystem_scope)}
end
```

Since `ensure_filesystem/3` is idempotent, it is safe to call on every `mount`. If the `FileSystemServer` is already running for that scope key, the call is a no-op that returns the existing PID.

The filesystem continues running after the LiveView disconnects and the agent shuts down due to inactivity. It persists for the lifetime of your application process (or until explicitly stopped), so returning users find their files intact.

## Scoping Strategies

The scope key determines how files are isolated and shared:

| Scope | Key format | Files visible to |
|---|---|---|
| Per-user | `{:user, user_id}` | All conversations for that user |
| Per-project | `{:project, project_id}` | All agents working on that project |
| Per-conversation | `{:agent, agent_id}` | Only that specific conversation |
| Custom | `{:team, team_id}` | Any tuple you choose |

For most user-facing chat applications, **user-scoped** is the right default. It lets the agent's files accumulate across conversations, creating a persistent long-term memory.

## Seeding Files for New Users

When a user's storage directory doesn't exist yet, you can copy template files to give them a helpful starting point. Check for the directory before starting the filesystem:

```elixir
defmodule MyApp.Agents.Setup do
  alias Sagents.FileSystem
  alias Sagents.FileSystem.{FileSystemConfig, Persistence.Disk}

  def ensure_user_filesystem(user_id) do
    storage_path = user_storage_path(user_id)
    scope_key = {:user, user_id}

    # Seed template files for new users before starting the server
    if not File.exists?(storage_path) do
      File.mkdir_p!(storage_path)
      seed_new_user_files(storage_path)
    end

    {:ok, fs_config} = FileSystemConfig.new(%{
      base_directory: "Memories",
      persistence_module: Disk,
      debounce_ms: 5_000,
      storage_opts: [path: storage_path]
    })

    case FileSystem.ensure_filesystem(scope_key, [fs_config]) do
      {:ok, _pid} -> {:ok, scope_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_new_user_files(storage_path) do
    template_path = Path.join(:code.priv_dir(:my_app), "new_user_template")

    if File.exists?(template_path) do
      copy_directory_contents(template_path, storage_path)
    end
  end

  defp copy_directory_contents(source, dest) do
    {:ok, entries} = File.ls(source)

    Enum.each(entries, fn entry ->
      src = Path.join(source, entry)
      dst = Path.join(dest, entry)

      if File.dir?(src) do
        File.mkdir_p!(dst)
        copy_directory_contents(src, dst)
      else
        File.cp!(src, dst)
      end
    end)
  end

  defp user_storage_path(user_id) do
    base = Application.get_env(:my_app, :user_files_path, "user_files")
    Path.join([base, to_string(user_id), "memories"])
  end
end
```

Place template files in `priv/new_user_template/` in your application. They are copied once when the directory is first created and left alone for returning users.

## Database-Backed Persistence

For production applications, you may want to store files in your database instead of on disk. Implement the `Sagents.FileSystem.Persistence` behaviour:

```elixir
defmodule MyApp.FileSystem.DBPersistence do
  @behaviour Sagents.FileSystem.Persistence

  alias MyApp.{Repo, UserFile}
  import Ecto.Query

  @impl true
  def list_persisted_files(_scope_key, opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    paths =
      UserFile
      |> where([f], f.user_id == ^user_id)
      |> select([f], f.path)
      |> Repo.all()

    {:ok, paths}
  end

  @impl true
  def load_from_storage(entry, opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    case Repo.get_by(UserFile, user_id: user_id, path: entry.path) do
      nil ->
        {:error, :enoent}

      file ->
        {:ok, %{entry | content: file.content, loaded: true, dirty: false}}
    end
  end

  @impl true
  def write_to_storage(entry, opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    result =
      case Repo.get_by(UserFile, user_id: user_id, path: entry.path) do
        nil ->
          %UserFile{}
          |> UserFile.changeset(%{user_id: user_id, path: entry.path, content: entry.content})
          |> Repo.insert()

        existing ->
          existing
          |> UserFile.changeset(%{content: entry.content})
          |> Repo.update()
      end

    case result do
      {:ok, _} -> {:ok, %{entry | dirty: false}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def delete_from_storage(entry, opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    UserFile
    |> where([f], f.user_id == ^user_id and f.path == ^entry.path)
    |> Repo.delete_all()

    :ok
  end
end
```

Configure it in place of `Disk`:

```elixir
{:ok, fs_config} = FileSystemConfig.new(%{
  base_directory: "Memories",
  persistence_module: MyApp.FileSystem.DBPersistence,
  debounce_ms: 5_000,
  storage_opts: [user_id: user_id]
})
```

The `storage_opts` keyword list is passed through to every persistence callback, so you can include whatever context your implementation needs (`user_id`, `tenant_id`, S3 bucket name, etc.).

If you want the LLM to see and edit *application-defined attributes* on these entries (status, tags, author, word count, etc.), pair this backend with a `FileSchema` — see [Customizing What the LLM Sees: FileSchema](#customizing-what-the-llm-sees-fileschema) below.

## Customizing What the LLM Sees: FileSchema

By default, when the agent calls `list_files` or `update_file_attrs`, the LLM sees a generic `FileEntry` shape — `path`, `title`, `entry_type`, `file_type`, `persistence`, and `size`. For many applications that's enough. But if you want to expose **domain-specific attributes** like `tags`, `status`, `author`, `published_at`, `word_count`, etc. — and have the LLM read or update them through built-in tools — you need to teach the filesystem two things:

- **What attributes exist and how to validate them** (when the LLM proposes a change)
- **How to render a file entry as JSON the LLM will understand** (when the LLM reads or lists)

`Sagents.FileSystem.FileSchema` is the behaviour that captures both, in a single module.

### The two callbacks

| Callback | When called | Purpose |
|---|---|---|
| `changeset(attrs)` | LLM calls `update_file_attrs` | Cast and validate the LLM's proposed attribute changes. Returns an `Ecto.Changeset`. Invalid changesets become tool errors so the LLM can self-correct on its next turn. |
| `to_llm_map(entry)` | `list_files`, `create_file`, and `update_file_attrs` responses | Convert a `FileEntry` into the JSON map sent back to the LLM. You decide which fields are visible and how they're shaped. |

`Sagents.FileSystem.FileEntry` itself implements `FileSchema`, which is why the basic setup just works — when no schema is configured, the middleware uses `FileEntry`'s own `changeset/1` and `to_llm_map/1` as the defaults.

### Example: a `DocumentFileSchema`

```elixir
defmodule MyApp.DocumentFileSchema do
  @behaviour Sagents.FileSystem.FileSchema

  use Ecto.Schema
  import Ecto.Changeset

  alias Sagents.FileSystem.FileEntry

  @primary_key false
  embedded_schema do
    field :title, :string
    field :system_tag, :string
    field :tags, {:array, :string}, default: []
    field :status, :string
  end

  @impl true
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:title, :system_tag, :tags, :status])
    |> validate_inclusion(:system_tag, ~w(draft review approved published))
  end

  @impl true
  def to_llm_map(%FileEntry{} = entry) do
    custom = (entry.metadata && entry.metadata.custom) || %{}

    %{
      path: entry.path,
      title: entry.title,
      file_type: entry.file_type,
      system_tag: custom["system_tag"],
      tags: custom["tags"],
      status: custom["status"],
      size: entry.metadata && entry.metadata.size
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
end
```

The `embedded_schema` declares what attributes exist and what their types are. The `changeset/1` callback decides which of those are accepted from the LLM and what validations apply. The `to_llm_map/1` callback decides what the LLM sees back — note that it pulls custom attributes out of `entry.metadata.custom` (string-keyed) and surfaces them as top-level fields in the response.

### Wiring it in — at the middleware level

This is the most important detail to get right: `:file_schema` is configured on `Sagents.Middleware.FileSystem`, **not** on `FileSystemConfig`. `FileSystemConfig` describes persistence (where data lives); `FileSchema` describes the LLM-facing surface (what attributes exist). They're two independent dimensions.

```elixir
# In your agent factory
{:ok, agent} = Sagents.Agent.new(%{
  model: model,
  middleware: [
    {Sagents.Middleware.FileSystem, [
      filesystem_scope: {:user, user_id},
      file_schema: MyApp.DocumentFileSchema
    ]},
    # ... other middleware
  ]
})
```

If `:file_schema` is omitted, the middleware uses `Sagents.FileSystem.FileEntry` itself as the default schema.

### How updates flow: automatic field routing

When the LLM calls `update_file_attrs`, the middleware handles the entire lifecycle for you:

1. The LLM calls `update_file_attrs` with, for example, `attrs: %{"title" => "New Title", "system_tag" => "draft", "tags" => ["a", "b"]}`.
2. The middleware calls `MyApp.DocumentFileSchema.changeset(attrs)`. If the changeset is invalid, the formatted error is returned to the LLM as a tool error so it can retry with a corrected payload.
3. The middleware takes the validated changes and splits them against the built-in `FileEntry` struct fields `[:title, :id, :file_type]`:
   - **`:title`** matches a struct field → routed to `Sagents.FileSystemServer.update_entry/4` (modifies the `FileEntry` struct directly).
   - **`:system_tag`, `:tags`** don't match → routed to `Sagents.FileSystemServer.update_custom_metadata/4` (stored as string-keyed entries in `entry.metadata.custom`).
4. The middleware reads the updated entry, calls `to_llm_map(entry)`, and returns the JSON to the LLM.

You don't write any routing code. You only declare fields in the schema; the middleware decides where each one belongs.

> **`update_file_attrs` is metadata-only.** If your schema includes `:content` in its cast list, the middleware rejects the change with an error directing the LLM to use `replace_text`, `replace_lines`, or `create_file` instead. File content is never changed through `update_file_attrs`.

### Mapping a domain entity into the filesystem

The headline use case for `FileSchema` is exposing existing application entities (database rows, blog posts, knowledge-base articles) as files the LLM can interact with through built-in tools. The recipe combines a custom `Persistence` backend (for loading and saving) with a custom `FileSchema` (for validation and presentation):

```elixir
# 1. Your domain entity
defmodule MyApp.Document do
  use Ecto.Schema

  schema "documents" do
    field :slug, :string
    field :title, :string
    field :body, :string
    field :status, :string
    field :tags, {:array, :string}
    field :user_id, :integer
    timestamps()
  end
end

# 2. Persistence — loads Documents as FileEntries
defmodule MyApp.DocumentPersistence do
  @behaviour Sagents.FileSystem.Persistence

  import Ecto.Query
  alias Sagents.FileSystem.{FileEntry, FileMetadata}
  alias MyApp.{Repo, Document}

  @impl true
  def list_persisted_entries(_scope_key, opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    entries =
      Document
      |> where(user_id: ^user_id)
      |> Repo.all()
      |> Enum.map(&document_to_entry/1)

    {:ok, entries}
  end

  @impl true
  def load_from_storage(entry, opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    case Repo.get_by(Document, user_id: user_id, slug: entry.id) do
      nil -> {:error, :enoent}
      doc -> {:ok, %{entry | content: doc.body, loaded: true, dirty_content: false}}
    end
  end

  @impl true
  def write_to_storage(entry, opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    custom = (entry.metadata && entry.metadata.custom) || %{}

    attrs = %{
      user_id: user_id,
      slug: entry.id,
      title: entry.title,
      body: entry.content,
      status: custom["status"],
      tags: custom["tags"] || []
    }

    result =
      case Repo.get_by(Document, user_id: user_id, slug: entry.id) do
        nil -> %Document{} |> Document.changeset(attrs) |> Repo.insert()
        doc -> doc |> Document.changeset(attrs) |> Repo.update()
      end

    case result do
      {:ok, _} -> {:ok, %{entry | dirty_content: false}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def delete_from_storage(entry, opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    Document
    |> where([d], d.user_id == ^user_id and d.slug == ^entry.id)
    |> Repo.delete_all()

    :ok
  end

  defp document_to_entry(%Document{} = doc) do
    {:ok, metadata} =
      FileMetadata.new("", custom: %{
        "status" => doc.status,
        "tags" => doc.tags
      })

    %FileEntry{
      path: "/documents/#{doc.slug}.md",
      id: doc.slug,
      title: doc.title,
      file_type: "markdown",
      entry_type: :file,
      persistence: :persisted,
      loaded: false,
      metadata: metadata
    }
  end
end

# 3. Wire them together
{:ok, fs_config} = FileSystemConfig.new(%{
  default: true,
  persistence_module: MyApp.DocumentPersistence,
  storage_opts: [user_id: user_id]
})

{:ok, _pid} = FileSystem.ensure_filesystem({:user, user_id}, [fs_config])

# In your agent factory:
{Sagents.Middleware.FileSystem, [
  filesystem_scope: {:user, user_id},
  file_schema: MyApp.DocumentFileSchema
]}
```

This is the canonical pattern: **`Persistence` decides how entities are loaded and saved; `FileSchema` decides how they appear and what the LLM is allowed to change about them.** Together they let an existing application expose its domain objects to the agent as files, with no custom tools required.

Notice how `entry.id` doubles as the slug for lookups — using a stable identifier rather than the path makes renames safe. The path is presentation; the id is identity.

### Tips and gotchas

- **Custom metadata keys are strings, not atoms.** Read them as `entry.metadata.custom["status"]`, not `[:status]`. The middleware stringifies keys before storing them, regardless of how your schema declared the fields.
- **Don't put `:content` in your schema's cast list.** It's metadata only; content is changed via `replace_text`, `replace_lines`, or `create_file`. The middleware enforces this by raising a tool error if `:content` shows up in validated changes.
- **`:title`, `:id`, and `:file_type`** are the only built-in `FileEntry` struct fields the LLM can update through `update_file_attrs`; everything else falls into `metadata.custom` automatically. If your domain "title" really is the file's display name, declaring `:title` in your schema will cause the routing to write it to the struct field — exactly what you want.
- **`to_llm_map` is the LLM's view of the file.** You can rename, hide, or reformat any field. Invest in keeping this map small and unambiguous; it directly affects how well the LLM uses your files.
- **Validation errors become LLM tool errors.** Use `validate_inclusion`, `validate_number`, `validate_format`, etc. liberally — when the LLM passes a bad value, it sees the changeset error in the tool result and can self-correct on the next turn without any application code in the loop.

## Default Configs — Catch-All Persistence

When you want a single persistence backend to handle **all** file paths (not just a specific directory), set `default: true` on your `FileSystemConfig`. This makes it a catch-all that matches any path not claimed by a more specific config.

With `default: true`, the `base_directory` field is **optional** — if omitted, a sentinel value is used internally. This is useful when all files should go to one backend regardless of path:

```elixir
# All files persisted to DB, no directory restriction
{:ok, fs_config} = FileSystemConfig.new(%{
  default: true,
  persistence_module: MyApp.FileSystem.DBPersistence,
  debounce_ms: 5_000,
  storage_opts: [user_id: user_id]
})

{:ok, _pid} = FileSystem.ensure_filesystem({:user, user_id}, [fs_config])
```

With this setup, the agent can write to any path — `/notes.txt`, `/projects/plan.md`, `/deep/nested/file.txt` — and all files are persisted through the same backend.

You can still provide an explicit `base_directory` with `default: true` if you want a meaningful label, but it is not required and has no effect on path matching.

## Multiple Persistence Backends

A single `FileSystemServer` can serve files from multiple backends simultaneously. Pass a list of `FileSystemConfig` structs, one per virtual directory:

```elixir
# Writable user memories stored on disk
{:ok, memories_config} = FileSystemConfig.new(%{
  base_directory: "Memories",
  persistence_module: Disk,
  debounce_ms: 5_000,
  storage_opts: [path: "/var/lib/myapp/user_files/#{user_id}"]
})

# Read-only shared reference documents from S3
{:ok, reference_config} = FileSystemConfig.new(%{
  base_directory: "Reference",
  persistence_module: MyApp.S3Persistence,
  readonly: true,
  storage_opts: [bucket: "my-app-shared", prefix: "reference-docs/"]
})

{:ok, _pid} = FileSystem.ensure_filesystem(
  {:user, user_id},
  [memories_config, reference_config]
)
```

The agent will see both directories via `ls` but will receive an error if it tries to write to `/Reference/`.

### Default Config with Specific Overrides

You can combine a `default: true` catch-all with specific directory overrides. The specific configs take priority for their directories, and everything else falls through to the default:

```elixir
# Default: all files go to DB
{:ok, default_config} = FileSystemConfig.new(%{
  default: true,
  persistence_module: MyApp.FileSystem.DBPersistence,
  storage_opts: [user_id: user_id]
})

# Override: /Reference/* served read-only from S3
{:ok, reference_config} = FileSystemConfig.new(%{
  base_directory: "Reference",
  persistence_module: MyApp.S3Persistence,
  readonly: true,
  storage_opts: [bucket: "my-app-shared", prefix: "reference-docs/"]
})

{:ok, _pid} = FileSystem.ensure_filesystem(
  {:user, user_id},
  [default_config, reference_config]
)
```

With this setup:
- `/Reference/guide.pdf` → read-only S3 config (specific match wins)
- `/notes.txt` → writable DB config (default catch-all)
- `/projects/plan.md` → writable DB config (default catch-all)

## Pre-Populating Files at Runtime

For files that don't come from a persistence backend — for example, injecting dynamic context before a conversation begins — use `FileSystemServer.register_files/2`:

```elixir
alias Sagents.FileSystemServer
alias Sagents.FileSystem.FileEntry

scope_key = {:user, user_id}

# Ensure the server is running first
{:ok, _pid} = FileSystem.ensure_filesystem(scope_key, [fs_config])

# Inject a dynamic file into memory (not persisted)
{:ok, entry} = FileEntry.new_memory_file(
  "/session/context.md",
  "User's current project: #{project.name}\nRecent activity: ..."
)

FileSystemServer.register_files(scope_key, entry)
```

Memory-only files (created with `FileEntry.new_memory_file/2`) exist only for the lifetime of the `FileSystemServer` process and are not written to any persistence backend.

## Real-Time File Change Notifications

Subscribe to the `FileSystemServer`'s PubSub topic to receive events when the agent creates, edits, or deletes files. This is useful for updating a file browser in your UI.

Requires the server to be started with a PubSub configuration:

```elixir
{:ok, _pid} = FileSystem.ensure_filesystem(
  scope_key,
  [fs_config],
  pubsub: {Phoenix.PubSub, MyApp.PubSub}
)
```

Then subscribe in your LiveView:

```elixir
# In mount/3 (connected socket only)
if connected?(socket) do
  FileSystemServer.subscribe(scope_key)
end

# Handle events
def handle_info({:file_system, {:file_updated, path}}, socket) do
  # Refresh your file list UI
  {:noreply, update_file_list(socket)}
end

def handle_info({:file_system, {:file_deleted, path}}, socket) do
  {:noreply, update_file_list(socket)}
end
```

## Reference: agents_demo

The `agents_demo` project demonstrates all of the above patterns in a complete Phoenix application:

| File | Role |
|---|---|
| `lib/agents_demo/agents/demo_setup.ex` | `ensure_user_filesystem/1` — starts the `FileSystemServer` with disk persistence, seeds template files for new users |
| `lib/agents_demo_web/live/chat_live.ex` | Calls `DemoSetup.ensure_user_filesystem/1` in `mount/3`, subscribes to file change events, passes the scope to the Coordinator |
| `lib/agents_demo/agents/coordinator.ex` | Receives `filesystem_scope` from the LiveView and forwards it to the Factory |
| `lib/agents_demo/agents/factory.ex` | Passes `filesystem_scope` to `{Sagents.Middleware.FileSystem, [filesystem_scope: scope]}` |
| `priv/new_user_template/` | Template files copied to new users' storage directories |
