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
    # Build metadata opts (mime_type only — pass through if provided)
    metadata_opts = Keyword.take(opts, [:mime_type])

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
        if existing_entry do
          FileEntry.update_content(existing_entry, content, metadata_opts)
        else
          FileEntry.new_file(path, content, metadata_opts)
        end

      case entry_result do
        {:ok, entry} ->
          # Memory-only files (no matching config) have nothing to flush;
          # mark them clean so the dirty flag stays meaningful.
          entry = if config, do: entry, else: FileEntry.mark_clean(entry)

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
  sidebar trees or LLM `list_files` tool responses.
  """
  @spec list_entries(t()) :: [FileEntry.t()]
  def list_entries(%FileSystemState{} = state) do
    state.files
    |> Map.values()
    |> Enum.sort_by(& &1.path)
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

        %FileEntry{} = entry ->
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
      end
    end
  end

  @doc """
  Moves a file or directory (and its children) from one path to another.

  This is an atomic re-key operation that does **not** trigger `delete_from_storage`
  or create new entries. Instead, it:

  1. Re-keys entries in the files map from old path to new path
  2. Updates the `path` field on each entry
  3. Transfers any pending debounce timers to the new paths
  4. Calls the optional `move_in_storage/3` persistence callback so backends
     can update their path references
  5. If the backend doesn't implement `move_in_storage/3`, marks entries as
     `dirty_non_content` so the next persist cycle pushes the changes

  Returns `{:ok, moved_entries, new_state}` or `{:error, reason, state}`.
  """
  @spec move_file(t(), String.t(), String.t()) ::
          {:ok, [FileEntry.t()], t()} | {:error, term(), t()}
  def move_file(%FileSystemState{} = state, path, path) do
    case Map.get(state.files, path) do
      nil -> {:error, :enoent, state}
      entry -> {:ok, [entry], state}
    end
  end

  def move_file(%FileSystemState{} = state, old_path, new_path) do
    config = find_config_for_path(state, old_path)
    new_config = find_config_for_path(state, new_path)

    cond do
      config && config.readonly ->
        {:error, "Cannot move from read-only directory: #{config.base_directory}", state}

      new_config && new_config.readonly ->
        {:error, "Cannot move to read-only directory: #{new_config.base_directory}", state}

      !same_persistence_config?(state, old_path, new_path) ->
        base_dir = if config, do: "/#{config.base_directory}", else: "the current directory"

        {:error,
         "Cannot move files across different storage backends. " <>
           "The file can only be moved within #{base_dir}.", state}

      true ->
        # Collect the entry at old_path (if any) and all children under the prefix.
        # This supports both single-file moves and bulk renames of a path prefix
        # (the latter is what "rename a directory" reduces to once directory
        # entries are gone).
        affected =
          state.files
          |> Enum.filter(fn {path, _} ->
            path == old_path or String.starts_with?(path, old_path <> "/")
          end)
          |> Enum.sort_by(fn {path, _} -> String.length(path) end)

        case affected do
          [] ->
            {:error, :enoent, state}

          _ ->
            # Check target doesn't conflict (except with entries we're moving)
            moving_paths = MapSet.new(affected, fn {path, _} -> path end)

            conflict =
              Enum.any?(affected, fn {path, _} ->
                target = String.replace_prefix(path, old_path, new_path)
                Map.has_key?(state.files, target) and not MapSet.member?(moving_paths, target)
              end)

            if conflict do
              {:error, :already_exists, state}
            else
              do_move_entries(state, affected, old_path, new_path, config)
            end
        end
    end
  end

  defp do_move_entries(state, affected, old_path, new_path, config) do
    opts = if config, do: FileSystemConfig.build_storage_opts(config, state.scope_key), else: nil

    has_move_callback =
      config != nil and
        function_exported?(config.persistence_module, :move_in_storage, 3)

    {new_files, new_timers, moved_entries} =
      Enum.reduce(affected, {state.files, state.debounce_timers, []}, fn {path, entry},
                                                                         {files, timers, moved} ->
        target_path = String.replace_prefix(path, old_path, new_path)

        # Update path on the entry struct
        moved_entry = %{entry | path: target_path}

        # Call move_in_storage if available, otherwise mark dirty for next persist
        moved_entry =
          if has_move_callback do
            case config.persistence_module.move_in_storage(entry, target_path, opts) do
              {:ok, updated} -> updated
              {:error, _reason} -> mark_dirty_for_persist(moved_entry)
            end
          else
            mark_dirty_for_persist(moved_entry)
          end

        # Re-key in files map
        files = files |> Map.delete(path) |> Map.put(target_path, moved_entry)

        # Transfer any pending debounce timer
        timers =
          case Map.pop(timers, path) do
            {nil, timers} -> timers
            {timer_ref, timers} -> Map.put(timers, target_path, timer_ref)
          end

        {files, timers, [moved_entry | moved]}
      end)

    new_state = %{state | files: new_files, debounce_timers: new_timers}

    # If no move callback, persist dirty entries immediately by default
    new_state =
      if not has_move_callback and config do
        Enum.reduce(moved_entries, new_state, fn entry, acc ->
          persist_file(acc, entry.path)
        end)
      else
        new_state
      end

    {:ok, Enum.reverse(moved_entries), new_state}
  end

  @doc """
  Persists a file to storage (called when debounce timer fires).

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
      %FileEntry{dirty_content: true} = entry ->
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

      %FileEntry{loaded: false} = entry ->
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
          # No persistence config for this path - shouldn't happen if file was indexed
          {:error, :no_persistence_config, state}
        end
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

    {persisted_files, memory_files} =
      Enum.reduce(all_entries, {0, 0}, fn entry, {p, m} ->
        if find_config_for_path(state, entry.path), do: {p + 1, m}, else: {p, m + 1}
      end)

    loaded_files = Enum.count(all_entries, fn entry -> entry.loaded end)
    not_loaded_files = Enum.count(all_entries, fn entry -> not entry.loaded end)
    dirty_files = Enum.count(all_entries, fn entry -> entry.dirty_content end)

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

  # Check whether two paths route to the same persistence config.
  # Returns true if both paths would use the same backend (or both have no config).
  defp same_persistence_config?(state, path_a, path_b) do
    find_config_for_path(state, path_a) == find_config_for_path(state, path_b)
  end

  # Persist a file to storage immediately (used for new file creation).
  defp persist_file_now(%FileSystemState{} = state, path, config) do
    case Map.get(state.files, path) do
      %FileEntry{dirty_content: true} = entry ->
        opts = FileSystemConfig.build_storage_opts(config, state.scope_key)

        case config.persistence_module.write_to_storage(entry, opts) do
          {:ok, updated_entry} ->
            new_files = Map.put(state.files, path, updated_entry)
            Logger.debug("Persisted new file immediately: #{path}")
            %{state | files: new_files}

          :ok ->
            new_files = Map.put(state.files, path, FileEntry.mark_clean(entry))
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

  # Mark an entry as dirty (e.g. after a path change from move). The state
  # machine only persists dirty entries that have a matching config, so it
  # is safe to mark all entries dirty here regardless of their backing.
  defp mark_dirty_for_persist(%FileEntry{} = entry) do
    %{entry | dirty_content: true}
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
