defmodule Sagents.AbilitySet do
  @moduledoc """
  One ability set declared to `Sagents.Middleware.AbilitySetSwitcher`: a named
  set of middleware the model can switch to, shown to it as a "mode".

      sets: %{
        "billing" =>
          AbilitySet.new!(%{
            name: "Billing",
            when_to_use: "Invoices, balances, and payment status.",
            middleware: [MyApp.Middleware.Billing]
          })
      }

  The set's key in the `:sets` map is its name, the value the model passes to
  `switch_mode`. The switcher also accepts a plain map or keyword list per
  set and builds the struct from it, with the same validation.

  ## Fields

  - `:when_to_use` - One line telling the model when the set applies
    (required)
  - `:name` - Display name, used in tool results and hints (default: the
    capitalized set key, filled in by the switcher)
  - `:switch_message` - The tool result the model reads after switching to
    the set: a non-empty string, a 1-arity function or a
    `{module, function, args}` tuple. See the switcher's "Switch messages".
  - `:middleware` - The set's middleware specs (default: `[]`)

  ## Unknown keys

  A key that is not a field is an error, not ignored. A misspelled key such as
  `:when_to_us` would otherwise drop its value without a trace, and the set
  would run without it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias LangChain.Utils

  @primary_key false
  embedded_schema do
    field :name, :string
    field :when_to_use, :string
    field :switch_message, :any, virtual: true
    field :middleware, :any, virtual: true, default: []
  end

  @type t :: %AbilitySet{
          name: String.t() | nil,
          when_to_use: String.t(),
          switch_message: String.t() | (map() -> String.t()) | {module(), atom(), list()} | nil,
          middleware: list()
        }

  @fields [:name, :when_to_use, :switch_message, :middleware]
  @field_names Enum.map(@fields, &Atom.to_string/1)

  @doc """
  Build an ability set from a map or keyword list.

  Returns `{:error, changeset}` for a missing or invalid field, or for a key
  that is not a field.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs \\ %{})

  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    # Empty strings are kept, not cast to nil, so an empty :name or
    # :switch_message is an error instead of a silent fall back to the default.
    %AbilitySet{}
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required([:when_to_use])
    |> validate_length(:name, min: 1)
    |> validate_switch_message()
    |> validate_middleware()
    |> reject_unknown_keys(attrs)
    |> apply_action(:insert)
  end

  @doc """
  Build an ability set, raising `LangChain.LangChainError` when it is invalid.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, set} -> set
      {:error, changeset} -> raise LangChain.LangChainError, changeset
    end
  end

  @doc """
  Build an ability set from a struct, map or keyword list, with the error as a
  string. A struct is validated again, so one built without `new/1` is held to
  the same rules.
  """
  @spec cast_set(t() | map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def cast_set(%AbilitySet{} = set), do: set |> Map.from_struct() |> cast_set()

  def cast_set(attrs) when is_map(attrs) or is_list(attrs) do
    case new(attrs) do
      {:ok, set} -> {:ok, set}
      {:error, changeset} -> {:error, Utils.changeset_error_to_string(changeset)}
    end
  end

  @doc """
  True for a 1-arity function or a `{module, function, args}` tuple, the
  callback forms ability sets accept.
  """
  @spec callback?(term()) :: boolean()
  def callback?(fun) when is_function(fun, 1), do: true

  def callback?({module, function, args})
      when is_atom(module) and is_atom(function) and is_list(args),
      do: true

  def callback?(_other), do: false

  defp validate_switch_message(changeset) do
    case get_field(changeset, :switch_message) do
      nil ->
        changeset

      message when is_binary(message) and message != "" ->
        changeset

      other ->
        if callback?(other),
          do: changeset,
          else:
            add_error(
              changeset,
              :switch_message,
              "must be a non-empty string, a 1-arity function or a {module, function, args} tuple"
            )
    end
  end

  defp validate_middleware(changeset) do
    if is_list(get_field(changeset, :middleware)),
      do: changeset,
      else: add_error(changeset, :middleware, "must be a list of middleware specs")
  end

  # Ecto's cast/3 drops keys it does not permit. Here that would hide a typo,
  # so every key must name a field.
  defp reject_unknown_keys(changeset, attrs) do
    unknown =
      attrs
      |> Map.keys()
      |> Enum.reject(&(to_string(&1) in @field_names))

    if unknown == [],
      do: changeset,
      else:
        add_error(
          changeset,
          :attrs,
          "has unknown keys #{inspect(unknown)}; valid keys are #{inspect(@fields)}"
        )
  end
end
