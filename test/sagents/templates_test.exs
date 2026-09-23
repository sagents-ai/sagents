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
    app_module: MyApp,
    # coordinator.ex.eex
    presence_module: MyAppWeb.Presence,
    pubsub_module: MyApp.PubSub,
    factory_module: MyApp.Agents.Factory,
    factory_router_module: MyApp.Agents.FactoryRouter,
    agent_persistence_module: MyApp.Agents.AgentPersistence,
    display_message_persistence_module: MyApp.Agents.DisplayMessagePersistence,
    owner_type: "user",
    owner_field: :user_id,
    # sagents.gen.persistence/*
    context_module: MyApp.Conversations,
    owner_module: MyApp.Accounts.User,
    scope_module: MyApp.Accounts.Scope,
    repo: MyApp.Repo,
    table_prefix: "sagents_"
  ]

  defp render(name) do
    EEx.eval_file(Path.join([__DIR__, "..", "..", "priv", "templates", name]), @bindings)
  end

  # The persistence templates read their bindings as assigns, unlike the
  # top-level ones which take bare variables.
  defp render_persistence(name) do
    EEx.eval_file(
      Path.join([__DIR__, "..", "..", "priv", "templates", "sagents.gen.persistence", name]),
      assigns: @bindings
    )
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

    test "subscribes tagged so a second subscription can be added later", %{source: source} do
      # A socket showing one conversation could take the bare `{:agent, event}`.
      # Naming the source costs it one wildcard per clause and means a host that
      # later opens a second panel adds a subscription rather than reworking
      # every clause it already wrote.
      assert source =~ "Subscriber.subscribe_to_agent(subs, agent_id, tagged: true)"
    end

    test "the emitted handle_info examples match the tagged envelope", %{source: source} do
      # The examples are what a host copies. An untagged example against a
      # tagged subscription is a FunctionClauseError on the first event, or
      # worse, a silent no-op for a host that wrote a catch-all.
      assert source =~ "{:agent, _agent_id, {:status_changed, :running, nil}}"
      refute source =~ "handle_info({:agent, {:status_changed"
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

    test "leaving a conversation gives back the viewer's presence entry", %{source: source} do
      # Presence tracks the host pid, which survives a conversation switch. A
      # switch that only unsubscribes leaves a viewer behind, and a viewer is
      # what stops an idle agent from shutting down, so every conversation
      # opened in a session pins another agent for its full inactivity timeout.
      assert source =~ "defp leave_current_conversation(socket) do"
      assert source =~ "AgentSubscriberSession.remove_tracked_viewer("
      assert source =~ "AgentSubscriberSession.add_tracked_viewer("

      # Both ways out route through a leaving step.
      refute source =~ "defp maybe_unsubscribe_previous(",
             "the switch path still only unsubscribes"

      # And there is no second way to take an entry. Reaching past the session
      # module to the coordinator's presence API is what lets the recorded entry
      # drift from what Presence holds, and it is how the next hand-rolled call
      # site gets added.
      refute source =~ "Coordinator.track_conversation_viewer"
      refute source =~ "Coordinator.untrack_conversation_viewer"
    end

    test "the switch releases only the conversation being left", %{source: source} do
      # These helpers show one conversation, but a host can view others from the
      # same process. Releasing everything held on a switch would tear down a
      # panel of sibling conversations the switch says nothing about.
      assert source =~ "socket.assigns[:conversation_id]"

      refute source =~ ~r/defp leave_current_conversation.*clear_tracked_viewers/s,
             "the switch path releases every entry this process holds"

      # Resetting is the opposite case: nothing is shown afterwards, and
      # init_agent_state/1 is about to rewrite the record either way.
      assert source =~ "defp leave_all_conversations(socket) do"
      assert source =~ "AgentSubscriberSession.clear_tracked_viewers(socket.assigns)"
    end

    test "offers an entry point for conversations opened without a DB read", %{source: source} do
      # A host that creates a conversation assigns :conversation_id itself and
      # navigates, so a same-id guard on the load path can short-circuit and
      # load_conversation/3 never runs for it. Without a supported entry point
      # those paths hand-roll a track call, and nothing releases it.
      assert source =~ "def enter_conversation(socket, conversation, opts \\\\ []) do"

      # One funnel, not two: the load path enters the same way.
      assert source =~ "defp enter(socket, conversation, conversation_id, user_id) do"
      assert source =~ "socket = enter(socket, conversation, conversation_id, user_id)"
    end

    test "reads the conversation before leaving the one on screen", %{source: source} do
      # A conversation_id that 404s must not take the subscription off the agent
      # still on screen. The {:error, socket} return promises the caller its
      # socket is unchanged.
      read = index_of(source, "conversations.get_conversation!(scope, conversation_id)")
      leave = index_of(source, "socket = enter(socket, conversation, conversation_id, user_id)")

      assert read, "expected the load path to still read the conversation"
      assert leave, "expected the load path to enter through the funnel"

      assert read < leave,
             "the load path leaves the open conversation before knowing the new one exists"
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

  describe "agent_subscriber_session.ex.eex" do
    setup do
      %{source: render("agent_subscriber_session.ex.eex")}
    end

    test "renders to syntactically valid Elixir", %{source: source} do
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    test "the session records the presence entry it holds", %{source: source} do
      # Untracking needs the key that was tracked. Recomputing it from the
      # current user is a guess about the past: the host may have no viewer id
      # by then (a reset) or a different one (a re-auth), and untracking a key
      # that was never tracked answers :ok while leaving the real entry behind.
      assert source =~ "tracked_viewers: %{}"
      assert source =~ "def add_tracked_viewer(state, conversation_id, viewer_id) do"
      assert source =~ "def remove_tracked_viewer(state, conversation_id) do"
      assert source =~ "def clear_tracked_viewers(state) do"

      # Taking an entry with nothing that gives it back is the leak.
      refute source =~ "def maybe_track_viewer("
    end

    test "the recovery helpers take the reporting return shapes", %{source: source} do
      # Both helpers return the single-subscription shape unless asked. Asking
      # here means the generated host is already written for the day it holds
      # several, and it is the shape the multi-panel guidance documents.
      assert source =~ "Subscriber.handle_publisher_down(subs, ref, reason, report: true)"
      assert source =~ "{:matched, _sub_key, new_subs} ->"
      assert source =~ "{new_subs, _revived} ="

      assert source =~
               "Subscriber.handle_presence_diff(subs, Subscriber.presence_topic(), payload, report: true)"
    end

    test "only the subs map goes back into state", %{source: source} do
      # `sagents_subs` is read as a map on every path. Storing the reporting
      # tuple instead is what makes the *next* presence diff fail, one event
      # after the mistake.
      refute source =~ "%{sagents_subs: {"
    end

    test "the session holds a set, not a slot", %{source: source} do
      # One process can view any number of conversations at once: a split view,
      # a dashboard row per running agent, a panel of threads each backed by its
      # own agent. A single-slot record makes the second one impossible to hold.
      refute source =~ "tracked_viewer:", "the presence record is still a single slot"

      # The declarative shape, which is the one that cannot accumulate entries.
      assert source =~ "def sync_tracked_viewers(state, desired) do"
    end
  end

  describe "coordinator.ex.eex" do
    setup do
      %{source: render("coordinator.ex.eex")}
    end

    test "renders to syntactically valid Elixir", %{source: source} do
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    test "every path that subscribes carries the same tag policy", %{source: source} do
      # A publisher keeps one entry per {channel, pid}, so whichever path
      # subscribes last decides the envelope. A load path that tags and an
      # action path that does not gives a conversation whose event shape
      # changes the first time the user does something, with no error anywhere.
      assert source =~ "@subscribe_opts [tagged: true]"

      for call <- [
            "Sagents.Session.ensure_running",
            "Sagents.Session.resume",
            "Sagents.Session.dismiss"
          ] do
        assert source =~ call, "expected the coordinator to still call #{call}"
      end

      # One occurrence per subscribing path.
      assert length(String.split(source, "++ @subscribe_opts")) - 1 == 3
    end

    test "declares the viewer-presence contract it implements", %{source: source} do
      # A host that renames or drops one of these gets a compile warning rather
      # than an UndefinedFunctionError the next time someone switches threads.
      assert source =~ "@behaviour Sagents.ViewerPresence"
      assert source =~ "@impl Sagents.ViewerPresence"
    end
  end

  defp index_of(source, needle) do
    case :binary.match(source, needle) do
      {start, _length} -> start
      :nomatch -> nil
    end
  end

  describe "sagents.gen.persistence templates" do
    # Nothing else in this suite renders these, so an edit that breaks the EEx
    # or the Elixir underneath it would reach a host's generator run first.
    @persistence_templates ~w(
      agent_state.ex.eex
      context.ex.eex
      conversation.ex.eex
      display_message.ex.eex
      migration.exs.eex
    )

    for template <- @persistence_templates do
      test "#{template} renders to syntactically valid Elixir" do
        source = render_persistence(unquote(template))
        assert {:ok, _ast} = Code.string_to_quoted(source)
      end
    end

    test "the display message schema documents every content key the framework writes" do
      # The generated schema is a copy: a host reads these docs to learn what
      # can turn up in `content`, and a key the framework writes but the schema
      # does not mention is a key nobody renders.
      source = render_persistence("display_message.ex.eex")

      for key <- ~w(stop_reason stop_details utterance display_text error_type) do
        assert source =~ ~s(- `"#{key}"`),
               "the schema template does not document the #{inspect(key)} content key"
      end
    end

    test "the schema accepts content carrying keys beyond the per-type ones" do
      # `utterance` and `stop_reason` ride inside `content` alongside `text`.
      # Validation matches on the keys it requires, so it must not be written
      # as an exact match, or the framework's own rows would be rejected.
      source = render_persistence("display_message.ex.eex")

      assert source =~ ~s|defp validate_content("text", %{"text" => _text}), do: :ok|
    end
  end
end
