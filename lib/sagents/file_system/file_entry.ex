defmodule Sagents.FileSystem.FileEntry do
  @moduledoc """
  Represents a file or directory in the virtual filesystem.

  ## Field Semantics

  - `:entry_type` - Whether this is a file or directory
    - `:file` - A regular file with content
    - `:directory` - A directory entry (no content, never dirty)

  - `:title` - Human-readable display name (e.g. "Hero Character Sheet")
    Promoted to a first-class field so both application code and LLM tools
    can reference entries by their user-visible name.

  - `:persistence` - Storage strategy
    - `:memory` - Ephemeral, exists only in ETS (e.g., /scratch files)
    - `:persisted` - Durable, backed by storage (e.g., /Memories files)

  - `:loaded` - Content availability
    - `true` - Content is in ETS, ready to use
    - `false` - Content exists in storage but not loaded (lazy load on read)

  - `:dirty_content` - Content sync status (only meaningful when persistence: :persisted)
    - `false` - In-memory content matches storage
    - `true` - In-memory content differs from storage (needs persist)

  - `:dirty_non_content` - Non-content change tracking
    - `false` - Entry-level fields and metadata match storage
    - `true` - Only non-content fields changed (enables metadata-only persist optimization)

  ## State Examples

  Memory file (always loaded, never dirty):
    %FileEntry{entry_type: :file, persistence: :memory, loaded: true, dirty_content: false, content: "data"}

  Persisted file, clean, loaded:
    %FileEntry{entry_type: :file, persistence: :persisted, loaded: true, dirty_content: false, content: "data"}

  Persisted file, not yet loaded (lazy):
    %FileEntry{entry_type: :file, persistence: :persisted, loaded: false, dirty_content: false, content: nil}

  Persisted file, modified since last save:
    %FileEntry{entry_type: :file, persistence: :persisted, loaded: true, dirty_content: true, content: "new data"}

  Directory entry:
    %FileEntry{entry_type: :directory, persistence: :persisted, loaded: true, dirty_content: false, content: nil}
  """
  @behaviour Sagents.FileSystem.FileSchema

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias Sagents.FileSystem.FileMetadata
  alias LangChain.Utils

  @primary_key false
  embedded_schema do
    field :path, :string
    # Human-readable display name
    field :title, :string
    # Optional stable identifier for referencing files by ID
    field :id, :string
    # LLM-readable file type: "markdown", "image", "pdf", "json", etc.
    field :file_type, :string, default: "markdown"
    # Whether this is a file or directory
    field :entry_type, Ecto.Enum, values: [:file, :directory], default: :file
    # Content is always string for LLM text-based work
    field :content, :string
    # Where the file lives: memory-only or persisted to storage
    field :persistence, Ecto.Enum, values: [:memory, :persisted], default: :memory
    # Is content currently loaded in ETS? (false = lazy load needed)
    field :loaded, :boolean, default: true
    # Has content been modified since last storage write? (only relevant for :persisted files)
    field :dirty_content, :boolean, default: false
    # Only non-content fields changed; enables metadata-only persist optimization
    field :dirty_non_content, :boolean, default: false
    embeds_one :metadata, FileMetadata
  end

  @type t :: %FileEntry{
          path: String.t(),
          title: String.t() | nil,
          id: String.t() | nil,
          file_type: String.t() | nil,
          entry_type: :file | :directory,
          content: String.t() | nil,
          persistence: :memory | :persisted,
          loaded: boolean(),
          dirty_content: boolean(),
          dirty_non_content: boolean(),
          metadata: FileMetadata.t() | nil
        }

  @doc """
  Creates a changeset for a file entry from internal attrs.

  This is the full internal changeset used by `new_memory_file/3`,
  `new_persisted_file/3`, etc. It casts all schema fields including
  `:path`, `:content`, and persistence-related state.

  This is **not** the changeset used for LLM-supplied attribute updates —
  that is `changeset/1` (the `Sagents.FileSystem.FileSchema` callback),
  which only allows `:title`, `:id`, and `:file_type`.
  """
  def internal_changeset(entry \\ %FileEntry{}, attrs) do
    entry
    |> cast(attrs, [
      :path,
      :title,
      :id,
      :file_type,
      :entry_type,
      :content,
      :persistence,
      :loaded,
      :dirty_content
    ])
    |> cast_embed(:metadata, with: &FileMetadata.changeset/2)
    |> validate_path()
    |> validate_required([:persistence, :loaded, :dirty_content])
  end

  @doc """
  Changeset for updating entry-level fields (not content or internal state).

  Only allows `:title`, `:id`, and `:file_type` to be changed.
  """
  def update_entry_changeset(%FileEntry{} = entry, attrs) do
    entry
    |> cast(attrs, [:title, :id, :file_type])
  end

  # --- Sagents.FileSystem.FileSchema callbacks ---

  @doc """
  Default `Sagents.FileSystem.FileSchema` changeset.

  Casts only entry-level fields safe for LLM updates: `:title`, `:id`,
  and `:file_type`. `:content` is intentionally **not** in the cast list —
  content is changed via `replace_text`, `replace_lines`, or `create_file`,
  never `update_file_attrs`.
  """
  @impl Sagents.FileSystem.FileSchema
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:title, :id, :file_type])
  end

  @doc """
  Default `Sagents.FileSystem.FileSchema` representation of a file entry
  for the LLM. Includes path, title, entry_type, file_type, persistence,
  size, and (when present) id.
  """
  @impl Sagents.FileSystem.FileSchema
  def to_llm_map(%__MODULE__{} = entry) do
    %{
      path: entry.path,
      title: entry.title,
      entry_type: entry.entry_type,
      file_type: entry.file_type,
      persistence: entry.persistence,
      size: entry.metadata && entry.metadata.size
    }
    |> maybe_put_field(:id, entry.id)
  end

  defp maybe_put_field(map, _key, nil), do: map
  defp maybe_put_field(map, key, value), do: Map.put(map, key, value)

  @doc """
  Validates that a name (title or path segment) is safe for use in paths.

  The library enforces minimal restrictions — only characters that would break
  path resolution are disallowed:
  - `/` (path separator)
  - null bytes
  - leading/trailing whitespace
  - empty strings
  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    name != "" and
      not String.contains?(name, ["/", "\0"]) and
      String.trim(name) == name
  end

  def valid_name?(_), do: false

  @doc """
  Creates a new file entry for memory storage.
  """
  def new_memory_file(path, content, opts \\ []) do
    title = Keyword.get(opts, :title)
    id = Keyword.get(opts, :id)
    file_type = Keyword.get(opts, :file_type)

    with {:ok, metadata} <- FileMetadata.new(content, opts) do
      attrs =
        %{
          path: path,
          title: title,
          id: id,
          entry_type: :file,
          content: content,
          persistence: :memory,
          loaded: true,
          dirty_content: false
        }
        |> maybe_put(:file_type, file_type)

      %FileEntry{}
      |> internal_changeset(attrs)
      |> put_embed(:metadata, metadata)
      |> apply_action(:insert)
      |> case do
        {:ok, entry} -> {:ok, entry}
        {:error, changeset} -> {:error, Utils.changeset_error_to_string(changeset)}
      end
    else
      {:error, _changeset} = error -> error
    end
  end

  @doc """
  Creates a new file entry for persisted storage. Intended for situations when
  the LLM instructs a new file to be created that will need to be persisted to
  storage.
  """
  def new_persisted_file(path, content, opts \\ []) do
    title = Keyword.get(opts, :title)
    id = Keyword.get(opts, :id)
    file_type = Keyword.get(opts, :file_type)

    with {:ok, metadata} <- FileMetadata.new(content, opts) do
      attrs =
        %{
          path: path,
          title: title,
          id: id,
          entry_type: :file,
          content: content,
          persistence: :persisted,
          loaded: true,
          dirty_content: true
        }
        |> maybe_put(:file_type, file_type)

      %FileEntry{}
      |> internal_changeset(attrs)
      |> put_embed(:metadata, metadata)
      |> apply_action(:insert)
      |> case do
        {:ok, entry} -> {:ok, entry}
        {:error, changeset} -> {:error, Utils.changeset_error_to_string(changeset)}
      end
    else
      {:error, _changeset} = error -> error
    end
  end

  @doc """
  Creates a file entry for an indexed persisted file (not yet loaded).

  Accepts optional keyword opts to set `:title`, `:entry_type`, and `:metadata`.
  """
  def new_indexed_file(path, opts \\ []) do
    title = Keyword.get(opts, :title)
    id = Keyword.get(opts, :id)
    file_type = Keyword.get(opts, :file_type)
    entry_type = Keyword.get(opts, :entry_type, :file)
    metadata = Keyword.get(opts, :metadata)

    attrs =
      %{
        path: path,
        title: title,
        id: id,
        entry_type: entry_type,
        content: nil,
        persistence: :persisted,
        loaded: entry_type == :directory,
        dirty_content: false
      }
      |> maybe_put(:file_type, file_type)

    result =
      %FileEntry{}
      |> internal_changeset(attrs)
      |> maybe_put_embed_metadata(metadata)
      |> apply_action(:insert)

    case result do
      {:ok, entry} -> {:ok, entry}
      {:error, changeset} -> {:error, Utils.changeset_error_to_string(changeset)}
    end
  end

  @doc """
  Creates a new directory entry.

  Directories have no content, are always "loaded", and are never dirty on creation.

  ## Options

  - `:title` - Human-readable name for the directory
  - `:custom` - Custom metadata map
  - `:persistence` - `:memory` or `:persisted` (default: `:persisted`)
  """
  def new_directory(path, opts \\ []) do
    title = Keyword.get(opts, :title)
    id = Keyword.get(opts, :id)
    custom = Keyword.get(opts, :custom, %{})
    persistence = Keyword.get(opts, :persistence, :persisted)

    metadata_result = FileMetadata.new("", custom: custom)

    case metadata_result do
      {:ok, metadata} ->
        attrs = %{
          path: path,
          title: title,
          id: id,
          file_type: nil,
          entry_type: :directory,
          content: nil,
          persistence: persistence,
          loaded: true,
          dirty_content: persistence == :persisted
        }

        %FileEntry{}
        |> internal_changeset(attrs)
        |> put_embed(:metadata, metadata)
        |> apply_action(:insert)
        |> case do
          {:ok, entry} -> {:ok, entry}
          {:error, changeset} -> {:error, Utils.changeset_error_to_string(changeset)}
        end

      error ->
        error
    end
  end

  @doc """
  Marks a file as loaded with the given content.

  Preserves existing metadata if present, updating only content-related fields.
  """
  def mark_loaded(entry, content) do
    if entry.metadata do
      case FileMetadata.update_for_modification(entry.metadata, content) do
        {:ok, updated_metadata} ->
          {:ok, %{entry | content: content, loaded: true, metadata: updated_metadata}}

        {:error, _} = error ->
          error
      end
    else
      case FileMetadata.new(content, []) do
        {:ok, metadata} ->
          {:ok, %{entry | content: content, loaded: true, metadata: metadata}}

        error ->
          error
      end
    end
  end

  @doc """
  Marks a persisted file as clean (synced with storage).
  """
  def mark_clean(entry) do
    %{entry | dirty_content: false, dirty_non_content: false}
  end

  @doc """
  Updates file content and marks as dirty if persisted.

  Preserves existing metadata (custom, created_at, mime_type, etc.) and only
  updates content-related fields (size, modified_at, checksum).

  Returns `{:error, :directory_has_no_content}` if called on a directory entry.
  """
  def update_content(entry, new_content, opts \\ [])

  def update_content(%FileEntry{entry_type: :directory}, _new_content, _opts) do
    {:error, :directory_has_no_content}
  end

  def update_content(%FileEntry{} = entry, new_content, opts) do
    dirty_content = entry.persistence == :persisted

    metadata_result =
      if entry.metadata do
        FileMetadata.update_for_modification(entry.metadata, new_content, opts)
      else
        FileMetadata.new(new_content, opts)
      end

    case metadata_result do
      {:ok, new_metadata} ->
        {:ok,
         %{
           entry
           | content: new_content,
             loaded: true,
             dirty_content: dirty_content,
             dirty_non_content: false,
             metadata: new_metadata
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns true if the entry is a directory.
  """
  @spec directory?(t()) :: boolean()
  def directory?(%FileEntry{entry_type: :directory}), do: true
  def directory?(_), do: false

  # Private validation helpers

  defp validate_path(changeset) do
    changeset
    |> validate_required([:path])
    |> validate_format(:path, ~r{^/}, message: "must start with /")
    |> validate_no_double_dots()
    |> validate_path_segments()
  end

  defp validate_no_double_dots(changeset) do
    path = Ecto.Changeset.get_field(changeset, :path)

    if path && String.contains?(path, "..") do
      Ecto.Changeset.add_error(changeset, :path, "cannot contain ..")
    else
      changeset
    end
  end

  defp validate_path_segments(changeset) do
    case Ecto.Changeset.get_field(changeset, :path) do
      nil ->
        changeset

      path ->
        # Drop the first empty segment from the leading "/"
        [_ | segments] = String.split(path, "/")

        case Enum.find(segments, fn seg -> not valid_name?(seg) end) do
          nil ->
            changeset

          invalid_segment ->
            Ecto.Changeset.add_error(
              changeset,
              :path,
              "contains invalid segment %{segment}: must be non-empty with no /, null bytes, or leading/trailing whitespace",
              segment: inspect(invalid_segment)
            )
        end
    end
  end

  defp maybe_put_embed_metadata(changeset, nil), do: changeset

  defp maybe_put_embed_metadata(changeset, %FileMetadata{} = metadata),
    do: put_embed(changeset, :metadata, metadata)

  # Only include key in attrs map if value is non-nil (lets schema default apply)
  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)
end
