defmodule Mix.Tasks.Sagents.Gen.Factory do
  use Mix.Task

  @shortdoc "Generates a Factory module for creating agents"

  @moduledoc """
  Generates a Factory module for creating agents with consistent configuration.

      $ mix sagents.gen.factory
      $ mix sagents.gen.factory --module MyApp.Agents.Factory

  ## Options

    * `--module` - The Factory module name (default: MyApp.Agents.Factory)

  ## Generated Files

    * `lib/my_app/agents/factory.ex` - Factory module

  The generated Factory includes:
    - ChatAnthropic as default model with Bedrock fallback example
    - Default middleware stack (TodoList, FileSystem, SubAgent, Summarization, PatchToolCalls)
    - HumanInTheLoop integration
    - Commented examples for alternative providers (OpenAI/Azure)

  ## Getting Started

  The Factory is typically generated after the Persistence layer and before
  the Coordinator. See the recommended order:

      # Step 1: Database persistence layer
      mix sagents.gen.persistence MyApp.Conversations \\
        --scope MyApp.Accounts.Scope \\
        --owner-type user \\
        --owner-field user_id

      # Step 2: Agent factory (this generator)
      mix sagents.gen.factory

      # Step 3: Coordinator (ties everything together)
      mix sagents.gen.coordinator

  ## Customization

  After generation, customize the following:

    - `get_model_config/0` - Change LLM provider (OpenAI, Ollama, etc.)
    - `get_fallback_models/0` - Configure model fallbacks for resilience
    - `base_system_prompt/0` - Define your agent's personality and capabilities
    - `build_middleware/2` - Add/remove middleware from the stack
    - `default_interrupt_on/0` - Configure which tools require human approval

  """

  @switches [
    module: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: @switches)

    # Infer application name
    app_name = Mix.Project.config()[:app]
    app_module = app_name |> to_string() |> Macro.camelize()

    # Parse options
    module = Keyword.get(opts, :module, "#{app_module}.Agents.Factory")

    # Generate file
    binding = [
      module: module
    ]

    template_path = Application.app_dir(:sagents, "priv/templates/factory.ex.eex")
    content = EEx.eval_file(template_path, binding)

    # Write file
    module_path = module_to_path(module)
    File.mkdir_p!(Path.dirname(module_path))
    File.write!(module_path, content)

    Mix.shell().info("""

    Generated Factory module:
      #{module_path}

    Next steps:
      1. Set environment variables:
         - ANTHROPIC_API_KEY (required for default configuration)
         - Or configure a different provider in get_model_config/0

      2. Customize the Factory for your use case:
         - Modify base_system_prompt/0 for your agent's purpose
         - Add/remove middleware in build_middleware/2
         - Configure HITL in default_interrupt_on/0

      3. Generate a Coordinator to use this Factory:
         mix sagents.gen.coordinator --factory #{module}

    See the module documentation for detailed customization examples.
    """)
  end

  defp module_to_path(module) when is_binary(module) do
    path =
      module
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()

    "lib/#{path}.ex"
  end
end
