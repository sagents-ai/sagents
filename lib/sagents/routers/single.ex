defmodule Sagents.Routers.Single do
  @moduledoc """
  Trivial single-factory router. Use when your app has one agent type.

      defmodule MyApp.Agents.Router do
        use Sagents.Routers.Single,
          factory: MyApp.Agents.Factory,
          config: MyApp.Agents.FactoryConfig
      end

  The generated `resolve/3` always returns the configured factory paired
  with a config built from the configured Config module. The Config
  module must expose:

  - `from_inputs(map) :: Ecto.Changeset.t()` — start a build pipeline
    from a map containing at least `:scope` and `:conversation_id`.
  - `build(Ecto.Changeset.t()) :: {:ok, struct} | {:error, Ecto.Changeset.t()}` —
    finalize.

  Apps with multiple agent types should hand-write `resolve/3` instead.
  """

  defmacro __using__(opts) do
    factory = Keyword.fetch!(opts, :factory)
    config_module = Keyword.fetch!(opts, :config)

    quote do
      @behaviour Sagents.FactoryRouter

      @impl true
      def resolve(scope, conversation_id, request_opts) do
        inputs =
          request_opts
          |> Map.new()
          |> Map.put(:scope, scope)
          |> Map.put(:conversation_id, conversation_id)

        case unquote(config_module).from_inputs(inputs)
             |> unquote(config_module).build() do
          {:ok, config} -> {:ok, unquote(factory), config}
          {:error, %Ecto.Changeset{}} = err -> err
        end
      end
    end
  end
end
