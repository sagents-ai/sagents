defmodule Sagents.AgentUtils do
  @moduledoc """
  Shared utilities for Agent and SubAgent HITL (Human-in-the-Loop) support.

  Provides common functions for:
  - Checking for HITL interrupts
  - Building full decisions lists
  - Extracting tool calls from chains

  These utilities provide consistent HITL behavior across Agent and SubAgent
  implementations.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias Sagents.Middleware
  alias Sagents.MiddlewareEntry

  @doc """
  Check if a chain has pending tool calls that require human approval.

  ## Parameters
  - chain: LLMChain with potentially pending tool calls
  - interrupt_on: Map of tool_name => true/false/config

  ## Returns
  - `{:interrupt, interrupt_data}` - Some tools need approval
  - `:continue` - No tools need approval or no tool calls present

  ## Example
      case AgentUtils.check_for_hitl_interrupt(chain, %{"write_file" => true}) do
        {:interrupt, interrupt_data} ->
          # Pause and request human decisions
          {:interrupt, state, interrupt_data}

        :continue ->
          # Execute tools automatically
          execute_tools(chain)
      end
  """
  def check_for_hitl_interrupt(%LLMChain{} = chain, interrupt_on) when is_map(interrupt_on) do
    case chain.last_message do
      %Message{role: :assistant, tool_calls: tool_calls}
      when is_list(tool_calls) and tool_calls != [] ->
        # Filter tool calls that need approval
        hitl_tool_calls =
          Enum.filter(tool_calls, fn tc ->
            requires_approval?(tc.name, interrupt_on)
          end)

        if hitl_tool_calls == [] do
          :continue
        else
          # Build interrupt data
          action_requests =
            Enum.map(hitl_tool_calls, fn tc ->
              %{
                tool_call_id: tc.call_id,
                tool_name: tc.name,
                arguments: tc.arguments
              }
            end)

          hitl_tool_call_ids = Enum.map(hitl_tool_calls, & &1.call_id)

          interrupt_data = %{
            action_requests: action_requests,
            hitl_tool_call_ids: hitl_tool_call_ids
          }

          {:interrupt, interrupt_data}
        end

      _other ->
        # No tool calls in last message
        :continue
    end
  end

  @doc """
  Build a full decisions list for ALL tool calls in a message.

  Mixes human decisions (for HITL tools) with auto-approvals (for non-HITL tools).
  This is needed because LLMChain.execute_tool_calls_with_decisions expects a decision
  for EVERY tool call, not just the ones that needed approval.

  ## Parameters
  - all_tool_calls: All tool calls from assistant message (HITL + non-HITL)
  - hitl_tool_call_ids: List of tool_call_ids that needed human approval
  - human_decisions: List of decisions from human (same order as action_requests)
  - action_requests: List of action_requests (to map decisions to tool_call_ids)

  ## Returns
  - List of decisions matching all_tool_calls order

  ## Example
      all_tool_calls = [tc1, tc2, tc3]  # 3 total tool calls
      hitl_tool_call_ids = [tc1.call_id]  # Only tc1 needed approval
      action_requests = [%{tool_call_id: tc1.call_id, ...}]
      human_decisions = [%{type: :approve}]  # Human approved tc1

      full_decisions = build_full_decisions(all_tool_calls, hitl_tool_call_ids, human_decisions, action_requests)
      # => [%{type: :approve}, %{type: :approve}, %{type: :approve}]
      # First is human decision, others are auto-approved
  """
  def build_full_decisions(all_tool_calls, hitl_tool_call_ids, human_decisions, action_requests) do
    # Build decisions map indexed by tool_call_id
    decisions_by_id =
      action_requests
      |> Enum.zip(human_decisions)
      |> Map.new(fn {action_req, decision} ->
        {action_req.tool_call_id, decision}
      end)

    # Build full decisions list matching ALL tool calls
    Enum.map(all_tool_calls, fn tc ->
      if tc.call_id in hitl_tool_call_ids do
        # Use human decision for HITL tool
        Map.fetch!(decisions_by_id, tc.call_id)
      else
        # Auto-approve non-HITL tool
        %{type: :approve}
      end
    end)
  end

  @doc """
  Extract tool calls from the last assistant message in a chain.

  ## Parameters
  - chain: LLMChain

  ## Returns
  - List of tool calls or empty list

  ## Example
      tool_calls = AgentUtils.get_tool_calls_from_last_message(chain)
      # => [%ToolCall{call_id: "1", name: "write_file", ...}, ...]
  """
  def get_tool_calls_from_last_message(%LLMChain{} = chain) do
    case chain.last_message do
      %Message{role: :assistant, tool_calls: tool_calls} when is_list(tool_calls) ->
        tool_calls

      _other ->
        []
    end
  end

  @doc """
  Resolve the callback handler maps to run for an execution.

  Collecting middleware callbacks is intrinsic to running an agent: this always
  collects `middleware`'s callbacks (via `Sagents.Middleware.collect_callbacks/1`)
  and merges any caller-supplied `:callbacks` from `opts` *on top* rather than
  substituting them. Supplying `:callbacks` therefore never disables an agent's
  middleware callbacks.

  Supplied callbacks come first to preserve the historical ordering of the server
  path (PubSub broadcasting, then middleware handlers). Empty `%{}` maps are
  dropped so a `%{}` default never adds a no-op callback to the chain.

  Both execution engines share this contract: `Sagents.Agent` passes its own
  `agent.middleware`, while `Sagents.SubAgent` passes the inherited
  `parent_middleware` carried in its chain's `custom_context`. The server layers
  pass only their PubSub callbacks via `:callbacks`; collection happens here, so
  middleware is never collected twice.

  ## Parameters
  - `middleware`: List of `Sagents.MiddlewareEntry` structs to collect from
  - `opts`: Keyword list; reads the optional `:callbacks` key (a map or list of
    maps)

  ## Example
      callbacks = AgentUtils.resolve_callbacks(agent.middleware, opts)
  """
  @spec resolve_callbacks([MiddlewareEntry.t()], keyword()) :: [map()]
  def resolve_callbacks(middleware, opts) when is_list(middleware) and is_list(opts) do
    supplied =
      opts
      |> Keyword.get(:callbacks, [])
      |> List.wrap()
      |> Enum.reject(&(&1 == %{}))

    supplied ++ Middleware.collect_callbacks(middleware)
  end

  @doc """
  Map an interrupt-data payload to the assigns/state changes a host
  (LiveView, GenServer, etc.) should merge to display the interrupt.

  Routes the four sagents-internal interrupt variants to their UI shapes:

  - `:halt` — surface as a terminal halt with `:pending_halt`
  - `:ask_user_question` — pull the single question to the front
  - `:multiple_interrupts` — "halt wins": if any sub-interrupt is `:halt`,
    surface as a halt; otherwise present as questions if all are
    questions, or as a HITL tool batch
  - `:subagent_hitl` — unwrap the inner `action_requests`
  - any other map — treat as a generic HITL tool batch

  Returns an empty map for `nil`, so callers can apply the result
  unconditionally on top of base assigns.

  ## Returned keys

  When a halt is present:
  `:pending_halt`, `:pending_question`, `:pending_tools`

  When questions are present:
  `:pending_question`, `:remaining_questions`, `:question_responses`, `:pending_tools`

  When HITL tools are present:
  `:pending_tools`, `:pending_question`

  ## Example

      base = %{loading: false, agent_status: :interrupted, interrupt_data: data}
      Map.merge(base, AgentUtils.interrupt_session_changes(data))

  """
  @spec interrupt_session_changes(map() | nil) :: map()
  def interrupt_session_changes(nil), do: %{}

  def interrupt_session_changes(%{type: :halt} = halt), do: present_halt(halt)

  def interrupt_session_changes(%{type: :ask_user_question} = question) do
    present_questions([question])
  end

  def interrupt_session_changes(%{type: :multiple_interrupts, interrupts: interrupts}) do
    cond do
      Enum.any?(interrupts, &(&1.type == :halt)) ->
        # Halt wins: surface the first halt sibling and ignore the rest.
        # The other interrupts are moot because the workflow is over.
        halt = Enum.find(interrupts, &(&1.type == :halt))
        present_halt(halt)

      Enum.all?(interrupts, &(&1.type == :ask_user_question)) ->
        present_questions(interrupts)

      true ->
        present_hitl_tools(interrupts)
    end
  end

  def interrupt_session_changes(interrupt_data), do: present_hitl_tools(interrupt_data)

  @doc """
  Changes that fully clear all interrupt-derived host state.

  Single source of truth for the complete set of `pending_*` /
  interrupt-related keys a host carries. Merge this into any status
  transition that lands on a **non-interrupted** status (`:running`,
  `:idle`, `:cancelled`, `:error`, `:not_running`) to enforce the
  invariant: *any status other than `:interrupted` means there is no
  pending interrupt UI.*

  This prevents a dismissed/superseded interrupt's derived keys (e.g. a
  `:pending_halt`) from surviving invisibly behind a
  `status == :interrupted` render guard and re-appearing on the next
  transition back into `:interrupted`.

  ## Example

      def handle_status_idle,
        do: Map.merge(AgentUtils.cleared_interrupt_changes(),
              %{loading: false, agent_status: :idle, streaming_delta: nil})

  """
  @spec cleared_interrupt_changes() :: map()
  def cleared_interrupt_changes do
    %{
      pending_tools: [],
      pending_question: nil,
      pending_halt: nil,
      remaining_questions: [],
      question_responses: [],
      hitl_decisions: [],
      interrupt_data: nil
    }
  end

  @doc """
  Compute the state transition for a single HITL approve/reject decision
  in a host's pending-tool list.

  Reads `:pending_tools` and `:hitl_decisions` from `state` (treating
  missing keys as empty list / empty list), records `decision_type` for
  the tool at `index`, and returns:

  - `{:resume, accumulated_decisions, changes}` — all pending tools have
    been decided. The host should call
    `Sagents.AgentServer.resume(agent_id, accumulated_decisions)` and then
    merge `changes` (which clears `:pending_tools`, `:interrupt_data`, and
    `:hitl_decisions`).
  - `{:more, changes}` — tools still pending. Merge `changes` (which
    advances `:pending_tools` and `:hitl_decisions`).

  ## Example

      case AgentUtils.advance_hitl_decisions(socket.assigns, idx, :approve) do
        {:resume, decisions, changes} ->
          AgentServer.resume(agent_id, decisions)
          {:noreply, assign(socket, changes)}

        {:more, changes} ->
          {:noreply, assign(socket, changes)}
      end

  """
  @spec advance_hitl_decisions(map(), non_neg_integer(), atom()) ::
          {:resume, [map()], map()} | {:more, map()}
  def advance_hitl_decisions(state, index, decision_type)
      when is_map(state) and is_integer(index) and is_atom(decision_type) do
    pending_tools = Map.get(state, :pending_tools, []) || []
    accumulated = (Map.get(state, :hitl_decisions, []) || []) ++ [%{type: decision_type}]
    remaining_tools = List.delete_at(pending_tools, index)

    if remaining_tools == [] do
      {:resume, accumulated,
       %{
         pending_tools: [],
         interrupt_data: nil,
         hitl_decisions: []
       }}
    else
      {:more,
       %{
         pending_tools: remaining_tools,
         hitl_decisions: accumulated
       }}
    end
  end

  # Private helpers

  defp present_halt(halt) do
    %{
      pending_halt: %{
        message: Map.get(halt, :message),
        source_tool: Map.get(halt, :source_tool) || Map.get(halt, :source),
        tool_call_id: Map.get(halt, :tool_call_id)
      },
      pending_question: nil,
      pending_tools: []
    }
  end

  defp present_questions([first | rest]) do
    %{
      pending_question: first,
      remaining_questions: rest,
      question_responses: [],
      pending_tools: [],
      pending_halt: nil
    }
  end

  defp present_hitl_tools(interrupt_data) do
    %{
      pending_tools: extract_action_requests(interrupt_data),
      pending_question: nil,
      pending_halt: nil
    }
  end

  defp extract_action_requests(%{type: :subagent_hitl, interrupt_data: inner}) do
    Map.get(inner, :action_requests, [])
  end

  defp extract_action_requests(interrupt_data) when is_list(interrupt_data) do
    Enum.flat_map(interrupt_data, &extract_action_requests/1)
  end

  defp extract_action_requests(interrupt_data) when is_map(interrupt_data) do
    Map.get(interrupt_data, :action_requests, [])
  end

  defp extract_action_requests(_other), do: []

  defp requires_approval?(tool_name, interrupt_on) do
    case Map.get(interrupt_on, tool_name) do
      # Not in config = no approval needed
      nil -> false
      # Explicitly false = no approval
      false -> false
      # Explicitly true = requires approval
      true -> true
      # Config map = requires approval
      %{} -> true
    end
  end
end
