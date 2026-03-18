defmodule Sagents.FileSystem.FileSystemState do
  @moduledoc """
  State management for the FileSystem.

  This module handles all state transitions for the virtual filesystem.
  File entries are stored in an in-memory map within the GenServer state.
  """

  require Logger
  alias __MODULE__
  alias Sagents.FileSystem.FileEntry
  alias Sagents.FileSystem.FileSystemConfig

  defstruct [
    :scope_key,
    :files,
    :persistence_configs,
    :debounce_timers,
    :pubsub,
    :topic
  ]

  @type t :: %FileSystemState{
          scope_key: term(),
          files: %{String.t() => FileEntry.t()},
          persistence_configs: %{String.t() => FileSystemConfig.t()},
          debounce_timers: %{String.t() => reference()},
          pubsub: {module(), atom()} | nil,
          topic: String.t() | nil
        }

  @doc """
  Creates a new FileSystemState.

  ## Options

  - `:scope_key` - Scope identifier (required) - Can be any term that uniquely identifies the scope
    - Tuple: `{:user, 123}`, `{:agent, uuid}`, `{:project, id}`
    - UUID: `"550e8400-e29b-41d4-a716-446655440000"`
    - Database ID: `12345` or `"12345"`
  - `:configs` - List of FileSystemConfig structs (optional, default: [])
  - `:pubsub` - PubSub configuration as `{module(), atom()}` tuple or `nil` (optional, default: nil)
    Example: `{Phoenix.PubSub, :my_app_pubsub}`
    When configured, broadcasts `{:files_updated, file_list}` after write/delete operations.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    with {:ok, scope_key} <- fetch_scope_key(opts),
         {:ok, persistence_configs} <- build_persistence_configs(opts) do
      # Get optional pubsub configuration
      pubsub = Keyword.get(opts, :pubsub)
      topic = if pubsub, do: "filesystem:#{inspect(scope_key)}", else: nil

      state = %FileSystemState{
        scope_key: scope_key,
        files: %{},
        persistence_configs: persistence_configs,
        debounce_timers: %{},
        pubsub: pubsub,
        topic: topic
      }

      # Index existing files from all persistence backends
      state = index_persisted_files(state)

      Logger.debug("FileSystemState initialized for scope #{inspect(scope_key)}")
      {:ok, state}
    end
  end

  @doc """
  Registers a new persistence configuration.

  When a persistence config is registered, this function calls the persistence module's
  `list_persisted_files/2` callback to discover existing files and adds them to the
  filesystem with `loaded: false` (lazy loading).

  ## Parameters

  - `state` - Current FileSystemState
  - `config` - FileSystemConfig to register

  ## Returns

  - `{:ok, new_state}` on success
  - `{:error, reason}` if base_directory already registered

  ## Examples

      iex> config = FileSystemConfig.new!(%{
      ...>   base_directory: "user_files",
      ...>   persistence_module: MyApp.Persistence.Disk
      ...> })
      iex> {:ok, new_state} = FileSystemState.register_persistence(state, config)
  """
  @spec register_persistence(t(), FileSystemConfig.t()) :: {:ok, t()} | {:error, term()}
  def register_persistence(%FileSystemState{} = state, %FileSystemConfig{} = config) do
    base_dir = config.base_directory

    if Map.has_key?(state.persistence_configs, base_dir) do
      {:error, "Base directory '#{base_dir}' already has a registered persistence config"}
    else
      # Add the config
      new_configs = Map.put(state.persistence_configs, base_dir, config)
      new_state = %{state | persistence_configs: new_configs}

      # List existing persisted files and add them as indexed (not loaded)
      opts = FileSystemConfig.build_storage_opts(config, state.scope_key)
      agent_id = scope_key_to_agent_id(state.scope_key)

      new_files = index_from_persistence(config, agent_id, opts, new_state.files)
      {:ok, %{new_state | files: new_files}}
    end
  end

  @doc """
  Registers file entries in the filesystem.

  This is useful for pre-populating the filesystem with file metadata without
  loading content. For example, used by tests or for in-memory only files.

  ## Parameters

  - `state` - Current FileSystemState
  - `file_entries` - List of FileEntry structs to register

  ## Returns

  - `{:ok, new_state}` on success

  ## Examples

      iex> {:ok, entry} = FileEntry.new_memory_file("/scratch/temp.txt", "data")
      iex> {:ok, new_state} = FileSystemState.register_files(state, [entry])
  """
  @spec register_files(t(), [FileEntry.t()]) :: {:ok, t()}
  def register_files(%FileSystemState{} = state, file_entries) when is_list(file_entries) do
    # Add all entries to files map
    new_files =
      Enum.reduce(file_entries, state.files, fn entry, acc_files ->
        Logger.debug("Registered file: #{entry.path}")
        Map.put(acc_files, entry.path, entry)
      end)

    {:ok, %{state | files: new_files}}
  end

  @doc """
  Writes a file to the filesystem.

  For existing files, preserves existing metadata (custom, created_at, mime_type)
  and only updates content-related fields. For new files, creates a fresh entry.

  Returns `{:ok, entry, new_state}` or `{:error, reason, state}`.
  """
  @spec write_file(t(), String.t(), String.t(), keyword()) ::
          {:ok, FileEntry.t(), t()} | {:error, term(), t()}
  def write_file(%FileSystemState{} = state, path, content, opts \\ []) do
    # Ensure all ancestor directories exist (like mkdir -p)
    state = ensure_ancestor_directories(state, path)

    # Build metadata opts
    mime_type = Keyword.get(opts, :mime_type, "text/plain")
    custom = Keyword.get(opts, :custom, %{})
    title = Keyword.get(opts, :title)
    metadata_opts = [mime_type: mime_type, custom: custom]

    # Find matching persistence config
    config = find_config_for_path(state, path)

    # Check if readonly
    if config && config.readonly do
      {:error, "Cannot write to read-only directory: #{config.base_directory}", state}
    else
      existing_entry = Map.get(state.files, path)
      is_new_file = is_nil(existing_entry)

      # For existing files, update content preserving metadata.
      # For new files, create a fresh entry.
      entry_result =
        if existing_entry && existing_entry.entry_type == :file do
          # Update existing entry, preserving metadata.
          # Only pass opts that were explicitly provided (not defaults)
          # to avoid overwriting existing metadata with empty values.
          update_opts =
            Keyword.take(opts, [:mime_type, :custom]) |> Enum.reject(fn {_k, v} -> v == %{} end)

          updated = if title, do: %{existing_entry | title: title}, else: existing_entry
          FileEntry.update_content(updated, content, update_opts)
        else
          # New file
          create_opts = metadata_opts ++ if(title, do: [title: title], else: [])

          if config do
            FileEntry.new_persisted_file(path, content, create_opts)
          else
            FileEntry.new_memory_file(path, content, create_opts)
          end
        end

      case entry_result do
        {:ok, entry} ->
          # Add to files map
          new_files = Map.put(state.files, path, entry)
          new_state = %{state | files: new_files}

          # New files persist immediately; edits to existing files are debounced
          new_state =
            if config do
              if is_new_file do
                persist_file_now(new_state, path, config)
              else
                schedule_persist(new_state, path, config)
              end
            else
              new_state
            end

          # Return the entry as it is in state (may have been updated by persist_file_now)
          final_entry = Map.get(new_state.files, path)
          {:ok, final_entry, new_state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  @doc """
  Reads a file entry from the filesystem state.

  ## Parameters

  - `state` - Current FileSystemState
  - `path` - The file path to read

  ## Returns

  - `{:ok, entry}` - File entry found
  - `{:error, :enoent}` - File not found
  """
  @spec read_file(t(), String.t()) :: {:ok, FileEntry.t()} | {:error, :enoent}
  def read_file(%FileSystemState{} = state, path) do
    case Map.get(state.files, path) do
      nil -> {:error, :enoent}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Lists all file entries in the filesystem (without loading content).

  Returns entries with metadata but content NOT loaded — suitable for building
  sidebar trees, directory listings, or LLM `ls` tool responses.

  As a safety net, synthesizes directory entries for any parent paths that
  don't have explicit entries. This prevents orphaned files from becoming
  invisible in tree-based UIs when their parent directory was never created.
  """
  @spec list_entries(t()) :: [FileEntry.t()]
  def list_entries(%FileSystemState{} = state) do
    explicit_entries = state.files
    synthesized = synthesize_missing_directories(explicit_entries)

    Map.merge(synthesized, explicit_entries)
    |> Map.values()
    |> Enum.sort_by(& &1.path)
  end

  @doc """
  Updates only the metadata.custom map for a file entry.

  Does not touch content or trigger content persistence. Marks the entry dirty
  and schedules a debounced persist via `update_metadata_in_storage` (if the
  persistence module implements it) or falls back to `write_to_storage`.

  Also accepts `:title` in opts to update the entry's title.

  Returns `{:ok, entry, new_state}` or `{:error, reason, state}`.
  """
  @spec update_metadata(t(), String.t(), map(), keyword()) ::
          {:ok, FileEntry.t(), t()} | {:error, term(), t()}
  def update_metadata(%FileSystemState{} = state, path, custom, opts \\ []) do
    title = Keyword.get(opts, :title)

    case Map.get(state.files, path) do
      nil ->
        {:error, :enoent, state}

      %FileEntry{} = entry ->
        config = find_config_for_path(state, path)

        if config && config.readonly do
          {:error, "Cannot update metadata in read-only directory: #{config.base_directory}",
           state}
        else
          # Update custom metadata on the entry
          updated_metadata =
            if entry.metadata do
              %{entry.metadata | custom: Map.merge(entry.metadata.custom, custom)}
            else
              case Sagents.FileSystem.FileMetadata.new("", custom: custom) do
                {:ok, m} -> m
                _ -> nil
              end
            end

          updated_entry = %{entry | metadata: updated_metadata}
          updated_entry = if title, do: %{updated_entry | title: title}, else: updated_entry

          # Mark dirty if persisted
          updated_entry =
            if entry.persistence == :persisted do
              %{updated_entry | dirty: true}
            else
              updated_entry
            end

          new_files = Map.put(state.files, path, updated_entry)
          new_state = %{state | files: new_files}

          # Schedule debounced persist for persisted files
          new_state =
            if config && entry.persistence == :persisted do
              schedule_persist(new_state, path, config)
            else
              new_state
            end

          {:ok, updated_entry, new_state}
        end
    end
  end

  @doc """
  Creates a directory entry in the filesystem.

  Directories have no content and are always "loaded". They are persisted
  immediately (like new files).

  Returns `{:ok, entry, new_state}` or `{:error, reason, state}`.
  """
  @spec create_directory(t(), String.t(), keyword()) ::
          {:ok, FileEntry.t(), t()} | {:error, term(), t()}
  def create_directory(%FileSystemState{} = state, path, opts \\ []) do
    config = find_config_for_path(state, path)

    if config && config.readonly do
      {:error, "Cannot create directory in read-only directory: #{config.base_directory}", state}
    else
      if Map.has_key?(state.files, path) do
        {:error, :already_exists, state}
      else
        title = Keyword.get(opts, :title)
        custom = Keyword.get(opts, :custom, %{})

        persistence = if config, do: :persisted, else: :memory

        case FileEntry.new_directory(path, title: title, custom: custom, persistence: persistence) do
          {:ok, entry} ->
            new_files = Map.put(state.files, path, entry)
            new_state = %{state | files: new_files}

            # Persist immediately for persisted directories
            new_state =
              if config do
                persist_file_now(new_state, path, config)
              else
                new_state
              end

            final_entry = Map.get(new_state.files, path)
            {:ok, final_entry, new_state}

          {:error, reason} ->
            {:error, reason, state}
        end
      end
    end
  end

  @doc """
  Deletes a file from the filesystem.

  Returns `{:ok, new_state}` or `{:error, reason, state}`.
  """
  @spec delete_file(t(), String.t()) :: {:ok, t()} | {:error, term(), t()}
  def delete_file(%FileSystemState{} = state, path) do
    # Find matching config
    config = find_config_for_path(state, path)

    # Check if readonly
    if config && config.readonly do
      {:error, "Cannot delete from read-only directory: #{config.base_directory}", state}
    else
      case Map.get(state.files, path) do
        nil ->
          # File doesn't exist
          {:error, "File not found", state}

        %FileEntry{persistence: :persisted} = entry ->
          # Cancel any pending timer
          new_state = cancel_timer(state, path)

          # Delete from storage immediately if we have a config
          if config do
            opts = FileSystemConfig.build_storage_opts(config, state.scope_key)

            case config.persistence_module.delete_from_storage(entry, opts) do
              :ok ->
                new_files = Map.delete(new_state.files, path)
                {:ok, %{new_state | files: new_files}}

              {:error, reason} ->
                Logger.error("Failed to delete #{path} from storage: #{inspect(reason)}")
                {:error, reason, state}
            end
          else
            new_files = Map.delete(new_state.files, path)
            {:ok, %{new_state | files: new_files}}
          end

        _entry ->
          # Memory-only file, just delete from map
          new_files = Map.delete(state.files, path)
          {:ok, %{state | files: new_files}}
      end
    end
  end

  @doc """
  Persists a file to storage (called when debounce timer fires).

  For directory entries or entries where `update_metadata_in_storage` is available
  and the persistence module implements it, uses the metadata-only callback.
  Otherwise falls back to `write_to_storage`.

  Returns updated state.
  """
  @spec persist_file(t(), String.t()) :: t()
  def persist_file(%FileSystemState{} = state, path) do
    # Remove timer from map (it's fired)
    state = %{state | debounce_timers: Map.delete(state.debounce_timers, path)}

    # Find matching config
    config = find_config_for_path(state, path)

    # Persist the file
    case Map.get(state.files, path) do
      %FileEntry{dirty: true, persistence: :persisted} = entry ->
        if config do
          opts = FileSystemConfig.build_storage_opts(config, state.scope_key)

          result = config.persistence_module.write_to_storage(entry, opts)

          case result do
            {:ok, updated_entry} ->
              # Persistence backend returned updated FileEntry with refreshed metadata
              new_files = Map.put(state.files, path, updated_entry)
              Logger.debug("Persisted file after debounce: #{path}")
              %{state | files: new_files}

            {:error, reason} ->
              Logger.error("Failed to persist #{path}: #{inspect(reason)}")
              state
          end
        else
          state
        end

      _ ->
        # File no longer dirty or doesn't exist - no-op
        state
    end
  end

  @doc """
  Flushes all pending debounce timers by persisting files synchronously.

  Returns updated state with cleared timers.
  """
  @spec flush_all(t()) :: t()
  def flush_all(%FileSystemState{} = state) do
    # Get all paths with pending timers
    paths = Map.keys(state.debounce_timers)

    # Cancel all timers
    state = %{state | debounce_timers: %{}}

    # Persist each file synchronously
    Enum.reduce(paths, state, fn path, acc_state ->
      persist_file(acc_state, path)
    end)
  end

  @doc """
  Reset the filesystem to pristine persisted state.

  This clears:
  - All memory-only files (completely removed)
  - All in-memory modifications to persisted files (discarded)
  - All dirty flags (no persistence of pending changes)
  - All debounce timers (pending writes cancelled)

  Then re-indexes all persisted files from storage backends, ensuring:
  - Fresh metadata from storage (picks up any external changes)
  - Files marked as unloaded (will lazy-load on next access)
  - Latest list of persisted files (includes files created during execution)

  Uses the existing `index_persisted_files/1` code path for consistency.

  ## Returns

  Updated state with reset filesystem.

  ## Examples

      iex> state = FileSystemState.reset(state)
  """
  @spec reset(t()) :: t()
  def reset(%FileSystemState{} = state) do
    # Cancel all debounce timers (discard pending writes)
    Enum.each(state.debounce_timers, fn {_path, timer_ref} ->
      Process.cancel_timer(timer_ref)
    end)

    # Clear all files and timers
    cleared_state = %{state | files: %{}, debounce_timers: %{}}

    # Re-index persisted files from storage backends
    # This reuses the existing tested code path from initialization
    # and picks up the latest state from storage
    index_persisted_files(cleared_state)
  end

  @doc """
  Loads a file's content from persistence into ETS.

  Called by FileSystemServer when a file needs to be lazy-loaded.
  If the file is already loaded or is memory-only, returns {:ok, state} without changes.

  ## Returns

  - `{:ok, state}` - File loaded successfully (or already loaded)
  - `{:error, reason, state}` - Failed to load from persistence
  """
  @spec load_file(t(), String.t()) :: {:ok, t()} | {:error, term(), t()}
  def load_file(%FileSystemState{} = state, path) do
    case Map.get(state.files, path) do
      nil ->
        # File doesn't exist
        {:error, :enoent, state}

      %FileEntry{loaded: true} = _entry ->
        # Already loaded
        {:ok, state}

      %FileEntry{loaded: false, persistence: :persisted} = entry ->
        # File exists but not loaded, load from persistence
        config = find_config_for_path(state, path)

        if config do
          opts = FileSystemConfig.build_storage_opts(config, state.scope_key)

          case config.persistence_module.load_from_storage(entry, opts) do
            {:ok, loaded_entry} ->
              # Persistence backend returned complete FileEntry with content and metadata
              new_files = Map.put(state.files, path, loaded_entry)
              Logger.debug("Lazy-loaded file from persistence: #{path}")
              {:ok, %{state | files: new_files}}

            {:error, reason} ->
              Logger.error("Failed to load #{path} from persistence: #{inspect(reason)}")
              {:error, reason, state}
          end
        else
          # No persistence config for this path - shouldn't happen for persisted files
          {:error, :no_persistence_config, state}
        end

      %FileEntry{persistence: :memory} ->
        # Memory-only file should always be loaded
        {:ok, state}
    end
  end

  @doc """
  Lists all file paths in the filesystem.

  Returns paths for both memory and persisted files, regardless of load status.

  ## Parameters

  - `state` - Current FileSystemState

  ## Examples

      iex> FileSystemState.list_files(state)
      ["/file1.txt", "/Memories/file2.txt"]
  """
  @spec list_files(t()) :: [String.t()]
  def list_files(%FileSystemState{} = state) do
    state.files
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Check if a file exists in the filesystem.

  ## Examples

      iex> FileSystemState.file_exists?(state, "/notes.txt")
      true

      iex> FileSystemState.file_exists?(state, "/nonexistent.txt")
      false
  """
  @spec file_exists?(t(), String.t()) :: boolean()
  def file_exists?(%FileSystemState{} = state, path) do
    Map.has_key?(state.files, path)
  end

  @doc """
  Computes filesystem statistics.
  """
  @spec stats(t()) :: map()
  def stats(%FileSystemState{} = state) do
    all_entries = Map.values(state.files)

    total_files = length(all_entries)

    memory_files =
      Enum.count(all_entries, fn entry -> entry.persistence == :memory end)

    persisted_files =
      Enum.count(all_entries, fn entry -> entry.persistence == :persisted end)

    loaded_files = Enum.count(all_entries, fn entry -> entry.loaded end)
    not_loaded_files = Enum.count(all_entries, fn entry -> not entry.loaded end)
    dirty_files = Enum.count(all_entries, fn entry -> entry.dirty end)

    total_size =
      all_entries
      |> Enum.filter(fn entry -> entry.loaded and not is_nil(entry.content) end)
      |> Enum.reduce(0, fn entry, acc ->
        acc + byte_size(entry.content)
      end)

    %{
      total_files: total_files,
      memory_files: memory_files,
      persisted_files: persisted_files,
      loaded_files: loaded_files,
      not_loaded_files: not_loaded_files,
      dirty_files: dirty_files,
      total_size: total_size
    }
  end

  @doc """
  Ensures all ancestor directories exist for a given path.

  Works like `mkdir -p`: walks the path segments and creates any missing
  directory entries. Each auto-created directory gets its title inferred
  from the path segment name. Directories that already exist are left
  untouched.

  Auto-created directories use the same persistence strategy as the file
  being written (determined by `find_config_for_path`), and are persisted
  immediately so the persistence callback can return enriched entries
  (e.g. with a database-assigned ID).

  Returns the updated state.
  """
  @spec ensure_ancestor_directories(t(), String.t()) :: t()
  def ensure_ancestor_directories(%FileSystemState{} = state, path) do
    ancestor_paths = ancestor_paths(path)

    Enum.reduce(ancestor_paths, state, fn dir_path, acc_state ->
      if Map.has_key?(acc_state.files, dir_path) do
        # Directory already exists, skip
        acc_state
      else
        # Infer title from the last segment of the path
        title = Path.basename(dir_path)
        config = find_config_for_path(acc_state, dir_path)
        persistence = if config, do: :persisted, else: :memory

        case FileEntry.new_directory(dir_path, title: title, persistence: persistence) do
          {:ok, entry} ->
            new_files = Map.put(acc_state.files, dir_path, entry)
            new_state = %{acc_state | files: new_files}

            # Persist immediately so callback can return enriched entry (with ID, etc.)
            if config do
              persist_file_now(new_state, dir_path, config)
            else
              new_state
            end

          {:error, reason} ->
            Logger.warning("Failed to auto-create directory #{dir_path}: #{inspect(reason)}")

            acc_state
        end
      end
    end)
  end

  @doc """
  Computes the ancestor directory paths for a given file path.

  Returns paths from shallowest to deepest, excluding the root `/`.

  ## Examples

      iex> FileSystemState.ancestor_paths("/Characters/Hero/Backstory")
      ["/Characters", "/Characters/Hero"]

      iex> FileSystemState.ancestor_paths("/notes.txt")
      []
  """
  @spec ancestor_paths(String.t()) :: [String.t()]
  def ancestor_paths(path) when is_binary(path) do
    segments =
      path
      |> String.split("/", trim: true)
      # Drop the last segment (the file/leaf itself)
      |> Enum.drop(-1)

    # Build cumulative paths: ["Characters"] -> ["/Characters"]
    # ["Characters", "Hero"] -> ["/Characters", "/Characters/Hero"]
    {paths, _} =
      Enum.reduce(segments, {[], ""}, fn segment, {acc, prefix} ->
        dir_path = prefix <> "/" <> segment
        {[dir_path | acc], dir_path}
      end)

    Enum.reverse(paths)
  end

  # Private helpers

  defp fetch_scope_key(opts) do
    case Keyword.fetch(opts, :scope_key) do
      {:ok, nil} ->
        {:error, :invalid_scope_key}

      {:ok, scope_key} ->
        {:ok, scope_key}

      :error ->
        {:error, :scope_key_required}
    end
  end

  # Build persistence configs map from list of FileSystemConfig structs
  defp build_persistence_configs(opts) do
    configs = Keyword.get(opts, :configs, [])

    # Validate that all configs are FileSystemConfig structs
    with :ok <- validate_all_configs(configs) do
      persistence_configs =
        configs
        |> Enum.map(fn config -> {config.base_directory, config} end)
        |> Map.new()

      {:ok, persistence_configs}
    end
  end

  # Validate that all items in the list are FileSystemConfig structs
  defp validate_all_configs(configs) when is_list(configs) do
    invalid_configs = Enum.reject(configs, &is_struct(&1, FileSystemConfig))

    case invalid_configs do
      [] -> :ok
      _ -> {:error, :invalid_configs}
    end
  end

  defp validate_all_configs(_), do: {:error, :invalid_configs}

  # Extract agent_id from scope_key for backward compatibility with persistence modules
  # Persistence modules still expect agent_id as first parameter
  defp scope_key_to_agent_id({:agent, agent_id}), do: "agent:#{agent_id}"
  defp scope_key_to_agent_id({:user, user_id}), do: "user:#{user_id}"
  defp scope_key_to_agent_id({:project, project_id}), do: "project:#{project_id}"
  defp scope_key_to_agent_id({:organization, org_id}), do: "org:#{org_id}"

  defp scope_key_to_agent_id(scope_key) when is_tuple(scope_key) do
    # Generic handler for any other scope types
    scope_key
    |> Tuple.to_list()
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  defp scope_key_to_agent_id(scope_key) when is_binary(scope_key) do
    scope_key
  end

  # Find the persistence config that matches a given path.
  # Checks specific (non-default) configs first, then falls back to the default config.
  defp find_config_for_path(state, path) do
    Enum.find_value(state.persistence_configs, fn {_base_dir, config} ->
      if !config.default && FileSystemConfig.matches_path?(config, path), do: config
    end) ||
      Enum.find_value(state.persistence_configs, fn {_base_dir, config} ->
        if config.default, do: config
      end)
  end

  # Persist a file to storage immediately (used for new file creation).
  defp persist_file_now(%FileSystemState{} = state, path, config) do
    case Map.get(state.files, path) do
      %FileEntry{dirty: true, persistence: :persisted} = entry ->
        opts = FileSystemConfig.build_storage_opts(config, state.scope_key)

        case config.persistence_module.write_to_storage(entry, opts) do
          {:ok, updated_entry} ->
            new_files = Map.put(state.files, path, updated_entry)
            Logger.debug("Persisted new file immediately: #{path}")
            %{state | files: new_files}

          :ok ->
            new_files = Map.put(state.files, path, %{entry | dirty: false})
            Logger.debug("Persisted new file immediately: #{path}")
            %{state | files: new_files}

          {:error, reason} ->
            Logger.error("Failed to persist new file #{path}: #{inspect(reason)}")
            state
        end

      _ ->
        state
    end
  end

  defp schedule_persist(%FileSystemState{} = state, path, config) do
    # Cancel existing timer for this path (if any)
    state = cancel_timer(state, path)

    # Start new debounce timer by sending a message
    timer_ref = Process.send_after(self(), {:persist_file, path}, config.debounce_ms)

    # Store timer reference
    %{state | debounce_timers: Map.put(state.debounce_timers, path, timer_ref)}
  end

  defp cancel_timer(%FileSystemState{} = state, path) do
    case Map.get(state.debounce_timers, path) do
      nil ->
        state

      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{state | debounce_timers: Map.delete(state.debounce_timers, path)}
    end
  end

  # Synthesize directory entries for parent paths that don't have explicit entries.
  # This is a read-only safety net: the synthesized entries exist only in the
  # returned list, NOT in the state.files map. They prevent orphaned files from
  # being invisible in tree-based UIs.
  defp synthesize_missing_directories(files_map) do
    all_paths = Map.keys(files_map)

    all_paths
    |> Enum.flat_map(&ancestor_paths/1)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(files_map, &1))
    |> Enum.reduce(%{}, fn dir_path, acc ->
      title = Path.basename(dir_path)

      case FileEntry.new_directory(dir_path, title: title, persistence: :memory) do
        {:ok, entry} -> Map.put(acc, dir_path, entry)
        {:error, _} -> acc
      end
    end)
  end

  # Index files from all registered persistence backends
  defp index_persisted_files(%FileSystemState{} = state) do
    agent_id = scope_key_to_agent_id(state.scope_key)

    new_files =
      Enum.reduce(state.persistence_configs, state.files, fn {_base_dir, config}, acc_files ->
        opts = FileSystemConfig.build_storage_opts(config, state.scope_key)
        index_from_persistence(config, agent_id, opts, acc_files)
      end)

    %{state | files: new_files}
  end

  defp index_from_persistence(config, agent_id, opts, acc_files) do
    case config.persistence_module.list_persisted_entries(agent_id, opts) do
      {:ok, entries} ->
        Enum.reduce(entries, acc_files, fn entry, inner_acc ->
          Logger.debug("Indexed persisted entry: #{entry.path}")
          Map.put(inner_acc, entry.path, entry)
        end)

      {:error, reason} ->
        Logger.error(
          "Failed to list persisted entries for #{config.base_directory}: #{inspect(reason)}"
        )

        acc_files
    end
  end
end
