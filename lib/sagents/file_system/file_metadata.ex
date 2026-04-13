defmodule Sagents.FileSystem.FileMetadata do
  @moduledoc """
  Metadata for a file entry in the virtual filesystem.

  Tracks size, timestamps, checksum, and mime_type. The mime_type field
  exists so multi-modal LLMs and downstream tools can route binary content
  (PDFs, images) correctly even when the path extension is ambiguous or
  absent.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias __MODULE__

  @primary_key false
  embedded_schema do
    field :size, :integer
    field :created_at, :utc_datetime_usec
    field :modified_at, :utc_datetime_usec
    field :mime_type, :string, default: "text/markdown"
    field :checksum, :string
  end

  @type t :: %FileMetadata{
          size: integer() | nil,
          created_at: DateTime.t() | nil,
          modified_at: DateTime.t() | nil,
          mime_type: String.t(),
          checksum: String.t() | nil
        }

  @doc """
  Creates a changeset for file metadata.
  """
  def changeset(metadata \\ %FileMetadata{}, attrs) do
    metadata
    |> cast(attrs, [:size, :created_at, :modified_at, :mime_type, :checksum])
    |> validate_required([:size, :mime_type])
    |> validate_number(:size, greater_than_or_equal_to: 0)
  end

  @doc """
  Creates new metadata for file content.

  Accepts optional `:mime_type` to override the default `"text/markdown"`.
  """
  def new(content, opts \\ []) do
    now = DateTime.utc_now()
    size = byte_size(content)
    mime_type = Keyword.get(opts, :mime_type, "text/markdown")

    attrs = %{
      size: size,
      created_at: now,
      modified_at: now,
      mime_type: mime_type,
      checksum: compute_checksum(content)
    }

    case changeset(%FileMetadata{}, attrs) do
      %{valid?: true} = cs -> {:ok, Ecto.Changeset.apply_changes(cs)}
      cs -> {:error, cs}
    end
  end

  @doc """
  Updates metadata timestamps and checksum for modified content.

  Preserves existing metadata fields (created_at, mime_type) and only
  updates content-related fields. Accepts an optional `:mime_type` opt
  to override that field.

  Returns `{:ok, metadata}` or `{:error, changeset}`.
  """
  def update_for_modification(metadata, new_content, opts \\ []) do
    now = DateTime.utc_now()
    size = byte_size(new_content)
    checksum = compute_checksum(new_content)

    attrs = %{
      size: size,
      modified_at: now,
      checksum: checksum
    }

    attrs =
      if mime = Keyword.get(opts, :mime_type), do: Map.put(attrs, :mime_type, mime), else: attrs

    case changeset(metadata, attrs) do
      %{valid?: true} = cs -> {:ok, Ecto.Changeset.apply_changes(cs)}
      cs -> {:error, cs}
    end
  end

  # Private helpers

  defp compute_checksum(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
