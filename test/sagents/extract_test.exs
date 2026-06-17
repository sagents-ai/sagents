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

  # Middleware that registers an `on_message_processed` LangChain callback.
  # Used to prove Extract self-collects middleware callbacks and merges any
  # caller-supplied `:callbacks` rather than replacing them.
  defmodule CallbackRecordingMiddleware do
    @behaviour Sagents.Middleware

    @impl true
    def init(opts), do: {:ok, %{pid: Keyword.fetch!(opts, :pid)}}

    @impl true
    def system_prompt(_config), do: ""

    @impl true
    def tools(_config), do: []

    @impl true
    def callbacks(config) do
      %{on_message_processed: fn _chain, _message -> send(config.pid, :mw_callback_fired) end}
    end
  end

  @schema %{
    type: "object",
    properties: %{
      "title" => %{type: "string"},
      "summary" => %{type: "string"}
    },
    required: ["title", "summary"]
  }

  # The canonical submit tool: hands the raw LLM args back as processed_content.
  defp submit_tool(name \\ "submit_result") do
    LangChain.Function.new!(%{
      name: name,
      description: "Submit the structured result.",
      parameters_schema: @schema,
      function: fn args, _ctx -> {:ok, Jason.encode!(args), args} end
    })
  end

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
    test "returns LLM-supplied arguments when the agent-owned submit tool is called" do
      agent = build_agent([submit_tool()])
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      assert {:ok, %{"title" => "T", "summary" => "S"}} =
               Extract.run(agent, build_state(), until_tool_success: "submit_result")
    end

    test "stops via :until_tool (parity with :until_tool_success)" do
      agent = build_agent([submit_tool()])
      stub_submit_call("submit_result", %{"title" => "x", "summary" => "y"})

      assert {:ok, %{"title" => "x"}} =
               Extract.run(agent, build_state(), until_tool: "submit_result")
    end

    test "carries the caller's full message history" do
      agent = build_agent([submit_tool()])
      stub_submit_call("submit_result", %{"title" => "a", "summary" => "b"})

      state =
        State.new!(%{
          messages: [
            Message.new_system!("be terse"),
            Message.new_user!("summarize this")
          ]
        })

      assert {:ok, %{"title" => "a"}} =
               Extract.run(agent, state, until_tool_success: "submit_result")
    end
  end

  describe "run/3 — processed_content" do
    test "returns the tool's processed_content, not the raw LLM args" do
      # Tool shapes the raw args into a different structure and hands it back as
      # the 3rd element. run/3 should return that, not the LLM-supplied map.
      tool =
        LangChain.Function.new!(%{
          name: "submit_result",
          description: "Submit",
          parameters_schema: @schema,
          function: fn args, _ctx ->
            {:ok, "saved", %{id: 42, title: args["title"]}}
          end
        })

      agent = build_agent([tool])
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      assert {:ok, %{id: 42, title: "T"}} =
               Extract.run(agent, build_state(), until_tool_success: "submit_result")
    end

    test "falls back to LLM args when the tool returns a 2-tuple (no processed_content)" do
      tool =
        LangChain.Function.new!(%{
          name: "submit_result",
          description: "Submit",
          parameters_schema: @schema,
          function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
        })

      agent = build_agent([tool])
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      assert {:ok, %{"title" => "T", "summary" => "S"}} =
               Extract.run(agent, build_state(), until_tool_success: "submit_result")
    end
  end

  describe "run/3 — error paths" do
    test "errors when neither :until_tool_success nor :until_tool is supplied" do
      agent = build_agent([submit_tool()])

      assert {:error, %LangChainError{type: "extract_invalid_opts"}} =
               Extract.run(agent, build_state(), [])
    end

    test "errors when the named tool is not on the agent" do
      agent = build_agent()

      assert {:error, %LangChainError{type: "extract_tool_not_found"}} =
               Extract.run(agent, build_state(), until_tool_success: "missing")
    end

    test "errors when LLM never calls the submit tool within max_runs" do
      agent = build_agent([submit_tool()])

      ChatAnthropic
      |> stub(:call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("I refuse")]}
      end)

      assert {:error, %LangChainError{type: "until_tool_not_called"}} =
               Extract.run(agent, build_state(), until_tool_success: "submit_result", max_runs: 2)
    end
  end

  describe "run/3 — callbacks" do
    defp build_agent_with_recorder(tools) do
      Agent.new!(
        %{
          model: mock_model(),
          tools: tools,
          middleware: [{CallbackRecordingMiddleware, [pid: self()]}]
        },
        replace_default_middleware: true
      )
    end

    test "fires the agent's middleware callbacks even when none are supplied" do
      agent = build_agent_with_recorder([submit_tool()])
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      assert {:ok, %{"title" => "T"}} =
               Extract.run(agent, build_state(), until_tool_success: "submit_result")

      assert_received :mw_callback_fired
    end

    test "merges supplied :callbacks with the agent's middleware callbacks" do
      agent = build_agent_with_recorder([submit_tool()])
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      test_pid = self()

      supplied = %{
        on_message_processed: fn _chain, _message -> send(test_pid, :supplied_fired) end
      }

      assert {:ok, %{"title" => "T"}} =
               Extract.run(agent, build_state(),
                 until_tool_success: "submit_result",
                 callbacks: [supplied]
               )

      assert_received :supplied_fired
      assert_received :mw_callback_fired
    end
  end

  describe "run/3 — validation and retry" do
    # Submit tool that enforces a business rule the JSON schema can't: only a
    # "good" title is accepted. Anything else returns an error result.
    defp validating_tool do
      LangChain.Function.new!(%{
        name: "submit_result",
        description: "Submit the result",
        parameters_schema: @schema,
        function: fn
          %{"title" => "good"} = args, _ctx -> {:ok, Jason.encode!(args), args}
          _args, _ctx -> {:error, "title must be 'good'"}
        end
      })
    end

    test "retries past a validation error and returns the corrected arguments" do
      agent = build_agent([validating_tool()])

      # First call: rejected by the tool body -> error result -> loop continues.
      ChatAnthropic
      |> expect(:call, fn _model, _messages, _tools ->
        call =
          ToolCall.new!(%{
            call_id: "c1",
            name: "submit_result",
            arguments: %{"title" => "bad", "summary" => "S"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [call]})]}
      end)
      # Second call: corrected args -> success -> run completes.
      |> expect(:call, fn _model, _messages, _tools ->
        call =
          ToolCall.new!(%{
            call_id: "c2",
            name: "submit_result",
            arguments: %{"title" => "good", "summary" => "S"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [call]})]}
      end)

      assert {:ok, %{"title" => "good", "summary" => "S"}} =
               Extract.run(agent, build_state(), until_tool_success: "submit_result")
    end

    test "returns an error rather than malformed args when validation never passes" do
      agent = build_agent([validating_tool()])

      # The model always submits bad args, so the tool always errors.
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        call =
          ToolCall.new!(%{
            call_id: "c#{System.unique_integer([:positive])}",
            name: "submit_result",
            arguments: %{"title" => "bad", "summary" => "S"}
          })

        {:ok, [Message.new_assistant!(%{tool_calls: [call]})]}
      end)

      assert {:error, %LangChainError{}} =
               Extract.run(agent, build_state(), until_tool_success: "submit_result", max_runs: 2)
    end
  end
end
