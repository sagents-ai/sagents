defmodule Sagents.TextLines do
  @moduledoc """
  Pure helper for line-number math on text content.

  Shared by file system tools, document editing tools, and any other
  surface that needs consistent line-numbered text operations.
  All line numbers are **1-indexed**.

  The line-numbered format uses right-aligned 6-char numbers with a tab separator:

      "     1\tFirst line of content"
      "     2\t"
      "     3\tThird line"
  """

  @doc """
  Splits `body` on newlines and returns the total line count.
  An empty or nil body is treated as a single empty line.
  """
  @spec split(String.t() | nil) :: {list(String.t()), non_neg_integer()}
  def split(nil), do: {[""], 1}
  def split(""), do: {[""], 1}

  def split(body) when is_binary(body) do
    # `String.split("foo\nbar\n", "\n")` returns `["foo", "bar", ""]` — the
    # trailing empty element is an artifact of the line terminator, not a
    # real line. Keeping it mis-renders file lengths and misleads LLMs into
    # editing a phantom "last line". Drop it so line counts match human /
    # editor conventions. `replace_range/4` re-adds the terminator on save.
    lines =
      body
      |> String.split("\n")
      |> drop_trailing_empty()

    {lines, length(lines)}
  end

  defp drop_trailing_empty(lines) do
    case List.last(lines) do
      "" when length(lines) > 1 -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  @doc """
  Renders lines with right-aligned 6-char line numbers and a tab separator.

  Options:
    - `:start_line` - 1-indexed start line (default 1)
    - `:limit`      - max lines to return (default: all)

  Returns `{formatted_string, start_line, end_line, total_lines}`.
  """
  @spec render(String.t() | nil, keyword()) ::
          {String.t(), pos_integer(), pos_integer(), pos_integer()}
  def render(body, opts \\ []) do
    {lines, total} = split(body)
    start_line = max(Keyword.get(opts, :start_line, 1), 1)
    limit = Keyword.get(opts, :limit, total)

    # Convert 1-indexed start_line to 0-indexed for Enum.slice
    start_idx = start_line - 1

    selected =
      lines
      |> Enum.slice(start_idx, limit)
      |> Enum.with_index(start_line)
      |> Enum.map(fn {line, line_num} ->
        padded = String.pad_leading(Integer.to_string(line_num), 6)
        "#{padded}\t#{line}"
      end)

    end_line = start_line + length(selected) - 1

    formatted =
      if start_idx > 0 or end_line < total do
        "Showing lines #{start_line} to #{end_line} of #{total}:\n" <>
          Enum.join(selected, "\n")
      else
        Enum.join(selected, "\n")
      end

    {formatted, start_line, end_line, total}
  end

  @doc """
  Replaces lines `start_line..end_line` (1-indexed, inclusive) with
  `new_lines_text` and returns the rejoined body.

  `new_lines_text` semantics:
    - `""` deletes the targeted range (zero lines inserted)
    - `"\\n"` inserts exactly one blank line
    - A trailing `"\\n"` on non-empty content is a line terminator, not an
      extra blank line: `"foo\\n"` and `"foo"` both insert one line `"foo"`

  Returns `{:ok, new_body, lines_replaced}` or `{:error, reason}`.
  """
  @spec replace_range(String.t() | nil, pos_integer(), pos_integer(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, String.t()}
  def replace_range(body, start_line, end_line, new_lines_text) do
    {lines, total} = split(body)
    had_trailing_newline? = is_binary(body) and String.ends_with?(body, "\n")

    cond do
      start_line < 1 ->
        {:error, "start_line must be >= 1 (line numbers are 1-based)"}

      end_line < start_line ->
        {:error, "end_line (#{end_line}) must be >= start_line (#{start_line})"}

      start_line > total ->
        {:error,
         "start_line #{start_line} is beyond content length (#{total} lines). " <>
           "Re-read the content to get current line numbers."}

      end_line > total ->
        {:error,
         "end_line #{end_line} is beyond content length (#{total} lines). " <>
           "Re-read the content to get current line numbers."}

      true ->
        start_idx = start_line - 1
        end_idx = end_line - 1
        lines_replaced = end_idx - start_idx + 1

        before = Enum.slice(lines, 0, start_idx)
        after_lines = Enum.slice(lines, end_idx + 1, total - end_idx - 1)
        new_lines = split_new_content(new_lines_text)

        new_body = Enum.join(before ++ new_lines ++ after_lines, "\n")
        new_body = if had_trailing_newline?, do: new_body <> "\n", else: new_body

        {:ok, new_body, lines_replaced}
    end
  end

  # Splits replacement content into the list of lines to insert.
  #   ""          -> []           (delete the range)
  #   "\n"        -> [""]         (one blank line)
  #   "foo"       -> ["foo"]
  #   "foo\n"     -> ["foo"]      (trailing \n is a terminator)
  #   "foo\nbar"  -> ["foo", "bar"]
  defp split_new_content(""), do: []

  defp split_new_content(text) when is_binary(text) do
    stripped =
      if String.ends_with?(text, "\n") do
        binary_part(text, 0, byte_size(text) - 1)
      else
        text
      end

    String.split(stripped, "\n")
  end

  @doc """
  Counts occurrences of `old_string` in `body`.
  """
  @spec count_occurrences(String.t(), String.t()) :: non_neg_integer()
  def count_occurrences(body, old_string) do
    parts = String.split(body, old_string, parts: :infinity)
    length(parts) - 1
  end

  @doc """
  Replaces `old_string` in `body`.

  When `replace_all` is false, requires exactly one occurrence.
  Returns `{:ok, new_body, replacement_count}` or `{:error, reason}`.
  """
  @spec replace_text(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t(), pos_integer()} | {:error, String.t()}
  def replace_text(body, old_string, new_string, replace_all \\ false) do
    count = count_occurrences(body, old_string)

    cond do
      count == 0 ->
        {:error,
         "String not found. Use a search to locate " <>
           "the exact text, then retry with a corrected `old_string`."}

      count > 1 and not replace_all ->
        {:error,
         "String appears #{count} times. " <>
           "Add more surrounding context to `old_string` to make it unique, " <>
           "or pass `replace_all: true` to replace all #{count} occurrences."}

      count == 1 ->
        new_body = String.replace(body, old_string, new_string, global: false)
        {:ok, new_body, 1}

      true ->
        new_body = String.replace(body, old_string, new_string, global: true)
        {:ok, new_body, count}
    end
  end

  @doc """
  Finds matches of `pattern` in `body`, returning structured results
  with line numbers and optional context.

  Options:
    - `:regex` - treat pattern as regex (default false)
    - `:case_sensitive` - (default true)
    - `:context_lines` - lines of context before/after each match (default 2)
    - `:max_matches` - cap on returned matches (default 20)

  Returns `{:ok, matches, truncated?}` or `{:error, reason}`.
  Each match is `%{line_number: n, line: text, context_before: [...], context_after: [...]}`.
  """
  @spec find(String.t() | nil, String.t(), keyword()) ::
          {:ok, list(map()), boolean()} | {:error, String.t()}
  def find(body, pattern, opts \\ []) do
    is_regex = Keyword.get(opts, :regex, false)
    case_sensitive = Keyword.get(opts, :case_sensitive, true)
    context_lines = Keyword.get(opts, :context_lines, 2)
    max_matches = Keyword.get(opts, :max_matches, 20)

    case compile_pattern(pattern, is_regex, case_sensitive) do
      {:ok, regex} ->
        {lines, _total} = split(body)

        all_matches =
          lines
          |> Enum.with_index(1)
          |> Enum.reduce([], fn {line, line_num}, acc ->
            if Regex.match?(regex, line) do
              match = %{
                line_number: line_num,
                line: line,
                context_before: context_before(lines, line_num, context_lines),
                context_after: context_after(lines, line_num, context_lines)
              }

              [match | acc]
            else
              acc
            end
          end)
          |> Enum.reverse()

        truncated = length(all_matches) > max_matches
        matches = Enum.take(all_matches, max_matches)
        {:ok, matches, truncated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_pattern(pattern, false, case_sensitive) do
    escaped = Regex.escape(pattern)
    pattern_str = if case_sensitive, do: escaped, else: "(?i)#{escaped}"

    case Regex.compile(pattern_str) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:error, "Failed to compile escaped pattern: #{pattern}"}
    end
  end

  defp compile_pattern(pattern, true, case_sensitive) do
    pattern_str = if case_sensitive, do: pattern, else: "(?i)#{pattern}"

    case Regex.compile(pattern_str) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, "Invalid regex pattern: #{reason}"}
    end
  end

  defp context_before(lines, line_num, context_lines) do
    start_idx = max(0, line_num - 1 - context_lines)
    count = line_num - 1 - start_idx
    Enum.slice(lines, start_idx, count)
  end

  defp context_after(lines, line_num, context_lines) do
    total = length(lines)
    end_idx = min(total, line_num + context_lines)
    Enum.slice(lines, line_num, end_idx - line_num)
  end
end
