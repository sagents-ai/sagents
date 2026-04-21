defmodule Sagents.Middleware.FileSystem do
  @moduledoc """
  Middleware that adds virtual filesystem capabilities to agents.

  Provides tools for file operations in an isolated, persistable filesystem:
  - `list_files`: List all files (with optional pattern filtering)
  - `read_file`: Read file contents with line numbers and pagination
  - `create_file`: Create new files (errors if file exists)
  - `replace_file_text`: Make targeted edits with string replacement
  - `replace_file_lines`: Replace a range of lines by line number
  - `find_in_file`: Find text or regex matches within a single file
  - `delete_file`: Delete files from the filesystem
  - `move_file`: Move or rename files and directories

  ## Usage

      {:ok, agent} = Agent.new(
        model: model,
        middleware: [Filesystem]
      )

      # Agent can now use filesystem tools

  ## Configuration

  ### Basic Configuration

  - `:filesystem_scope` - Scope tuple identifying the filesystem (e.g. `{:agent, id}`,
    `{:user, id}`, `{:project, id}`)
  - `:enabled_tools` - List of tool names to enable (default: all tools)
  - `:custom_tool_descriptions` - Map of custom descriptions per tool
  - `:custom_display_texts` - Map of custom `display_text` labels (per tool)
    shown in the UI when the tool runs. Useful when a consuming project wants
    user-facing language different from the defaults (e.g. `"Writing document"`
    instead of `"Creating file"`).

  ### Selective Tool Enabling

  Enable only specific tools (e.g., read-only access):

      {:ok, agent} = Agent.new(
        model: model,
        filesystem_opts: [
          enabled_tools: ["list_files", "read_file"]  # Read-only
        ]
      )

  Available tools: `"list_files"`, `"read_file"`, `"create_file"`, `"replace_file_text"`,
  `"replace_file_lines"`, `"find_in_file"`, `"delete_file"`, `"move_file"`

  ### Custom Tool Descriptions

  Override default tool descriptions:

      {:ok, agent} = Agent.new(
        model: model,
        filesystem_opts: [
          custom_tool_descriptions: %{
            "read_file" => "Custom description for reading files...",
            "create_file" => "Custom description for creating files..."
          }
        ]
      )

  ### Custom Display Texts

  Override the default UI label shown when a tool runs. Only the tools you
  specify are overridden; the rest keep their defaults.

      {:ok, agent} = Agent.new(
        model: model,
        filesystem_opts: [
          custom_display_texts: %{
            "create_file" => "Writing document",
            "delete_file" => "Removing document"
          }
        ]
      )

  ## File Organization

  Use hierarchical paths to organize files:

      create_file(file_path: "/reports/q1-summary.md", content: "...")
      create_file(file_path: "/images/diagram.png", content: "...")
      list_files(pattern: "/reports/*")

  ## Pattern Filtering

  The `list_files` tool supports wildcard patterns:
  - `*` matches any characters
  - Examples: `*summary*`, `*.md`, `reports/*`

  ## Path Security

  Paths are validated to prevent security issues:
  - Paths must start with "/"
  - Path traversal attempts ("..") are rejected
  - Home directory shortcuts ("~") are rejected
  """

  @behaviour Sagents.Middleware

  require Logger
  alias LangChain.Function
  alias Sagents.FileSystem.FileEntry
  alias Sagents.FileSystemServer
  alias Sagents.TextLines

  @default_enabled_tools [
    "list_files",
    "read_file",
    "create_file",
    "replace_file_text",
    "replace_file_lines",
    "find_in_file",
    "delete_file",
    "move_file"
  ]

  # Default `display_text` per tool. Single source of truth so the defaults
  # aren't scattered across builder functions and `get_display_text/2` can
  # fall back consistently.
  @default_display_texts %{
    "list_files" => "Listing files",
    "read_file" => "Reading file",
    "create_file" => "Creating file",
    "replace_file_text" => "Replacing file text",
    "replace_file_lines" => "Replacing file lines",
    "find_in_file" => "Searching file",
    "delete_file" => "Deleting file",
    "move_file" => "Moving file"
  }

  # Per-tool bullet for the "You have access to..." list. Keyed by tool name so
  # enabling/disabling a tool via `:enabled_tools` adds/removes exactly one line.
  @tool_descriptions %{
    "list_files" =>
      "`list_files`: List files — returns a JSON array of file entries with metadata (path, size, etc.). Optionally filter by wildcard pattern.",
    "read_file" => "`read_file`: Read file contents with line numbers and pagination.",
    "create_file" =>
      "`create_file`: Create a new file with content. Errors if the file already exists.",
    "replace_file_text" =>
      "`replace_file_text`: Replace a string with another string in an existing file. The old_string must appear exactly once unless replace_all is set.",
    "replace_file_lines" =>
      "`replace_file_lines`: Replace a range of lines (by line number) with new content. More token-efficient than replace_file_text for large block replacements.",
    "find_in_file" =>
      "`find_in_file`: Find text or regex matches within a single file. Requires an exact file path — use `list_files` first to discover paths.",
    "delete_file" => "`delete_file`: Delete a file from the filesystem.",
    "move_file" => "`move_file`: Move or rename a file."
  }

  # Per-tool best-practice bullet(s). A tool may contribute multiple lines.
  # Lines are dropped entirely when the tool isn't enabled, so the prompt
  # never advises using a tool the agent can't call.
  @tool_best_practices %{
    "list_files" => ["Always use `list_files` first to see available files"],
    "read_file" => ["Read files before editing to understand content"],
    "create_file" => ["Use `create_file` only for new files (errors if file exists)"],
    "replace_file_text" => [
      "Use `replace_file_text` for small, targeted edits where you have the exact text",
      "Provide sufficient context in `old_string` for `replace_file_text` to ensure unique matches"
    ],
    "replace_file_lines" => [
      "Use `replace_file_lines` for large block replacements (more token-efficient)"
    ],
    "find_in_file" => [],
    "move_file" => ["Use `move_file` to rename files or move them to a different path"],
    "delete_file" => ["Never `delete_file` without first using `list_files` to locate it"]
  }

  # Compile-time guarantee that every known tool has a description and
  # best-practices entry. Adding a tool to `@default_enabled_tools` without
  # updating these maps will fail the build.
  for tool <- @default_enabled_tools do
    unless Map.has_key?(@tool_descriptions, tool) do
      raise "Missing @tool_descriptions entry for #{inspect(tool)}"
    end

    unless Map.has_key?(@tool_best_practices, tool) do
      raise "Missing @tool_best_practices entry for #{inspect(tool)}"
    end
  end

  @prompt_header "## Virtual Filesystem\n\nYou have access to a virtual filesystem with these tools:"

  @prompt_file_organization """
  ### File Organization

  Use hierarchical paths to organize files logically:
  - All paths must start with a forward slash "/"
  - Examples: "/notes.txt", "/reports/q1-summary.md", "/data/results.csv"
  - No path traversal ("..") or home directory ("~") allowed\
  """

  @prompt_pattern_filtering """
  ## Pattern Filtering

  The `list_files` tool supports wildcard patterns:
  - `*` matches any characters
  - Examples: `*summary*`, `*.md`, `/reports/*`\
  """

  @prompt_persistence """
  ### Persistence Behavior

  - Different directories may have different persistence settings
  - Some directories may be read-only (you can read but not write)
  - Large or archived files may load slowly on first access\
  """

  @impl true
  def init(opts) do
    # Support both new filesystem_scope and old agent_id (backward compatible)
    filesystem_scope =
      case Keyword.get(opts, :filesystem_scope) do
        nil ->
          # Backward compatible: use agent_id wrapped in tuple
          agent_id = Keyword.fetch!(opts, :agent_id)
          {:agent, agent_id}

        scope when is_tuple(scope) ->
          # Use provided scope: {:user, 123}, {:project, 456}, etc.
          scope
      end

    enabled_tools = Keyword.get(opts, :enabled_tools, @default_enabled_tools)
    custom_tool_descriptions = Keyword.get(opts, :custom_tool_descriptions, %{})
    custom_display_texts = Keyword.get(opts, :custom_display_texts, %{})

    with :ok <- validate_enabled_tools(enabled_tools),
         :ok <- validate_custom_tool_descriptions(custom_tool_descriptions),
         :ok <- validate_custom_display_texts(custom_display_texts) do
      config = %{
        filesystem_scope: filesystem_scope,
        # Tool configuration
        enabled_tools: enabled_tools,
        custom_tool_descriptions: custom_tool_descriptions,
        custom_display_texts: custom_display_texts
      }

      {:ok, config}
    end
  end

  # Rejects unknown tool names in `:enabled_tools` so misconfigured middleware
  # fails fast at agent construction (rather than silently dropping the entry
  # in `tools/1`). This is especially useful when a tool is renamed: stale
  # config will surface immediately instead of becoming a silent no-op.
  defp validate_enabled_tools(enabled_tools) when is_list(enabled_tools) do
    unknown = Enum.reject(enabled_tools, &(&1 in @default_enabled_tools))

    if unknown == [] do
      :ok
    else
      {:error,
       "Unknown tool name(s) in :enabled_tools: #{inspect(unknown)}. " <>
         "Valid tools: #{inspect(@default_enabled_tools)}."}
    end
  end

  defp validate_enabled_tools(other) do
    {:error, ":enabled_tools must be a list of tool name strings, got: #{inspect(other)}"}
  end

  # Rejects unknown keys in `:custom_tool_descriptions`. Same rationale as
  # `validate_enabled_tools/1`: a stale key from a renamed tool is silently
  # ignored at lookup time (`get_custom_description/3`), which makes typos
  # and migration leftovers invisible. Validates against the full set of
  # known tools — not just the currently-enabled subset — so a description
  # for a tool the user has temporarily disabled is still allowed.
  defp validate_custom_tool_descriptions(descriptions) when is_map(descriptions) do
    unknown =
      descriptions
      |> Map.keys()
      |> Enum.reject(&(&1 in @default_enabled_tools))

    if unknown == [] do
      :ok
    else
      {:error,
       "Unknown tool name(s) in :custom_tool_descriptions: #{inspect(unknown)}. " <>
         "Valid tools: #{inspect(@default_enabled_tools)}."}
    end
  end

  defp validate_custom_tool_descriptions(other) do
    {:error,
     ":custom_tool_descriptions must be a map of tool name strings to descriptions, got: #{inspect(other)}"}
  end

  # Same validation shape as `validate_custom_tool_descriptions/1`: reject
  # unknown tool names so typos/stale keys surface at construction time
  # rather than silently falling through to the default at lookup time.
  # Also validates values are strings — `display_text` is always rendered in
  # the UI, so a non-string value is a programming error worth catching early.
  defp validate_custom_display_texts(display_texts) when is_map(display_texts) do
    unknown =
      display_texts
      |> Map.keys()
      |> Enum.reject(&(&1 in @default_enabled_tools))

    non_string =
      display_texts
      |> Enum.reject(fn {_k, v} -> is_binary(v) end)

    cond do
      unknown != [] ->
        {:error,
         "Unknown tool name(s) in :custom_display_texts: #{inspect(unknown)}. " <>
           "Valid tools: #{inspect(@default_enabled_tools)}."}

      non_string != [] ->
        {:error, ":custom_display_texts values must be strings, got: #{inspect(non_string)}"}

      true ->
        :ok
    end
  end

  defp validate_custom_display_texts(other) do
    {:error,
     ":custom_display_texts must be a map of tool name strings to display text strings, got: #{inspect(other)}"}
  end

  @impl true
  def system_prompt(config) do
    enabled = Map.get(config, :enabled_tools, @default_enabled_tools)

    [
      @prompt_header <> "\n" <> tool_list_section(enabled),
      @prompt_file_organization,
      maybe_pattern_filtering_section(enabled),
      best_practices_section(enabled),
      @prompt_persistence
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # Emit bullets in canonical (`@default_enabled_tools`) order so the prompt
  # is deterministic regardless of how the user ordered their `:enabled_tools`.
  defp tool_list_section(enabled) do
    @default_enabled_tools
    |> Enum.filter(&(&1 in enabled))
    |> Enum.map(&("- " <> Map.fetch!(@tool_descriptions, &1)))
    |> Enum.join("\n")
  end

  defp maybe_pattern_filtering_section(enabled) do
    if "list_files" in enabled, do: @prompt_pattern_filtering
  end

  defp best_practices_section(enabled) do
    bullets =
      @default_enabled_tools
      |> Enum.filter(&(&1 in enabled))
      |> Enum.flat_map(&Map.fetch!(@tool_best_practices, &1))

    case bullets do
      [] ->
        nil

      lines ->
        "### Best Practices\n\n" <> Enum.map_join(lines, "\n", &("- " <> &1))
    end
  end

  @impl true
  def tools(config) do
    all_tools = %{
      "list_files" => build_list_files_tool(config),
      "read_file" => build_read_file_tool(config),
      "create_file" => build_create_file_tool(config),
      "replace_file_text" => build_replace_text_tool(config),
      "replace_file_lines" => build_replace_lines_tool(config),
      "find_in_file" => build_find_in_file_tool(config),
      "delete_file" => build_delete_file_tool(config),
      "move_file" => build_move_file_tool(config)
    }

    enabled_tools = Map.get(config, :enabled_tools, @default_enabled_tools)

    enabled_tools
    |> Enum.map(fn tool_name -> Map.get(all_tools, tool_name) end)
    |> Enum.reject(&is_nil/1)
  end

  @impl true
  def state_schema do
    # Files are stored in state.files as %{file_path => content}
    []
  end

  # Tool builders

  defp build_list_files_tool(config) do
    default_description = """
    Lists files in the filesystem, optionally filtering by wildcard pattern.

    Returns a JSON array of file entries with metadata (path, title, file_type, size, etc.).

    Wildcard patterns:
    - Use '*' to match any characters
    - Examples: '*summary*', '*.md', '/reports/*'

    You should almost ALWAYS use this tool before using the read or replace tools.
    """

    description = get_custom_description(config, "list_files", default_description)

    Function.new!(%{
      name: "list_files",
      description: description,
      display_text: get_display_text(config, "list_files"),
      parameters_schema: %{
        type: "object",
        properties: %{
          pattern: %{
            type: "string",
            description:
              "Optional wildcard pattern to filter files (e.g., '*summary*', '*.md', '/reports/*')"
          }
        }
      },
      function: fn args, context -> execute_list_files_tool(args, context, config) end
    })
  end

  defp build_read_file_tool(config) do
    default_description = """
    Read a file's contents with line numbers.

    Supports pagination with start_line and limit parameters. Line numbers are
    1-based and match those used by `replace_file_lines` and `find_in_file`.

    ## Output format

    Results are returned in a `cat -n`-style format — each line is prefixed with
    its 1-based line number (right-aligned, 6-char width) and a tab separator,
    then the actual line content. Example:

        41	Feel free to groan at any time! 😄

    The line number prefix is rendering metadata, NOT part of the file content.
    When passing text back to `replace_file_lines` or `replace_file_text`, send
    only the content that appears AFTER the tab separator. Never include the
    `    N\\t` prefix in `new_content`, `old_string`, or `new_string` — doing so
    will write the line number prefix into the file and corrupt it.

    ## Usage tips

    - For large files: read in chunks with `start_line` and `limit`.
    - For editing: always read first to verify current line numbers, then make
      the edit. Line numbers shift after every edit, so re-read between edits.
    """

    description = get_custom_description(config, "read_file", default_description)

    Function.new!(%{
      name: "read_file",
      description: description,
      display_text: get_display_text(config, "read_file"),
      parameters_schema: %{
        type: "object",
        properties: %{
          file_path: %{
            type: "string",
            description: "Path to the file to read"
          },
          start_line: %{
            type: "integer",
            description:
              "1-based line number to start reading from. Matches " <>
                "`replace_file_lines`'s start_line so the same number refers " <>
                "to the same line across tools. Default: 1 (start of file).",
            default: 1
          },
          limit: %{
            type: "integer",
            description: "Maximum number of lines to read",
            default: 2000
          }
        },
        required: ["file_path"]
      },
      function: fn args, context -> execute_read_file_tool(args, context, config) end
    })
  end

  defp build_create_file_tool(config) do
    default_description = """
    Create a new file with content.

    This tool only creates new files. If the file already exists, an error will be
    returned — use replace_file_text or replace_file_lines to modify existing files instead.
    """

    description = get_custom_description(config, "create_file", default_description)

    Function.new!(%{
      name: "create_file",
      description: description,
      display_text: get_display_text(config, "create_file"),
      parameters_schema: %{
        type: "object",
        properties: %{
          file_path: %{
            type: "string",
            description: "Path where the file should be created"
          },
          content: %{
            type: "string",
            description: "Content to write to the file"
          }
        },
        required: ["file_path", "content"]
      },
      function: fn args, context -> execute_create_file_tool(args, context, config) end
    })
  end

  defp build_replace_text_tool(config) do
    default_description = """
    Replace a string with another string in an existing file.

    By default, the old_string must appear exactly once in the file (for safety).
    Use replace_all: true to replace every occurrence.

    For large block replacements where you have line numbers, prefer replace_file_lines —
    it is significantly more token-efficient.

    ## Critical: do not include read_file's line-number prefixes

    `read_file` renders content in `cat -n` format: each line prefixed with
    `    N\\t` (right-aligned 6-char line number + tab + content). That prefix
    is rendering metadata, NOT part of the file. When you copy text from
    read_file's output into `old_string` or `new_string`, include only what
    appears AFTER the tab separator. Including the `    N\\t` prefix will
    cause the search to miss (old_string wouldn't match the actual file) or,
    for new_string, write the line numbers literally into the file.

    Preserve the exact indentation (tabs/spaces) that appears after the tab
    separator — that indentation IS part of the file content.
    """

    description = get_custom_description(config, "replace_file_text", default_description)

    Function.new!(%{
      name: "replace_file_text",
      description: description,
      display_text: get_display_text(config, "replace_file_text"),
      parameters_schema: %{
        type: "object",
        properties: %{
          file_path: %{
            type: "string",
            description: "Path to the file to edit"
          },
          old_string: %{
            type: "string",
            description: "String to find and replace (must be unique unless replace_all is true)"
          },
          new_string: %{
            type: "string",
            description: "String to replace old_string with"
          },
          replace_all: %{
            type: "boolean",
            description: "If true, replace all occurrences. If false, require exactly one match.",
            default: false
          }
        },
        required: ["file_path", "old_string", "new_string"]
      },
      function: fn args, context -> execute_replace_text_tool(args, context, config) end
    })
  end

  defp build_delete_file_tool(config) do
    default_description = """
    Delete a file from the filesystem.

    Removes the file from both memory and persistence (if applicable).
    Files in read-only directories cannot be deleted.
    """

    description = get_custom_description(config, "delete_file", default_description)

    Function.new!(%{
      name: "delete_file",
      description: description,
      display_text: get_display_text(config, "delete_file"),
      parameters_schema: %{
        type: "object",
        properties: %{
          file_path: %{
            type: "string",
            description: "Path to the file to delete"
          }
        },
        required: ["file_path"]
      },
      function: fn args, context -> execute_delete_file_tool(args, context, config) end
    })
  end

  defp build_move_file_tool(config) do
    default_description = """
    Moves or renames a file or directory to a new path.

    Usage:
    - Provide the current path (old_path) and the desired new path (new_path)
    - Works for both files and directories (moves all children too)
    - Use this to rename files or reorganize the directory structure
    - The target path must not already exist

    Examples (call with a JSON object matching the schema):
    - Rename a file: {"old_path": "/draft.txt", "new_path": "/final.txt"}
    - Move to a directory: {"old_path": "/notes.txt", "new_path": "/archive/notes.txt"}
    - Rename a directory: {"old_path": "/drafts", "new_path": "/published"}
    """

    description = get_custom_description(config, "move_file", default_description)

    Function.new!(%{
      name: "move_file",
      description: description,
      display_text: get_display_text(config, "move_file"),
      parameters_schema: %{
        type: "object",
        properties: %{
          old_path: %{
            type: "string",
            description: "Current path of the file or directory to move"
          },
          new_path: %{
            type: "string",
            description: "New path for the file or directory"
          }
        },
        required: ["old_path", "new_path"]
      },
      function: fn args, context -> execute_move_file_tool(args, context, config) end
    })
  end

  defp build_find_in_file_tool(config) do
    default_description = """
    Find text or regex matches within a single file.

    Returns matches with line numbers and optional surrounding context lines.
    This tool searches one specific file at a time. To search across multiple
    files, call `list_files` first to discover paths, then call `find_in_file`
    for each path you want to search.

    Wildcards and glob patterns (e.g. `/chapters/*`) are NOT supported in
    `file_path` — provide an exact path. Use `list_files` with a pattern to
    enumerate matching files first.

    Usage:
    - Provide pattern (required) - text or regex to search for
    - Provide file_path (required) - exact path to the file to search
    - Set case_sensitive (optional, default: true)
    - Set context_lines (optional, default: 0) - lines before/after to show
    - Set max_results (optional, default: 50) - limit number of results

    Examples (call with a JSON object matching the schema):
    - Find a literal string: {"pattern": "TODO", "file_path": "/notes.txt"}
    - Case-insensitive: {"pattern": "important", "file_path": "/notes.txt", "case_sensitive": false}
    - With surrounding context: {"pattern": "error", "file_path": "/app.log", "context_lines": 2}
    - Regex pattern: {"pattern": "error\\\\d+", "file_path": "/app.log"}
    """

    description = get_custom_description(config, "find_in_file", default_description)

    Function.new!(%{
      name: "find_in_file",
      description: description,
      display_text: get_display_text(config, "find_in_file"),
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Text or regex pattern to search for"
          },
          "file_path" => %{
            "type" => "string",
            "description" =>
              "Exact path of the file to search (e.g. '/notes.txt'). Wildcards/globs are not supported."
          },
          "case_sensitive" => %{
            "type" => "boolean",
            "description" => "Whether the search should be case-sensitive",
            "default" => true
          },
          "context_lines" => %{
            "type" => "integer",
            "description" => "Number of lines before and after each match to show",
            "default" => 0
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of matches to return",
            "default" => 50
          }
        },
        "required" => ["pattern", "file_path"]
      },
      function: fn args, context -> execute_find_in_file_tool(args, context, config) end
    })
  end

  defp build_replace_lines_tool(config) do
    default_description = """
    Replace a range of lines (by line number) with new content. Line numbers are
    1-based and the range is inclusive (both start_line and end_line are replaced).

    This tool is significantly more token-efficient than replace_file_text for large
    block replacements — you don't need to send the original content character-
    for-character, just the line range.

    The return value includes a preview of the edited region (2 lines of
    context before and after the affected range, with post-edit line numbers)
    so you can verify the edit succeeded without issuing a follow-up read_file.

    ## Deleting lines and inserting blank lines

    `new_content` has two special values you should know about:

    - `new_content: ""` — **DELETES** the targeted line(s) entirely. The lines
      are removed and the surrounding content closes up. Use this whenever you
      want a line gone. Example: to delete line 69, call with start_line=69,
      end_line=69, new_content="".
    - `new_content: "\\n"` — **INSERTS** exactly one blank line in place of the
      range. Use this (not "") when you deliberately want to replace the range
      with an empty line rather than remove it.

    A trailing `\\n` on non-empty content (e.g. "foo\\n") is treated as a line
    terminator, not as an instruction to append a blank line — so "foo" and
    "foo\\n" produce the same result: one line containing "foo".

    ## Best Practices

    - ALWAYS use read_file first to see the current line numbers. Line numbers
      shift after every edit, so re-read between edits if you're making multiple
      changes to the same file.
    - Carefully verify start_line and end_line before calling. Wrong line numbers
      will destructively replace the wrong content with no way to undo.
    - NEVER include the `    N\\t` line-number prefix from read_file's output
      in `new_content`. That prefix is rendering metadata, not file content —
      including it will write the line numbers literally into the file and
      corrupt it. Copy only what appears AFTER the tab separator.
    - Preserve the exact indentation (tabs/spaces) from the content you saw
      after the tab separator in read_file's output.
    - For small, targeted edits where you know the exact text, use replace_file_text
      instead — it has a built-in safety check (the old_string must match).
    - For multi-line replacements where you have line numbers from a recent
      read_file, this tool is the right choice.
    - To APPEND content to a file, replace the real last line with itself plus
      the new content (e.g. if the file has 41 lines, call with start_line=41,
      end_line=41, new_content="<line 41's current content>\\n<new lines>").
      A file's trailing newline is a terminator — there is no "line 42" to
      target. The trailing newline is preserved automatically on save.

    ## Examples

    Call with a JSON object matching the schema:

    - Replace lines 10-15:
      {"file_path": "/doc.txt", "start_line": 10, "end_line": 15, "new_content": "new text"}
    - Replace a single line:
      {"file_path": "/doc.txt", "start_line": 42, "end_line": 42, "new_content": "new line"}
    - Replace a large block:
      {"file_path": "/notes/research.md", "start_line": 120, "end_line": 135, "new_content": "..."}
    - Delete lines 30-32 entirely:
      {"file_path": "/doc.txt", "start_line": 30, "end_line": 32, "new_content": ""}
    - Replace line 10 with a single blank line:
      {"file_path": "/doc.txt", "start_line": 10, "end_line": 10, "new_content": "\\n"}
    """

    description = get_custom_description(config, "replace_file_lines", default_description)

    Function.new!(%{
      name: "replace_file_lines",
      description: description,
      display_text: get_display_text(config, "replace_file_lines"),
      parameters_schema: %{
        type: "object",
        properties: %{
          file_path: %{
            type: "string",
            description: "Path to the file to edit"
          },
          start_line: %{
            type: "integer",
            description: "Starting line number (1-based, inclusive)"
          },
          end_line: %{
            type: "integer",
            description: "Ending line number (1-based, inclusive)"
          },
          new_content: %{
            type: "string",
            description:
              "New content to replace the line range. Can be multi-line. " <>
                "Special values: \"\" deletes the range entirely (lines are removed); " <>
                "\"\\n\" inserts a single blank line. " <>
                "A trailing newline on non-empty content is treated as a terminator, not an extra blank line."
          }
        },
        required: ["file_path", "start_line", "end_line", "new_content"]
      },
      function: fn args, context -> execute_replace_lines_tool(args, context, config) end
    })
  end

  # Tool execution functions

  defp execute_list_files_tool(args, _context, config) do
    pattern = get_arg(args, "pattern")

    # List all entries using FileSystemServer (returns FileEntry structs with metadata)
    all_entries = FileSystemServer.list_entries(config.filesystem_scope)

    # Apply pattern filtering
    filtered_entries = filter_entries_by_pattern(all_entries, pattern)

    if Enum.empty?(filtered_entries) do
      if pattern do
        {:ok, "No files match pattern: #{pattern}"}
      else
        {:ok, "No files in filesystem"}
      end
    else
      entry_maps = Enum.map(filtered_entries, &FileEntry.to_llm_map/1)
      {:ok, Jason.encode!(entry_maps)}
    end
  rescue
    e ->
      {:error, "Filesystem not available: #{Exception.message(e)}"}
  end

  defp execute_read_file_tool(args, _context, config) do
    file_path = get_arg(args, "file_path")
    start_line = get_arg(args, "start_line") || 1
    limit = get_arg(args, "limit") || 2000

    # Validate path
    with {:ok, normalized_path} <- validate_path(file_path) do
      # Read file using FileSystemServer (handles lazy loading automatically)
      case FileSystemServer.read_file(config.filesystem_scope, normalized_path) do
        {:ok, entry} ->
          format_file_content(entry.content || "", normalized_path, start_line, limit)

        {:error, :enoent} ->
          {:error, "File not found: #{normalized_path}"}

        {:error, reason} ->
          {:error, "Failed to read file: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      {:error, "Filesystem not available: #{Exception.message(e)}"}
  end

  defp format_file_content(content, _file_path, start_line, limit) do
    {formatted, rendered_start, rendered_end, _total} =
      TextLines.render(content, start_line: start_line, limit: limit)

    result =
      if rendered_end < rendered_start do
        "File is empty or start_line is beyond file length."
      else
        formatted
      end

    {:ok, result}
  end

  defp execute_create_file_tool(args, _context, config) do
    file_path = get_arg(args, "file_path")
    content = get_arg(args, "content")

    cond do
      is_nil(file_path) or is_nil(content) ->
        {:error, "Both file_path and content are required"}

      true ->
        # Validate path
        with {:ok, normalized_path} <- validate_path(file_path) do
          # Check if file already exists (overwrite protection)
          if FileSystemServer.file_exists?(config.filesystem_scope, normalized_path) do
            {:error,
             "File already exists: #{normalized_path}. Use replace_file_text or replace_file_lines to modify existing files."}
          else
            # Write file using FileSystemServer
            case FileSystemServer.write_file(
                   config.filesystem_scope,
                   normalized_path,
                   content
                 ) do
              {:ok, entry} ->
                {:ok, Jason.encode!(FileEntry.to_llm_map(entry))}

              {:error, reason} ->
                {:error, "Failed to create file: #{inspect(reason)}"}
            end
          end
        else
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      {:error, "Filesystem not available: #{Exception.message(e)}"}
  end

  defp execute_replace_text_tool(args, _context, config) do
    file_path = get_arg(args, "file_path")
    old_string = get_arg(args, "old_string")
    new_string = get_arg(args, "new_string")
    replace_all = get_boolean_arg(args, "replace_all", false)

    cond do
      is_nil(file_path) or is_nil(old_string) or is_nil(new_string) ->
        {:error, "file_path, old_string, and new_string are required"}

      true ->
        # Validate path
        with {:ok, normalized_path} <- validate_path(file_path) do
          # Read current content using FileSystemServer
          case FileSystemServer.read_file(config.filesystem_scope, normalized_path) do
            {:ok, entry} ->
              perform_text_replacement(
                config.filesystem_scope,
                normalized_path,
                entry.content || "",
                old_string,
                new_string,
                replace_all
              )

            {:error, :enoent} ->
              {:error, "File not found: #{normalized_path}"}

            {:error, reason} ->
              {:error, "Failed to read file: #{inspect(reason)}"}
          end
        else
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      {:error, "Filesystem not available: #{Exception.message(e)}"}
  end

  defp execute_delete_file_tool(args, _context, config) do
    file_path = get_arg(args, "file_path")

    cond do
      is_nil(file_path) ->
        {:error, "file_path is required"}

      true ->
        # Validate path
        with {:ok, normalized_path} <- validate_path(file_path) do
          # Delete file using FileSystemServer
          case FileSystemServer.delete_file(config.filesystem_scope, normalized_path) do
            :ok ->
              {:ok, "File deleted successfully: #{normalized_path}"}

            {:error, reason} ->
              {:error, "Failed to delete file: #{inspect(reason)}"}
          end
        else
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      {:error, "Filesystem not available: #{Exception.message(e)}"}
  end

  defp execute_move_file_tool(args, _context, config) do
    old_path = get_arg(args, "old_path")
    new_path = get_arg(args, "new_path")

    cond do
      is_nil(old_path) or is_nil(new_path) ->
        {:error, "old_path and new_path are required"}

      true ->
        with {:ok, normalized_old} <- validate_path(old_path),
             {:ok, normalized_new} <- validate_path(new_path) do
          case FileSystemServer.move_file(
                 config.filesystem_scope,
                 normalized_old,
                 normalized_new
               ) do
            {:ok, moved_entries} ->
              {:ok,
               "Moved successfully: #{normalized_old} -> #{normalized_new} (#{length(moved_entries)} entries)"}

            {:error, :enoent} ->
              {:error, "File not found: #{normalized_old}"}

            {:error, :already_exists} ->
              {:error, "Target already exists: #{normalized_new}"}

            {:error, reason} ->
              {:error, "Failed to move file: #{inspect(reason)}"}
          end
        end
    end
  rescue
    e ->
      {:error, "Filesystem not available: #{Exception.message(e)}"}
  end

  defp execute_find_in_file_tool(args, _context, config) do
    pattern = get_arg(args, "pattern")
    file_path = get_arg(args, "file_path")
    case_sensitive = get_boolean_arg(args, "case_sensitive", true)
    context_lines = get_integer_arg(args, "context_lines", 0)
    max_results = get_integer_arg(args, "max_results", 50)

    cond do
      is_nil(pattern) ->
        {:error, "pattern is required"}

      is_nil(file_path) ->
        {:error, "file_path is required"}

      String.contains?(file_path, ["*", "?", "[", "]"]) ->
        {:error,
         "Wildcards and globs are not supported in file_path. Provide an exact file path (e.g., '/notes.txt'). Use list_files to discover matching files first."}

      true ->
        with {:ok, normalized_path} <- validate_path(file_path),
             {:ok, entry} <-
               FileSystemServer.read_file(config.filesystem_scope, normalized_path) do
          case TextLines.find(entry.content || "", pattern,
                 regex: true,
                 case_sensitive: case_sensitive,
                 context_lines: context_lines,
                 max_matches: max_results
               ) do
            {:ok, matches, truncated} ->
              format_search_results([{normalized_path, matches}], max_results, truncated)

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :enoent} ->
            {:error, "File not found: #{file_path}"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "Failed to search file: #{inspect(reason)}"}
        end
    end
  rescue
    e ->
      {:error, "Search failed: #{Exception.message(e)}"}
  end

  defp execute_replace_lines_tool(args, _context, config) do
    file_path = get_arg(args, "file_path")
    start_line = get_integer_arg(args, "start_line", nil)
    end_line = get_integer_arg(args, "end_line", nil)
    new_content = get_arg(args, "new_content")

    cond do
      is_nil(file_path) ->
        {:error, "file_path is required"}

      is_nil(start_line) or is_nil(end_line) ->
        {:error, "start_line and end_line are required"}

      is_nil(new_content) ->
        {:error, "new_content is required"}

      start_line < 1 ->
        {:error, "start_line must be >= 1 (line numbers are 1-based)"}

      end_line < start_line ->
        {:error, "end_line must be >= start_line"}

      true ->
        with {:ok, normalized_path} <- validate_path(file_path),
             {:ok, entry} <-
               FileSystemServer.read_file(config.filesystem_scope, normalized_path) do
          perform_line_replacement(
            config.filesystem_scope,
            normalized_path,
            entry.content || "",
            start_line,
            end_line,
            new_content
          )
        else
          {:error, :enoent} ->
            {:error, "File not found: #{file_path}"}

          {:error, reason} ->
            {:error, "Failed to read file: #{inspect(reason)}"}
        end
    end
  rescue
    e ->
      {:error, "Edit failed: #{Exception.message(e)}"}
  end

  defp format_search_results(results, max_results, truncated) do
    if Enum.empty?(results) or Enum.all?(results, fn {_, matches} -> Enum.empty?(matches) end) do
      {:ok, "No matches found"}
    else
      formatted =
        results
        |> Enum.flat_map(fn {file_path, matches} ->
          file_header = ["", "File: #{file_path}"]
          match_lines = Enum.map(matches, &format_match/1)
          file_header ++ match_lines
        end)
        |> Enum.join("\n")

      footer = if truncated, do: "\n\n(Results truncated at #{max_results} matches)", else: ""

      {:ok, formatted <> footer}
    end
  end

  defp format_match(%{
         line_number: line_num,
         line: line,
         context_before: context_before,
         context_after: context_after
       }) do
    before =
      context_before
      |> Enum.with_index()
      |> Enum.map(fn {ctx_line, idx} ->
        ctx_line_num = line_num - length(context_before) + idx
        formatted_num = String.pad_leading(Integer.to_string(ctx_line_num), 6)
        "#{formatted_num} |\t#{ctx_line}"
      end)
      |> Enum.join("\n")

    after_ctx =
      context_after
      |> Enum.with_index()
      |> Enum.map(fn {ctx_line, idx} ->
        ctx_line_num = line_num + idx + 1
        formatted_num = String.pad_leading(Integer.to_string(ctx_line_num), 6)
        "#{formatted_num} |\t#{ctx_line}"
      end)
      |> Enum.join("\n")

    formatted_line_num = String.pad_leading(Integer.to_string(line_num), 6)
    match_line = "#{formatted_line_num}\t#{line}"

    [before, match_line, after_ctx]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp perform_text_replacement(
         filesystem_scope,
         file_path,
         content,
         old_string,
         new_string,
         replace_all
       ) do
    case TextLines.replace_text(content, old_string, new_string, replace_all) do
      {:ok, updated_content, count} ->
        suffix = if count > 1, do: " (#{count} replacements)", else: ""

        write_edit(
          filesystem_scope,
          file_path,
          updated_content,
          "File edited successfully: #{file_path}#{suffix}"
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_edit(filesystem_scope, file_path, updated_content, success_message) do
    case FileSystemServer.write_file(filesystem_scope, file_path, updated_content) do
      {:ok, _entry} ->
        {:ok, success_message}

      {:error, reason} ->
        {:error, "Failed to save edit: #{inspect(reason)}"}
    end
  end

  # Number of context lines to include on each side of an edit's affected
  # range in the post-edit preview. Saves the model from issuing a follow-up
  # read_file just to verify the edit landed correctly. Kept small because
  # a single "line" can be an entire paragraph in markdown / prose content —
  # 2 on each side gives enough context to see what's adjacent without
  # inflating token cost for long-form documents.
  @replace_edit_context_lines 2

  defp perform_line_replacement(
         filesystem_scope,
         file_path,
         content,
         start_line,
         end_line,
         new_content
       ) do
    case TextLines.replace_range(content, start_line, end_line, new_content) do
      {:ok, updated_content, lines_replaced_count} ->
        case FileSystemServer.write_file(filesystem_scope, file_path, updated_content) do
          {:ok, _entry} ->
            preview = build_edit_preview(updated_content, start_line, new_content)

            {:ok,
             "File edited successfully: #{file_path}\n" <>
               "Replaced #{lines_replaced_count} lines (#{start_line}-#{end_line})\n\n" <>
               "Context after edit:\n#{preview}"}

          {:error, reason} ->
            {:error, "Failed to save edit: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Render a slice of the post-edit file showing the affected range plus
  # `@replace_edit_context_lines` lines on each side. For insertions/
  # replacements, the new lines are included. For deletions (new_content
  # is empty), just the context around the former range is shown.
  defp build_edit_preview(updated_content, start_line, new_content) do
    {_lines, total_after} = TextLines.split(updated_content)

    new_line_count =
      case new_content do
        "" -> 0
        other -> length(String.split(other, "\n"))
      end

    edit_end = start_line + max(new_line_count - 1, 0)

    show_start = max(1, start_line - @replace_edit_context_lines)
    show_end = min(total_after, edit_end + @replace_edit_context_lines)
    limit = max(show_end - show_start + 1, 1)

    {formatted, _, _, _} = TextLines.render(updated_content, start_line: show_start, limit: limit)
    formatted
  end

  defp get_arg(nil = _args, _key), do: nil

  defp get_arg(args, key) when is_map(args) do
    # Use Map.get to avoid issues with false values
    case Map.get(args, key) do
      nil -> Map.get(args, String.to_atom(key))
      value -> value
    end
  end

  defp get_boolean_arg(args, key, default) when is_map(args) do
    case get_arg(args, key) do
      nil -> default
      val when is_boolean(val) -> val
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp get_integer_arg(args, key, default) when is_map(args) do
    case get_arg(args, key) do
      nil -> default
      val when is_integer(val) -> val
      val when is_binary(val) -> String.to_integer(val)
      _ -> default
    end
  end

  defp filter_entries_by_pattern(entries, nil), do: entries

  defp filter_entries_by_pattern(entries, pattern) do
    # Convert wildcard pattern to regex
    # "*summary*" -> ~r/.*summary.*/
    # "Chapter 1/*" -> ~r/Chapter 1\/.*/
    # "*.md" -> ~r/.*\.md/
    regex_pattern =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")
      |> then(&Regex.compile!(&1))

    Enum.filter(entries, &Regex.match?(regex_pattern, &1.path))
  end

  # Path validation and security

  @doc false
  def validate_path(path) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, "Path cannot be empty"}

      not String.starts_with?(path, "/") ->
        {:error, "Path must start with '/' (e.g., '/notes.txt', '/data/file.csv')"}

      String.contains?(path, "..") ->
        {:error, "Path traversal with '..' is not allowed"}

      String.starts_with?(path, "~") ->
        {:error, "Home directory paths starting with '~' are not allowed"}

      true ->
        {:ok, normalize_path(path)}
    end
  end

  def validate_path(_path), do: {:error, "Path must be a string"}

  @doc false
  def normalize_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.replace(~r|/+|, "/")
  end

  @doc false
  def get_custom_description(config, tool_name, default_description) do
    custom_descriptions = Map.get(config, :custom_tool_descriptions, %{})
    Map.get(custom_descriptions, tool_name, default_description)
  end

  # Returns the configured display_text for a tool, falling back to the
  # default when no override is set. Public so the builder functions can
  # use it; it's a thin lookup, not an API contract.
  def get_display_text(config, tool_name) do
    config
    |> Map.get(:custom_display_texts, %{})
    |> Map.get(tool_name, Map.fetch!(@default_display_texts, tool_name))
  end
end
