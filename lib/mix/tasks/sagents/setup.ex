defmodule Mix.Tasks.Sagents.Setup do
  @shortdoc "Sets up Sagents for conversation-centric agents"

  @moduledoc """
  Generates all infrastructure needed for conversation-centric agents.

  This single command generates everything you need to get started with Sagents:
  database persistence, agent factory, and coordinator for managing agent lifecycles.

  ## Examples

      # Basic setup
      mix sagents.setup MyApp.Conversations \\
        --scope MyApp.Accounts.Scope

      # With all options
      mix sagents.setup MyApp.Conversations \\
        --scope MyApp.Accounts.Scope \\
        --owner-type user \\
        --owner-field user_id \\
        --factory MyApp.Agents.Factory \\
        --coordinator MyApp.Agents.Coordinator \\
        --pubsub MyApp.PubSub \\
        --presence MyAppWeb.Presence

  ## Generated files

    * **Persistence layer**: Context, schemas (Conversation, AgentState, DisplayMessage), migration
    * **Factory module**: Agent creation with model/middleware configuration
    * **Coordinator module**: Session management and agent lifecycle orchestration
    * **AgentPersistence module**: Behaviour implementation for agent state persistence
    * **DisplayMessagePersistence module**: Behaviour implementation for display message persistence

  ## Options

    * `--scope` - Application scope module (required)
    * `--owner-type` - Owner association type (default: user)
    * `--owner-field` - Owner FK field (default: user_id)
    * `--owner-module` - Owner schema module (inferred from type)
    * `--table-prefix` - Table name prefix (default: sagents_)
    * `--repo` - Repo module (inferred from app)
    * `--web` - Web module namespace (inferred from app)
    * `--factory` - Factory module name (default: MyApp.Agents.Factory)
    * `--coordinator` - Coordinator module name (default: MyApp.Agents.Coordinator)
    * `--pubsub` - PubSub module name (default: MyApp.PubSub)
    * `--presence` - Presence module name (default: MyAppWeb.Presence)
  """

  use Mix.Task
  alias Mix.Sagents.Gen.Persistence.Generator

  @switches [
    scope: :string,
    owner_type: :string,
    owner_field: :string,
    owner_module: :string,
    table_prefix: :string,
    repo: :string,
    web: :string,
    factory: :string,
    coordinator: :string,
    pubsub: :string,
    presence: :string
  ]

  @aliases [
    s: :scope,
    t: :owner_type,
    f: :owner_field
  ]

  @impl Mix.Task
  def run(args) do
    # Parse arguments
    {opts, parsed, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    # Validate context argument
    context_module = parse_context!(parsed)

    # Build configuration
    config = build_config(context_module, opts)

    # Check for existing files before generating
    check_existing_files!(config)

    # Generate persistence files (returns list of generated file paths)
    persistence_files = Generator.generate(config)

    # Generate coordinator
    coordinator_path = generate_coordinator(config)

    # Generate persistence behaviour modules
    agent_persistence_path = generate_agent_persistence(config)
    display_message_persistence_path = generate_display_message_persistence(config)

    # Print all generated files
    all_files = [coordinator_path, agent_persistence_path, display_message_persistence_path | persistence_files]
    print_generated_files(all_files)

    # Print instructions
    print_instructions(config)

    # Prompt for LiveView helpers generation
    prompt_live_helpers(config)
  end

  defp parse_context!([context | _]) do
    # Validate module name format
    unless context =~ ~r/^[A-Z][A-Za-z0-9.]*$/ do
      Mix.raise("Context module must be a valid Elixir module name")
    end

    context
  end

  defp parse_context!([]) do
    Mix.raise(
      "Context module is required. Example: mix sagents.setup MyApp.Conversations --scope MyApp.Accounts.Scope"
    )
  end

  defp build_config(context_module, opts) do
    # Infer application from context
    app = infer_app(context_module)

    # Get or prompt for scope module
    scope_module = opts[:scope] || prompt_scope() || Mix.raise("Scope module is required")

    %{
      context_module: context_module,
      context_name: context_name(context_module),
      app: app,
      app_module: app_module(app),
      scope_module: scope_module,
      owner_type: opts[:owner_type] || "user",
      owner_field: opts[:owner_field] || "user_id",
      owner_module: opts[:owner_module] || infer_owner_module(app, opts[:owner_type] || "user"),
      table_prefix: opts[:table_prefix] || "sagents_",
      repo: opts[:repo] || "#{app_module(app)}.Repo",
      web: opts[:web] || "#{app_module(app)}Web",
      factory_module: opts[:factory] || "#{app_module(app)}.Agents.Factory",
      coordinator_module: opts[:coordinator] || "#{app_module(app)}.Agents.Coordinator",
      agent_persistence_module: "#{app_module(app)}.Agents.AgentPersistence",
      display_message_persistence_module: "#{app_module(app)}.Agents.DisplayMessagePersistence",
      pubsub_module: opts[:pubsub] || "#{app_module(app)}.PubSub",
      presence_module: opts[:presence] || "#{app_module(app)}Web.Presence"
    }
  end

  defp check_existing_files!(config) do
    # Get list of all files that will be generated
    files_to_generate = [
      module_to_path(config.factory_module),
      module_to_path(config.coordinator_module),
      module_to_path(config.agent_persistence_module),
      module_to_path(config.display_message_persistence_module),
      module_to_path(config.context_module),
      module_to_path("#{config.context_module}.Conversation"),
      module_to_path("#{config.context_module}.AgentState"),
      module_to_path("#{config.context_module}.DisplayMessage")
    ]

    # Check which files already exist
    existing_files = Enum.filter(files_to_generate, &File.exists?/1)

    if Enum.any?(existing_files) do
      Mix.shell().info(
        "\n#{IO.ANSI.yellow()}Warning: The following files already exist:#{IO.ANSI.reset()}\n"
      )

      Enum.each(existing_files, fn file ->
        Mix.shell().info("  * #{IO.ANSI.red()}#{file}#{IO.ANSI.reset()}")
      end)

      Mix.shell().info("")

      response =
        Mix.shell().yes?(
          "Do you want to overwrite these files? This cannot be undone unless you have them in git."
        )

      unless response do
        Mix.shell().info(
          "\n#{IO.ANSI.yellow()}Aborted. No files were modified.#{IO.ANSI.reset()}"
        )

        System.halt(0)
      end

      Mix.shell().info("")
    end
  end

  defp prompt_scope do
    Mix.shell().prompt("Application scope module (e.g., MyApp.Accounts.Scope):")
    |> String.trim()
    |> case do
      "" -> nil
      scope -> scope
    end
  end

  defp context_name(context_module) do
    context_module
    |> String.split(".")
    |> List.last()
  end

  defp infer_app(context_module) do
    context_module
    |> String.split(".")
    |> hd()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp app_module(app) do
    app
    |> Atom.to_string()
    |> Macro.camelize()
  end

  defp infer_owner_module(app, "user"), do: "#{app_module(app)}.Accounts.User"
  defp infer_owner_module(app, "account"), do: "#{app_module(app)}.Accounts.Account"

  defp infer_owner_module(app, "organization"),
    do: "#{app_module(app)}.Organizations.Organization"

  defp infer_owner_module(app, "org"), do: "#{app_module(app)}.Organizations.Organization"
  defp infer_owner_module(app, "team"), do: "#{app_module(app)}.Teams.Team"
  defp infer_owner_module(_app, "none"), do: nil
  defp infer_owner_module(app, type), do: "#{app_module(app)}.#{Macro.camelize(type)}"

  defp generate_coordinator(config) do
    # Prepare bindings for Coordinator template
    binding = [
      module: config.coordinator_module,
      factory_module: config.factory_module,
      conversations_module: config.context_module,
      agent_persistence_module: config.agent_persistence_module,
      display_message_persistence_module: config.display_message_persistence_module,
      pubsub_module: config.pubsub_module,
      presence_module: config.presence_module,
      owner_type: config.owner_type,
      owner_field: config.owner_field
    ]

    # Load and evaluate template
    template_path = Application.app_dir(:sagents, "priv/templates/coordinator.ex.eex")
    content = EEx.eval_file(template_path, binding)

    # Write file
    coordinator_path = module_to_path(config.coordinator_module)
    File.mkdir_p!(Path.dirname(coordinator_path))
    File.write!(coordinator_path, content)

    coordinator_path
  end

  defp generate_agent_persistence(config) do
    binding = [
      module: config.agent_persistence_module,
      conversations_module: config.context_module
    ]

    template_path = Application.app_dir(:sagents, "priv/templates/agent_persistence.ex.eex")
    content = EEx.eval_file(template_path, binding)

    file_path = module_to_path(config.agent_persistence_module)
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, content)

    file_path
  end

  defp generate_display_message_persistence(config) do
    binding = [
      module: config.display_message_persistence_module,
      conversations_module: config.context_module
    ]

    template_path = Application.app_dir(:sagents, "priv/templates/display_message_persistence.ex.eex")
    content = EEx.eval_file(template_path, binding)

    file_path = module_to_path(config.display_message_persistence_module)
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, content)

    file_path
  end

  defp print_generated_files(files) do
    Mix.shell().info("\nGenerated files:")

    Enum.each(files, fn file ->
      Mix.shell().info("  * #{IO.ANSI.green()}#{file}#{IO.ANSI.reset()}")
    end)
  end

  defp print_instructions(config) do
    factory_path = module_to_path(config.factory_module)

    Mix.shell().info([
      :green,
      """

      🎉 Sagents setup complete!

      Next steps:

        1. Add Sagents.Supervisor to your application supervision tree
           (after Repo and PubSub, before Endpoint):

           # lib/#{config.app}/application.ex
           children = [
             #{config.app_module}.Repo,
             {Phoenix.PubSub, name: #{config.pubsub_module}},
             #{config.presence_module},
             Sagents.Supervisor,    # <-- Add this
             #{config.web}.Endpoint
           ]

        2. Run migrations:

           mix ecto.migrate

        3. Set environment variables:

           export ANTHROPIC_API_KEY=your_api_key

        4. Customize the Factory (#{factory_path}):
           * Modify base_system_prompt/0 for your agent's purpose
           * Add/remove middleware in build_middleware/2
           * Add custom tools under the :tools key in create_agent/1
           * Configure HITL in default_interrupt_on/0
           * Change model provider in get_model_config/0 if needed

      Your Sagents infrastructure is configured for:
        - Owner type: :#{config.owner_type}
        - Owner field: #{config.owner_field}
        - Conversations context: #{config.context_module}
        - Factory: #{config.factory_module}
        - Coordinator: #{config.coordinator_module}

      """
    ])
  end

  defp module_to_path(module) when is_binary(module) do
    module
    |> String.split(".")
    |> Enum.map(&Macro.underscore/1)
    |> Path.join()
    |> then(&"lib/#{&1}.ex")
  end

  defp prompt_live_helpers(config) do
    Mix.shell().info([
      :cyan,
      """

      📝 LiveView Integration
      """
    ])

    response = Mix.shell().yes?("Would you like to generate LiveView integration helpers?")

    if response do
      Mix.shell().info("\n#{IO.ANSI.cyan()}Generating LiveView helpers...#{IO.ANSI.reset()}")

      # Build the command
      web_module = config.web
      helper_module = "#{web_module}.AgentLiveHelpers"

      # Run the gen.live_helpers task
      Mix.Task.run("sagents.gen.live_helpers", [
        helper_module,
        "--context",
        config.context_module
      ])
    else
      # Show them how to generate it later
      web_module = config.web
      helper_module = "#{web_module}.AgentLiveHelpers"

      Mix.shell().info([
        :yellow,
        """

        If you're using Phoenix LiveView, you can generate integration helpers later:

          mix sagents.gen.live_helpers #{helper_module} --context #{config.context_module}

        The AgentLiveHelpers module provides reusable patterns for:
          - State management (init_agent_state, load_conversation, reset_conversation)
          - Agent event handling (status changes, messages, tool execution)
          - Automatic subscription and presence tracking

        """
      ])
    end
  end
end
