defmodule Sagents.FileSystem.Persistence do
  @moduledoc """
  Behaviour for persisting files to storage.

  Custom persistence implementations must implement all required callbacks.
  The default implementation writes to the local filesystem.

  ## Usage

  Create a `FileSystemConfig` with your persistence module:

      alias Sagents.FileSystem.{FileSystemServer, FileSystemConfig}

      {:ok, config} = FileSystemConfig.new(%{
        base_directory: "user_files",
        persistence_module: MyApp.DBPersistence,
        storage_opts: [path: "/data/agents"]
      })

      FileSystemServer.start_link(
        agent_id: "agent-123",
        persistence_configs: [config]
      )

  ## Storage Options

  The `:storage_opts` from your `FileSystemConfig` are passed to your persistence
  module's callbacks via the `opts` parameter. Use it to configure storage location,
  DB connection, credentials, etc.

  The `FileSystemConfig` also automatically adds `:agent_id` and `:base_directory`
  to the opts for convenience.

  ## Callbacks

  All callbacks receive `opts` as their second parameter, which includes:
  - `:agent_id` - The agent's unique identifier
  - `:base_directory` - The virtual directory (from `FileSystemConfig`). Note: this key
    is **not present** for default configs (`default: true`), since the default config
    catches all paths and has no meaningful base directory.
  - All custom options from `FileSystemConfig.storage_opts`

  ### write_to_storage/2

  Write a file entry to persistent storage. Called after the debounce timer fires.

  ### load_from_storage/2

  Load a file's content from persistent storage. Called during lazy loading when a
  file is read but content is not yet in memory.

  ### delete_from_storage/2

  Delete a file from persistent storage. Called immediately when a persisted file
  is deleted (no debounce).

  ### list_persisted_entries/2

  List all persisted file entries for an agent. Called during initialization
  to index existing files with their metadata (title, type, tags, etc.)
  without loading content.
  """

  alias Sagents.FileSystem.FileEntry

  @doc """
  Write a file entry to persistent storage.

  The persistence backend should return the FileEntry with updated metadata
  after the write completes (actual size on disk, updated timestamps, etc.).

  ## Parameters

  - `file_entry` - The FileEntry to persist (includes path, content, metadata)
  - `opts` - Storage configuration options (e.g., [path: "/data/agents", agent_id: "agent-123"])

  ## Returns

  - `{:ok, file_entry}` where file_entry has updated metadata from the storage system
  - `{:error, reason}` on failure
  """
  @callback write_to_storage(file_entry :: FileEntry.t(), opts :: keyword()) ::
              {:ok, FileEntry.t()} | {:error, term()}

  @doc """
  Load a file from persistent storage.

  The persistence backend should return a complete FileEntry with all metadata
  populated from the storage system (size, MIME type, timestamps, etc.).

  ## Parameters

  - `file_entry` - The FileEntry with path to load (content may be nil)
  - `opts` - Storage configuration options

  ## Returns

  - `{:ok, file_entry}` where file_entry is a complete FileEntry with content and metadata
  - `{:error, :enoent}` if file doesn't exist
  - `{:error, reason}` on other failures
  """
  @callback load_from_storage(file_entry :: FileEntry.t(), opts :: keyword()) ::
              {:ok, FileEntry.t()} | {:error, term()}

  @doc """
  Delete a file from persistent storage.

  ## Parameters

  - `file_entry` - The FileEntry to delete (uses path field)
  - `opts` - Storage configuration options

  ## Returns

  - `:ok` on success (even if file doesn't exist)
  - `{:error, reason}` on failure
  """
  @callback delete_from_storage(file_entry :: FileEntry.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  List all persisted file entries for an agent.

  Used during initialization to index existing files with their metadata
  (title, entry_type, custom metadata, etc.) without loading content.

  Returns FileEntry structs with `content: nil, loaded: false` (for files)
  or `loaded: true` (for directories, which have no content to load).

  ## Parameters

  - `agent_id` - The agent's unique identifier
  - `opts` - Storage configuration options

  ## Returns

  - `{:ok, entries}` where entries is a list of FileEntry structs
  - `{:error, reason}` on failure
  """
  @callback list_persisted_entries(agent_id :: String.t(), opts :: keyword()) ::
              {:ok, [FileEntry.t()]} | {:error, term()}

  @doc """
  Update only metadata for a persisted file entry (no content write).

  This is an optional callback used when metadata changes without content changes
  (e.g., rename, reorder, tag updates). Falls back to `write_to_storage/2` if
  not implemented.

  ## Parameters

  - `file_entry` - The FileEntry with updated metadata
  - `opts` - Storage configuration options

  ## Returns

  - `{:ok, file_entry}` with updated metadata
  - `{:error, reason}` on failure
  """
  @callback update_metadata_in_storage(file_entry :: FileEntry.t(), opts :: keyword()) ::
              {:ok, FileEntry.t()} | {:error, term()}

  @optional_callbacks update_metadata_in_storage: 2
end
