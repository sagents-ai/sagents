defmodule Sagents.FileSystem.FileEntry do
  @moduledoc """
  Represents a file in the virtual filesystem.

  ## Field Semantics

  - `:loaded` - Content availability
    - `true` - Content is in ETS, ready to use
    - `false` - Content exists in storage but not loaded (lazy load on read)

  - `:dirty_content` - Content sync status
    - `false` - In-memory content matches storage (or no storage attached)
    - `true` - In-memory content needs to be flushed to storage

  Whether a given entry is actually backed by storage is determined by
  the `Sagents.FileSystem.FileSystemConfig` registered for its path —
  not by the entry itself. Entries that don't match any config live only
  in memory; their `dirty_content` flag is irrelevant.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias Sagents.FileSystem.FileMetadata
  alias LangChain.Utils

  @primary_key false
  embedded_schema do
    field :path, :string
    # Content is always string for LLM text-based work
    field :content, :string
    # Is content currently loaded in ETS? (false = lazy load needed)
    field :loaded, :boolean, default: true
    # Has content been modified since last storage write? (caller decides relevance)
    field :dirty_content, :boolean, default: false
    embeds_one :metadata, FileMetadata
  end

  @type t :: %FileEntry{
          path: String.t(),
          content: String.t() | nil,
          loaded: boolean(),
          dirty_content: boolean(),
          metadata: FileMetadata.t() | nil
        }

  @doc """
  Creates a changeset for a file entry from internal attrs.

  This is the full internal changeset used by `new_file/3` and friends.
  It casts all schema fields including `:path`, `:content`, and
  `:dirty_content`.
  """
  def internal_changeset(entry \\ %FileEntry{}, attrs) do
    entry
    |> cast(attrs, [
      :path,
      :content,
      :loaded,
      :dirty_content
    ])
    |> cast_embed(:metadata, with: &FileMetadata.changeset/2)
    |> validate_path()
    |> validate_required([:loaded, :dirty_content])
  end

  @doc """
  Returns the canonical LLM-facing JSON map for a file entry.

  This is the single source of truth for what a `FileEntry` looks like
  to the LLM. Tools that render entries to the model (e.g. `list_files`,
  `create_file`) call this directly.
  """
  def to_llm_map(%__MODULE__{} = entry) do
    %{
      path: entry.path,
      mime_type: entry.metadata && entry.metadata.mime_type,
      size: entry.metadata && entry.metadata.size
    }
  end

  @doc """
  Validates that a path segment is safe for use in paths.

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
  Creates a new file entry.

  The returned entry is marked `dirty_content: true` so any registered
  persistence backend picks it up on the next persist cycle. If no
  backend is registered for the path, the state machine simply ignores
  the dirty flag — memory-only files never have anywhere to be flushed
  to.

  ## Options

  - `:mime_type` - Override the metadata mime type (default `"text/markdown"`).
  """
  def new_file(path, content, opts \\ []) do
    with {:ok, metadata} <- FileMetadata.new(content, opts) do
      attrs = %{
        path: path,
        content: content,
        loaded: true,
        dirty_content: true
      }

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

  Accepts an optional `:metadata` keyword to attach pre-built metadata.
  """
  def new_indexed_file(path, opts \\ []) do
    metadata = Keyword.get(opts, :metadata)

    attrs = %{
      path: path,
      content: nil,
      loaded: false,
      dirty_content: false
    }

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
    %{entry | dirty_content: false}
  end

  @doc """
  Updates file content and marks as dirty.

  Preserves existing metadata (created_at, mime_type, etc.) and only
  updates content-related fields (size, modified_at, checksum).
  """
  def update_content(entry, new_content, opts \\ [])

  def update_content(%FileEntry{} = entry, new_content, opts) do
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
             dirty_content: true,
             metadata: new_metadata
         }}

      {:error, _} = error ->
        error
    end
  end

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
end
