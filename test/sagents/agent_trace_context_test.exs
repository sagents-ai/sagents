defmodule Sagents.AgentTraceContextTest do
  @moduledoc """
  Covers the observability context an Agent forwards into `LLMChain.custom_context`:
  `:otel_attributes`, `:conversation_id`, `:agent_name`, and sub-agent lineage.

  These are the keys LangChain's OpenTelemetry layer reads to populate span
  attributes, so what matters is that they arrive in `custom_context` with the right
  values. The span-level behaviour is covered upstream in LangChain.
  """

  use ExUnit.Case, async: true

  alias Sagents.{Agent, State, SubAgent}
  alias Sagents.Persistence.StateSerializer
  alias LangChain.ChatModels.ChatAnthropic

  defp test_model do
    ChatAnthropic.new!(%{model: "claude-sonnet-4-6", api_key: "test_key"})
  end

  defp bare_agent(attrs \\ %{}) do
    Agent.new!(
      Map.merge(
        %{
          model: test_model(),
          system_prompt: "Test",
          replace_default_middleware: true,
          middleware: []
        },
        attrs
      )
    )
  end

  defp chain_context(agent, state) do
    {:ok, chain} = Agent.build_chain(agent, [], state, [])
    chain.custom_context
  end

  describe "otel_attributes" do
    test "defaults to an empty map" do
      assert bare_agent().otel_attributes == %{}
    end

    test "is forwarded into custom_context under the key LangChain reserves" do
      agent = bare_agent(%{otel_attributes: %{"user.id" => "u-1", "organization.id" => "org-2"}})

      ctx = chain_context(agent, State.new!())

      assert ctx.otel_attributes == %{"user.id" => "u-1", "organization.id" => "org-2"}
    end

    test "put_otel_attributes/2 merges, with new values winning" do
      agent =
        bare_agent(%{otel_attributes: %{"user.id" => "u-1", "myapp.stage" => "init"}})
        |> Agent.put_otel_attributes(%{"myapp.stage" => "ready", "myapp.workspace" => "ws-9"})

      assert agent.otel_attributes == %{
               "user.id" => "u-1",
               "myapp.stage" => "ready",
               "myapp.workspace" => "ws-9"
             }
    end

    test "put_otel_attributes/2 works on an agent that had none" do
      agent = bare_agent() |> Agent.put_otel_attributes(%{"a" => "b"})

      assert agent.otel_attributes == %{"a" => "b"}
    end

    test "an agent without attributes still supplies an empty map, never nil" do
      # LangChain's passthrough only matches on a map, so a nil here would be
      # harmless but would also silently mean "no attributes" for a caller who
      # thought they had set some. Keeping it a map makes merges predictable.
      assert chain_context(bare_agent(), State.new!()).otel_attributes == %{}
    end
  end

  describe "conversation_id" do
    test "reaches custom_context from the state" do
      ctx = chain_context(bare_agent(), State.new!(%{conversation_id: "conv-1"}))

      assert ctx.conversation_id == "conv-1"
    end

    test "accepts a non-string id, which is what most stores actually use" do
      ctx = chain_context(bare_agent(), State.new!(%{conversation_id: 4211}))

      assert ctx.conversation_id == 4211
    end

    test "is nil when the agent runs outside a conversation" do
      assert chain_context(bare_agent(), State.new!()).conversation_id == nil
    end

    # Virtual on purpose: AgentServer re-supplies it per execute, so a persisted copy
    # could only ever disagree with the server that restored it.
    test "is not persisted" do
      state = State.new!(%{conversation_id: "conv-1"})

      serialized = StateSerializer.serialize_state(state)
      {:ok, restored} = StateSerializer.deserialize_state("agent-1", serialized)

      refute Map.has_key?(serialized, "conversation_id")
      assert restored.conversation_id == nil
    end
  end

  describe "agent identity" do
    test "agent_name reaches custom_context" do
      agent = bare_agent(%{name: "support_agent"})

      assert chain_context(agent, State.new!()).agent_name == "support_agent"
    end

    test "agent_id reaches custom_context from the state" do
      state = State.new!(%{agent_id: "agent-7"})

      assert chain_context(bare_agent(), state).agent_id == "agent-7"
    end
  end

  describe "sub-agent lineage" do
    test "carries its own id, its parent's id, and its name" do
      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Do work",
          agent_config: bare_agent(%{name: "researcher"})
        )

      ctx = subagent.chain.custom_context

      assert ctx.parent_agent_id == "parent-1"
      assert ctx.sub_agent_id == subagent.id
      assert ctx.agent_name == "researcher"
      # Unchanged: tools publish events back through the parent's AgentServer, so
      # :agent_id must keep pointing at the parent.
      assert ctx.agent_id == "parent-1"
    end

    test "inherits the parent's otel_attributes and conversation_id" do
      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Do work",
          agent_config: bare_agent(),
          parent_trace: %{
            otel_attributes: %{"organization.id" => "org-2"},
            conversation_id: "conv-3"
          }
        )

      ctx = subagent.chain.custom_context

      assert ctx.otel_attributes["organization.id"] == "org-2"
      assert ctx.conversation_id == "conv-3"
    end

    test "the sub-agent's own attributes win over the parent's on collision" do
      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Do work",
          agent_config:
            bare_agent(%{otel_attributes: %{"myapp.role" => "sub", "myapp.own" => "yes"}}),
          parent_trace: %{
            otel_attributes: %{"myapp.role" => "parent", "organization.id" => "org-2"}
          }
        )

      attrs = subagent.chain.custom_context.otel_attributes

      assert attrs["myapp.role"] == "sub"
      assert attrs["myapp.own"] == "yes"
      assert attrs["organization.id"] == "org-2"
    end

    # LangChain maps only a fixed set of custom_context keys onto spans, so lineage
    # has to travel in :otel_attributes to be visible in a trace at all.
    test "puts lineage in otel_attributes so it reaches the spans" do
      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Do work",
          agent_config: bare_agent()
        )

      attrs = subagent.chain.custom_context.otel_attributes

      assert attrs["sagents.parent_agent_id"] == "parent-1"
      assert attrs["gen_ai.agent.id"] == subagent.id
    end

    # custom_context[:agent_id] points at the parent so tools can publish events back
    # through its AgentServer. Left alone, that would make every sub-agent's spans
    # claim to be the parent.
    test "gen_ai.agent.id reports the sub-agent, not the parent whose id routes events" do
      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Do work",
          agent_config: bare_agent()
        )

      ctx = subagent.chain.custom_context

      assert ctx.agent_id == "parent-1"
      assert ctx.otel_attributes["gen_ai.agent.id"] == subagent.id
    end

    test "an application cannot misreport a sub-agent's own identity" do
      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Do work",
          agent_config: bare_agent(%{otel_attributes: %{"gen_ai.agent.id" => "spoofed"}})
        )

      assert subagent.chain.custom_context.otel_attributes["gen_ai.agent.id"] == subagent.id
    end

    test "carries lineage even when no parent trace is supplied" do
      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Do work",
          agent_config: bare_agent()
        )

      assert subagent.chain.custom_context.conversation_id == nil

      assert subagent.chain.custom_context.otel_attributes == %{
               "gen_ai.agent.id" => subagent.id,
               "sagents.parent_agent_id" => "parent-1"
             }
    end
  end
end
