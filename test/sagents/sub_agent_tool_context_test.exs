defmodule Sagents.SubAgentToolContextTest do
  @moduledoc """
  Tests verifying that tool_context and state.metadata propagate from parent Agent
  to SubAgents, preserving the structural distinction between the two context channels.

  - tool_context: static, caller-supplied data merged flat into custom_context
    (accessed as `context.project_id`). Propagated via `:parent_tool_context` option.
  - state.metadata: dynamic, middleware-managed data nested in State
    (accessed as `context.state.metadata["key"]`). Propagated via `:parent_metadata` option.
  """

  use ExUnit.Case
  use Mimic

  alias Sagents.{Agent, SubAgent, State}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Function

  defp test_model do
    ChatAnthropic.new!(%{
      model: "claude-sonnet-4-6",
      api_key: "test_key"
    })
  end

  # Helper: create a bare agent with no default middleware
  defp bare_agent(opts \\ []) do
    tools = Keyword.get(opts, :tools, [])

    Agent.new!(%{
      model: test_model(),
      system_prompt: "Test",
      tools: tools,
      replace_default_middleware: true,
      middleware: []
    })
  end

  describe "tool_context propagation via new_from_config" do
    test "SubAgent custom_context includes parent_tool_context keys" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-1",
          instructions: "Do work",
          agent_config: agent,
          parent_tool_context: %{project_id: 123, tenant: "acme"}
        )

      ctx = subagent.chain.custom_context

      assert ctx.project_id == 123
      assert ctx.tenant == "acme"
      # Internal keys still present
      assert %State{} = ctx.state
      assert is_list(ctx.parent_middleware)
    end

    test "SubAgent context.agent_id is the parent_agent_id (subscribers live there)" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-with-subscribers",
          instructions: "Do work",
          agent_config: agent
        )

      ctx = subagent.chain.custom_context

      # context.agent_id routes tool-published events to the entity that
      # actually has subscribers — the parent. SubAgents run as Tasks and
      # have no subscribers of their own.
      assert ctx.agent_id == "parent-with-subscribers"
      # The sub-agent's own runtime id remains accessible via state.
      assert is_binary(ctx.state.agent_id)
      refute ctx.state.agent_id == "parent-with-subscribers"
    end

    test "internal keys take precedence over parent_tool_context on collision" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-2",
          instructions: "Do work",
          agent_config: agent,
          parent_tool_context: %{
            state: "should_be_overridden",
            parent_middleware: "should_be_overridden",
            project_id: 456
          }
        )

      ctx = subagent.chain.custom_context

      # Internal :state must be the State struct, not the caller's string
      assert %State{} = ctx.state
      # Internal :parent_middleware must be a list, not the string
      assert is_list(ctx.parent_middleware)
      # Non-colliding key survives
      assert ctx.project_id == 456
    end

    test "defaults to empty tool_context when parent_tool_context not provided" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-3",
          instructions: "Do work",
          agent_config: agent
        )

      ctx = subagent.chain.custom_context

      assert %State{} = ctx.state
      assert is_list(ctx.parent_middleware)
      # Only internal keys present (including :tool_context which holds the
      # empty map, :scope which defaults to nil when no scope is supplied,
      # and :agent_id which routes back to the parent AgentServer because
      # SubAgents have no subscribers of their own).
      assert Map.keys(ctx) |> Enum.sort() ==
               [:agent_id, :parent_middleware, :scope, :state, :tool_context]

      assert ctx.tool_context == %{}
      assert ctx.scope == nil
      # context.agent_id is the parent's id (the entity with subscribers),
      # not the sub-agent's own runtime id. Tools that need the sub-agent's
      # id can still read it from ctx.state.agent_id.
      assert ctx.agent_id == "parent-3"
      refute ctx.agent_id == ctx.state.agent_id
    end
  end

  describe "tool_context propagation via new_from_compiled" do
    test "compiled SubAgent custom_context includes parent_tool_context keys" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_compiled(
          parent_agent_id: "parent-4",
          instructions: "Extract data",
          compiled_agent: agent,
          initial_messages: [],
          parent_tool_context: %{project_id: 789, env: :staging}
        )

      ctx = subagent.chain.custom_context

      assert ctx.project_id == 789
      assert ctx.env == :staging
      assert %State{} = ctx.state
    end
  end

  describe "state.metadata propagation" do
    test "new_from_config inherits parent_metadata into SubAgent state" do
      agent = bare_agent()

      parent_metadata = %{
        "conversation_title" => "Research Chat",
        "debug_log.msg_count" => 5
      }

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-5",
          instructions: "Do work",
          agent_config: agent,
          parent_metadata: parent_metadata
        )

      # Metadata is nested in state, not flat in custom_context
      ctx = subagent.chain.custom_context

      assert ctx.state.metadata["conversation_title"] == "Research Chat"
      assert ctx.state.metadata["debug_log.msg_count"] == 5
      # Metadata is NOT flat in custom_context
      refute Map.has_key?(ctx, "conversation_title")
    end

    test "new_from_compiled inherits parent_metadata into SubAgent state" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_compiled(
          parent_agent_id: "parent-6",
          instructions: "Extract",
          compiled_agent: agent,
          initial_messages: [],
          parent_metadata: %{"session_id" => "abc-123"}
        )

      assert subagent.chain.custom_context.state.metadata["session_id"] == "abc-123"
    end

    test "parent_metadata defaults to empty map when absent" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-7",
          instructions: "Do work",
          agent_config: agent
        )

      assert subagent.chain.custom_context.state.metadata == %{}
    end

    test "SubAgent gets its own agent_id despite inheriting metadata" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-8",
          instructions: "Do work",
          agent_config: agent,
          parent_metadata: %{"key" => "value"}
        )

      assert String.starts_with?(subagent.chain.custom_context.state.agent_id, "parent-8-sub-")
      assert subagent.chain.custom_context.state.metadata["key"] == "value"
    end
  end

  describe "both tool_context and metadata propagate together" do
    test "tool function receives both flat tool_context and nested metadata" do
      test_pid = self()

      combined_tool =
        Function.new!(%{
          name: "check_both",
          description: "Checks both context channels",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, context ->
            send(test_pid, {:context, context})
            {:ok, "ok"}
          end
        })

      agent = bare_agent(tools: [combined_tool])

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-9",
          instructions: "Check both",
          agent_config: agent,
          parent_tool_context: %{user_id: 42, tenant: "acme"},
          parent_metadata: %{"conversation_title" => "Test Chat"}
        )

      ctx = subagent.chain.custom_context
      tool = Enum.find(subagent.chain.tools, &(&1.name == "check_both"))

      # Simulate LLMChain tool execution
      assert {:ok, "ok"} = tool.function.(%{}, ctx)

      assert_received {:context, received_ctx}

      # Flat tool_context keys
      assert received_ctx.user_id == 42
      assert received_ctx.tenant == "acme"

      # Nested metadata
      assert received_ctx.state.metadata["conversation_title"] == "Test Chat"

      # Internal keys
      assert %State{} = received_ctx.state
      assert is_list(received_ctx.parent_middleware)
    end

    test "tool accessing context.project_id works in SubAgent (regression)" do
      # This is the exact scenario from the bug report
      context_reader_tool =
        Function.new!(%{
          name: "read_project",
          description: "Reads project_id from context",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, context ->
            {:ok, "Project: #{context.project_id}"}
          end
        })

      agent = bare_agent(tools: [context_reader_tool])

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-10",
          instructions: "Read the project",
          agent_config: agent,
          parent_tool_context: %{project_id: 42}
        )

      ctx = subagent.chain.custom_context
      tool = Enum.find(subagent.chain.tools, &(&1.name == "read_project"))

      assert {:ok, "Project: 42"} = tool.function.(%{}, ctx)
    end
  end

  describe "tool_context stored as explicit key for clean extraction" do
    test "custom_context contains :tool_context key with the original map" do
      agent = bare_agent()

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-11",
          instructions: "Work",
          agent_config: agent,
          parent_tool_context: %{user_id: 42, tenant: "acme"}
        )

      ctx = subagent.chain.custom_context

      # The :tool_context key holds the parent_tool_context map
      assert is_map(ctx.tool_context)
      assert ctx.tool_context == %{user_id: 42, tenant: "acme"}

      # The same keys are also flat in custom_context for tool access
      assert ctx.user_id == 42
      assert ctx.tenant == "acme"
    end

    test "nested SubAgent can propagate tool_context from parent SubAgent" do
      # Simulate: main agent -> SubAgent -> nested SubAgent
      # The nested SubAgent should still receive the original tool_context.
      agent = bare_agent()

      # First SubAgent (created by middleware with parent_tool_context)
      first_subagent =
        SubAgent.new_from_config(
          parent_agent_id: "main",
          instructions: "First task",
          agent_config: agent,
          parent_tool_context: %{user_id: 42, tenant: "acme"},
          parent_metadata: %{"title" => "Chat"}
        )

      first_ctx = first_subagent.chain.custom_context

      # Simulate what the middleware would do for a nested SubAgent:
      # extract tool_context from the first SubAgent's custom_context
      extracted_tool_context = Map.get(first_ctx, :tool_context, %{})
      extracted_metadata = first_ctx.state.metadata

      # Second SubAgent (nested, using extracted context)
      nested_subagent =
        SubAgent.new_from_config(
          parent_agent_id: first_subagent.id,
          instructions: "Nested task",
          agent_config: agent,
          parent_tool_context: extracted_tool_context,
          parent_metadata: extracted_metadata
        )

      nested_ctx = nested_subagent.chain.custom_context

      # tool_context propagated through two levels
      assert nested_ctx.user_id == 42
      assert nested_ctx.tenant == "acme"
      assert nested_ctx.tool_context == %{user_id: 42, tenant: "acme"}

      # metadata propagated through two levels
      assert nested_ctx.state.metadata["title"] == "Chat"

      # Each SubAgent has its own unique ID
      assert String.starts_with?(nested_ctx.state.agent_id, first_subagent.id <> "-sub-")
    end

    test "middleware extraction simulated end-to-end" do
      # Simulate the full flow: Agent.build_chain produces context,
      # middleware extracts :tool_context key, passes to SubAgent creation.
      parent_state =
        State.new!(%{
          agent_id: "parent-agent",
          metadata: %{"conversation_title" => "Chat"}
        })

      # This is what Agent.build_chain produces (with :tool_context key)
      runtime_context = %{
        state: parent_state,
        parent_middleware: [%{module: :some_middleware}],
        parent_tools: [%{name: "tool1"}],
        mode_state: %{run_count: 1},
        tool_context: %{user_id: 42, tenant: "acme"},
        # These flat keys also exist (merged by Agent.build_chain)
        user_id: 42,
        tenant: "acme"
      }

      # Middleware extracts cleanly via the :tool_context key
      parent_tool_context = Map.get(runtime_context, :tool_context, %{})
      parent_metadata = runtime_context.state.metadata

      agent = bare_agent()

      subagent =
        SubAgent.new_from_config(
          parent_agent_id: "parent-12",
          instructions: "Work",
          agent_config: agent,
          parent_tool_context: parent_tool_context,
          parent_metadata: parent_metadata
        )

      ctx = subagent.chain.custom_context

      # tool_context keys present (flat for tool access)
      assert ctx.user_id == 42
      assert ctx.tenant == "acme"

      # :tool_context key present (for further SubAgent extraction)
      assert ctx.tool_context == %{user_id: 42, tenant: "acme"}

      # metadata propagated
      assert ctx.state.metadata["conversation_title"] == "Chat"

      # SubAgent has its own state
      assert String.starts_with?(ctx.state.agent_id, "parent-12-sub-")
    end
  end
end
