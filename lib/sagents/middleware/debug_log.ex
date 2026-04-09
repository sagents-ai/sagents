defmodule Sagents.Middleware.DebugLog do
  @moduledoc """
  Middleware that writes detailed, structured logs to per-conversation log files.

  Captures the full lifecycle of agent execution -- every message, tool call, state
  change, and error -- in a dedicated, readable log file. Each conversation gets its
  own log file, separate from application logs.

  ## Usage

  Place DebugLog **first** in the middleware stack so `before_model` sees raw state
  and `after_model` sees the final processed state:

      middleware: [
        {Sagents.Middleware.DebugLog, [log_dir: "tmp/agent_logs"]},
        TodoList,
        FileSystem,
        # ...
      ]

  ## Configuration

  - `:enabled` - Enable or disable logging (default: `true`). When `false`, all
    callbacks become noops -- no files are created and no I/O occurs. Useful for
    keeping the middleware in the stack but disabling it in non-dev environments.
  - `:log_dir` - Directory for log files (default: `"tmp/agent_logs"`)
  - `:prefix` - Filename prefix (default: `"debug"`)
  - `:log_deltas` - Log streaming deltas? (default: `false`)
  - `:pretty` - Pretty-print inspect output? (default: `true`)
  - `:inspect_limit` - Inspect limit for large structs (default: `:infinity`)

  ## Disabling in Production

  Since `Mix.env()` is not available in compiled releases, use application config:

      # config/dev.exs (or simply omit -- defaults to true)
      config :my_app, :debug_logging, true

      # config/prod.exs
      config :my_app, :debug_logging, false

      # In your middleware stack
      {Sagents.Middleware.DebugLog, [enabled: Application.compile_env(:my_app, :debug_logging, false)]}

  ## Log File Naming

      {log_dir}/{prefix}_{start_timestamp}_{agent_id}.log

  The timestamp comes first so that log files sort chronologically when
  listed alphabetically. The timestamp is captured when the middleware
  initializes, so a server restart produces a new log file.
  """

  @behaviour Sagents.Middleware

  require Logger

  alias Sagents.State

  @separator String.duplicate("=", 80)

  # -- Middleware Callbacks --

  @impl true
  def init(opts) do
    config = %{
      enabled: Keyword.get(opts, :enabled, true),
      log_dir: Keyword.get(opts, :log_dir, "tmp/agent_logs"),
      prefix: Keyword.get(opts, :prefix, "debug"),
      log_deltas: Keyword.get(opts, :log_deltas, false),
      pretty: Keyword.get(opts, :pretty, true),
      inspect_limit: Keyword.get(opts, :inspect_limit, :infinity),
      start_timestamp: format_timestamp_for_filename(DateTime.utc_now())
    }

    {:ok, config}
  end

  @impl true
  def on_server_start(state, %{enabled: false}), do: {:ok, state}

  def on_server_start(state, config) do
    log_event(config, state.agent_id, "ON_SERVER_START", fn ->
      msg_count = length(state.messages)
      todo_count = length(state.todos)
      metadata_keys = state.metadata |> Map.keys() |> Enum.sort()

      lines = [
        "State.agent_id: #{inspect(state.agent_id)}",
        "Messages: #{msg_count}",
        "Todos: #{todo_count}",
        "Metadata keys: #{inspect(metadata_keys)}"
      ]

      lines =
        if msg_count > 0 do
          lines ++ ["", "--- Messages ---"] ++ Enum.map(state.messages, &safe_inspect(&1, config))
        else
          lines
        end

      Enum.join(lines, "\n")
    end)

    {:ok, state}
  end

  @impl true
  def before_model(state, %{enabled: false}), do: {:ok, state}

  def before_model(state, config) do
    prev_count = State.get_metadata(state, "debug_log.msg_count", 0)
    current_count = length(state.messages)

    log_event(config, state.agent_id, "BEFORE_MODEL", fn ->
      new_count = current_count - prev_count
      new_messages = Enum.slice(state.messages, prev_count..current_count)

      lines = [
        "Message count: #{current_count} (#{new_count} new since last)"
      ]

      lines =
        if new_count > 0 do
          lines ++
            ["New messages:"] ++
            Enum.map(new_messages, &safe_inspect(&1, config))
        else
          lines
        end

      Enum.join(lines, "\n")
    end)

    updated_state = State.put_metadata(state, "debug_log.msg_count", current_count)
    {:ok, updated_state}
  end

  @impl true
  def after_model(state, %{enabled: false}), do: {:ok, state}

  def after_model(state, config) do
    prev_count = State.get_metadata(state, "debug_log.msg_count", 0)
    current_count = length(state.messages)

    log_event(config, state.agent_id, "AFTER_MODEL", fn ->
      new_count = current_count - prev_count
      new_messages = Enum.slice(state.messages, prev_count..current_count)

      lines = [
        "New messages since BEFORE_MODEL: #{new_count}"
      ]

      lines =
        if new_count > 0 do
          lines ++
            Enum.map(new_messages, fn msg ->
              role = msg.role
              tool_calls = if is_list(msg.tool_calls), do: length(msg.tool_calls), else: 0

              summary =
                cond do
                  tool_calls > 0 ->
                    "  [#{role}] (with #{tool_calls} tool call#{if tool_calls > 1, do: "s", else: ""})"

                  is_binary(msg.content) and byte_size(msg.content) > 100 ->
                    "  [#{role}] #{inspect(String.slice(msg.content, 0, 100))}..."

                  true ->
                    "  [#{role}] #{inspect(msg.content)}"
                end

              summary
            end)
        else
          lines
        end

      interrupt_line =
        if state.interrupt_data do
          "Interrupt: #{safe_inspect(state.interrupt_data, config)}"
        else
          "Interrupt: none"
        end

      lines = lines ++ ["", interrupt_line]
      Enum.join(lines, "\n")
    end)

    updated_state = State.put_metadata(state, "debug_log.msg_count", current_count)
    {:ok, updated_state}
  end

  @impl true
  def handle_resume(_agent, state, _resume_data, %{enabled: false}, _opts), do: {:cont, state}

  def handle_resume(agent, state, resume_data, config, _opts) do
    log_event(config, state.agent_id, "HANDLE_RESUME", fn ->
      lines = [
        "Agent: #{inspect(agent.agent_id)}",
        "Interrupt data: #{safe_inspect(state.interrupt_data, config)}",
        "Resume data: #{safe_inspect(resume_data, config)}"
      ]

      Enum.join(lines, "\n")
    end)

    {:cont, state}
  end

  @impl true
  def handle_message(_message, state, %{enabled: false}), do: {:ok, state}

  def handle_message(message, state, config) do
    log_event(config, state.agent_id, "HANDLE_MESSAGE", fn ->
      safe_inspect(message, config)
    end)

    {:ok, state}
  end

  @impl true
  def callbacks(%{enabled: false}), do: %{}

  def callbacks(config) do
    callback_map = %{
      on_llm_new_message: fn chain, message ->
        agent_id = get_agent_id(chain)
        log_event(config, agent_id, "LLM_NEW_MESSAGE", fn -> safe_inspect(message, config) end)
      end,
      on_message_processed: fn chain, message ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "MESSAGE_PROCESSED", fn ->
          safe_inspect(message, config)
        end)
      end,
      on_tool_call_identified: fn chain, tool_call, function ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "TOOL_CALL_IDENTIFIED", fn ->
          lines = [
            "Tool: #{inspect(function.display_text || tool_call.name)}",
            safe_inspect(tool_call, config)
          ]

          Enum.join(lines, "\n")
        end)
      end,
      on_tool_execution_started: fn chain, tool_call, function ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "TOOL_EXECUTION_STARTED", fn ->
          "Tool: #{inspect(function.display_text || tool_call.name)}\nArguments: #{safe_inspect(tool_call.arguments, config)}"
        end)
      end,
      on_tool_execution_completed: fn chain, tool_call, tool_result ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "TOOL_EXECUTION_COMPLETED", fn ->
          "Tool: #{inspect(tool_call.name)}\nResult: #{safe_inspect(tool_result, config)}"
        end)
      end,
      on_tool_execution_failed: fn chain, tool_call, error ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "TOOL_EXECUTION_FAILED", fn ->
          "Tool: #{inspect(tool_call.name)}\nError: #{safe_inspect(error, config)}"
        end)
      end,
      on_tool_interrupted: fn chain, tool_results ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "TOOL_INTERRUPTED", fn ->
          Enum.map_join(tool_results, "\n", &safe_inspect(&1, config))
        end)
      end,
      on_tool_response_created: fn chain, message ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "TOOL_RESPONSE_CREATED", fn ->
          safe_inspect(message, config)
        end)
      end,
      on_llm_token_usage: fn chain, usage ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "LLM_TOKEN_USAGE", fn ->
          safe_inspect(usage, config)
        end)
      end,
      on_llm_ratelimit_info: fn chain, info ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "LLM_RATELIMIT_INFO", fn ->
          safe_inspect(info, config)
        end)
      end,
      on_message_processing_error: fn chain, message ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "MESSAGE_PROCESSING_ERROR", fn ->
          safe_inspect(message, config)
        end)
      end,
      on_error_message_created: fn chain, message ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "ERROR_MESSAGE_CREATED", fn ->
          safe_inspect(message, config)
        end)
      end,
      on_retries_exceeded: fn chain ->
        agent_id = get_agent_id(chain)
        log_event(config, agent_id, "RETRIES_EXCEEDED", fn -> "Max retries exhausted" end)
      end,
      on_llm_error: fn chain, error ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "LLM_ERROR", fn ->
          "LLM call failed (may be retried): #{safe_inspect(error, config)}"
        end)
      end,
      on_error: fn chain, error ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "CHAIN_ERROR", fn ->
          "Terminal error (all retries/fallbacks exhausted): #{safe_inspect(error, config)}"
        end)
      end
    }

    if config.log_deltas do
      Map.put(callback_map, :on_llm_new_delta, fn chain, deltas ->
        agent_id = get_agent_id(chain)

        log_event(config, agent_id, "LLM_NEW_DELTA", fn ->
          Enum.map_join(deltas, "\n", &safe_inspect(&1, config))
        end)
      end)
    else
      callback_map
    end
  end

  # -- Internal Helpers --

  @doc false
  def log_path(config, agent_id) do
    sanitized_id = sanitize_agent_id(agent_id)
    Path.join(config.log_dir, "#{config.prefix}_#{config.start_timestamp}_#{sanitized_id}.log")
  end

  defp log_event(config, agent_id, event_name, content_fn) do
    try do
      path = log_path(config, agent_id)
      ensure_log_dir(config.log_dir)

      timestamp = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S.%fZ")
      content = content_fn.()

      entry =
        IO.iodata_to_binary([
          "\n",
          @separator,
          "\n[",
          timestamp,
          "] ",
          event_name,
          "\n",
          @separator,
          "\n",
          content,
          "\n"
        ])

      File.write(path, entry, [:append])
    rescue
      error ->
        Logger.warning("DebugLog middleware failed to write log: #{Exception.message(error)}")
    end
  end

  defp ensure_log_dir(log_dir) do
    File.mkdir_p(log_dir)
  end

  defp sanitize_agent_id(agent_id) when is_binary(agent_id) do
    String.replace(agent_id, ~r/[^\w\-.]/, "_")
  end

  defp sanitize_agent_id(agent_id), do: sanitize_agent_id(to_string(agent_id))

  defp format_timestamp_for_filename(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%dT%H-%M-%S")
  end

  defp safe_inspect(term, config) do
    try do
      inspect_opts = [
        limit: config.inspect_limit,
        pretty: config.pretty,
        width: 120
      ]

      inspect(term, inspect_opts)
    rescue
      _ -> "<inspect failed>"
    end
  end

  defp get_agent_id(chain) do
    try do
      chain.custom_context.state.agent_id
    rescue
      _ -> "unknown"
    end
  end
end
