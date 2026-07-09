defmodule Sagents.AgentServerDisplayTransformTest do
  @moduledoc """
  Tests for the `transform_display_message/2` middleware hook.

  As each message is about to become a display message, middleware can shape it
  (annotate metadata for the UI, or rewrite content) before it is persisted and
  broadcast. The message in agent state — what the LLM sees next turn — is left
  untouched. Persistence stays eager (per message), so the tool-execution
  lifecycle is unaffected.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.Agent
  alias Sagents.AgentServer
  alias Sagents.AgentSupervisor
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias Sagents.TestingHelpers

  # Use case: annotate metadata based on the message so the
  # UI can render it accordingly. Content is unchanged.
  defmodule MetadataAnnotateMiddleware do
    @behaviour Sagents.Middleware

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def transform_display_message(%Message{role: :assistant} = message, _config) do
      annotated = Map.put(message.metadata || %{}, :ui_component, "special_card")
      {:ok, %{message | metadata: annotated}}
    end

    def transform_display_message(message, _config), do: {:ok, message}
  end

  # Content rewrite variant: shape the display content (e.g. model emits a tag we
  # turn into something renderable). Canonical state content is left untouched.
  defmodule ContentRewriteMiddleware do
    @behaviour Sagents.Middleware

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def transform_display_message(%Message{role: :assistant} = message, _config) do
      original = ContentPart.parts_to_string(message.content)
      {:ok, %{message | content: [ContentPart.text!("DISPLAY[" <> original <> "]")]}}
    end

    def transform_display_message(message, _config), do: {:ok, message}
  end

  setup :set_mimic_global

  setup do
    stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
      {:ok, [Message.new_assistant!("original content")]}
    end)

    :ok
  end

  defp start_agent(agent_id, middleware) do
    model = ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"})

    agent =
      Agent.new!(%{
        agent_id: agent_id,
        model: model,
        base_system_prompt: "Test agent",
        replace_default_middleware: true,
        middleware: middleware
      })

    supervisor_config = [
      name: AgentSupervisor.get_name(agent_id),
      agent: agent,
      pubsub: {Phoenix.PubSub, :test_pubsub},
      conversation_id: "conv-#{agent_id}",
      display_message_persistence: Sagents.TestDisplayMessagePersistenceForwarding
    ]

    {:ok, _sup} = AgentSupervisor.start_link_sync(supervisor_config)
    AgentServer.subscribe(agent_id)
    agent_id
  end

  test "middleware can annotate display-message metadata without touching agent state" do
    Sagents.TestDisplayMessagePersistenceForwarding.register_test_process(self())
    agent_id = start_agent(TestingHelpers.generate_test_agent_id(), [MetadataAnnotateMiddleware])

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

    # User message passes through the transform unchanged (middleware only
    # annotates assistant messages).
    assert_receive {:saved_message, %Message{role: :user} = user_saved, _}, 500
    refute user_saved.metadata[:ui_component]

    # The persisted assistant display message carries the annotated metadata.
    assert_receive {:saved_message, %Message{role: :assistant} = saved, _}, 500
    assert saved.metadata[:ui_component] == "special_card"

    # But the canonical message in agent state (what the LLM sees) is untouched.
    state = AgentServer.get_state(agent_id)
    last = List.last(state.messages)
    assert last.role == :assistant
    assert last.metadata[:ui_component] == nil

    AgentServer.stop(agent_id)
  end

  test "middleware can rewrite display content without touching agent state" do
    Sagents.TestDisplayMessagePersistenceForwarding.register_test_process(self())
    agent_id = start_agent(TestingHelpers.generate_test_agent_id(), [ContentRewriteMiddleware])

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

    assert_receive {:saved_message, %Message{role: :user}, _}, 500

    # The persisted display message is the transformed representation.
    assert_receive {:saved_message, %Message{role: :assistant} = saved, _}, 500
    assert ContentPart.parts_to_string(saved.content) == "DISPLAY[original content]"

    # The canonical state message is the original.
    state = AgentServer.get_state(agent_id)
    last = state.messages |> List.last() |> Map.get(:content) |> ContentPart.parts_to_string()
    assert last == "original content"

    AgentServer.stop(agent_id)
  end

  test "no transform middleware leaves the message unchanged" do
    Sagents.TestDisplayMessagePersistenceForwarding.register_test_process(self())
    agent_id = start_agent(TestingHelpers.generate_test_agent_id(), [])

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

    assert_receive {:saved_message, %Message{role: :user}, _}, 500

    assert_receive {:saved_message, %Message{role: :assistant} = saved, _}, 500
    assert ContentPart.parts_to_string(saved.content) == "original content"
    refute saved.metadata[:ui_component]

    AgentServer.stop(agent_id)
  end
end
