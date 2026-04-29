defmodule Mix.Tasks.Sagents.Gen.LiveHelpers do
  @shortdoc "Generates AgentLiveHelpers module for Phoenix LiveView integration"

  @moduledoc """
  Generates AgentLiveHelpers module for Phoenix LiveView integration with Sagents.

  This module provides reusable patterns for agent event handling, state management,
  and UI updates in Phoenix LiveView applications. All functions take a socket and
  return an updated socket, following the LiveView pattern.

  ## Examples

      mix sagents.gen.live_helpers MyAppWeb.AgentLiveHelpers \\
        --context MyApp.Conversations

  ## Generated files

    * **Helper module**: Reusable handlers for agent events (status, messages, tools, lifecycle)
      and state management helpers (init, load, reset)

  ## Options

    * `--context` - Your conversations context module (required, e.g., MyApp.Conversations)

  ## Integration

  After generation, use the helpers in your LiveView:

      # In mount/3
      def mount(_params, _session, socket) do
        {:ok, socket |> AgentLiveHelpers.init_agent_state() |> assign(...)}
      end

      # In handle_params/3 -- pass scope (required) and user_id (for presence)
      def handle_params(%{"conversation_id" => id}, _uri, socket) do
        current_scope = socket.assigns.current_scope

        case AgentLiveHelpers.load_conversation(
               socket,
               id,
               scope: current_scope,
               user_id: current_scope.user.id
             ) do
          {:ok, socket} -> {:noreply, socket}
          {:error, socket} -> {:noreply, push_navigate(socket, to: ~p"/chat")}
        end
      end

      # In handle_info/2
      def handle_info({:agent, {:status_changed, :running, nil}}, socket) do
        {:noreply, AgentLiveHelpers.handle_status_running(socket)}
      end

  See the generated file for complete documentation and usage examples.

  ## Reference Implementation

  See `agents_demo/test/agents_demo_web/live/agent_live_helpers_test.exs` for
  a comprehensive test suite that you can adapt for your application.
  """

  use Mix.Task

  @switches [
    context: :string
  ]

  @aliases [
    c: :context
  ]

  @impl Mix.Task
  def run(args) do
    # Parse arguments
    {opts, parsed, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    # Validate helper module argument
    helper_module = parse_helper_module!(parsed)

    # Validate context option
    context_module = parse_context!(opts)

    # Build configuration
    config = build_config(helper_module, context_module, opts)

    # Check for existing files before generating
    check_existing_files!(config)

    # Generate files
    generated_files = generate_files(config)

    # Print all generated files
    print_generated_files(generated_files)

    # Print instructions
    print_instructions(config)
  end

  defp parse_helper_module!([helper_module | _]) do
    # Validate module name format
    unless helper_module =~ ~r/^[A-Z][A-Za-z0-9.]*$/ do
      Mix.raise("Helper module must be a valid Elixir module name")
    end

    # Validate that the module is in the Web namespace (Phoenix convention)
    unless String.contains?(helper_module, "Web") do
      base_module = helper_module |> String.split(".") |> hd()

      Mix.raise("""
      Helper module must be in the Web namespace for Phoenix LiveView.

      You provided: #{helper_module}
      Did you mean: #{base_module}Web.AgentLiveHelpers?

      LiveView helpers should always be under your application's Web module.
      Example: mix sagents.gen.live_helpers MyAppWeb.AgentLiveHelpers --context MyApp.Conversations
      """)
    end

    helper_module
  end

  defp parse_helper_module!([]) do
    Mix.raise(
      "Helper module is required. Example: mix sagents.gen.live_helpers MyAppWeb.AgentLiveHelpers --context MyApp.Conversations"
    )
  end

  defp parse_context!(opts) do
    case opts[:context] do
      nil ->
        Mix.raise(
          "Context module is required. Use --context flag. Example: --context MyApp.Conversations"
        )

      context_module ->
        # Validate module name format
        unless context_module =~ ~r/^[A-Z][A-Za-z0-9.]*$/ do
          Mix.raise("Context module must be a valid Elixir module name")
        end

        context_module
    end
  end

  defp build_config(helper_module, context_module, _opts) do
    # Infer application from helper module
    app = infer_app(helper_module)

    %{
      helper_module: helper_module,
      context_module: context_module,
      app: app,
      app_module: app_module(app)
    }
  end

  defp check_existing_files!(config) do
    # Get list of all files that will be generated
    files_to_generate = [module_to_path(config.helper_module)]

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

  defp generate_files(config) do
    # Generate helper module
    helper_file = generate_helper_module(config)
    [helper_file]
  end

  defp generate_helper_module(config) do
    # Extract short alias for conversations module (e.g., Conversations from AgentsDemo.Conversations)
    conversations_alias =
      config.context_module
      |> String.split(".")
      |> List.last()

    # Infer coordinator module from context module
    # E.g., MyApp.Conversations -> MyApp.Agents.Coordinator
    coordinator_module = infer_coordinator_module(config.context_module)

    coordinator_alias =
      coordinator_module
      |> String.split(".")
      |> List.last()

    # Infer the host-agnostic subscriber-session module (sibling of Coordinator).
    subscriber_session_module = infer_subscriber_session_module(config.context_module)

    subscriber_session_alias =
      subscriber_session_module
      |> String.split(".")
      |> List.last()

    # Prepare bindings for helper template
    binding = [
      module: config.helper_module,
      conversations_module: config.context_module,
      conversations_alias: conversations_alias,
      coordinator_module: coordinator_module,
      coordinator_alias: coordinator_alias,
      subscriber_session_module: subscriber_session_module,
      subscriber_session_alias: subscriber_session_alias,
      app: config.app,
      app_module: config.app_module
    ]

    # Load and evaluate template
    template_path = Application.app_dir(:sagents, "priv/templates/agent_live_helpers.ex.eex")
    content = EEx.eval_file(template_path, binding)

    # Write file
    helper_path = module_to_path(config.helper_module)
    File.mkdir_p!(Path.dirname(helper_path))
    File.write!(helper_path, content)

    helper_path
  end

  defp print_generated_files(files) do
    Mix.shell().info("\nGenerated files:")

    Enum.each(files, fn file ->
      Mix.shell().info("  * #{IO.ANSI.green()}#{file}#{IO.ANSI.reset()}")
    end)
  end

  defp print_instructions(config) do
    helper_path = module_to_path(config.helper_module)

    Mix.shell().info([
      :green,
      """

      🎉 AgentLiveHelpers generated successfully!

      Next steps:

        1. Review the generated helper module (#{helper_path}):
           * State management helpers (init_agent_state, load_conversation, reset_conversation)
           * Event handlers for all agent lifecycle events
           * Customize message formatting or error handling as needed
           * The module is hardcoded with your context (#{config.context_module})

        2. Integrate state management helpers. `load_conversation/3` requires
           a `:scope` — pass the Phoenix scope from the socket so that
           every DB query and persistence callback is tenant-filtered.

           defmodule MyAppWeb.ChatLive do
             alias #{config.helper_module}

             def mount(_params, _session, socket) do
               {:ok,
                socket
                |> AgentLiveHelpers.init_agent_state()
                |> assign(:input, "")
                # ... other app-specific assigns
               }
             end

             def handle_params(%{"conversation_id" => id}, _uri, socket) do
               current_scope = socket.assigns.current_scope

               case AgentLiveHelpers.load_conversation(
                      socket,
                      id,
                      scope: current_scope,
                      user_id: current_scope.user.id
                    ) do
                 {:ok, socket} -> {:noreply, socket}
                 {:error, socket} -> {:noreply, push_navigate(socket, to: ~p"/chat")}
               end
             end
           end

        3. Integrate event handlers:

           def handle_info({:agent, {:status_changed, :running, nil}}, socket) do
             {:noreply, AgentLiveHelpers.handle_status_running(socket)}
           end

           def handle_info({:agent, {:llm_deltas, deltas}}, socket) do
             {:noreply, AgentLiveHelpers.handle_llm_deltas(socket, deltas)}
           end

           # Subscription recovery — required for crash and Horde-migration handling.
           def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
             {:noreply, AgentLiveHelpers.handle_publisher_down(socket, ref, reason)}
           end

           def handle_info(
                 %Phoenix.Socket.Broadcast{event: "presence_diff", payload: payload},
                 socket
               ) do
             {:noreply, AgentLiveHelpers.handle_presence_diff(socket, payload)}
           end

           # In mount/3, subscribe to the agent presence topic so presence_diff
           # broadcasts can fulfill any pending subscription:
           #
           #   if connected?(socket) do
           #     Phoenix.PubSub.subscribe(#{config.app_module}.PubSub,
           #       Sagents.Subscriber.presence_topic())
           #   end

           # ... see generated file for all available handlers

      Key features of the generated helpers:
        - State management: init_agent_state/1, load_conversation/3, reset_conversation/1
        - Status change handlers (running, idle, cancelled, error, interrupted)
        - Message handlers (LLM deltas, message complete, display messages)
        - Tool execution handlers (identified, started, completed, failed)
        - Lifecycle handlers (title generated, agent shutdown)

      Reference implementation:
        See agents_demo/test/agents_demo_web/live/agent_live_helpers_test.exs
        for a comprehensive test suite you can adapt for your application.

      See the generated file for complete documentation and all available functions.

      """
    ])
  end

  # Helper functions

  defp infer_app(module) do
    module
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

  defp module_to_path(module) when is_binary(module) do
    # Convert MyAppWeb.AgentLiveHelpers to lib/my_app_web/live/agent_live_helpers.ex
    parts = String.split(module, ".")

    # Get the web module parts (e.g., ["MyAppWeb"]) and the helper name (e.g., "AgentLiveHelpers")
    {web_parts, [helper_name]} = Enum.split(parts, -1)

    # Convert to path: my_app_web/live/agent_live_helpers
    web_path = web_parts |> Enum.map(&Macro.underscore/1) |> Path.join()
    helper_file = Macro.underscore(helper_name) <> ".ex"

    Path.join(["lib", web_path, "live", helper_file])
  end

  defp infer_coordinator_module(context_module) do
    # Convert MyApp.Conversations -> MyApp.Agents.Coordinator
    # Get base application module (e.g., MyApp from MyApp.Conversations)
    parts = String.split(context_module, ".")
    base_module = hd(parts)

    "#{base_module}.Agents.Coordinator"
  end

  defp infer_subscriber_session_module(context_module) do
    # Convert MyApp.Conversations -> MyApp.Agents.AgentSubscriberSession
    parts = String.split(context_module, ".")
    base_module = hd(parts)

    "#{base_module}.Agents.AgentSubscriberSession"
  end
end
