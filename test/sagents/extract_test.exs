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

      agent = build_agent()
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      assert {:ok, %{id: 42, title: "T"}} = Extract.run(agent, build_state(), tool: tool)
    end

    test "falls back to LLM args when the tool returns a 2-tuple (no processed_content)" do
      tool =
        LangChain.Function.new!(%{
          name: "submit_result",
          description: "Submit",
          parameters_schema: @schema,
          function: fn args, _ctx -> {:ok, Jason.encode!(args)} end
        })

      agent = build_agent()
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      assert {:ok, %{"title" => "T", "summary" => "S"}} =
               Extract.run(agent, build_state(), tool: tool)
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

  describe "run/3 — callbacks" do
    defp build_agent_with_recorder do
      Agent.new!(
        %{
          model: mock_model(),
          tools: [],
          middleware: [{CallbackRecordingMiddleware, [pid: self()]}]
        },
        replace_default_middleware: true
      )
    end

    test "fires the agent's middleware callbacks even when none are supplied" do
      agent = build_agent_with_recorder()
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      assert {:ok, %{"title" => "T"}} = Extract.run(agent, build_state(), schema: @schema)
      assert_received :mw_callback_fired
    end

    test "merges supplied :callbacks with the agent's middleware callbacks" do
      agent = build_agent_with_recorder()
      stub_submit_call("submit_result", %{"title" => "T", "summary" => "S"})

      test_pid = self()

      supplied = %{
        on_message_processed: fn _chain, _message -> send(test_pid, :supplied_fired) end
      }

      assert {:ok, %{"title" => "T"}} =
               Extract.run(agent, build_state(), schema: @schema, callbacks: [supplied])

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
      agent = build_agent()

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
               Extract.run(agent, build_state(), tool: validating_tool())
    end

    test "returns an error rather than malformed args when validation never passes" do
      agent = build_agent()

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
               Extract.run(agent, build_state(), tool: validating_tool(), max_runs: 2)
    end
  end
end
