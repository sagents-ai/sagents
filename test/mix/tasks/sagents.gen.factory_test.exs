defmodule Mix.Tasks.Sagents.Gen.FactoryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @tmp_dir "test/tmp/factory_gen"

  setup do
    # Clean up any leftover files from previous test runs
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  describe "run/1" do
    test "generates factory with default module name" do
      in_tmp_project(fn ->
        output = capture_io(fn ->
          Mix.Tasks.Sagents.Gen.Factory.run([])
        end)

        # Check output message
        assert output =~ "Generated Factory module:"
        assert output =~ "lib/test_app/agents/factory.ex"
        assert output =~ "mix sagents.gen.coordinator"
        assert output =~ "ANTHROPIC_API_KEY"

        # Check file was created
        assert File.exists?("lib/test_app/agents/factory.ex")

        # Check file contents
        content = File.read!("lib/test_app/agents/factory.ex")
        assert content =~ "defmodule TestApp.Agents.Factory do"
        assert content =~ "def create_agent(opts \\\\ [])"
        assert content =~ "ChatAnthropic"
        assert content =~ "build_middleware"
        assert content =~ "default_interrupt_on"
        assert content =~ "HumanInTheLoop.maybe_append"
      end)
    end

    test "generates factory with custom module name" do
      in_tmp_project(fn ->
        output = capture_io(fn ->
          Mix.Tasks.Sagents.Gen.Factory.run(["--module", "MyApp.Custom.AgentFactory"])
        end)

        assert output =~ "lib/my_app/custom/agent_factory.ex"

        # Check file was created at custom path
        assert File.exists?("lib/my_app/custom/agent_factory.ex")

        # Check module name in content
        content = File.read!("lib/my_app/custom/agent_factory.ex")
        assert content =~ "defmodule MyApp.Custom.AgentFactory do"
      end)
    end

    test "generated factory contains required components" do
      in_tmp_project(fn ->
        capture_io(fn ->
          Mix.Tasks.Sagents.Gen.Factory.run([])
        end)

        content = File.read!("lib/test_app/agents/factory.ex")

        # Check for model configuration
        assert content =~ "get_model_config"
        assert content =~ "claude-sonnet-4-5-20250929"
        assert content =~ "ANTHROPIC_API_KEY"

        # Check for fallback models section
        assert content =~ "get_fallback_models"
        assert content =~ "BedrockConfig"

        # Check for system prompt
        assert content =~ "base_system_prompt"

        # Check for middleware
        assert content =~ "Sagents.Middleware.TodoList"
        assert content =~ "Sagents.Middleware.FileSystem"
        assert content =~ "Sagents.Middleware.SubAgent"
        assert content =~ "Sagents.Middleware.Summarization"
        assert content =~ "Sagents.Middleware.PatchToolCalls"
        assert content =~ "ConversationTitle"

        # Check for title generation model configuration
        assert content =~ "@title_model"
        assert content =~ "claude-3-5-haiku-latest"
        assert content =~ "get_title_model"
        assert content =~ "get_title_fallbacks"

        # Check for HITL configuration
        assert content =~ "default_interrupt_on"
        assert content =~ "delete_file"

        # Check for agent options
        assert content =~ ":agent_id"
        assert content =~ ":timezone"
        assert content =~ ":interrupt_on"
      end)
    end

    test "generated factory contains commented examples" do
      in_tmp_project(fn ->
        capture_io(fn ->
          Mix.Tasks.Sagents.Gen.Factory.run([])
        end)

        content = File.read!("lib/test_app/agents/factory.ex")

        # Check for OpenAI alternative comments
        assert content =~ "OpenAI alternative"
        assert content =~ "ChatOpenAI"

        # Check for Azure alternative comments
        assert content =~ "Azure"

        # Check for filesystem scope example
        assert content =~ "filesystem_scope"

        # Check for block_middleware example
        assert content =~ "block_middleware"
      end)
    end

    test "generated factory has proper documentation" do
      in_tmp_project(fn ->
        capture_io(fn ->
          Mix.Tasks.Sagents.Gen.Factory.run([])
        end)

        content = File.read!("lib/test_app/agents/factory.ex")

        # Check moduledoc
        assert content =~ "@moduledoc \"\"\""
        assert content =~ "Factory for creating agents"

        # Check function doc
        assert content =~ "@doc \"\"\""
        assert content =~ "Creates an agent with the standard configuration"
        assert content =~ "## Options"
        assert content =~ "## Examples"
      end)
    end

    test "next steps mention coordinator generator" do
      in_tmp_project(fn ->
        output = capture_io(fn ->
          Mix.Tasks.Sagents.Gen.Factory.run([])
        end)

        assert output =~ "mix sagents.gen.coordinator"
        assert output =~ "--factory TestApp.Agents.Factory"
      end)
    end
  end

  # Helper to run tests in a temporary Mix project context
  defp in_tmp_project(fun) do
    File.cd!(@tmp_dir, fn ->
      # Create a minimal mix.exs for the test project
      File.write!("mix.exs", """
      defmodule TestApp.MixProject do
        use Mix.Project

        def project do
          [
            app: :test_app,
            version: "0.1.0"
          ]
        end
      end
      """)

      # Load the project config
      Mix.Project.in_project(:test_app, ".", fn _module ->
        fun.()
      end)
    end)
  end
end
