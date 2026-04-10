defmodule Sagents.Middleware.FileSystem do
  @moduledoc """
  Middleware that adds virtual filesystem capabilities to agents.

  Provides tools for file operations in an isolated, persistable filesystem:
  - `list_files`: List all files (with optional pattern filtering)
  - `read_file`: Read file contents with line numbers and pagination
  - `create_file`: Create new files (errors if file exists)
  - `replace_text`: Make targeted edits with string replacement
  - `replace_lines`: Replace a range of lines by line number
  - `update_file_attrs`: Update file attributes (title, tags, etc.) — no content changes
  - `search_text`: Search for text patterns within files or across all files
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
  - `:file_schema` - Module implementing `Sagents.FileSystem.FileSchema`. Defaults to
    `Sagents.FileSystem.FileEntry`, which provides basic file attributes
    (`:title`, `:id`, `:file_type`). Applications override with their own module to
    add custom attributes with validation.

  ### Selective Tool Enabling

  Enable only specific tools (e.g., read-only access):

      {:ok, agent} = Agent.new(
        model: model,
        filesystem_opts: [
          enabled_tools: ["list_files", "read_file"]  # Read-only
        ]
      )

  Available tools: `"list_files"`, `"read_file"`, `"create_file"`, `"replace_text"`,
  `"replace_lines"`, `"update_file_attrs"`, `"search_text"`, `"delete_file"`,
  `"move_file"`

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

  ### Custom File Schema

  The `:file_schema` option controls both how `FileEntry` structs are serialized
  to JSON for LLM tool results AND how LLM-supplied attribute updates are
  validated. The default `Sagents.FileSystem.FileEntry` provides basic file
  attributes. Provide your own module to add validated custom fields:

      defmodule MyApp.DocumentFileSchema do
        @behaviour Sagents.FileSystem.FileSchema

        use Ecto.Schema
        import Ecto.Changeset

        @primary_key false
        embedded_schema do
          field :title, :string
          field :system_tag, :string
          field :tags, {:array, :string}, default: []
        end

        @impl true
        def changeset(attrs) do
          %__MODULE__{}
          |> cast(attrs, [:title, :system_tag, :tags])
          |> validate_inclusion(:system_tag, ~w(draft review approved published))
        end

        @impl true
        def to_llm_map(entry), do: # ... build map from entry ...
      end

      {Sagents.Middleware.FileSystem, [
        filesystem_scope: {:project, project_id},
        file_schema: MyApp.DocumentFileSchema
      ]}

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
  alias LangChain.Utils
  alias Sagents.FileSystem.FileEntry
  alias Sagents.FileSystemServer

  # Fields that live directly on the FileEntry struct. Anything else in a
  # validated changeset is routed to metadata.custom.
  @entry_fields [:title, :id, :file_type]

  @default_enabled_tools [
    "list_files",
    "read_file",
    "create_file",
    "replace_text",
    "replace_lines",
    "update_file_attrs",
    "search_text",
    "delete_file",
    "move_file"
  ]

  @system_prompt """
  ## Filesystem Tools

  You have access to a virtual filesystem with these tools:
  - `list_files`: List files — returns a JSON array of file entries with metadata (path, title, file_type, size, etc.). Optionally filter by wildcard pattern.
  - `read_file`: Read file contents with line numbers and pagination.
  - `create_file`: Create a new file with content. Errors if the file already exists.
  - `replace_text`: Replace a string with another string in an existing file. The old_string must appear exactly once unless replace_all is set.
  - `replace_lines`: Replace a range of lines (by line number) with new content. More token-efficient than replace_text for large block replacements.
  - `update_file_attrs`: Update file attributes (title, tags, etc.) without modifying file content. Validated against the file schema.
  - `search_text`: Search for text patterns within or across files.
  - `delete_file`: Delete a file from the filesystem.
  - `move_file`: Move or rename a file or directory.

  ## File Organization

  Use hierarchical paths to organize files logically:
  - All paths must start with a forward slash "/"
  - Examples: "/notes.txt", "/reports/q1-summary.md", "/data/results.csv"
  - No path traversal ("..") or home directory ("~") allowed

  ## Pattern Filtering

  The `list_files` tool supports wildcard patterns:
  - `*` matches any characters
  - Examples: `*summary*`, `*.md`, `/reports/*`

  ## Best Practices

  - Always use `list_files` first to see available files
  - Read files before editing to understand content
  - Use `replace_text` for small, targeted edits where you have the exact text
  - Use `replace_lines` for large block replacements (more token-efficient)
  - Use `create_file` only for new files (errors if file exists)
  - Use `update_file_attrs` to change metadata like title or tags — never to change content
  - Provide sufficient context in `old_string` for `replace_text` to ensure unique matches
  - Group related files in the same directory
  - Use `move_file` to rename files or move them to a different directory
  - Never `delete_file` without first using `list_files` to locate it

  ## Persistence Behavior

  - Different directories may have different persistence settings
  - Some directories may be read-only (you can read but not write)
  - Large or archived files may load slowly on first access
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

    config = %{
      filesystem_scope: filesystem_scope,
      # Tool configuration
      enabled_tools: Keyword.get(opts, :enabled_tools, @default_enabled_tools),
      custom_tool_descriptions: Keyword.get(opts, :custom_tool_descriptions, %{}),
      file_schema: Keyword.get(opts, :file_schema, FileEntry)
    }

    {:ok, config}
  end

  @impl true
  def system_prompt(_config) do
    @system_prompt
  end

  @impl true
  def tools(config) do
    all_tools = %{
      "list_files" => build_list_files_tool(config),
      "read_file" => build_read_file_tool(config),
      "create_file" => build_create_file_tool(config),
      "replace_text" => build_replace_text_tool(config),
      "replace_lines" => build_replace_lines_tool(config),
      "update_file_attrs" => build_update_file_attrs_tool(config),
      "search_text" => build_search_text_tool(config),
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
      display_text: "Listing files",
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

    Supports pagination with offset and limit parameters.
    Returns the file content with line numbers for easy reference.
    """

    description = get_custom_description(config, "read_file", default_description)

    Function.new!(%{
      name: "read_file",
      description: description,
      display_text: "Reading file",
      parameters_schema: %{
        type: "object",
        properties: %{
          file_path: %{
            type: "string",
            description: "Path to the file to read"
          },
          offset: %{
            type: "integer",
            description: "Line number to start reading from (0-based)",
            default: 0
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
    returned — use replace_text or replace_lines to modify existing files instead.
    """

    description = get_custom_description(config, "create_file", default_description)

    Function.new!(%{
      name: "create_file",
      description: description,
      display_text: "Creating file",
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

    For large block replacements where you have line numbers, prefer replace_lines —
    it is significantly more token-efficient.
    """

    description = get_custom_description(config, "replace_text", default_description)

    Function.new!(%{
      name: "replace_text",
      description: description,
      display_text: "Replacing text",
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
      display_text: "Deleting file",
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
      display_text: "Moving file",
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

  defp build_search_text_tool(config) do
    default_description = """
    Search for text patterns within files.

    Can search within a specific file or across all loaded files.
    Returns matches with line numbers and optional context lines.

    Usage:
    - Provide pattern (required) - text or regex to search for
    - Provide file_path (optional) - if omitted, searches all files
    - Set case_sensitive (optional, default: true)
    - Set context_lines (optional, default: 0) - lines before/after to show
    - Set max_results (optional, default: 50) - limit number of results

    Examples (call with a JSON object matching the schema):
    - Search a single file: {"pattern": "TODO", "file_path": "/notes.txt"}
    - Search all files: {"pattern": "important", "case_sensitive": false}
    - With surrounding context: {"pattern": "error", "context_lines": 2}
    """

    description = get_custom_description(config, "search_text", default_description)

    Function.new!(%{
      name: "search_text",
      description: description,
      display_text: "Searching files",
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
              "Optional: specific file to search. If omitted, searches all loaded files."
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
        "required" => ["pattern"]
      },
      function: fn args, context -> execute_search_text_tool(args, context, config) end
    })
  end

  defp build_replace_lines_tool(config) do
    default_description = """
    Replace a range of lines (by line number) with new content. Line numbers are
    1-based and the range is inclusive (both start_line and end_line are replaced).

    This tool is significantly more token-efficient than replace_text for large
    block replacements — you don't need to send the original content character-
    for-character, just the line range.

    ## Best Practices

    - ALWAYS use read_file first to see the current line numbers. Line numbers
      shift after every edit, so re-read between edits if you're making multiple
      changes to the same file.
    - Carefully verify start_line and end_line before calling. Wrong line numbers
      will destructively replace the wrong content with no way to undo.
    - For small, targeted edits where you know the exact text, use replace_text
      instead — it has a built-in safety check (the old_string must match).
    - For multi-line replacements where you have line numbers from a recent
      read_file, this tool is the right choice.

    ## Examples

    Call with a JSON object matching the schema:

    - Replace lines 10-15:
      {"file_path": "/doc.txt", "start_line": 10, "end_line": 15, "new_content": "new text"}
    - Replace a single line:
      {"file_path": "/doc.txt", "start_line": 42, "end_line": 42, "new_content": "new line"}
    - Replace a large block:
      {"file_path": "/notes/research.md", "start_line": 120, "end_line": 135, "new_content": "..."}
    """

    description = get_custom_description(config, "replace_lines", default_description)

    Function.new!(%{
      name: "replace_lines",
      description: description,
      display_text: "Replacing lines",
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
            description: "New content to replace the line range. Can be multi-line."
          }
        },
        required: ["file_path", "start_line", "end_line", "new_content"]
      },
      function: fn args, context -> execute_replace_lines_tool(args, context, config) end
    })
  end

  defp build_update_file_attrs_tool(config) do
    default_description = """
    Update file attributes (title, tags, etc.) without modifying file content.

    Validated against the configured file schema. Pass only the attributes you
    want to change. Returns the updated file's JSON metadata.

    To change file content use replace_text, replace_lines, or create_file —
    never this tool.
    """

    description = get_custom_description(config, "update_file_attrs", default_description)

    Function.new!(%{
      name: "update_file_attrs",
      description: description,
      display_text: "Updating file attributes",
      parameters_schema: %{
        type: "object",
        properties: %{
          file_path: %{
            type: "string",
            description: "Path to the file to update"
          },
          attrs: %{
            type: "object",
            description: "Attributes to update. Only include fields you want to change.",
            properties: %{}
          }
        },
        required: ["file_path", "attrs"]
      },
      function: fn args, context -> execute_update_file_attrs_tool(args, context, config) end
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
      entry_maps = Enum.map(filtered_entries, &config.file_schema.to_llm_map(&1))
      {:ok, Jason.encode!(entry_maps)}
    end
  rescue
    e ->
      {:error, "Filesystem not available: #{Exception.message(e)}"}
  end

  defp execute_read_file_tool(args, _context, config) do
    file_path = get_arg(args, "file_path")
    offset = get_arg(args, "offset") || 0
    limit = get_arg(args, "limit") || 2000

    # Validate path
    with {:ok, normalized_path} <- validate_path(file_path) do
      # Read file using FileSystemServer (handles lazy loading automatically)
      case FileSystemServer.read_file(config.filesystem_scope, normalized_path) do
        {:ok, entry} ->
          format_file_content(entry.content || "", normalized_path, offset, limit)

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

  defp format_file_content(content, _file_path, offset, limit) do
    lines = String.split(content, "\n")
    total_lines = length(lines)

    # Apply offset and limit
    selected_lines =
      lines
      |> Enum.slice(offset, limit)
      |> Enum.with_index(offset)
      |> Enum.map(fn {line, idx} ->
        # Format with fixed-width line numbers (1-based for display), truncate long lines
        line_num = String.pad_leading(Integer.to_string(idx + 1), 6)

        truncated_line =
          if String.length(line) > 2000 do
            String.slice(line, 0, 2000) <> "... (line truncated)"
          else
            line
          end

        "#{line_num}\t#{truncated_line}"
      end)

    result =
      if Enum.empty?(selected_lines) do
        "File is empty or offset is beyond file length."
      else
        header =
          if offset > 0 or offset + limit < total_lines do
            showing_end = min(offset + limit, total_lines)
            "Showing lines #{offset + 1} to #{showing_end} of #{total_lines}:\n"
          else
            ""
          end

        header <> Enum.join(selected_lines, "\n")
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
             "File already exists: #{normalized_path}. Use replace_text or replace_lines to modify existing files."}
          else
            # Write file using FileSystemServer
            case FileSystemServer.write_file(
                   config.filesystem_scope,
                   normalized_path,
                   content
                 ) do
              {:ok, entry} ->
                {:ok, Jason.encode!(config.file_schema.to_llm_map(entry))}

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

  defp execute_search_text_tool(args, _context, config) do
    pattern = get_arg(args, "pattern")
    file_path = get_arg(args, "file_path")
    case_sensitive = get_boolean_arg(args, "case_sensitive", true)
    context_lines = get_integer_arg(args, "context_lines", 0)
    max_results = get_integer_arg(args, "max_results", 50)

    cond do
      is_nil(pattern) ->
        {:error, "pattern is required"}

      true ->
        # Compile regex pattern with inline flags for case-insensitive search
        pattern_with_flags = if case_sensitive, do: pattern, else: "(?i)#{pattern}"

        case Regex.compile(pattern_with_flags) do
          {:ok, regex} ->
            if file_path do
              # Search single file
              search_single_file(
                config.filesystem_scope,
                file_path,
                regex,
                context_lines,
                max_results
              )
            else
              # Search all files
              search_all_files(config.filesystem_scope, regex, context_lines, max_results)
            end

          {:error, _reason} ->
            {:error, "Invalid regex pattern: #{pattern}"}
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

  defp execute_update_file_attrs_tool(args, _context, config) do
    file_path = get_arg(args, "file_path")
    raw_attrs = get_arg(args, "attrs") || %{}
    schema = config.file_schema

    with {:ok, normalized_path} <- validate_path(file_path),
         {:ok, _entry} <-
           FileSystemServer.read_file(config.filesystem_scope, normalized_path) do
      changeset = schema.changeset(raw_attrs)

      if changeset.valid? do
        # Use only the cast-and-validated changes. Fields the LLM supplied that
        # weren't in the schema's cast list are silently dropped here, which is
        # the correct behaviour: the schema defines the surface area.
        changes = changeset.changes

        case apply_validated_changes(config.filesystem_scope, normalized_path, changes) do
          :ok ->
            {:ok, updated_entry} =
              FileSystemServer.read_file(config.filesystem_scope, normalized_path)

            {:ok, Jason.encode!(schema.to_llm_map(updated_entry))}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "Failed to update: #{inspect(reason)}"}
        end
      else
        {:error, Utils.changeset_error_to_string(changeset)}
      end
    else
      {:error, :enoent} ->
        {:error, "File not found: #{file_path}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    e ->
      {:error, "Filesystem not available: #{Exception.message(e)}"}
  end

  # Splits a validated change map into entry-level fields and custom metadata,
  # routing each group to the appropriate FileSystemServer call. Refuses content
  # changes outright — `update_file_attrs` is metadata-only.
  defp apply_validated_changes(scope, path, changes) do
    cond do
      Map.has_key?(changes, :content) ->
        {:error,
         "update_file_attrs cannot modify file content. " <>
           "Use replace_text or replace_lines to change content, " <>
           "or create_file for new files."}

      true ->
        {entry_changes, custom_changes} = Map.split(changes, @entry_fields)

        with :ok <- maybe_update_entry(scope, path, entry_changes),
             :ok <- maybe_update_custom(scope, path, stringify_keys(custom_changes)) do
          :ok
        end
    end
  end

  defp maybe_update_entry(_scope, _path, changes) when map_size(changes) == 0, do: :ok

  defp maybe_update_entry(scope, path, changes) do
    case FileSystemServer.update_entry(scope, path, changes) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_update_custom(_scope, _path, changes) when map_size(changes) == 0, do: :ok

  defp maybe_update_custom(scope, path, changes) do
    case FileSystemServer.update_custom_metadata(scope, path, changes) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp search_single_file(filesystem_scope, file_path, regex, context_lines, max_results) do
    with {:ok, normalized_path} <- validate_path(file_path),
         {:ok, entry} <- FileSystemServer.read_file(filesystem_scope, normalized_path) do
      {matches, truncated} =
        find_matches_in_content(entry.content || "", regex, context_lines, max_results)

      format_search_results([{normalized_path, matches}], max_results, truncated)
    else
      {:error, :enoent} ->
        {:error, "File not found: #{file_path}"}

      {:error, reason} ->
        {:error, "Failed to search file: #{inspect(reason)}"}
    end
  end

  defp search_all_files(filesystem_scope, regex, context_lines, max_results) do
    all_files = FileSystemServer.list_files(filesystem_scope)

    # Search each file and collect matches, tracking total matches
    {results, _total_matches, any_truncated} =
      all_files
      |> Enum.reduce({[], 0, false}, fn file_path, {acc, match_count, truncated} ->
        # Calculate remaining limit for this file
        remaining = max_results - match_count

        if remaining <= 0 do
          # Already hit limit, stop collecting
          {acc, match_count, truncated}
        else
          case FileSystemServer.read_file(filesystem_scope, file_path) do
            {:ok, entry} ->
              {matches, file_truncated} =
                find_matches_in_content(entry.content || "", regex, context_lines, remaining)

              if Enum.empty?(matches) do
                {acc, match_count, truncated}
              else
                {[{file_path, matches} | acc], match_count + length(matches),
                 truncated or file_truncated}
              end

            {:error, _} ->
              {acc, match_count, truncated}
          end
        end
      end)

    results = Enum.reverse(results)
    format_search_results(results, max_results, any_truncated)
  end

  defp find_matches_in_content(content, regex, context_lines, max_results) do
    lines = String.split(content, "\n")

    # Collect up to max_results + 1 to detect truncation
    matches =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {line, line_num}, acc ->
        if length(acc) > max_results do
          acc
        else
          if Regex.match?(regex, line) do
            match_info = %{
              line_number: line_num,
              line: line,
              context: extract_context(lines, line_num - 1, context_lines)
            }

            [match_info | acc]
          else
            acc
          end
        end
      end)
      |> Enum.reverse()

    # Return matches and truncation flag
    if length(matches) > max_results do
      {Enum.take(matches, max_results), true}
    else
      {matches, false}
    end
  end

  defp extract_context(lines, zero_based_line_num, context_lines) do
    if context_lines > 0 do
      start_idx = max(0, zero_based_line_num - context_lines)
      end_idx = min(length(lines) - 1, zero_based_line_num + context_lines)

      %{
        before: Enum.slice(lines, start_idx, zero_based_line_num - start_idx),
        after: Enum.slice(lines, zero_based_line_num + 1, end_idx - zero_based_line_num)
      }
    else
      nil
    end
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

  defp format_match(%{line_number: line_num, line: line, context: nil}) do
    # Format line number the same way as format_file_content (6 chars padded, tab separator)
    formatted_line_num = String.pad_leading(Integer.to_string(line_num), 6)
    "#{formatted_line_num}\t#{line}"
  end

  defp format_match(%{line_number: line_num, line: line, context: context}) do
    # Format context lines with line numbers
    before =
      if context.before do
        context.before
        |> Enum.with_index()
        |> Enum.map(fn {ctx_line, idx} ->
          # Calculate line number for context line
          ctx_line_num = line_num - length(context.before) + idx
          formatted_num = String.pad_leading(Integer.to_string(ctx_line_num), 6)
          "#{formatted_num} |\t#{ctx_line}"
        end)
        |> Enum.join("\n")
      else
        ""
      end

    after_ctx =
      if context.after do
        context.after
        |> Enum.with_index()
        |> Enum.map(fn {ctx_line, idx} ->
          # Calculate line number for context line
          ctx_line_num = line_num + idx + 1
          formatted_num = String.pad_leading(Integer.to_string(ctx_line_num), 6)
          "#{formatted_num} |\t#{ctx_line}"
        end)
        |> Enum.join("\n")
      else
        ""
      end

    # Format the matching line
    formatted_line_num = String.pad_leading(Integer.to_string(line_num), 6)
    match_line = "#{formatted_line_num}\t#{line}"

    lines =
      [
        before,
        match_line,
        after_ctx
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    lines
  end

  defp perform_text_replacement(
         filesystem_scope,
         file_path,
         content,
         old_string,
         new_string,
         replace_all
       ) do
    # Split to count occurrences
    parts = String.split(content, old_string, parts: :infinity)
    occurrence_count = length(parts) - 1

    cond do
      occurrence_count == 0 ->
        {:error, "String not found in file: '#{old_string}'"}

      occurrence_count == 1 ->
        # Single occurrence, safe to replace
        updated_content = String.replace(content, old_string, new_string, global: false)

        write_edit(
          filesystem_scope,
          file_path,
          updated_content,
          "File edited successfully: #{file_path}"
        )

      occurrence_count > 1 and not replace_all ->
        {:error,
         "String appears #{occurrence_count} times in file. Use replace_all: true or provide more context in old_string."}

      occurrence_count > 1 and replace_all ->
        # Replace all occurrences
        updated_content = String.replace(content, old_string, new_string, global: true)

        write_edit(
          filesystem_scope,
          file_path,
          updated_content,
          "File edited successfully: #{file_path} (#{occurrence_count} replacements)"
        )
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

  defp perform_line_replacement(
         filesystem_scope,
         file_path,
         content,
         start_line,
         end_line,
         new_content
       ) do
    lines = String.split(content, "\n")
    total_lines = length(lines)

    # Convert to 0-based for Enum operations
    start_idx = start_line - 1
    end_idx = end_line - 1

    cond do
      start_idx >= total_lines ->
        {:error, "start_line #{start_line} is beyond file length (#{total_lines} lines)"}

      end_idx >= total_lines ->
        {:error, "end_line #{end_line} is beyond file length (#{total_lines} lines)"}

      true ->
        # Extract the lines being replaced (for confirmation message)
        replaced_lines = Enum.slice(lines, start_idx, end_idx - start_idx + 1)
        lines_replaced_count = length(replaced_lines)

        # Build the new file content
        before = Enum.slice(lines, 0, start_idx)
        after_lines = Enum.slice(lines, end_idx + 1, total_lines - end_idx - 1)

        # Split new_content into lines (preserving the newlines)
        new_lines = String.split(new_content, "\n")

        updated_lines = before ++ new_lines ++ after_lines
        updated_content = Enum.join(updated_lines, "\n")

        # Write the updated content
        case FileSystemServer.write_file(filesystem_scope, file_path, updated_content) do
          {:ok, _entry} ->
            {:ok,
             "File edited successfully: #{file_path}\nReplaced #{lines_replaced_count} lines (#{start_line}-#{end_line})"}

          {:error, reason} ->
            {:error, "Failed to save edit: #{inspect(reason)}"}
        end
    end
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
end
