defmodule Sagents.UserRequest do
  @moduledoc """
  Groups a conversation's messages by the user request that caused them.

  A user request starts when a human message lands in the conversation,
  stating something the user wants, and covers everything produced in
  response: assistant messages (thinking, narration, answers), tool calls and
  results, messages a tool queued or expanded into, and sub-agent work. It
  ends when the agent has nothing left to do for that request.

  The user taking part along the way does not start a new request. Answering
  an `ask_user` question, approving or rejecting a tool call, and any other
  resume of an interrupt all serve the request that asked, and carry its
  number. Sending a new message instead of answering does start one, and the
  abandoned request is reported as `:superseded`.

  User requests are numbered per conversation, starting at 1.
  `Sagents.State.user_request_seq` holds the current number, and every message
  carries the number it was produced under in `metadata[:user_request_seq]`.
  There is no stored user request record: everything here is derived from
  those stamps.

  `0` means no user request has started. Stamping with `0` leaves messages
  untouched.

  A user request is not the same thing as a model turn (see
  `LangChain.Message.continues_turn?/1`) or a run (one `Sagents.Agent.execute/3`).
  One user request can span several runs and many model turns.
  """

  alias LangChain.Message
  alias LangChain.TokenUsage
  alias Sagents.State

  @type seq :: non_neg_integer()

  @type summary :: %{
          seq: pos_integer(),
          messages: [Message.t()],
          final_message: Message.t() | nil,
          assistant_message_count: non_neg_integer(),
          tool_calls: %{String.t() => pos_integer()},
          token_usage: TokenUsage.t() | nil
        }

  @doc """
  Return the user request number a message was stamped with, or `nil`.
  """
  @spec seq(Message.t()) :: pos_integer() | nil
  def seq(%Message{metadata: %{user_request_seq: seq}}) when is_integer(seq) and seq > 0,
    do: seq

  def seq(%Message{}), do: nil

  @doc """
  Set a message's user request number, replacing any it had.
  """
  @spec put_seq(Message.t(), pos_integer()) :: Message.t()
  def put_seq(%Message{metadata: metadata} = message, seq) when is_integer(seq) and seq > 0 do
    %Message{message | metadata: Map.put(metadata || %{}, :user_request_seq, seq)}
  end

  @doc """
  Stamp a message with `seq` unless it already has a number.

  A message keeps the number it was first stamped with, so stamping the same
  message again, at any later point, changes nothing. A `seq` of `0` leaves
  the message untouched.
  """
  @spec stamp(Message.t(), seq()) :: Message.t()
  def stamp(%Message{} = message, seq) when is_integer(seq) and seq > 0 do
    case seq(message) do
      nil -> put_seq(message, seq)
      _stamped -> message
    end
  end

  def stamp(%Message{} = message, _seq), do: message

  @doc """
  Stamp every message in a list that has no number yet. See `stamp/2`.
  """
  @spec stamp_all([Message.t()], seq()) :: [Message.t()]
  def stamp_all(messages, seq) when is_list(messages), do: Enum.map(messages, &stamp(&1, seq))

  @doc """
  Stamp the messages inside a `Sagents.Agent.execute/3` result. Results
  without a state pass through unchanged.
  """
  @spec stamp_result(term(), seq()) :: term()
  def stamp_result({:ok, %State{} = state}, seq), do: {:ok, stamp_state(state, seq)}

  def stamp_result({:ok, %State{} = state, extra}, seq),
    do: {:ok, stamp_state(state, seq), extra}

  def stamp_result({:interrupt, %State{} = state, data}, seq),
    do: {:interrupt, stamp_state(state, seq), data}

  def stamp_result({:pause, %State{} = state}, seq), do: {:pause, stamp_state(state, seq)}
  def stamp_result(other, _seq), do: other

  @doc """
  Stamp the messages of a state that have no number yet.
  """
  @spec stamp_state(State.t(), seq()) :: State.t()
  def stamp_state(%State{messages: messages} = state, seq),
    do: %State{state | messages: stamp_all(messages, seq)}

  @doc """
  Return `true` when a message can be a user request's final answer: an
  assistant message with no tool calls that does not leave the model's turn
  open, and is not a summary standing in for older history.

  This is the question the chain asks to stop a run, asked at the user request
  boundary instead.
  """
  @spec final_answer?(Message.t()) :: boolean()
  def final_answer?(%Message{role: :assistant, metadata: %{summary: true}}), do: false

  def final_answer?(%Message{role: :assistant} = message) do
    not Message.is_tool_call?(message) and not Message.continues_turn?(message)
  end

  def final_answer?(%Message{}), do: false

  @doc """
  Summarize every user request whose messages are in the state, in order.

  Summarization removes older messages from a state, so this only describes
  user requests whose messages are still present. A durable record belongs to
  the host, written when each user request completes.
  """
  @spec list(State.t()) :: [summary()]
  def list(%State{messages: messages}) do
    messages
    |> Enum.filter(&seq/1)
    |> Enum.group_by(&seq/1)
    |> Enum.sort_by(fn {seq, _messages} -> seq end)
    |> Enum.map(fn {seq, grouped} -> summarize(seq, grouped) end)
  end

  @doc """
  Summarize one user request, or return `nil` when no message carries its number.
  """
  @spec get(State.t(), pos_integer()) :: summary() | nil
  def get(%State{messages: messages}, seq) when is_integer(seq) do
    case Enum.filter(messages, &(seq(&1) == seq)) do
      [] -> nil
      grouped -> summarize(seq, grouped)
    end
  end

  @doc """
  Build a summary from a user request's messages, given in conversation order.

  `token_usage` is the total across the messages: each message's own usage plus
  any sub-agent usage recorded on it. It includes the usage of summarization
  calls the user request triggered.
  """
  @spec summarize(pos_integer(), [Message.t()]) :: summary()
  def summarize(seq, messages) when is_integer(seq) and is_list(messages) do
    %{
      seq: seq,
      messages: messages,
      final_message: messages |> Enum.reverse() |> Enum.find(&final_answer?/1),
      assistant_message_count:
        Enum.count(messages, &(&1.role == :assistant and not summary?(&1))),
      tool_calls:
        messages
        |> Enum.flat_map(&(&1.tool_calls || []))
        |> Enum.frequencies_by(& &1.name),
      token_usage:
        Enum.reduce(messages, nil, fn message, acc ->
          acc
          |> TokenUsage.add_total(TokenUsage.get(message))
          |> TokenUsage.add_total(subagent_usage(message))
        end)
    }
  end

  defp summary?(%Message{metadata: %{summary: true}}), do: true
  defp summary?(%Message{}), do: false

  defp subagent_usage(%Message{metadata: %{subagent_usage: %TokenUsage{} = usage}}), do: usage
  defp subagent_usage(%Message{}), do: nil
end
