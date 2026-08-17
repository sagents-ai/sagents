defmodule Sagents.AgentServerFrameworkRowsTest do
  @moduledoc """
  The transcript rows the framework writes itself, rather than relaying from the
  model: the cancellation notice and the error notice.

  A host implementing `save_synthetic_message/3` receives them classified, so it
  can style and translate them. A host generated before that callback existed
  receives the prose message instead, which is the only reason the fallback
  exists.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.Agent
  alias Sagents.AgentServer
  alias Sagents.AgentSupervisor
  alias Sagents.TestDisplayMessagePersistenceForwarding, as: Synthetic
  alias Sagents.TestDisplayMessagePersistenceNoSynthetic, as: NoSynthetic
  alias Sagents.TestingHelpers
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ContentPart

  # Blocks the run so it can be cancelled, and reports the moment it is in flight
  # so the test never has to sleep to find out.
  defmodule BlockingMode do
    @behaviour LangChain.Chains.LLMChain.Mode

    def register_test_process(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)

    @impl true
    def run(_chain, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), :mode_running)

      receive do
        :never -> {:error, :unreachable}
      end
    end
  end

  setup :set_mimic_global

  setup do
    Synthetic.register_test_process(self())
    Synthetic.clear_synthetic_response()
    NoSynthetic.register_test_process(self())
    BlockingMode.register_test_process(self())

    on_exit(fn -> Synthetic.clear_synthetic_response() end)
    :ok
  end

  defp start_agent(persistence, mode) do
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
        display_message_persistence: persistence
      )

    # The supervisor is linked to the test process, so it goes down with it.
    AgentServer.subscribe(agent_id)
    agent_id
  end

  defp cancel_a_running_agent(persistence) do
    agent_id = start_agent(persistence, BlockingMode)

    :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))
    assert_receive :mode_running, 500

    :ok = AgentServer.cancel(agent_id)
    agent_id
  end

  describe "cancellation" do
    test "is classified when the host implements save_synthetic_message/3" do
      cancel_a_running_agent(Synthetic)

      assert_receive {:saved_synthetic_message, _scope, attrs, _context}, 500

      assert attrs.content_type == "notification"
      assert attrs.content["stop_reason"] == "cancelled"

      # The row is not attributed to the model, which never said it.
      assert attrs.message_type == "system"

      # The prose stays as a fallback for a host that renders text before it
      # learns the content type.
      assert attrs.content["text"] == "Agent execution cancelled."
    end

    test "falls back to a message row when the host does not implement it" do
      # A host generated before save_synthetic_message/3 existed would otherwise
      # lose the row entirely.
      cancel_a_running_agent(NoSynthetic)

      assert_receive {:saved_message, %Message{role: :user}, _items}, 500
      assert_receive {:saved_message, %Message{role: :assistant} = row, _items}, 500
      assert ContentPart.parts_to_string(row.content) == "Agent execution cancelled."
    end
  end

  describe "a failed turn" do
    setup do
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:error, LangChainError.exception(type: "invalid_request_error", message: "bad request")}
      end)

      :ok
    end

    test "is classified when the host implements save_synthetic_message/3" do
      agent_id = start_agent(Synthetic, nil)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

      assert_receive {:saved_synthetic_message, _scope, attrs, _context}, 500

      assert attrs.content_type == "error"
      assert attrs.message_type == "system"
      assert attrs.content["error_type"] == "invalid_request_error"
      assert attrs.content["text"] =~ "Sorry, I encountered an error"

      # An error row is not a message that stopped early, so it does not borrow
      # that vocabulary.
      refute Map.has_key?(attrs.content, "stop_reason")
    end

    test "falls back to a message row when the host does not implement it" do
      agent_id = start_agent(NoSynthetic, nil)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

      assert_receive {:saved_message, %Message{role: :user}, _items}, 500
      assert_receive {:saved_message, %Message{role: :assistant} = row, _items}, 500
      assert ContentPart.parts_to_string(row.content) =~ "Sorry, I encountered an error"
    end

    test "carries no error_type when the failure named none" do
      agent_id = start_agent(Synthetic, __MODULE__.UntypedFailureMode)

      :ok = AgentServer.add_message(agent_id, Message.new_user!("Hello"))

      assert_receive {:saved_synthetic_message, _scope, attrs, _context}, 500

      assert attrs.content_type == "error"
      refute Map.has_key?(attrs.content, "error_type")
    end
  end

  defmodule UntypedFailureMode do
    @behaviour LangChain.Chains.LLMChain.Mode

    @impl true
    def run(chain, _opts) do
      {:error, chain, LangChain.LangChainError.exception(message: "something went wrong")}
    end
  end
end
