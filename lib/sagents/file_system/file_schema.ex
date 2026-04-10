defmodule Sagents.FileSystem.FileSchema do
  @moduledoc """
  Behaviour for defining how file entries are represented to the LLM
  and how LLM-supplied attribute updates are validated.

  `Sagents.FileSystem.FileEntry` implements this behaviour by default,
  supporting basic file attributes (`title`, `id`, `file_type`).
  Applications can implement this behaviour on their own module to add
  custom attributes with validation.

  ## Storage Routing

  The `Sagents.Middleware.FileSystem` middleware handles routing validated
  changes to the correct storage layer automatically. Fields that match
  `FileEntry` struct fields (`:title`, `:id`, `:file_type`) are updated via
  `Sagents.FileSystemServer.update_entry/4`. All other fields are stored in
  `metadata.custom` via `Sagents.FileSystemServer.update_custom_metadata/4`.

  This means implementations only need to define what attributes exist and
  how to validate them — not where they're stored.

  ## Content is Off-limits

  `update_file_attrs` is for metadata, not content. Implementations should
  never include `:content` in their changeset cast list. The middleware
  defends against this anyway: if `:content` appears in validated changes,
  the routing layer raises an error directing the LLM to use
  `replace_text`, `replace_lines`, or `create_file`.

  ## Example Implementation

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
  """

  alias Sagents.FileSystem.FileEntry

  @doc """
  Cast and validate LLM-supplied attributes.

  Returns an `Ecto.Changeset`. If invalid, the middleware formats the errors
  and returns them to the LLM as a tool error so it can self-correct.

  The changeset's underlying schema defines what attributes are accepted.
  Fields not in the schema's cast list are ignored. Type casting is automatic
  via Ecto.
  """
  @callback changeset(attrs :: map()) :: Ecto.Changeset.t()

  @doc """
  Convert a `FileEntry` into the map representation the LLM sees.

  Called by `list_files`, `create_file`, and `update_file_attrs` for tool
  responses. The returned map is JSON-encoded before being sent to the LLM.
  """
  @callback to_llm_map(entry :: FileEntry.t()) :: map()
end
