defmodule Sagents.SubagentHitlIntegrationTest do
  @moduledoc """
  End-to-end integration tests for the sub-agent Human-in-the-Loop (HITL)
  feature. These tests exercise the full flow with real AgentServer processes,
  verifying interrupt propagation and resume through the entire stack.

  Flow under test:
    1. AgentServer.execute -> Agent.execute returns {:interrupt, state, interrupt_data}
    2. AgentServer transitions to :interrupted status with subagent_hitl interrupt_data
    3. AgentServer.resume -> Agent.resume detects subagent_hitl, skips process_decisions
    4. Resume injects resume_info into context, task tool receives decisions
    5. Agent.resume returns {:ok, final_state}
    6. AgentServer transitions to :idle

  The tests mock at the Agent.execute/Agent.resume level to test the
  AgentServer lifecycle, while using realistic subagent_hitl interrupt_data
  structures that match what the real SubAgent middleware produces.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, State}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  setup :set_mimic_global
  setup :verify_on_exit!

  @moduletag timeout: 30_000

  setup_all do
    Mimic.copy(Agent)
    :ok
  end

  # Poll for a status change on the AgentServer.
  # Returns {:ok, status} when the expected status is reached,
  # or {:error, :timeout, actual_status} if it takes too long.
  defp wait_for_status(agent_id, expected_status, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 25)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_status(agent_id, expected_status, interval, deadline)
  end

  defp do_wait_for_status(agent_id, expected_status, interval, deadline) do
    current = AgentServer.get_status(agent_id)

    cond do
      current == expected_status ->
        {:ok, current}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout, current}

      true ->
        Process.sleep(interval)
        do_wait_for_status(agent_id, expected_status, interval, deadline)
    end
  end

  # Build a realistic subagent_hitl interrupt_data structure that matches
  # what the SubAgent middleware produces when a sub-agent hits HITL.
  defp build_subagent_interrupt_data(opts \\ []) do
    sub_agent_id = Keyword.get(opts, :sub_agent_id, "sub-agent-1")
    subagent_type = Keyword.get(opts, :subagent_type, "researcher")

    action_requests =
      Keyword.get(opts, :action_requests, [
        %{
          tool_call_id: "sa_call_1",
          tool_name: "ask_user",
          arguments: %{"question" => "Should I proceed with the research?"}
        }
      ])

    review_configs =
      Keyword.get(opts, :review_configs, %{
        "ask_user" => %{allowed_decisions: [:approve, :reject]}
      })

    hitl_tool_call_ids =
      Keyword.get(
        opts,
        :hitl_tool_call_ids,
        Enum.map(action_requests, & &1.tool_call_id)
      )

    %{
      type: :subagent_hitl,
      sub_agent_id: sub_agent_id,
      subagent_type: subagent_type,
      interrupt_data: %{
        action_requests: action_requests,
        review_configs: review_configs,
        hitl_tool_call_ids: hitl_tool_call_ids
      }
    }
  end

  describe "full AgentServer execute -> interrupt -> resume -> completion" do
    test "sub-agent HITL interrupt propagates through AgentServer and resume completes" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      # Build realistic interrupt data
      interrupt_data = build_subagent_interrupt_data()

      # Build an interrupted state that matches what Agent.execute would produce
      tool_call =
        ToolCall.new!(%{
          call_id: "tc_task_1",
          name: "task",
          arguments: %{
            "instructions" => "Research quantum computing",
            "subagent_type" => "researcher"
          }
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Research quantum computing"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data
        })

      # Mock Agent.execute to return interrupt (simulating sub-agent hitting HITL)
      Agent
      |> expect(:execute, fn ^agent, _state, _opts ->
        {:interrupt, interrupted_state, interrupt_data}
      end)

      # Mock Agent.resume to simulate successful resume after human decisions
      Agent
      |> expect(:resume, fn ^agent, state, decisions, _opts ->
        # Verify decisions were passed through
        assert [%{type: :approve}] = decisions

        # Verify the state has subagent_hitl interrupt_data
        assert state.interrupt_data.type == :subagent_hitl

        # Return completed state
        final_state =
          state
          |> State.add_message(Message.new_assistant!(%{content: "The research is complete."}))
          |> Map.put(:interrupt_data, nil)

        {:ok, final_state}
      end)

      # Start AgentServer with initial state
      initial_state =
        State.new!(%{messages: [Message.new_user!("Research quantum computing")]})

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           initial_state: initial_state,
           name: AgentServer.get_name(agent_id),
           pubsub: nil,
           inactivity_timeout: nil}
        )

      # --- Verify initial status ---
      assert AgentServer.get_status(agent_id) == :idle

      # --- Step 1: Execute the agent ---
      assert :ok = AgentServer.execute(agent_id)

      # --- Step 2: Wait for interrupt ---
      assert {:ok, :interrupted} = wait_for_status(agent_id, :interrupted)

      # Verify interrupt data structure
      info = AgentServer.get_info(agent_id)
      assert info.status == :interrupted
      assert info.interrupt_data != nil
      assert info.interrupt_data.type == :subagent_hitl
      assert info.interrupt_data.sub_agent_id == "sub-agent-1"
      assert info.interrupt_data.subagent_type == "researcher"

      # Verify nested interrupt data from the sub-agent
      nested_interrupt = info.interrupt_data.interrupt_data
      assert length(nested_interrupt.action_requests) == 1

      first_request = hd(nested_interrupt.action_requests)
      assert first_request.tool_name == "ask_user"
      assert first_request.arguments["question"] == "Should I proceed with the research?"

      # --- Step 3: Resume with human decisions ---
      decisions = [%{type: :approve}]
      assert :ok = AgentServer.resume(agent_id, decisions)

      # --- Step 4: Wait for completion ---
      assert {:ok, :idle} = wait_for_status(agent_id, :idle)

      # --- Step 5: Verify final state ---
      final_state = AgentServer.get_state(agent_id)

      # Should have messages from the resumed state
      assert length(final_state.messages) >= 3

      # Verify interrupt_data is cleared
      assert final_state.interrupt_data == nil

      # Verify final message is the assistant's response
      last_msg = List.last(final_state.messages)
      assert last_msg.role == :assistant
    end

    test "status transitions follow expected sequence using PubSub events" do
      # Use PubSub events to reliably observe all status transitions,
      # since polling can miss the brief :running state.
      pubsub_name = :"test_pubsub_status_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      agent = create_test_agent()
      agent_id = agent.agent_id

      interrupt_data = build_subagent_interrupt_data(sub_agent_id: "sub-status-1")

      tool_call =
        ToolCall.new!(%{
          call_id: "tc_s1",
          name: "task",
          arguments: %{"instructions" => "work"}
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do it"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data
        })

      Agent
      |> expect(:execute, fn ^agent, _state, _opts ->
        {:interrupt, interrupted_state, interrupt_data}
      end)

      Agent
      |> expect(:resume, fn ^agent, _state, _decisions, _opts ->
        completed_state =
          State.new!(%{
            messages: [
              Message.new_user!("Do it"),
              Message.new_assistant!(%{content: "All done."})
            ]
          })

        {:ok, completed_state}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Do it")]})

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           initial_state: initial_state,
           name: AgentServer.get_name(agent_id),
           pubsub: {Phoenix.PubSub, pubsub_name},
           id: agent_id,
           inactivity_timeout: nil}
        )

      # Subscribe to PubSub events to observe all status transitions
      :ok = AgentServer.subscribe(agent_id)

      # Verify initial status is idle
      assert AgentServer.get_status(agent_id) == :idle

      # Execute the agent
      :ok = AgentServer.execute(agent_id)

      # Transition 1: idle -> running
      assert_receive {:agent, {:status_changed, :running, nil}}, 2_000

      # Transition 2: running -> interrupted (with interrupt data)
      assert_receive {:agent, {:status_changed, :interrupted, ^interrupt_data}}, 5_000

      # Resume
      :ok = AgentServer.resume(agent_id, [%{type: :approve}])

      # Transition 3: interrupted -> running
      assert_receive {:agent, {:status_changed, :running, nil}}, 2_000

      # Transition 4: running -> idle (completion)
      assert_receive {:agent, {:status_changed, :idle, nil}}, 5_000

      # Verify final status
      assert AgentServer.get_status(agent_id) == :idle
    end

    test "PubSub events broadcast correctly through interrupt and resume cycle" do
      # Start a test PubSub
      pubsub_name = :"test_pubsub_hitl_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      agent = create_test_agent()
      agent_id = agent.agent_id

      interrupt_data =
        build_subagent_interrupt_data(
          sub_agent_id: "sub-pubsub-1",
          subagent_type: "analyst"
        )

      tool_call =
        ToolCall.new!(%{
          call_id: "tc_ps1",
          name: "task",
          arguments: %{"instructions" => "analyze"}
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Analyze this"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data
        })

      Agent
      |> expect(:execute, fn ^agent, _state, _opts ->
        {:interrupt, interrupted_state, interrupt_data}
      end)

      Agent
      |> expect(:resume, fn ^agent, _state, _decisions, _opts ->
        completed_state =
          State.new!(%{
            messages: [
              Message.new_user!("Analyze this"),
              Message.new_assistant!(%{content: "Analysis complete."})
            ]
          })

        {:ok, completed_state}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Analyze this")]})

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           initial_state: initial_state,
           name: AgentServer.get_name(agent_id),
           pubsub: {Phoenix.PubSub, pubsub_name},
           id: agent_id,
           inactivity_timeout: nil}
        )

      # Subscribe to events
      :ok = AgentServer.subscribe(agent_id)

      # Execute
      :ok = AgentServer.execute(agent_id)

      # Should receive: running status
      assert_receive {:agent, {:status_changed, :running, nil}}, 2_000

      # Should receive: interrupted status with subagent_hitl interrupt data
      assert_receive {:agent, {:status_changed, :interrupted, received_interrupt}}, 5_000
      assert received_interrupt.type == :subagent_hitl
      assert received_interrupt.sub_agent_id == "sub-pubsub-1"
      assert received_interrupt.subagent_type == "analyst"

      # Verify nested interrupt details
      nested = received_interrupt.interrupt_data
      assert length(nested.action_requests) == 1
      assert hd(nested.action_requests).tool_name == "ask_user"

      # Resume
      :ok = AgentServer.resume(agent_id, [%{type: :approve}])

      # Should receive: running status (for resume)
      assert_receive {:agent, {:status_changed, :running, nil}}, 2_000

      # Should receive: idle status (completion)
      assert_receive {:agent, {:status_changed, :idle, nil}}, 5_000

      # Verify final state
      assert AgentServer.get_status(agent_id) == :idle
    end

    test "resume passes correct decisions through Agent.resume" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      # Build interrupt with multiple action requests
      interrupt_data =
        build_subagent_interrupt_data(
          sub_agent_id: "sub-decisions-1",
          subagent_type: "editor",
          action_requests: [
            %{
              tool_call_id: "sa_d1",
              tool_name: "edit_file",
              arguments: %{"path" => "/tmp/doc.txt", "content" => "draft"}
            },
            %{
              tool_call_id: "sa_d2",
              tool_name: "delete_file",
              arguments: %{"path" => "/tmp/old.txt"}
            }
          ],
          review_configs: %{
            "edit_file" => %{allowed_decisions: [:approve, :edit, :reject]},
            "delete_file" => %{allowed_decisions: [:approve, :reject]}
          }
        )

      tool_call =
        ToolCall.new!(%{
          call_id: "tc_d1",
          name: "task",
          arguments: %{"instructions" => "edit documents"}
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Edit the docs"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data
        })

      # Use ETS to capture the decisions passed to Agent.resume
      call_log = :ets.new(:decisions_log, [:set, :public])

      Agent
      |> expect(:execute, fn ^agent, _state, _opts ->
        {:interrupt, interrupted_state, interrupt_data}
      end)

      Agent
      |> expect(:resume, fn ^agent, state, decisions, _opts ->
        # Record everything that was passed to resume for assertion
        :ets.insert(call_log, {:resume_state, state})
        :ets.insert(call_log, {:resume_decisions, decisions})
        :ets.insert(call_log, {:resume_interrupt_data, state.interrupt_data})

        completed_state =
          State.new!(%{
            messages: [
              Message.new_user!("Edit the docs"),
              Message.new_assistant!(%{content: "Edits complete."})
            ]
          })

        {:ok, completed_state}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Edit the docs")]})

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           initial_state: initial_state,
           name: AgentServer.get_name(agent_id),
           pubsub: nil,
           inactivity_timeout: nil}
        )

      :ok = AgentServer.execute(agent_id)
      {:ok, :interrupted} = wait_for_status(agent_id, :interrupted)

      # Human provides mixed decisions: approve edit, reject delete
      decisions = [
        %{type: :approve},
        %{type: :reject}
      ]

      :ok = AgentServer.resume(agent_id, decisions)
      {:ok, :idle} = wait_for_status(agent_id, :idle)

      # Verify the decisions were passed through correctly to Agent.resume
      [{:resume_decisions, received_decisions}] =
        :ets.lookup(call_log, :resume_decisions)

      assert received_decisions == decisions
      assert length(received_decisions) == 2
      assert Enum.at(received_decisions, 0).type == :approve
      assert Enum.at(received_decisions, 1).type == :reject

      # Verify the interrupt_data was available in the state passed to Agent.resume
      [{:resume_interrupt_data, received_interrupt}] =
        :ets.lookup(call_log, :resume_interrupt_data)

      assert received_interrupt.type == :subagent_hitl
      assert received_interrupt.sub_agent_id == "sub-decisions-1"

      :ets.delete(call_log)
    end

    test "multiple interrupt-resume cycles work correctly" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      # First interrupt: step 1 of plan
      interrupt_data_1 =
        build_subagent_interrupt_data(
          sub_agent_id: "sub-multi-1",
          subagent_type: "planner",
          action_requests: [
            %{
              tool_call_id: "sa_m1",
              tool_name: "confirm_plan",
              arguments: %{"plan" => "step 1"}
            }
          ],
          review_configs: %{
            "confirm_plan" => %{allowed_decisions: [:approve, :reject]}
          }
        )

      tool_call =
        ToolCall.new!(%{
          call_id: "tc_m1",
          name: "task",
          arguments: %{"instructions" => "plan and execute"}
        })

      interrupted_state_1 =
        State.new!(%{
          messages: [
            Message.new_user!("Plan and execute"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data_1
        })

      # Second interrupt: step 2 of plan
      interrupt_data_2 =
        build_subagent_interrupt_data(
          sub_agent_id: "sub-multi-1",
          subagent_type: "planner",
          action_requests: [
            %{
              tool_call_id: "sa_m2",
              tool_name: "confirm_plan",
              arguments: %{"plan" => "step 2"}
            }
          ],
          review_configs: %{
            "confirm_plan" => %{allowed_decisions: [:approve, :reject]}
          }
        )

      interrupted_state_2 =
        State.new!(%{
          messages: [
            Message.new_user!("Plan and execute"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data_2
        })

      # Mock Agent.execute to return first interrupt
      Agent
      |> expect(:execute, fn ^agent, _state, _opts ->
        {:interrupt, interrupted_state_1, interrupt_data_1}
      end)

      # Mock Agent.resume using stub with a counter to differentiate calls:
      # - Call 1: returns another interrupt (step 2)
      # - Call 2: returns completion
      resume_count = :counters.new(1, [:atomics])

      Agent
      |> stub(:resume, fn ^agent, _state, _decisions, _opts ->
        :counters.add(resume_count, 1, 1)
        count = :counters.get(resume_count, 1)

        if count == 1 do
          {:interrupt, interrupted_state_2, interrupt_data_2}
        else
          completed_state =
            State.new!(%{
              messages: [
                Message.new_user!("Plan and execute"),
                Message.new_assistant!(%{content: "Plan fully executed."})
              ]
            })

          {:ok, completed_state}
        end
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Plan and execute")]})

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           initial_state: initial_state,
           name: AgentServer.get_name(agent_id),
           pubsub: nil,
           inactivity_timeout: nil}
        )

      # --- Cycle 1: execute -> interrupt ---
      :ok = AgentServer.execute(agent_id)
      {:ok, :interrupted} = wait_for_status(agent_id, :interrupted)

      info1 = AgentServer.get_info(agent_id)
      assert info1.interrupt_data.type == :subagent_hitl
      nested1 = info1.interrupt_data.interrupt_data
      assert hd(nested1.action_requests).arguments["plan"] == "step 1"

      # --- Cycle 2: resume -> second interrupt ---
      :ok = AgentServer.resume(agent_id, [%{type: :approve}])
      {:ok, :interrupted} = wait_for_status(agent_id, :interrupted)

      info2 = AgentServer.get_info(agent_id)
      assert info2.interrupt_data.type == :subagent_hitl
      nested2 = info2.interrupt_data.interrupt_data
      assert hd(nested2.action_requests).arguments["plan"] == "step 2"

      # --- Cycle 3: resume -> completion ---
      :ok = AgentServer.resume(agent_id, [%{type: :approve}])
      {:ok, :idle} = wait_for_status(agent_id, :idle)

      # Verify final state
      final_state = AgentServer.get_state(agent_id)
      assert final_state.interrupt_data == nil
      assert length(final_state.messages) >= 2
    end

    test "resume returns error when AgentServer is not in interrupted state" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           name: AgentServer.get_name(agent_id),
           pubsub: nil,
           inactivity_timeout: nil}
        )

      # Agent is idle, not interrupted
      assert AgentServer.get_status(agent_id) == :idle

      # Resume should fail
      assert {:error, "Cannot resume, server is not interrupted"} =
               AgentServer.resume(agent_id, [%{type: :approve}])
    end

    test "Agent.resume error propagates correctly through AgentServer" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      interrupt_data = build_subagent_interrupt_data()

      tool_call =
        ToolCall.new!(%{
          call_id: "tc_err1",
          name: "task",
          arguments: %{"instructions" => "fail"}
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do something"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data
        })

      Agent
      |> expect(:execute, fn ^agent, _state, _opts ->
        {:interrupt, interrupted_state, interrupt_data}
      end)

      # Mock resume to return an error
      Agent
      |> expect(:resume, fn ^agent, _state, _decisions, _opts ->
        {:error, "Sub-agent failed to resume: connection timeout"}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Do something")]})

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           initial_state: initial_state,
           name: AgentServer.get_name(agent_id),
           pubsub: nil,
           inactivity_timeout: nil}
        )

      :ok = AgentServer.execute(agent_id)
      {:ok, :interrupted} = wait_for_status(agent_id, :interrupted)

      :ok = AgentServer.resume(agent_id, [%{type: :approve}])

      # Wait for error state
      {:ok, :error} = wait_for_status(agent_id, :error)

      info = AgentServer.get_info(agent_id)
      assert info.status == :error
      assert info.error == "Sub-agent failed to resume: connection timeout"
    end

    test "interrupt data is correctly stored and retrievable via get_info" do
      agent = create_test_agent()
      agent_id = agent.agent_id

      # Build interrupt with multiple action requests and detailed review configs
      interrupt_data =
        build_subagent_interrupt_data(
          sub_agent_id: "sub-info-1",
          subagent_type: "code_reviewer",
          action_requests: [
            %{
              tool_call_id: "sa_i1",
              tool_name: "write_file",
              arguments: %{
                "path" => "/src/main.py",
                "content" => "print('hello')"
              }
            },
            %{
              tool_call_id: "sa_i2",
              tool_name: "delete_file",
              arguments: %{"path" => "/src/old_main.py"}
            },
            %{
              tool_call_id: "sa_i3",
              tool_name: "run_command",
              arguments: %{"command" => "python main.py"}
            }
          ],
          review_configs: %{
            "write_file" => %{allowed_decisions: [:approve, :edit, :reject]},
            "delete_file" => %{allowed_decisions: [:approve, :reject]},
            "run_command" => %{allowed_decisions: [:approve, :reject]}
          }
        )

      tool_call =
        ToolCall.new!(%{
          call_id: "tc_info1",
          name: "task",
          arguments: %{"instructions" => "review code"}
        })

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Review the code"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data
        })

      Agent
      |> expect(:execute, fn ^agent, _state, _opts ->
        {:interrupt, interrupted_state, interrupt_data}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Review the code")]})

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           initial_state: initial_state,
           name: AgentServer.get_name(agent_id),
           pubsub: nil,
           inactivity_timeout: nil}
        )

      :ok = AgentServer.execute(agent_id)
      {:ok, :interrupted} = wait_for_status(agent_id, :interrupted)

      # Verify all interrupt data is accessible and structured correctly
      info = AgentServer.get_info(agent_id)

      # Top-level interrupt data
      assert info.interrupt_data.type == :subagent_hitl
      assert info.interrupt_data.sub_agent_id == "sub-info-1"
      assert info.interrupt_data.subagent_type == "code_reviewer"

      # Nested interrupt data from the sub-agent
      nested = info.interrupt_data.interrupt_data
      assert length(nested.action_requests) == 3
      assert length(nested.hitl_tool_call_ids) == 3

      # Verify each action request
      [req1, req2, req3] = nested.action_requests
      assert req1.tool_name == "write_file"
      assert req1.arguments["path"] == "/src/main.py"
      assert req2.tool_name == "delete_file"
      assert req3.tool_name == "run_command"

      # Verify review configs
      assert map_size(nested.review_configs) == 3
      assert nested.review_configs["write_file"].allowed_decisions == [:approve, :edit, :reject]
      assert nested.review_configs["delete_file"].allowed_decisions == [:approve, :reject]
      assert nested.review_configs["run_command"].allowed_decisions == [:approve, :reject]
    end
  end

  describe "Agent.resume with subagent_hitl bypass" do
    @describetag timeout: 15_000

    setup do
      # For these tests we need the REAL Agent.execute/resume
      # (not mocked), so we stub ChatAnthropic instead
      :ok
    end

    test "Agent.resume skips process_decisions for subagent_hitl and injects resume_info" do
      # This test verifies the critical bypass in Agent.resume/4:
      # When interrupt_data.type == :subagent_hitl, it skips process_decisions
      # (which would fail for empty interrupt_on) and calls
      # SubAgentServer.resume directly with the correct sub_agent_id and decisions.

      # The task tool still needs to exist (for message structure) but its
      # function won't be called during resume — SubAgentServer.resume is
      # called directly instead.
      task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task to sub-agent",
          function: fn _args, _context ->
            {:ok, "Sub-agent completed."}
          end
        })

      # Create agent with empty interrupt_on (the realistic parent config)
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      tool_call =
        ToolCall.new!(%{
          call_id: "tc_bypass1",
          name: "task",
          arguments: %{"instructions" => "do work", "subagent_type" => "researcher"}
        })

      # Construct interrupted state (matching unit test pattern - without tool_result)
      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do the work"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: %{
            type: :subagent_hitl,
            sub_agent_id: "sub-bypass-1",
            subagent_type: "researcher",
            interrupt_data: %{
              action_requests: [
                %{
                  tool_call_id: "sa_bp1",
                  tool_name: "ask_user",
                  arguments: %{"question" => "Proceed?"}
                }
              ],
              review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
              hitl_tool_call_ids: ["sa_bp1"]
            }
          }
        })

      decisions = [%{type: :approve}]

      # Mock SubAgentServer.resume to verify correct args and return success
      expect(Sagents.SubAgentServer, :resume, fn sub_agent_id, received_decisions ->
        assert sub_agent_id == "sub-bypass-1"
        assert received_decisions == decisions
        {:ok, "completed"}
      end)

      # Mock LLM for the continuation after resume
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("Great, the sub-agent finished.")]}
      end)

      # Call Agent.resume directly (not through AgentServer)
      result = Agent.resume(agent, interrupted_state, decisions)

      # Should succeed (the bypass means process_decisions is skipped)
      assert {:ok, final_state} = result
      assert final_state.interrupt_data == nil
    end

    test "Agent.resume with subagent_hitl through AgentServer exercises full bypass path" do
      # This test combines AgentServer lifecycle with the real Agent.resume
      # code path for subagent_hitl, verifying the bypass works end-to-end.
      # We mock Agent.execute (for the initial interrupt) but let Agent.resume
      # run real code.

      # The task tool still needs to exist (for message structure) but its
      # function won't be called during resume — SubAgentServer.resume is
      # called directly instead.
      task_tool =
        LangChain.Function.new!(%{
          name: "task",
          description: "Delegate task",
          function: fn _args, _context ->
            {:ok, "Sub-agent completed."}
          end
        })

      # Create agent with HITL middleware (empty interrupt_on)
      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            tools: [task_tool],
            middleware: [
              {Sagents.Middleware.HumanInTheLoop, [interrupt_on: %{}]}
            ]
          },
          replace_default_middleware: true
        )

      agent_id = agent.agent_id

      tool_call =
        ToolCall.new!(%{
          call_id: "tc_full1",
          name: "task",
          arguments: %{"instructions" => "do work"}
        })

      # Build interrupted state (without old tool_result - matching the unit test pattern)
      interrupt_data = %{
        type: :subagent_hitl,
        sub_agent_id: "sub-full-1",
        subagent_type: "researcher",
        interrupt_data: %{
          action_requests: [
            %{
              tool_call_id: "sa_f1",
              tool_name: "ask_user",
              arguments: %{"question" => "OK?"}
            }
          ],
          review_configs: %{"ask_user" => %{allowed_decisions: [:approve]}},
          hitl_tool_call_ids: ["sa_f1"]
        }
      }

      interrupted_state =
        State.new!(%{
          messages: [
            Message.new_user!("Do work"),
            Message.new_assistant!(%{tool_calls: [tool_call]})
          ],
          interrupt_data: interrupt_data
        })

      # Mock Agent.execute to return the interrupt
      Agent
      |> expect(:execute, fn ^agent, _state, _opts ->
        {:interrupt, interrupted_state, interrupt_data}
      end)

      # DO NOT mock Agent.resume - let it run real code!
      # This exercises the subagent_hitl bypass in Agent.resume/4

      # Mock SubAgentServer.resume to return success (stub because AgentServer
      # timing may be complex)
      stub(Sagents.SubAgentServer, :resume, fn _sub_agent_id, _decisions ->
        {:ok, "completed"}
      end)

      # Mock LLM for the continuation after resume
      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        {:ok, [Message.new_assistant!("All done.")]}
      end)

      initial_state = State.new!(%{messages: [Message.new_user!("Do work")]})

      _pid =
        start_supervised!(
          {AgentServer,
           agent: agent,
           initial_state: initial_state,
           name: AgentServer.get_name(agent_id),
           pubsub: nil,
           inactivity_timeout: nil}
        )

      # Execute and wait for interrupt
      :ok = AgentServer.execute(agent_id)
      {:ok, :interrupted} = wait_for_status(agent_id, :interrupted)

      # Verify interrupt
      info = AgentServer.get_info(agent_id)
      assert info.interrupt_data.type == :subagent_hitl

      # Resume with real Agent.resume (exercises the bypass)
      :ok = AgentServer.resume(agent_id, [%{type: :approve}])
      {:ok, :idle} = wait_for_status(agent_id, :idle)

      # Verify final state
      final_state = AgentServer.get_state(agent_id)
      assert final_state.interrupt_data == nil
    end
  end
end
