defmodule Sagents.AgentDeltaOrderingTest do
  @moduledoc """
  Tests for delta ordering in Agent's internal chain state functions.
  """
  use Sagents.BaseCase, async: true

  alias Sagents.{Agent, State}
  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias LangChain.Message.{ToolCall, ToolResult}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_chain_with_tool_results(messages, opts \\ []) do
    initial_state = Keyword.get(opts, :state, State.new!())
    model = mock_model()

    LLMChain.new!(%{llm: model, custom_context: %{state: initial_state}})
    |> LLMChain.add_messages(messages)
  end

  defp assistant_with_tool_calls(call_ids) do
    tool_calls =
      Enum.map(call_ids, fn id ->
        ToolCall.new!(%{call_id: id, name: "tool_#{id}", arguments: %{}, status: :complete})
      end)

    Message.new_assistant!(%{tool_calls: tool_calls})
  end

  defp tool_message_with_state(call_id, tool_name, %State{} = state_delta) do
    result =
      ToolResult.new!(%{
        tool_call_id: call_id,
        name: tool_name,
        content: "ok",
        processed_content: state_delta
      })

    Message.new_tool_result!(%{tool_results: [result]})
  end

  defp tool_message_plain(call_id, tool_name) do
    result =
      ToolResult.new!(%{
        tool_call_id: call_id,
        name: tool_name,
        content: "plain result"
      })

    Message.new_tool_result!(%{tool_results: [result]})
  end

  # ---------------------------------------------------------------------------
  # Group 2: extract_state_deltas_from_chain/1
  # ---------------------------------------------------------------------------

  describe "extract_state_deltas_from_chain/1" do
    test "returns empty list when no tool messages" do
      chain =
        build_chain_with_tool_results([
          Message.new_user!("hello"),
          Message.new_assistant!("hi there")
        ])

      assert Agent.extract_state_deltas_from_chain(chain) == []
    end

    test "extracts single state delta" do
      delta = State.new!(%{metadata: %{key: "value"}})

      chain =
        build_chain_with_tool_results([
          Message.new_user!("do something"),
          assistant_with_tool_calls(["call_1"]),
          tool_message_with_state("call_1", "my_tool", delta)
        ])

      deltas = Agent.extract_state_deltas_from_chain(chain)

      assert length(deltas) == 1
      assert hd(deltas).metadata == %{key: "value"}
    end

    @tag :delta_ordering_bug
    test "returns deltas in chronological order" do
      delta_a = State.new!(%{metadata: %{source: "older"}})
      delta_b = State.new!(%{metadata: %{source: "newer"}})

      # Messages are in chronological order: tool A result comes before tool B result
      chain =
        build_chain_with_tool_results([
          Message.new_user!("do two things"),
          assistant_with_tool_calls(["call_a", "call_b"]),
          tool_message_with_state("call_a", "tool_a", delta_a),
          tool_message_with_state("call_b", "tool_b", delta_b)
        ])

      deltas = Agent.extract_state_deltas_from_chain(chain)

      assert length(deltas) == 2
      # Chronological: older first, newer second
      assert Enum.at(deltas, 0).metadata == %{source: "older"}
      assert Enum.at(deltas, 1).metadata == %{source: "newer"}
    end

    @tag :delta_ordering_bug
    test "three tools, newest metadata wins after reduce" do
      delta_a = State.new!(%{metadata: %{winner: "A"}})
      delta_b = State.new!(%{metadata: %{winner: "B"}})
      delta_c = State.new!(%{metadata: %{winner: "C"}})

      chain =
        build_chain_with_tool_results([
          Message.new_user!("do three things"),
          assistant_with_tool_calls(["call_a", "call_b", "call_c"]),
          tool_message_with_state("call_a", "tool_a", delta_a),
          tool_message_with_state("call_b", "tool_b", delta_b),
          tool_message_with_state("call_c", "tool_c", delta_c)
        ])

      deltas = Agent.extract_state_deltas_from_chain(chain)
      base = State.new!()
      merged = Enum.reduce(deltas, base, &State.merge_states(&2, &1))

      # C is the newest tool result, so its value should win via right-side priority
      assert merged.metadata.winner == "C"
    end

    test "only extracts from messages after last assistant tool_call" do
      # Round 1: assistant calls tool_x
      delta_old = State.new!(%{metadata: %{round: 1}})
      # Round 2: assistant calls tool_y
      delta_new = State.new!(%{metadata: %{round: 2}})

      chain =
        build_chain_with_tool_results([
          Message.new_user!("first request"),
          assistant_with_tool_calls(["call_x"]),
          tool_message_with_state("call_x", "tool_x", delta_old),
          # Second round
          Message.new_user!("second request"),
          assistant_with_tool_calls(["call_y"]),
          tool_message_with_state("call_y", "tool_y", delta_new)
        ])

      deltas = Agent.extract_state_deltas_from_chain(chain)

      # Should only include deltas from the most recent round (after last assistant tool_call)
      assert length(deltas) == 1
      assert hd(deltas).metadata == %{round: 2}
    end

    test "skips non-State processed_content" do
      delta = State.new!(%{metadata: %{real: true}})

      chain =
        build_chain_with_tool_results([
          Message.new_user!("mixed results"),
          assistant_with_tool_calls(["call_1", "call_2"]),
          tool_message_plain("call_1", "plain_tool"),
          tool_message_with_state("call_2", "state_tool", delta)
        ])

      deltas = Agent.extract_state_deltas_from_chain(chain)

      assert length(deltas) == 1
      assert hd(deltas).metadata == %{real: true}
    end
  end

  # ---------------------------------------------------------------------------
  # Group 3: update_chain_state_from_tools/1
  # ---------------------------------------------------------------------------

  describe "update_chain_state_from_tools/1" do
    @tag :delta_ordering_bug
    test "merges multiple deltas in chronological order" do
      initial_state = State.new!(%{metadata: %{initial: true}})
      delta_a = State.new!(%{metadata: %{winner: "oldest"}})
      delta_b = State.new!(%{metadata: %{winner: "newest"}})

      chain =
        build_chain_with_tool_results(
          [
            Message.new_user!("do two things"),
            assistant_with_tool_calls(["call_a", "call_b"]),
            tool_message_with_state("call_a", "tool_a", delta_a),
            tool_message_with_state("call_b", "tool_b", delta_b)
          ],
          state: initial_state
        )

      updated_chain = Agent.update_chain_state_from_tools(chain)
      updated_state = updated_chain.custom_context.state

      # Newest delta (B) should win via right-side priority in merge
      assert updated_state.metadata.winner == "newest"
      # Initial metadata should be preserved
      assert updated_state.metadata.initial == true
    end

    test "returns chain unchanged when no deltas" do
      initial_state = State.new!(%{metadata: %{unchanged: true}})

      chain =
        build_chain_with_tool_results(
          [
            Message.new_user!("just chatting"),
            Message.new_assistant!("hello!")
          ],
          state: initial_state
        )

      updated_chain = Agent.update_chain_state_from_tools(chain)

      assert updated_chain.custom_context.state == initial_state
    end

    test "handles chain with no custom_context state" do
      delta = State.new!(%{metadata: %{created: true}})
      model = mock_model()

      chain =
        LLMChain.new!(%{llm: model, custom_context: %{}})
        |> LLMChain.add_messages([
          Message.new_user!("do something"),
          assistant_with_tool_calls(["call_1"]),
          tool_message_with_state("call_1", "my_tool", delta)
        ])

      updated_chain = Agent.update_chain_state_from_tools(chain)
      updated_state = updated_chain.custom_context.state

      assert updated_state.metadata.created == true
    end
  end
end
