defmodule Sagents.FileSystem.FileSystemConfig do
  @moduledoc """
  Configuration for a filesystem persistence backend.

  A FileSystemConfig defines how files in a specific virtual directory are persisted.
  Multiple configs can be registered with a FileSystemServer, allowing different
  directories to use different persistence backends with different settings.

  ## Fields

  - `:base_directory` - Virtual directory path this config applies to (e.g., "user_memories", "S3")
  - `:persistence_module` - Module implementing the Persistence behaviour
  - `:debounce_ms` - Milliseconds of inactivity before auto-persist (default: 5000)
  - `:readonly` - Whether files in this directory are read-only (default: false)
  - `:default` - When true, this config acts as a fallback for any file that doesn't
    match a specific `base_directory` config (default: false). When `default: true`,
    `base_directory` is optional — if omitted, the sentinel value `"__default__"` is
    used internally as an identifier.
  - `:storage_opts` - Backend-specific options passed to persistence module

  ## Examples

      # Writable user files with disk persistence
      {:ok, config} = FileSystemConfig.new(%{
        base_directory: "user_files",
        persistence_module: Sagents.FileSystem.Persistence.Disk,
        debounce_ms: 5000,
        storage_opts: [path: "/data/users"]
      })

      # Read-only account files from database
      {:ok, config} = FileSystemConfig.new(%{
        base_directory: "account_files",
        persistence_module: MyApp.DBPersistence,
        readonly: true,
        storage_opts: [repo: MyApp.Repo, table: "account_files"]
      })

      # Read-only S3 files
      {:ok, config} = FileSystemConfig.new(%{
        base_directory: "S3",
        persistence_module: MyApp.S3Persistence,
        readonly: true,
        debounce_ms: 30000,
        storage_opts: [bucket: "shared-assets", region: "us-east-1"]
      })
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias LangChain.Utils

  @primary_key false
  embedded_schema do
    field :base_directory, :string
    field :persistence_module, :any, virtual: true
    field :debounce_ms, :integer, default: 5000
    field :readonly, :boolean, default: false
    field :default, :boolean, default: false
    field :storage_opts, :any, virtual: true, default: []
  end

  @type t :: %FileSystemConfig{
          base_directory: String.t(),
          persistence_module: module(),
          debounce_ms: non_neg_integer(),
          readonly: boolean(),
          default: boolean(),
          storage_opts: keyword()
        }

  @doc """
  Creates a new FileSystemConfig.

  ## Parameters

  - `attrs` - Map or keyword list with config fields

  ## Required Fields

  - `:base_directory` - Virtual directory path (without leading/trailing slashes)
  - `:persistence_module` - Module implementing Persistence behaviour

  ## Optional Fields

  - `:debounce_ms` - Auto-persist delay in milliseconds (default: 5000)
  - `:readonly` - Read-only flag (default: false)
  - `:storage_opts` - Backend-specific options (default: [])

  ## Returns

  - `{:ok, config}` on success
  - `{:error, changeset}` on validation failure

  ## Examples

      iex> FileSystemConfig.new(%{
      ...>   base_directory: "user_files",
      ...>   persistence_module: MyApp.Persistence.Disk,
      ...>   debounce_ms: 3000,
      ...>   storage_opts: [path: "/data"]
      ...> })
      {:ok, %FileSystemConfig{}}

      iex> FileSystemConfig.new(%{base_directory: ""})
      {:error, %Ecto.Changeset{}}
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_list(attrs) do
    new(Map.new(attrs))
  end

  def new(attrs) when is_map(attrs) do
    %FileSystemConfig{}
    |> changeset(attrs)
    |> apply_action(:insert)
    |> case do
      {:ok, config} -> {:ok, config}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Creates a new FileSystemConfig, raising on error.

  Same as `new/1` but raises on validation errors.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, config} -> config
      {:error, changeset} -> raise ArgumentError, Utils.changeset_error_to_string(changeset)
    end
  end

  @doc """
  Creates a changeset for a FileSystemConfig.
  """
  def changeset(config \\ %FileSystemConfig{}, attrs) do
    config
    |> cast(attrs, [:base_directory, :debounce_ms, :readonly, :default])
    |> put_persistence_module(attrs)
    |> put_storage_opts(attrs)
    |> maybe_set_default_base_directory()
    |> validate_required([:base_directory, :persistence_module])
    |> validate_base_directory()
    |> validate_number(:debounce_ms, greater_than_or_equal_to: 0)
    |> validate_persistence_module()
  end

  # Private helpers

  defp put_persistence_module(changeset, %{persistence_module: module}) when is_atom(module) do
    put_change(changeset, :persistence_module, module)
  end

  defp put_persistence_module(changeset, _attrs), do: changeset

  defp put_storage_opts(changeset, %{storage_opts: opts}) when is_list(opts) do
    put_change(changeset, :storage_opts, opts)
  end

  defp put_storage_opts(changeset, _attrs) do
    put_change(changeset, :storage_opts, [])
  end

  # When default: true and no base_directory provided, set sentinel value.
  # Ecto cast converts "" to nil for string fields, so we only need to check for nil.
  defp maybe_set_default_base_directory(changeset) do
    is_default = get_field(changeset, :default) || false
    has_base_dir = get_field(changeset, :base_directory)

    if is_default && is_nil(has_base_dir) do
      put_change(changeset, :base_directory, "__default__")
    else
      changeset
    end
  end

  defp validate_base_directory(changeset) do
    if get_field(changeset, :base_directory) == "__default__" do
      changeset
    else
      changeset
      |> validate_format(:base_directory, ~r/^[^\/]/, message: "must not start with /")
      |> validate_format(:base_directory, ~r/[^\/]$/, message: "must not end with /")
      |> validate_format(:base_directory, ~r/^[^.]+$/, message: "must not contain .")
      |> validate_length(:base_directory, min: 1)
    end
  end

  defp validate_persistence_module(changeset) do
    case get_field(changeset, :persistence_module) do
      nil ->
        changeset

      module when is_atom(module) ->
        # Just verify it's an atom (module name)
        # Runtime will check if behaviour is actually implemented
        changeset

      _other ->
        add_error(
          changeset,
          :persistence_module,
          "must be a valid module name"
        )
    end
  end

  @doc """
  Checks if a given path matches this config's base directory.

  ## Examples

      iex> config = FileSystemConfig.new!(%{
      ...>   base_directory: "user_files",
      ...>   persistence_module: SomeMod
      ...> })
      iex> FileSystemConfig.matches_path?(config, "/user_files/data.txt")
      true
      iex> FileSystemConfig.matches_path?(config, "/other/file.txt")
      false
  """
  @spec matches_path?(t(), String.t()) :: boolean()
  def matches_path?(%FileSystemConfig{base_directory: base_dir}, path) do
    prefix = "/" <> base_dir
    String.starts_with?(path, prefix <> "/")
  end

  @doc """
  Builds storage options for this config, including scope_key.

  ## Examples

      iex> config = FileSystemConfig.new!(%{
      ...>   base_directory: "user_files",
      ...>   persistence_module: SomeMod,
      ...>   storage_opts: [path: "/data"]
      ...> })
      iex> FileSystemConfig.build_storage_opts(config, {:user, 123})
      [path: "/data", scope_key: {:user, 123}, base_directory: "user_files"]

      iex> FileSystemConfig.build_storage_opts(config, {:agent, "agent-123"})
      [path: "/data", scope_key: {:agent, "agent-123"}, base_directory: "user_files"]
  """
  @spec build_storage_opts(t(), tuple()) :: keyword()
  def build_storage_opts(%FileSystemConfig{default: true} = config, scope_key)
      when is_tuple(scope_key) do
    config.storage_opts
    |> Keyword.put(:scope_key, scope_key)
  end

  def build_storage_opts(%FileSystemConfig{} = config, scope_key) when is_tuple(scope_key) do
    config.storage_opts
    |> Keyword.put(:scope_key, scope_key)
    |> Keyword.put(:base_directory, config.base_directory)
  end
end
