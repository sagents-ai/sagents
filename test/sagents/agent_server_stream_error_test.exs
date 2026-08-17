defmodule Sagents.AgentServerStreamErrorTest do
  @moduledoc """
  What a reader sees when the stream dies mid-response.

  The partial text the model produced reaches the transcript, marked as having
  stopped early, and takes the place of a fabricated error row. Errors that
  produced no partial still get the row.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.Agent
  alias Sagents.AgentServer
  alias Sagents.AgentSupervisor
  alias Sagents.TestDisplayMessagePersistenceForwarding
  alias Sagents.TestingHelpers
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.LangChainError
  alias LangChain.Message

  # Reproduces LLMChain.cancel_delta/3: the partial is appended with
  # add_message/2, which fires no callbacks, and the run still reports success.
  defmodule DeadStreamMode do
    @behaviour LangChain.Chains.LLMChain.Mode

    @impl true
    def run(chain, _opts) do
      {:ok, LangChain.Chains.LLMChain.add_message(chain, partial())}
    end

    def partial do
      %LangChain.Message{
        role: :assistant,
        content: "Partial answ",
        status: :stream_error,
        metadata: %{
          streaming_error: LangChain.LangChainError.exception(type: "overloaded", message: "busy")
        }
      }
    end
  end

  setup :set_mimic_global

  setup do
    TestDisplayMessagePersistenceForwarding.register_test_process(self())
    :ok
  end

  defp start_agent(mode) do
    agent_id = TestingHelpers.generate_test_agent_id()
    model = ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"})

    agent =
      Agent.new!(%{
        agent_id: agent_id,
        model: model,
        base_system_prompt: "Test agent",
        replace_default_middleware: true,
        middleware: [],
        mode: mode
      })

    {:ok, _sup} =
      AgentSupervisor.start_link_sync(
        name: AgentSupervisor.get_name(agent_id),
        agent: agent,
        pubsub: {Phoenix.PubSub, :test_pubsub},
        conversation_id: "conv-#{agent_id}",
        display_message_persistence: TestDisplayMessagePersistenceForwarding
      )

    # The supervisor is linked to the test process, so it goes down with it.
    AgentServer.subscribe(agent_id)
    agent_id
  end

  test "the partial reaches the transcript marked as having stopped early" do
    agent_id = start_agent(DeadStreamMode)

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

    assert_receive {:saved_message, %Message{role: :user}, _items}, 500

    assert_receive {:saved_message, %Message{role: :assistant, content: "Partial answ"}, items},
                   500

    # The mark rides in the last item's content, so a host reads it from the same
    # JSONB column it already stores.
    assert [%{type: :text, content: content}] = items
    assert content["text"] == "Partial answ"
    assert content["stop_reason"] == "stream_error"
  end

  test "no fabricated error row is written alongside the partial" do
    agent_id = start_agent(DeadStreamMode)

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

    assert_receive {:saved_message, %Message{role: :assistant, content: "Partial answ"}, _}, 500

    # The error row is persisted before the status broadcast, so by the time this
    # arrives any second row would already be in the mailbox.
    assert_receive {:agent, {:status_changed, :error, %LangChainError{type: "overloaded"}}}, 500
    refute_received {:saved_message, %Message{role: :assistant}, _items}
    refute_received {:saved_synthetic_message, _scope, _attrs, _context}
  end

  test "the rolling state carries the partial the chain produced" do
    agent_id = start_agent(DeadStreamMode)

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))
    assert_receive {:agent, {:status_changed, :error, _reason}}, 500

    state = AgentServer.get_state(agent_id)

    assert %Message{content: "Partial answ", status: :stream_error} = List.last(state.messages)
  end

  test "an error that produced no partial still writes the error row" do
    # A request rejected before the stream opened leaves the reader nothing
    # otherwise.
    stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
      {:error, LangChainError.exception(type: "invalid_request_error", message: "bad request")}
    end)

    agent_id = start_agent(nil)

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

    assert_receive {:saved_message, %Message{role: :user}, _}, 500

    assert_receive {:saved_synthetic_message, _scope, attrs, _context}, 500
    assert attrs.content_type == "error"
    assert attrs.content["text"] =~ "Sorry, I encountered an error"
  end
end
