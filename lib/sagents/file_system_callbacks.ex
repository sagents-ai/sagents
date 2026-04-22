defmodule Sagents.FileSystemCallbacks do
  @moduledoc """
  Behavior for file system persistence callbacks.

  Implement this behavior to provide custom persistence for filesystem operations.
  All callbacks are optional — implement only what you need.

  ## Scope-first contract

  Every callback takes the integrator's scope struct as its first positional argument.

  ## Example Implementation

      defmodule MyApp.FilesystemPersistence do
        @behaviour Sagents.FileSystemCallbacks

        @impl true
        def on_write(%MyApp.Accounts.Scope{user: user}, file_path, content, _context) do
          case MyApp.Files.create_or_update(user.id, file_path, content) do
            {:ok, file} -> {:ok, %{id: file.id}}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def on_read(%MyApp.Accounts.Scope{user: user}, file_path, _context) do
          case MyApp.Files.get(user.id, file_path) do
            nil -> {:error, :not_found}
            file -> {:ok, file.content}
          end
        end

        @impl true
        def on_delete(%MyApp.Accounts.Scope{user: user}, file_path, _context) do
          case MyApp.Files.delete(user.id, file_path) do
            {:ok, _} -> {:ok, %{}}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def on_list(%MyApp.Accounts.Scope{user: user}, _context) do
          files = MyApp.Files.list_for_user(user.id)
          {:ok, Enum.map(files, & &1.path)}
        end
      end
  """

  @type file_path :: String.t()
  @type content :: String.t()
  @type context :: map()
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Called when a file is created or overwritten.

  ## Parameters
  - `scope` - Integrator-defined scope struct (or `nil`). Use to filter DB writes.
  - `file_path` - Path of the file being written
  - `content` - Full content of the file
  - `context` - Filesystem-specific fields (agent_id, session_id, etc.)

  ## Returns
  - `{:ok, metadata}` - Success, optionally with metadata
  - `{:error, reason}` - Failure reason
  """
  @callback on_write(scope :: term() | nil, file_path, content, context) :: result()

  @doc """
  Called when a file is read.

  If this callback is implemented, it will be called BEFORE checking the
  in-memory state. This enables lazy-loading from persistent storage.

  ## Parameters
  - `scope` - Integrator-defined scope struct (or `nil`)
  - `file_path` - Path of the file being read
  - `context` - Filesystem-specific fields

  ## Returns
  - `{:ok, content}` - File content from storage
  - `{:error, :not_found}` - File doesn't exist in storage
  - `{:error, reason}` - Other error
  """
  @callback on_read(scope :: term() | nil, file_path, context) ::
              {:ok, content} | {:error, term()}

  @doc """
  Called when a file is deleted.

  ## Parameters
  - `scope` - Integrator-defined scope struct (or `nil`)
  - `file_path` - Path of the file being deleted
  - `context` - Filesystem-specific fields

  ## Returns
  - `{:ok, metadata}` - Success
  - `{:error, reason}` - Failure reason
  """
  @callback on_delete(scope :: term() | nil, file_path, context) :: result()

  @doc """
  Called to list all files in persistent storage.

  Optional — if not implemented, only in-memory files are listed.

  ## Parameters
  - `scope` - Integrator-defined scope struct (or `nil`)
  - `context` - Filesystem-specific fields

  ## Returns
  - `{:ok, [file_path]}` - List of file paths
  - `{:error, reason}` - Failure reason
  """
  @callback on_list(scope :: term() | nil, context) ::
              {:ok, [file_path]} | {:error, term()}

  @optional_callbacks [on_write: 4, on_read: 3, on_delete: 3, on_list: 2]
end
