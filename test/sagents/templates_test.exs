defmodule Sagents.TemplatesTest do
  @moduledoc """
  Coverage for what `mix sagents.setup` generates.

  Generated modules are copies: a dependency bump never touches them, so a
  defect shipped in a template stays in every application that ran the
  generator, and only a migration guide can reach it. These assertions pin the
  properties that are expensive to notice are missing.

  The templates are EEx, so they are not compiled by this suite. These render
  them and assert on the source text.
  """
  use ExUnit.Case, async: true

  @bindings [
    module: MyAppWeb.AgentLiveHelpers,
    conversations_module: MyApp.Conversations,
    conversations_alias: "Conversations",
    coordinator_module: MyApp.Agents.Coordinator,
    coordinator_alias: "Coordinator",
    subscriber_session_module: MyApp.Agents.AgentSubscriberSession,
    subscriber_session_alias: "AgentSubscriberSession",
    app: :my_app,
    app_module: MyApp
  ]

  defp render(name) do
    EEx.eval_file(Path.join([__DIR__, "..", "..", "priv", "templates", name]), @bindings)
  end

  describe "agent_live_helpers.ex.eex" do
    setup do
      %{source: render("agent_live_helpers.ex.eex")}
    end

    test "renders to syntactically valid Elixir", %{source: source} do
      # The template is EEx, so nothing else in this suite would catch an edit
      # that breaks it. The generator's users would.
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    test "guards the conversation-load path on registry availability", %{source: source} do
      # AgentServer.get_status/1 raises Sagents.RegistryUnavailableError on a
      # draining node, past both its own `catch :exit` and this function's
      # `rescue Ecto.NoResultsError`. Without the guard, every generated app
      # crashes its LiveView mount for the length of every deploy.
      guard = index_of(source, "if Sagents.ready?() do")
      status_read = index_of(source, "AgentServer.get_status(agent_id)")

      assert guard, "load_conversation/3 has no Sagents.ready?/0 guard"
      assert status_read, "expected the template to still read the agent status"

      assert guard < status_read,
             "the Sagents.ready?/0 guard must come before the get_status/1 call"
    end

    test "reports a draining node with its own copy, not the generic failure" do
      source = render("agent_live_helpers.ex.eex")

      assert source =~ "@draining_message"
      assert source =~ "def flash_session_error(socket, reason, copy)"
      assert source =~ ":registry_unavailable ->"

      # Without an accessor a host test has to hardcode the copy, and then it
      # passes unchanged through the rewording the template invites.
      assert source =~ "def draining_message, do: @draining_message"
    end

    test "routes every session failure through the one funnel", %{source: source} do
      # A per-call-site clause is how the drain case gets missed on the paths
      # nobody thought about.
      refute source =~ ~r/Logger\.error\("halt dismissal failed/,
             "halt dismissal still formats its own error"

      refute source =~ ~r/Logger\.error\("#\{Keyword\.fetch!\(copy, :log_label\)\}/,
             "the resume funnel still formats its own error"
    end
  end

  defp index_of(source, needle) do
    case :binary.match(source, needle) do
      {start, _length} -> start
      :nomatch -> nil
    end
  end
end
