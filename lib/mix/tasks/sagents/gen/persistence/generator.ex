defmodule Mix.Sagents.Gen.Persistence.Generator do
  @moduledoc false

  alias Mix.Sagents.Gen.Persistence.{Schema, Context, Migration}

  def generate(config) do
    # Ensure directories exist
    ensure_directories(config)

    # Generate files
    files = []

    # 1. Generate context module
    context_file = Context.generate(config)
    files = [context_file | files]

    # 2. Generate schema files
    conversation_file = Schema.generate_conversation(config)
    agent_state_file = Schema.generate_agent_state(config)
    display_message_file = Schema.generate_display_message(config)
    files = [conversation_file, agent_state_file, display_message_file | files]

    # 3. Generate migration
    migration_file = Migration.generate(config)
    files = [migration_file | files]

    # 4. Generate Factory module
    factory_file = generate_factory(config)
    files = [factory_file | files]

    # Return files list for caller to print
    files
  end

  defp ensure_directories(config) do
    # Context directory
    context_dir = context_directory(config)
    File.mkdir_p!(context_dir)

    # Migration directory
    File.mkdir_p!("priv/repo/migrations")
  end

  defp context_directory(config) do
    config.context_module
    |> String.split(".")
    |> Enum.map(&Macro.underscore/1)
    |> Path.join()
    |> then(&"lib/#{&1}")
  end

  defp generate_factory(config) do
    # Prepare bindings for Factory template
    binding = [
      module: config.factory_module,
      owner_type: config.owner_type,
      owner_field: config.owner_field,
      conversations_module: config.context_module,
      repo_module: config.repo
    ]

    # Load and evaluate template
    template_path = Application.app_dir(:sagents, "priv/templates/factory.ex.eex")
    content = EEx.eval_file(template_path, binding)

    # Write file
    factory_path = module_to_path(config.factory_module)
    File.mkdir_p!(Path.dirname(factory_path))
    File.write!(factory_path, content)

    factory_path
  end

  defp module_to_path(module) when is_binary(module) do
    module
    |> String.split(".")
    |> Enum.map(&Macro.underscore/1)
    |> Path.join()
    |> then(&"lib/#{&1}.ex")
  end
end
