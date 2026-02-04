defmodule Sagents.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :sagents,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      name: "Sagents",
      description: """
      Agent orchestration framework for Elixir, built on top of LangChain.
      Provides AgentServer, middleware system, state management, and more.
      """
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sagents.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core dependency - the LangChain library
      {:langchain, "~> 0.5.1"},

      # Required dependencies
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto, "~> 3.10 or ~> 3.11"},

      # Optional dependencies
      {:phoenix, "~> 1.7", optional: true},

      # Development dependencies
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},

      # Test dependencies
      {:mimic, "~> 1.8", only: :test}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: extras(),
      groups_for_extras: [
        Docs: Path.wildcard("docs/*.md")
      ],
      before_closing_head_tag: &before_closing_head_tag/1,
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp extras do
    [
      "README.md",
      "docs/architecture.md",
      "docs/conversations_architecture.md",
      "docs/lifecycle.md",
      "docs/pubsub_presence.md",
      "docs/middleware.md",
      "docs/middleware_messaging.md",
      "docs/persistence.md"
    ]
  end

  defp before_closing_head_tag(:html) do
    """
    <!-- HTML injected at the end of the <head> element -->
    """
  end

  defp before_closing_head_tag(:epub), do: ""

  defp before_closing_body_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
    <script>
      let initialized = false;

      window.addEventListener("exdoc:loaded", () => {
        if (!initialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
        }

        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(:epub), do: ""
end
