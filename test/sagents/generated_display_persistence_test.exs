defmodule Sagents.GeneratedDisplayPersistenceTest do
  @moduledoc """
  Renders and compiles `priv/templates/display_message_persistence.ex.eex`, then
  exercises the generated `save_message/3`.

  The generated module is what every host actually runs, and it is the layer
  where a display item's position and stop reason become database columns. A
  test against `Sagents.Message.DisplayHelpers` alone cannot see whether the
  generated caller carries them across.
  """
  use Sagents.BaseCase, async: false

  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall

  # Stands in for the generated Conversations context. Every function the
  # template names is defined here so compiling the rendered module is quiet.
  defmodule FakeConversations do
    def append_display_message(_scope, conversation_id, attrs) do
      send(self(), {:appended, attrs})
      {:ok, %{id: System.unique_integer([:positive]), conversation_id: conversation_id}}
    end

    def mark_tool_executing(_scope, _call_id), do: {:ok, nil}
    def complete_tool_call(_scope, _call_id, _metadata), do: {:ok, nil}
    def fail_tool_call(_scope, _call_id, _metadata), do: {:ok, nil}
    def interrupt_tool_call(_scope, _call_id, _metadata), do: {:ok, nil}
    def cancel_tool_call(_scope, _call_id), do: {:ok, nil}
    def resolve_interrupted_tool_result(_scope, _call_id, _content), do: {:ok, nil}
  end

  setup do
    module_name =
      "Sagents.GeneratedDisplayPersistenceTest.Generated#{System.unique_integer([:positive])}"

    rendered =
      :sagents
      |> Application.app_dir("priv/templates/display_message_persistence.ex.eex")
      |> EEx.eval_file(
        module: module_name,
        conversations_module: inspect(FakeConversations)
      )

    [{module, _bytecode}] = Code.compile_string(rendered)

    on_exit(fn -> :code.purge(module) end)

    %{module: module}
  end

  describe "generated save_message/3" do
    test "assigns an ascending sequence across the items of one message", %{module: module} do
      message =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("Let me think"), ContentPart.text!("Searching now")],
          tool_calls: [
            ToolCall.new!(%{call_id: "call_1", name: "search", arguments: %{"q" => "elixir"}})
          ]
        })

      assert {:ok, saved} = module.save_message(:scope, message, %{conversation_id: 7})
      assert length(saved) == 3

      # All three rows are inserted within the same microsecond and share an
      # inserted_at, so sequence is the only thing that orders them.
      assert_receive {:appended, %{"content_type" => "thinking", "sequence" => 0}}
      assert_receive {:appended, %{"content_type" => "text", "sequence" => 1}}
      assert_receive {:appended, %{"content_type" => "tool_call", "sequence" => 2}}
    end

    test "a single-item message still gets sequence 0", %{module: module} do
      message = Message.new_assistant!("Just text")

      assert {:ok, [_row]} = module.save_message(:scope, message, %{conversation_id: 7})
      assert_receive {:appended, %{"content_type" => "text", "sequence" => 0}}
    end

    test "carries stop_reason through to the persisted content of the last item", %{
      module: module
    } do
      message =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("I should start by"), ContentPart.text!("Here is the")],
          status: :length
        })

      assert {:ok, _saved} = module.save_message(:scope, message, %{conversation_id: 7})

      assert_receive {:appended, %{"content_type" => "thinking", "content" => thinking_content}}
      assert_receive {:appended, %{"content_type" => "text", "content" => text_content}}

      refute Map.has_key?(thinking_content, "stop_reason")
      assert text_content["stop_reason"] == "length"
    end

    test "the reported case: a message cut off inside a lone thinking block", %{module: module} do
      message =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("First I need to work out")],
          status: :length
        })

      assert {:ok, [_row]} = module.save_message(:scope, message, %{conversation_id: 7})

      assert_receive {:appended, %{"content_type" => "thinking", "content" => content}}
      assert content["stop_reason"] == "length"
    end

    test "a finished message writes no stop_reason key", %{module: module} do
      message = Message.new_assistant!("All done")

      assert {:ok, [_row]} = module.save_message(:scope, message, %{conversation_id: 7})

      assert_receive {:appended, %{"content" => content}}
      refute Map.has_key?(content, "stop_reason")
    end

    test "carries the provider's stop detail through to persisted content", %{module: module} do
      # A refusal arrives on the success path with empty or partial content, so
      # the detail is the only thing that says why the transcript stops here.
      details = %{
        "type" => "refusal",
        "category" => "cyber",
        "explanation" => "Declined to assist."
      }

      message = %Message{
        role: :assistant,
        content: [ContentPart.text!("I can't help with")],
        status: :content_filtered,
        metadata: %{stop_details: details}
      }

      assert {:ok, [_row]} = module.save_message(:scope, message, %{conversation_id: 7})

      assert_receive {:appended, %{"content" => content}}
      assert content["stop_reason"] == "content_filtered"
      assert content["stop_details"] == details
    end

    test "still lifts tool_call_id into its own column and starts it pending", %{module: module} do
      message =
        Message.new_assistant!(%{
          tool_calls: [
            ToolCall.new!(%{call_id: "call_9", name: "search", arguments: %{"q" => "elixir"}})
          ]
        })

      assert {:ok, [_row]} = module.save_message(:scope, message, %{conversation_id: 7})

      assert_receive {:appended,
                      %{"tool_call_id" => "call_9", "status" => "pending", "sequence" => 0}}
    end
  end
end
