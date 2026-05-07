defmodule Sagents.FactoryRouter do
  @moduledoc """
  Behaviour for selecting the factory module for a conversation.

  The coordinator consults the configured router on every session start —
  including resume — so a restored conversation always picks the factory
  it was originally created with (correct system prompts, tools, middleware).

  ## Router contract

  `resolve/3` returns `{:ok, factory_module, config}` where `config` is
  forwarded verbatim to `factory_module.create_agent(agent_id, config)`.
  The library treats `config` as opaque — it does not inspect, modify, or
  merge into it. By convention `config` is a typed struct (commonly an
  `Ecto.Schema` `embedded_schema`) defined by a paired `*Config` module
  (see the generated `FactoryConfig` in `mix sagents.setup`).

  Routers can preload domain data (loaded conversations, project records,
  etc.) and bundle it into the config the factory will consume.

  ## Single-factory apps

  Use `Sagents.Routers.Single`:

      defmodule MyApp.Agents.Router do
        use Sagents.Routers.Single,
          factory: MyApp.Agents.Factory,
          config: MyApp.Agents.FactoryConfig
      end

  ## Multi-factory apps

  Implement `resolve/3` directly. A common pattern is to load the
  conversation, switch on a metadata field, and build the appropriate
  Config:

      defmodule MyApp.Agents.Router do
        @behaviour Sagents.FactoryRouter

        alias MyApp.Conversations
        alias MyApp.Agents.{CodingFactory, CodingConfig}
        alias MyApp.Agents.{WritingFactory, WritingConfig}
        alias MyApp.Agents.{DefaultFactory, DefaultConfig}

        @impl true
        def resolve(scope, conversation_id, request_opts) do
          conversation = Conversations.get_conversation!(scope, conversation_id)

          {factory, config_module} =
            case conversation.agent_kind do
              "coding" -> {CodingFactory, CodingConfig}
              "writing" -> {WritingFactory, WritingConfig}
              _ -> {DefaultFactory, DefaultConfig}
            end

          inputs =
            request_opts
            |> Map.new()
            |> Map.put(:scope, scope)
            |> Map.put(:conversation_id, conversation_id)
            |> Map.put(:conversation, conversation)

          case config_module.from_inputs(inputs) |> config_module.build() do
            {:ok, config} -> {:ok, factory, config}
            {:error, %Ecto.Changeset{}} = err -> err
          end
        end
      end
  """

  @callback resolve(scope :: term(), conversation_id :: term(), request_opts :: keyword()) ::
              {:ok, factory_module :: module(), config :: term()} | {:error, term()}
end
