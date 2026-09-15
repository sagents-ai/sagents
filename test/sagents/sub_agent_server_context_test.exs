defmodule Sagents.SubAgentServerContextTest do
  use Sagents.BaseCase, async: false
  use Mimic

  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span
  alias Sagents.{SubAgent, SubAgentServer}

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  setup :set_mimic_global
  setup :verify_on_exit!

  setup_all do
    Mimic.copy(LLMChain)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    {:ok, _apps} = Application.ensure_all_started(:opentelemetry)

    on_exit(fn ->
      Application.stop(:opentelemetry)
      Application.delete_env(:opentelemetry, :traces_exporter)
    end)

    :ok
  end

  setup do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  test "execute carries the calling task span and full context, then restores the server context" do
    subagent = new_subagent()
    pid = start_supervised!({SubAgentServer, subagent: subagent})
    original = server_context(pid)

    Tracer.with_span "execute_tool task" do
      parent = Tracer.current_span_ctx()
      Ctx.set_value(:request_id, "request-1")

      expect(LLMChain, :run, fn chain, _opts ->
        assert Tracer.current_span_ctx() == parent
        assert Ctx.get_value(:request_id, nil) == "request-1"

        Tracer.with_span "invoke_agent researcher" do
          {:ok, complete(chain)}
        end
      end)

      assert {:ok, "done"} = SubAgentServer.execute(subagent.id)
      assert Tracer.current_span_ctx() == parent
      assert server_context(pid) == original
      assert_child_span("invoke_agent researcher", parent)
    end
  end

  test "an interrupted agent resumes under the new caller and restores context after each call" do
    subagent = new_subagent()
    pid = start_supervised!({SubAgentServer, subagent: subagent})
    original = server_context(pid)

    Tracer.with_span "first task" do
      first = Tracer.current_span_ctx()
      Ctx.set_value(:request_id, "first")

      expect(LLMChain, :run, fn chain, _opts ->
        assert Tracer.current_span_ctx() == first
        {:interrupt, chain, %{action_requests: [], hitl_tool_call_ids: []}}
      end)

      assert {:interrupt, _interrupt} = SubAgentServer.execute(subagent.id)
      assert server_context(pid) == original
    end

    Tracer.with_span "resumed task" do
      resumed = Tracer.current_span_ctx()
      Ctx.set_value(:request_id, "resumed")

      expect(LLMChain, :execute_tool_calls_with_decisions, fn chain, [], [] ->
        assert Tracer.current_span_ctx() == resumed
        assert Ctx.get_value(:request_id, nil) == "resumed"
        chain
      end)

      expect(LLMChain, :run, fn chain, _opts ->
        Tracer.with_span "resumed agent" do
          {:ok, complete(chain)}
        end
      end)

      assert {:ok, "done"} = SubAgentServer.resume(subagent.id, [])
      assert server_context(pid) == original
      assert_child_span("resumed agent", resumed)
    end
  end

  test "an error restores server context before subsequent calls" do
    subagent = new_subagent()
    pid = start_supervised!({SubAgentServer, subagent: subagent})
    original = server_context(pid)

    Tracer.with_span "failing task" do
      parent = Tracer.current_span_ctx()

      expect(LLMChain, :run, fn chain, _opts ->
        assert Tracer.current_span_ctx() == parent
        Ctx.set_value(:temporary, "must not leak")
        {:error, chain, :model_failed}
      end)

      assert {:error, :model_failed} = SubAgentServer.execute(subagent.id)
      assert server_context(pid) == original
    end
  end

  defp new_subagent do
    SubAgent.new_from_config(
      parent_agent_id: generate_test_agent_id(),
      instructions: "Do something",
      agent_config: create_test_agent()
    )
  end

  defp complete(chain) do
    message = Message.new_assistant!(%{content: "done"})
    %{chain | messages: chain.messages ++ [message], last_message: message, needs_response: false}
  end

  defp server_context(pid) do
    caller = self()

    :sys.replace_state(pid, fn state ->
      send(caller, {:server_context, Ctx.get_current()})
      state
    end)

    receive do
      {:server_context, context} -> context
    after
      1000 -> flunk("server did not return its context")
    end
  end

  defp assert_child_span(name, parent) do
    :otel_tracer_provider.force_flush()
    assert_receive {:span, span(name: ^name, parent_span_id: parent_id, trace_id: trace_id)}, 1000
    assert parent_id == Span.span_id(parent)
    assert trace_id == Span.trace_id(parent)
  end
end
