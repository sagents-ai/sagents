defmodule Sagents.ExtractTest do
  use Sagents.BaseCase, async: true
  use Mimic

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias Sagents.Agent
  alias Sagents.Extract
  alias Sagents.State

  @schema %{
    type: "object",
    properties: %{
      "title" => %{type: "string"},
      "summary" => %{type: "string"}
    },
    required: ["title", "summary"]
  }

  defp build_agent(tools \\ []) do
    Agent.new!(
      %{
        model: mock_model(),
        tools: tools,
        middleware: []
      },
      replace_default_middleware: true
    )
  end

  defp build_state(text \\ "summarize this") do
    State.new!(%{messages: [Message.new_user!(text)]})
  end

  defp stub_submit_call(name, args) do
    ChatAnthropic
    |> expect(:call, fn _model, _messages, _tools ->
      call = ToolCall.new!(%{call_id: "c1", name: name, arguments: args})
      {:ok, [Message.new_assistant!(%{tool_calls: [call]})]}
    end)
  end

  describe "run/3 — happy path" do
    test "returns LLM-supplied arguments when submit tool is called" do
      agent = build_agent()
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      assert {:ok, %{"title" => "T", "summary" => "S"}} =
               Extract.run(agent, build_state(), schema: @schema)
    end

    test "honors custom :tool_name" do
      agent = build_agent()
      stub_submit_call("my_submit", %{"title" => "x", "summary" => "y"})

      assert {:ok, %{"title" => "x"}} =
               Extract.run(agent, build_state(), schema: @schema, tool_name: "my_submit")
    end

    test "accepts a pre-built tool via :tool" do
      tool =
        LangChain.Function.new!(%{
          name: "custom_tool",
          description: "Custom submit",
          parameters_schema: @schema,
          function: fn args, _ctx -> {:ok, Jason.encode!(args), args} end
        })

      agent = build_agent()
      stub_submit_call("custom_tool", %{"title" => "a", "summary" => "b"})

      assert {:ok, %{"title" => "a"}} = Extract.run(agent, build_state(), tool: tool)
    end

    test "carries the caller's full message history" do
      agent = build_agent()
      stub_submit_call("submit_result", %{"title" => "a", "summary" => "b"})

      state =
        State.new!(%{
          messages: [
            Message.new_system!("be terse"),
            Message.new_user!("summarize this")
          ]
        })

      assert {:ok, %{"title" => "a"}} = Extract.run(agent, state, schema: @schema)
    end
  end

  describe "run/3 — error paths" do
    test "errors when neither :schema nor :tool is supplied" do
      agent = build_agent()

      assert {:error, %LangChainError{type: "extract_invalid_opts"}} =
               Extract.run(agent, build_state(), [])
    end

    test "errors when :tool is not a Function struct" do
      agent = build_agent()

      assert {:error, %LangChainError{type: "extract_invalid_opts"}} =
               Extract.run(agent, build_state(), tool: "not a function")
    end

    test "errors when the agent already has a tool with the same name" do
      existing =
        LangChain.Function.new!(%{
          name: "submit_result",
          description: "preexisting",
          function: fn _args, _ctx -> {:ok, "ok"} end
        })

      agent = build_agent([existing])

      assert {:error, %LangChainError{type: "extract_tool_conflict"}} =
               Extract.run(agent, build_state(), schema: @schema)
    end

    test "errors when LLM never calls the submit tool within max_runs" do
      agent = build_agent()

      ChatAnthropic
      |> stub(:call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("I refuse")]}
      end)

      assert {:error, %LangChainError{type: "until_tool_not_called"}} =
               Extract.run(agent, build_state(), schema: @schema, max_runs: 2)
    end
  end

  describe "run/3 — non-mutation" do
    test "does not modify the caller's agent.tools" do
      agent = build_agent()
      original_tool_names = Enum.map(agent.tools, & &1.name)

      stub_submit_call("submit_result", %{"title" => "a", "summary" => "b"})

      {:ok, _result} = Extract.run(agent, build_state(), schema: @schema)

      assert Enum.map(agent.tools, & &1.name) == original_tool_names
    end
  end
end
