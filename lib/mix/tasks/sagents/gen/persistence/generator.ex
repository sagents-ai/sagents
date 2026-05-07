defmodule Mix.Sagents.Gen.Persistence.Generator do
  @moduledoc false

  alias Mix.Sagents.Gen.Persistence.{Schema, Context, Migration}

  def generate(config) do
    ensure_directories(config)

    [
      Context.generate(config),
      Schema.generate_conversation(config),
      Schema.generate_agent_state(config),
      Schema.generate_display_message(config),
      Migration.generate(config)
    ]
  end

  defp ensure_directories(config) do
    File.mkdir_p!(context_directory(config))
    File.mkdir_p!("priv/repo/migrations")
  end

  defp context_directory(config) do
    config.context_module
    |> String.split(".")
    |> Enum.map(&Macro.underscore/1)
    |> Path.join()
    |> then(&"lib/#{&1}")
  end
end
