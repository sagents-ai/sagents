defmodule Sagents.Middleware.FileSystemTest.CustomFileSchema do
  @moduledoc false
  @behaviour Sagents.FileSystem.FileSchema

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :title, :string
    field :system_tag, :string
    field :tags, {:array, :string}, default: []
    field :word_count, :integer
  end

  @impl true
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:title, :system_tag, :tags, :word_count])
    |> validate_inclusion(:system_tag, ~w(draft review approved published))
    |> validate_number(:word_count, greater_than: 0)
  end

  @impl true
  def to_llm_map(entry) do
    custom = (entry.metadata && entry.metadata.custom) || %{}

    %{
      custom_path: entry.path,
      custom_title: entry.title,
      system_tag: custom["system_tag"],
      tags: custom["tags"],
      word_count: custom["word_count"]
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
end

defmodule Sagents.Middleware.FileSystemTest.ContentLeakingFileSchema do
  @moduledoc """
  An intentionally-broken FileSchema that allows :content in the cast list.
  Used to verify the middleware's defense-in-depth check rejects content
  changes even when the schema lets them through.
  """
  @behaviour Sagents.FileSystem.FileSchema

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :title, :string
    field :content, :string
  end

  @impl true
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:title, :content])
  end

  @impl true
  def to_llm_map(entry), do: %{path: entry.path, title: entry.title}
end

defmodule Sagents.Middleware.FileSystemTest do
  use ExUnit.Case, async: false

  alias Sagents.Middleware.FileSystem
  alias Sagents.FileSystem.FileEntry
  alias Sagents.FileSystemServer
  alias Sagents.State

  setup_all do
    # Note: Registry is started globally in test_helper.exs
    :ok
  end

  setup do
    # Generate unique agent ID for each test
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({FileSystemServer, scope_key: {:agent, agent_id}})

    %{agent_id: agent_id}
  end

  describe "init/1" do
    test "initializes with agent_id", %{agent_id: agent_id} do
      assert {:ok, config} = FileSystem.init(agent_id: agent_id)
      assert config.filesystem_scope == {:agent, agent_id}

      assert config.enabled_tools == [
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

      assert config.custom_tool_descriptions == %{}
    end

    test "initializes with custom enabled_tools", %{agent_id: agent_id} do
      assert {:ok, config} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 enabled_tools: ["list_files", "read_file"]
               )

      assert config.enabled_tools == ["list_files", "read_file"]
    end

    test "initializes with custom tool descriptions", %{agent_id: agent_id} do
      custom = %{"list_files" => "Custom list_files description"}
      assert {:ok, config} = FileSystem.init(agent_id: agent_id, custom_tool_descriptions: custom)
      assert config.custom_tool_descriptions == custom
    end

    test "requires agent_id" do
      assert_raise KeyError, fn ->
        FileSystem.init([])
      end
    end

    test "accepts custom file_schema module", %{agent_id: agent_id} do
      assert {:ok, config} =
               FileSystem.init(agent_id: agent_id, file_schema: FileEntry)

      assert config.file_schema == FileEntry
    end

    test "defaults file_schema to FileEntry", %{agent_id: agent_id} do
      assert {:ok, config} = FileSystem.init(agent_id: agent_id)
      assert config.file_schema == FileEntry
    end
  end

  describe "system_prompt/1" do
    test "returns filesystem tools prompt" do
      config = %{agent_id: "test"}
      prompt = FileSystem.system_prompt(config)

      assert prompt =~ "Filesystem Tools"
      assert prompt =~ "list_files"
      assert prompt =~ "read_file"
      assert prompt =~ "create_file"
      assert prompt =~ "replace_text"
      assert prompt =~ "replace_lines"
      assert prompt =~ "update_file_attrs"
      assert prompt =~ "must start with a forward slash"
    end
  end

  describe "tools/1" do
    test "returns all nine filesystem tools by default", %{agent_id: agent_id} do
      tools =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          file_schema: FileEntry,
          enabled_tools: [
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
        })

      assert length(tools) == 9
      tool_names = Enum.map(tools, & &1.name)
      assert "list_files" in tool_names
      assert "read_file" in tool_names
      assert "create_file" in tool_names
      assert "replace_text" in tool_names
      assert "replace_lines" in tool_names
      assert "update_file_attrs" in tool_names
      assert "search_text" in tool_names
      assert "delete_file" in tool_names
      assert "move_file" in tool_names
    end

    test "returns only enabled tools", %{agent_id: agent_id} do
      tools =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          file_schema: FileEntry,
          enabled_tools: ["list_files", "read_file"]
        })

      assert length(tools) == 2
      tool_names = Enum.map(tools, & &1.name)
      assert "list_files" in tool_names
      assert "read_file" in tool_names
      refute "create_file" in tool_names
      refute "replace_text" in tool_names
    end

    test "old tool names no longer resolve", %{agent_id: agent_id} do
      tools =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          file_schema: FileEntry,
          enabled_tools: ["ls", "write_file", "edit_file", "edit_lines"]
        })

      assert tools == []
    end
  end

  defp tool_named(tools, name), do: Enum.find(tools, &(&1.name == name))

  describe "list_files tool" do
    test "lists files as JSON array of entry maps", %{agent_id: agent_id} do
      # Write some files
      FileSystemServer.write_file({:agent, agent_id}, "/file1.txt", "content1")
      FileSystemServer.write_file({:agent, agent_id}, "/file2.txt", "content2")

      list_files_tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files"],
          file_schema: FileEntry
        })
        |> tool_named("list_files")

      assert {:ok, result} = list_files_tool.function.(%{}, %{state: State.new!()})
      entries = Jason.decode!(result)
      assert is_list(entries)
      paths = Enum.map(entries, & &1["path"])
      assert "/file1.txt" in paths
      assert "/file2.txt" in paths

      # Each entry has expected keys
      entry = Enum.find(entries, &(&1["path"] == "/file1.txt"))
      assert entry["entry_type"] == "file"
      assert entry["file_type"] == "markdown"
      assert is_integer(entry["size"])
    end

    test "reports empty filesystem", %{agent_id: agent_id} do
      list_files_tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files"],
          file_schema: FileEntry
        })
        |> tool_named("list_files")

      assert {:ok, result} = list_files_tool.function.(%{}, %{state: State.new!()})
      assert result == "No files in filesystem"
    end

    test "filters by pattern", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "content")
      FileSystemServer.write_file({:agent, agent_id}, "/test.md", "content")
      FileSystemServer.write_file({:agent, agent_id}, "/other.txt", "content")

      list_files_tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files"],
          file_schema: FileEntry
        })
        |> tool_named("list_files")

      assert {:ok, result} =
               list_files_tool.function.(%{"pattern" => "*test*"}, %{state: State.new!()})

      entries = Jason.decode!(result)
      paths = Enum.map(entries, & &1["path"])
      assert "/test.txt" in paths
      assert "/test.md" in paths
      refute "/other.txt" in paths
    end

    test "uses custom file_schema module", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/doc.txt", "hello", title: "Doc Title")

      list_files_tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files"],
          file_schema: Sagents.Middleware.FileSystemTest.CustomFileSchema
        })
        |> tool_named("list_files")

      assert {:ok, result} = list_files_tool.function.(%{}, %{state: State.new!()})
      [entry] = Jason.decode!(result)
      assert entry["custom_path"] == "/doc.txt"
      assert entry["custom_title"] == "Doc Title"
      refute Map.has_key?(entry, "entry_type")
    end
  end

  describe "read_file tool" do
    setup %{agent_id: agent_id} do
      content = """
      line 1
      line 2
      line 3
      line 4
      line 5
      """

      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", String.trim(content))

      tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["read_file"]
        })
        |> tool_named("read_file")

      %{tool: tool}
    end

    test "reads entire file with line numbers", %{tool: tool} do
      args = %{"file_path" => "/test.txt"}

      assert {:ok, result} = tool.function.(args, %{state: State.new!()})
      assert result =~ "1\tline 1"
      assert result =~ "2\tline 2"
      assert result =~ "5\tline 5"
    end

    test "reads file with offset", %{tool: tool} do
      args = %{"file_path" => "/test.txt", "offset" => 2}

      assert {:ok, result} = tool.function.(args, %{state: State.new!()})
      assert result =~ "3\tline 3"
      assert result =~ "4\tline 4"
      refute result =~ "1\tline 1"
    end

    test "reads file with limit", %{tool: tool} do
      args = %{"file_path" => "/test.txt", "limit" => 2}

      assert {:ok, result} = tool.function.(args, %{state: State.new!()})
      assert result =~ "1\tline 1"
      assert result =~ "2\tline 2"
      refute result =~ "3\tline 3"
    end

    test "reads file with offset and limit", %{tool: tool} do
      args = %{"file_path" => "/test.txt", "offset" => 1, "limit" => 2}

      assert {:ok, result} = tool.function.(args, %{state: State.new!()})
      assert result =~ "2\tline 2"
      assert result =~ "3\tline 3"
      refute result =~ "1\tline 1"
      refute result =~ "4\tline 4"
    end

    test "returns error for non-existent file", %{tool: tool} do
      args = %{"file_path" => "/missing.txt"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "not found"
    end

    test "rejects paths without leading slash", %{tool: tool} do
      args = %{"file_path" => "no-slash.txt"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "must start with"
    end
  end

  describe "create_file tool" do
    setup %{agent_id: agent_id} do
      tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["create_file"],
          file_schema: FileEntry
        })
        |> tool_named("create_file")

      %{tool: tool}
    end

    test "creates new file and returns JSON entry map", %{agent_id: agent_id, tool: tool} do
      args = %{"file_path" => "/new.txt", "content" => "Hello, World!"}

      assert {:ok, result} = tool.function.(args, %{state: State.new!()})
      entry_map = Jason.decode!(result)
      assert entry_map["path"] == "/new.txt"
      assert entry_map["entry_type"] == "file"
      assert entry_map["file_type"] == "markdown"
      assert is_integer(entry_map["size"])
      assert entry_map["size"] > 0

      # Verify file was created in FileSystemServer
      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/new.txt")
      assert content == "Hello, World!"
    end

    test "rejects overwriting existing file", %{agent_id: agent_id, tool: tool} do
      # Create a file first
      FileSystemServer.write_file({:agent, agent_id}, "/existing.txt", "original")

      args = %{"file_path" => "/existing.txt", "content" => "new content"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "already exists"
      assert message =~ "replace_text or replace_lines"
    end

    test "rejects paths without leading slash", %{tool: tool} do
      args = %{"file_path" => "no-slash.txt", "content" => "content"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "must start with"
    end

    test "rejects path traversal attempts", %{tool: tool} do
      args = %{"file_path" => "/../etc/passwd", "content" => "bad"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "not allowed"
    end
  end

  describe "replace_text tool" do
    setup %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/edit.txt", "Hello World")

      tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["replace_text"]
        })
        |> tool_named("replace_text")

      %{tool: tool}
    end

    test "edits file with single occurrence", %{agent_id: agent_id, tool: tool} do
      args = %{
        "file_path" => "/edit.txt",
        "old_string" => "World",
        "new_string" => "Elixir"
      }

      assert {:ok, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "edited successfully"

      # Verify content changed
      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/edit.txt")
      assert content == "Hello Elixir"
    end

    test "errors on non-existent string", %{tool: tool} do
      args = %{
        "file_path" => "/edit.txt",
        "old_string" => "NotFound",
        "new_string" => "Something"
      }

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "not found"
    end

    test "errors on multiple occurrences without replace_all", %{agent_id: agent_id, tool: tool} do
      FileSystemServer.write_file({:agent, agent_id}, "/multi.txt", "test test test")

      args = %{
        "file_path" => "/multi.txt",
        "old_string" => "test",
        "new_string" => "foo"
      }

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "appears"
      assert message =~ "times"
    end

    test "replaces all occurrences with replace_all: true", %{agent_id: agent_id, tool: tool} do
      FileSystemServer.write_file({:agent, agent_id}, "/multi.txt", "test test test")

      args = %{
        "file_path" => "/multi.txt",
        "old_string" => "test",
        "new_string" => "foo",
        "replace_all" => true
      }

      assert {:ok, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "edited successfully"
      assert message =~ "3 replacements"

      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/multi.txt")
      assert content == "foo foo foo"
    end

    test "returns error for non-existent file", %{tool: tool} do
      args = %{
        "file_path" => "/missing.txt",
        "old_string" => "old",
        "new_string" => "new"
      }

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "not found"
    end
  end

  describe "move_file tool" do
    setup %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/source.txt", "file content")

      tools =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["move_file"],
          file_schema: FileEntry
        })

      [move_file_tool] = tools

      %{tool: move_file_tool}
    end

    test "moves a file to a new path", %{agent_id: agent_id, tool: tool} do
      args = %{"old_path" => "/source.txt", "new_path" => "/destination.txt"}

      assert {:ok, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "Moved successfully"
      assert message =~ "/source.txt -> /destination.txt"

      # Verify file exists at new path
      assert {:ok, %{content: "file content"}} =
               FileSystemServer.read_file({:agent, agent_id}, "/destination.txt")

      # Verify file no longer exists at old path
      assert {:error, :enoent} =
               FileSystemServer.read_file({:agent, agent_id}, "/source.txt")
    end

    test "renames a file in same directory", %{agent_id: agent_id, tool: tool} do
      args = %{"old_path" => "/source.txt", "new_path" => "/renamed.txt"}

      assert {:ok, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "Moved successfully"

      assert {:ok, %{content: "file content"}} =
               FileSystemServer.read_file({:agent, agent_id}, "/renamed.txt")
    end

    test "moves a directory with children", %{agent_id: agent_id, tool: tool} do
      FileSystemServer.write_file({:agent, agent_id}, "/dir/file1.txt", "content1")
      FileSystemServer.write_file({:agent, agent_id}, "/dir/file2.txt", "content2")

      args = %{"old_path" => "/dir", "new_path" => "/new_dir"}

      assert {:ok, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "Moved successfully"

      # Verify children moved
      assert {:ok, %{content: "content1"}} =
               FileSystemServer.read_file({:agent, agent_id}, "/new_dir/file1.txt")

      assert {:ok, %{content: "content2"}} =
               FileSystemServer.read_file({:agent, agent_id}, "/new_dir/file2.txt")

      # Verify old paths gone
      assert {:error, :enoent} =
               FileSystemServer.read_file({:agent, agent_id}, "/dir/file1.txt")
    end

    test "returns error for non-existent source", %{tool: tool} do
      args = %{"old_path" => "/missing.txt", "new_path" => "/dest.txt"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "not found"
    end

    test "returns error when target already exists", %{agent_id: agent_id, tool: tool} do
      FileSystemServer.write_file({:agent, agent_id}, "/existing.txt", "other content")

      args = %{"old_path" => "/source.txt", "new_path" => "/existing.txt"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "already exists"
    end

    test "rejects paths without leading slash", %{tool: tool} do
      args = %{"old_path" => "no-slash.txt", "new_path" => "/dest.txt"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "must start with"
    end

    test "rejects path traversal attempts", %{tool: tool} do
      args = %{"old_path" => "/source.txt", "new_path" => "/../etc/passwd"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "not allowed"
    end

    test "returns error when old_path is missing", %{tool: tool} do
      args = %{"new_path" => "/dest.txt"}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "old_path and new_path are required"
    end
  end

  describe "path validation" do
    test "validate_path/1 accepts valid paths" do
      assert {:ok, "/file.txt"} = FileSystem.validate_path("/file.txt")
      assert {:ok, "/dir/file.txt"} = FileSystem.validate_path("/dir/file.txt")
      assert {:ok, "/path/to/file.txt"} = FileSystem.validate_path("/path/to/file.txt")
    end

    test "validate_path/1 rejects paths without leading slash" do
      assert {:error, message} = FileSystem.validate_path("file.txt")
      assert message =~ "must start with"
    end

    test "validate_path/1 rejects path traversal" do
      assert {:error, message} = FileSystem.validate_path("/dir/../etc/passwd")
      assert message =~ "not allowed"
    end

    test "validate_path/1 rejects home directory paths" do
      assert {:error, message} = FileSystem.validate_path("~/file.txt")
      # This path fails the "must start with /" check first
      assert message =~ "must start with"
    end

    test "validate_path/1 rejects empty paths" do
      assert {:error, message} = FileSystem.validate_path("")
      assert message =~ "empty"
    end

    test "normalize_path/1 normalizes slashes" do
      assert "/path/to/file.txt" = FileSystem.normalize_path("/path//to///file.txt")
      assert "/path/to/file.txt" = FileSystem.normalize_path("/path\\to\\file.txt")
    end
  end

  defp get_search_text_tool(tools) when is_list(tools) do
    Enum.find(tools, fn tool -> tool.name == "search_text" end)
  end

  describe "search_text tool - single file search" do
    test "search_text tool is enabled in FileSystem", %{agent_id: agent_id} do
      # Initialize middleware
      {:ok, config} = FileSystem.init(agent_id: agent_id)

      # Find the search_text tool
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()
      assert search_tool != nil
    end

    test "finds matches in a single file with line numbers", %{agent_id: agent_id} do
      # Setup: create a file with searchable content
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Hello World
      This is a test
      TODO: Add feature
      Another line
      TODO: Fix bug
      End of file
      """)

      # Initialize middleware
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      # Execute search
      args = %{"pattern" => "TODO", "file_path" => "/test.txt"}
      {:ok, result} = search_tool.function.(args, %{})

      # Verify results - line numbers should be formatted like read_file (padded to 6 chars, tab separator)
      assert result =~ "File: /test.txt"
      assert result =~ "     3\tTODO: Add feature"
      assert result =~ "     5\tTODO: Fix bug"
    end

    test "returns no matches when pattern not found", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Hello World
      This is a test
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      args = %{"pattern" => "NOTFOUND"}
      {:ok, result} = search_tool.function.(args, %{})

      assert result == "No matches found"
    end

    test "handles case-insensitive search", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Hello World
      hello world
      HELLO WORLD
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      args = %{"pattern" => "hello", "file_path" => "/test.txt", "case_sensitive" => false}
      {:ok, result} = search_tool.function.(args, %{})

      # Should match all three lines (padded line numbers with tab separator)
      assert result =~ "     1\tHello World"
      assert result =~ "     2\thello world"
      assert result =~ "     3\tHELLO WORLD"
    end

    test "handles case-sensitive search", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Hello World
      hello world
      HELLO WORLD
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      args = %{"pattern" => "hello", "file_path" => "/test.txt", "case_sensitive" => true}
      {:ok, result} = search_tool.function.(args, %{})

      # Should only match line 2
      refute result =~ "     1\tHello World"
      assert result =~ "     2\thello world"
      refute result =~ "     3\tHELLO WORLD"
    end

    test "supports regex patterns", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      error123
      warning456
      error789
      info
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      # Search for lines starting with "error" followed by digits
      args = %{"pattern" => "error\\d+", "file_path" => "/test.txt"}
      {:ok, result} = search_tool.function.(args, %{})

      assert result =~ "     1\terror123"
      assert result =~ "     3\terror789"
      refute result =~ "     2\twarning456"
      refute result =~ "     4\tinfo"
    end

    test "returns error for invalid regex pattern", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "content")

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      args = %{"pattern" => "[invalid(regex", "file_path" => "/test.txt"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "Invalid regex pattern"
    end

    test "returns error for non-existent file", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      args = %{"pattern" => "test", "file_path" => "/nonexistent.txt"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "File not found"
    end
  end

  describe "search_text tool - context lines" do
    test "includes context lines before and after matches", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Before context 1
      Before context 2
      MATCH HERE
      After context 1
      After context 2
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      args = %{"pattern" => "MATCH", "file_path" => "/test.txt", "context_lines" => 2}
      {:ok, result} = search_tool.function.(args, %{})

      # Verify main match (padded line number with tab separator)
      assert result =~ "     3\tMATCH HERE"

      # Verify context lines (marked with | and have line numbers)
      assert result =~ "     1 |\tBefore context 1"
      assert result =~ "     2 |\tBefore context 2"
      assert result =~ "     4 |\tAfter context 1"
      assert result =~ "     5 |\tAfter context 2"
    end

    test "handles context at file boundaries", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      MATCH at start
      After
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      # Request 2 context lines, but match is at line 1 (no lines before)
      args = %{"pattern" => "MATCH", "file_path" => "/test.txt", "context_lines" => 2}
      {:ok, result} = search_tool.function.(args, %{})

      assert result =~ "     1\tMATCH at start"
      assert result =~ "     2 |\tAfter"
    end
  end

  describe "search_text tool - multi-file search" do
    test "searches across all files when no file_path specified", %{agent_id: agent_id} do
      # Create multiple files
      FileSystemServer.write_file({:agent, agent_id}, "/file1.txt", """
      TODO in file 1
      Normal line
      """)

      FileSystemServer.write_file({:agent, agent_id}, "/file2.txt", """
      Normal line
      TODO in file 2
      """)

      FileSystemServer.write_file({:agent, agent_id}, "/file3.txt", """
      No match here
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      # Search all files without specifying file_path
      args = %{"pattern" => "TODO"}
      {:ok, result} = search_tool.function.(args, %{})

      # Should find matches in both file1 and file2
      assert result =~ "File: /file1.txt"
      assert result =~ "     1\tTODO in file 1"
      assert result =~ "File: /file2.txt"
      assert result =~ "     2\tTODO in file 2"
      refute result =~ "file3.txt"
    end

    test "returns no matches when pattern not in any file", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/file1.txt", "content 1")
      FileSystemServer.write_file({:agent, agent_id}, "/file2.txt", "content 2")

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      args = %{"pattern" => "NOTFOUND"}
      {:ok, result} = search_tool.function.(args, %{})

      assert result == "No matches found"
    end
  end

  describe "search_text tool - max_results limiting" do
    test "limits results to max_results parameter", %{agent_id: agent_id} do
      # Create a file with many matches
      content =
        Enum.map(1..100, fn i -> "Line #{i}: MATCH #{i}" end)
        |> Enum.join("\n")

      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", content)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      # Limit to 10 results
      args = %{"pattern" => "MATCH", "file_path" => "/test.txt", "max_results" => 10}
      {:ok, result} = search_tool.function.(args, %{})

      # Count how many "Line X:" appear in results
      line_count =
        result
        |> String.split("\n")
        |> Enum.count(fn line -> String.contains?(line, "Line ") end)

      # Should have at most 10 matches
      assert line_count <= 10
    end

    test "shows truncation notice when results exceed max_results", %{agent_id: agent_id} do
      # Create a file with many matches
      content =
        Enum.map(1..60, fn i -> "Line #{i}: MATCH #{i}" end)
        |> Enum.join("\n")

      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", content)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      # Use default max_results (50)
      args = %{"pattern" => "MATCH", "file_path" => "/test.txt"}
      {:ok, result} = search_tool.function.(args, %{})

      # Should show truncation notice
      assert result =~ "Results truncated"
    end
  end

  describe "search_text tool - parameter validation" do
    test "returns error when pattern is missing", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      args = %{}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "pattern is required"
    end

    test "handles invalid path", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      # Path without leading slash
      args = %{"pattern" => "test", "file_path" => "invalid/path.txt"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "Path must start with '/'"
    end
  end

  describe "search_text tool - tool registration" do
    test "search_text tool is included in default enabled tools", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)

      assert "search_text" in config.enabled_tools
    end

    test "search_text tool can be disabled via config", %{agent_id: agent_id} do
      {:ok, config} =
        FileSystem.init(
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files", "read_file", "create_file"]
        )

      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      assert search_tool == nil
    end

    test "search_text tool has correct schema", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      assert search_tool.name == "search_text"
      assert is_binary(search_tool.description)

      # Verify parameters schema
      schema = search_tool.parameters_schema
      assert schema["type"] == "object"
      assert "pattern" in schema["required"]

      properties = schema["properties"]
      assert Map.has_key?(properties, "pattern")
      assert Map.has_key?(properties, "file_path")
      assert Map.has_key?(properties, "case_sensitive")
      assert Map.has_key?(properties, "context_lines")
      assert Map.has_key?(properties, "max_results")
    end
  end

  describe "search_text tool - integration scenarios" do
    test "search then read workflow", %{agent_id: agent_id} do
      # Create a file with searchable content
      FileSystemServer.write_file({:agent, agent_id}, "/project.md", """
      # Project Documentation

      ## Section 1
      Some content here.

      ## Section 2
      TODO: Complete this section

      ## Section 3
      More content.

      ## Section 4
      TODO: Add examples
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      tools = FileSystem.tools(config)

      # First, search for TODOs
      search_tool = Enum.find(tools, fn tool -> tool.name == "search_text" end)
      args = %{"pattern" => "TODO", "file_path" => "/project.md"}
      {:ok, search_result} = search_tool.function.(args, %{})

      # Verify we found the TODOs (line numbers padded to 6 chars with tab separator)
      assert search_result =~ "     7\tTODO: Complete this section"
      assert search_result =~ "    13\tTODO: Add examples"

      # Now read the file to get more context
      read_tool = Enum.find(tools, fn tool -> tool.name == "read_file" end)
      read_args = %{"file_path" => "/project.md", "offset" => 6, "limit" => 3}
      {:ok, read_result} = read_tool.function.(read_args, %{})

      # Should see the TODO line in context
      assert read_result =~ "TODO: Complete this section"
    end

    test "search across multiple files with different patterns", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/config.json", """
      {
        "error_log": true,
        "debug": false
      }
      """)

      FileSystemServer.write_file({:agent, agent_id}, "/app.log", """
      2024-01-01 10:00:00 INFO: Application started
      2024-01-01 10:05:00 ERROR: Connection failed
      2024-01-01 10:10:00 INFO: Retrying...
      2024-01-01 10:15:00 ERROR: Timeout occurred
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_search_text_tool()

      # Search for "error" (case-insensitive) across all files
      args = %{"pattern" => "error", "case_sensitive" => false}
      {:ok, result} = search_tool.function.(args, %{})

      # Should find matches in both files (with padded line numbers)
      assert result =~ "/config.json"
      assert result =~ "     2\t  \"error_log\": true,"
      assert result =~ "/app.log"
      assert result =~ "     2\t2024-01-01 10:05:00 ERROR: Connection failed"
      assert result =~ "     4\t2024-01-01 10:15:00 ERROR: Timeout occurred"
    end
  end

  defp get_replace_lines_tool(tools) when is_list(tools) do
    Enum.find(tools, fn tool -> tool.name == "replace_lines" end)
  end

  describe "replace_lines tool - basic functionality" do
    test "replace_lines tool is enabled in FileSystem", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()
      assert replace_lines_tool != nil
    end

    test "replaces a single line", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Line 1
      Line 2
      Line 3
      Line 4
      Line 5
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 3,
        "end_line" => 3,
        "new_content" => "REPLACED LINE 3"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})

      assert result =~ "File edited successfully"
      assert result =~ "Replaced 1 lines (3-3)"

      # Verify file content
      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      assert content =~ "Line 1"
      assert content =~ "Line 2"
      assert content =~ "REPLACED LINE 3"
      assert content =~ "Line 4"
      assert content =~ "Line 5"
      refute content =~ "Line 3\n"
    end

    test "replaces multiple lines", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Line 1
      Line 2
      Line 3
      Line 4
      Line 5
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 2,
        "end_line" => 4,
        "new_content" => "NEW LINE A\nNEW LINE B"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})

      assert result =~ "File edited successfully"
      assert result =~ "Replaced 3 lines (2-4)"

      # Verify file content
      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      lines = String.split(content, "\n", trim: true)
      assert lines == ["Line 1", "NEW LINE A", "NEW LINE B", "Line 5"]
    end

    test "replaces with multi-line content", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/story.txt", """
      Chapter 1
      Old paragraph 1
      Old paragraph 2
      Chapter 2
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      new_content = """
      New paragraph 1
      New paragraph 2
      New paragraph 3
      """

      args = %{
        "file_path" => "/story.txt",
        "start_line" => 2,
        "end_line" => 3,
        "new_content" => String.trim(new_content)
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})
      assert result =~ "Replaced 2 lines"

      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/story.txt")
      assert content =~ "Chapter 1"
      assert content =~ "New paragraph 1"
      assert content =~ "New paragraph 2"
      assert content =~ "New paragraph 3"
      assert content =~ "Chapter 2"
      refute content =~ "Old paragraph"
    end
  end

  describe "replace_lines tool - boundary conditions" do
    test "replaces first line only", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Line 1
      Line 2
      Line 3
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 1,
        "end_line" => 1,
        "new_content" => "REPLACED FIRST LINE"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})
      assert result =~ "Replaced 1 lines (1-1)"

      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      lines = String.split(content, "\n", trim: true)
      assert lines == ["REPLACED FIRST LINE", "Line 2", "Line 3"]
    end

    test "replaces last line only", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Line 1
      Line 2
      Line 3
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 4,
        "end_line" => 4,
        "new_content" => "REPLACED LAST LINE"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})
      assert result =~ "Replaced 1 lines (4-4)"

      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      lines = String.split(content, "\n", trim: true)
      assert lines == ["Line 1", "Line 2", "Line 3", "REPLACED LAST LINE"]
    end

    test "replaces entire file", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Line 1
      Line 2
      Line 3
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 1,
        "end_line" => 4,
        "new_content" => "Completely new content"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})
      assert result =~ "Replaced 4 lines (1-4)"

      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      assert String.trim(content) == "Completely new content"
    end

    test "replaces with empty content", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Line 1
      Line 2
      Line 3
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 2,
        "end_line" => 2,
        "new_content" => ""
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})
      assert result =~ "Replaced 1 lines"

      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      lines = String.split(content, "\n", trim: true)
      # Empty string creates an empty line
      assert length(lines) == 2
    end
  end

  describe "replace_lines tool - error cases" do
    test "returns error for non-existent file", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/nonexistent.txt",
        "start_line" => 1,
        "end_line" => 2,
        "new_content" => "content"
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "File not found"
    end

    test "returns error when start_line is less than 1", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "Line 1\nLine 2")

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 0,
        "end_line" => 1,
        "new_content" => "content"
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "start_line must be >= 1"
    end

    test "returns error when end_line is less than start_line", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "Line 1\nLine 2\nLine 3")

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 3,
        "end_line" => 1,
        "new_content" => "content"
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "end_line must be >= start_line"
    end

    test "returns error when start_line is beyond file length", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "Line 1\nLine 2")

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 10,
        "end_line" => 15,
        "new_content" => "content"
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "start_line 10 is beyond file length"
    end

    test "returns error when end_line is beyond file length", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", "Line 1\nLine 2\nLine 3")

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 2,
        "end_line" => 10,
        "new_content" => "content"
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "end_line 10 is beyond file length"
    end

    test "returns error for invalid path", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "no-slash.txt",
        "start_line" => 1,
        "end_line" => 1,
        "new_content" => "content"
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "Path must start with '/'"
    end

    test "returns error when file_path is missing", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "start_line" => 1,
        "end_line" => 1,
        "new_content" => "content"
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "file_path is required"
    end

    test "returns error when start_line is missing", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "end_line" => 1,
        "new_content" => "content"
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "start_line and end_line are required"
    end

    test "returns error when new_content is missing", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 1,
        "end_line" => 1
      }

      {:error, error_msg} = replace_lines_tool.function.(args, %{})
      assert error_msg =~ "new_content is required"
    end
  end

  describe "replace_lines tool - integration scenarios" do
    test "read then replace_lines workflow", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/document.md", """
      # Title

      ## Section 1
      Old content here.
      More old content.

      ## Section 2
      Keep this section.
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      tools = FileSystem.tools(config)

      # First, read the file to see line numbers
      read_tool = Enum.find(tools, fn tool -> tool.name == "read_file" end)
      {:ok, read_result} = read_tool.function.(%{"file_path" => "/document.md"}, %{})

      # Verify we can see the lines
      assert read_result =~ "4\tOld content here."
      assert read_result =~ "5\tMore old content."

      # Now use replace_lines to replace lines 4-5
      replace_lines_tool = Enum.find(tools, fn tool -> tool.name == "replace_lines" end)

      args = %{
        "file_path" => "/document.md",
        "start_line" => 4,
        "end_line" => 5,
        "new_content" => "Brand new content.\nCompletely rewritten."
      }

      {:ok, edit_result} = replace_lines_tool.function.(args, %{})
      assert edit_result =~ "Replaced 2 lines"

      # Read again to verify
      {:ok, final_result} = read_tool.function.(%{"file_path" => "/document.md"}, %{})
      assert final_result =~ "Brand new content."
      assert final_result =~ "Completely rewritten."
      refute final_result =~ "Old content here."
    end

    test "replace_lines can be disabled via config", %{agent_id: agent_id} do
      {:ok, config} =
        FileSystem.init(
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files", "read_file", "create_file"]
        )

      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()
      assert replace_lines_tool == nil
    end

    test "replace_lines tool has correct schema", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      assert replace_lines_tool.name == "replace_lines"
      assert is_binary(replace_lines_tool.description)

      # Verify parameters schema
      schema = replace_lines_tool.parameters_schema
      assert schema.type == "object"
      assert "file_path" in schema.required
      assert "start_line" in schema.required
      assert "end_line" in schema.required
      assert "new_content" in schema.required

      properties = schema.properties
      assert Map.has_key?(properties, :file_path)
      assert Map.has_key?(properties, :start_line)
      assert Map.has_key?(properties, :end_line)
      assert Map.has_key?(properties, :new_content)
    end
  end

  describe "update_file_attrs tool" do
    alias Sagents.Middleware.FileSystemTest.{CustomFileSchema, ContentLeakingFileSchema}

    defp update_attrs_tool(agent_id, opts \\ []) do
      schema = Keyword.get(opts, :file_schema, FileEntry)

      FileSystem.tools(%{
        filesystem_scope: {:agent, agent_id},
        enabled_tools: ["update_file_attrs"],
        file_schema: schema
      })
      |> tool_named("update_file_attrs")
    end

    test "is registered with correct name and display text", %{agent_id: agent_id} do
      tool = update_attrs_tool(agent_id)
      assert tool.name == "update_file_attrs"
      assert tool.display_text == "Updating file attributes"
    end

    test "updates entry-level fields (title, file_type)", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/doc.md", "body", title: "Old Title")
      tool = update_attrs_tool(agent_id)

      args = %{
        "file_path" => "/doc.md",
        "attrs" => %{"title" => "New Title", "file_type" => "json"}
      }

      assert {:ok, json} = tool.function.(args, %{state: State.new!()})
      result = Jason.decode!(json)
      assert result["title"] == "New Title"
      assert result["file_type"] == "json"

      {:ok, entry} = FileSystemServer.read_file({:agent, agent_id}, "/doc.md")
      assert entry.title == "New Title"
      assert entry.file_type == "json"
      assert entry.content == "body"
    end

    test "updates custom metadata fields via custom schema", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/doc.md", "body", title: "Doc")
      tool = update_attrs_tool(agent_id, file_schema: CustomFileSchema)

      args = %{
        "file_path" => "/doc.md",
        "attrs" => %{"system_tag" => "draft", "tags" => ["a", "b"], "word_count" => 100}
      }

      assert {:ok, json} = tool.function.(args, %{state: State.new!()})
      result = Jason.decode!(json)
      assert result["system_tag"] == "draft"
      assert result["tags"] == ["a", "b"]
      assert result["word_count"] == 100

      {:ok, entry} = FileSystemServer.read_file({:agent, agent_id}, "/doc.md")
      # Custom fields go into metadata.custom (string keys)
      assert entry.metadata.custom["system_tag"] == "draft"
      assert entry.metadata.custom["tags"] == ["a", "b"]
      assert entry.metadata.custom["word_count"] == 100
    end

    test "updates entry-level and custom fields in one call", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/doc.md", "body", title: "Old")
      tool = update_attrs_tool(agent_id, file_schema: CustomFileSchema)

      args = %{
        "file_path" => "/doc.md",
        "attrs" => %{"title" => "New", "system_tag" => "review"}
      }

      assert {:ok, _json} = tool.function.(args, %{state: State.new!()})

      {:ok, entry} = FileSystemServer.read_file({:agent, agent_id}, "/doc.md")
      assert entry.title == "New"
      assert entry.metadata.custom["system_tag"] == "review"
    end

    test "returns formatted changeset errors when validation fails", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/doc.md", "body")
      tool = update_attrs_tool(agent_id, file_schema: CustomFileSchema)

      args = %{
        "file_path" => "/doc.md",
        "attrs" => %{"system_tag" => "garbage", "word_count" => -5}
      }

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "system_tag"
      assert message =~ "word_count"
    end

    test "returns 'File not found' for missing file", %{agent_id: agent_id} do
      tool = update_attrs_tool(agent_id)

      args = %{"file_path" => "/missing.md", "attrs" => %{"title" => "x"}}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "not found"
    end

    test "rejects :content with redirect-to-replace-tools error", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/doc.md", "body")
      tool = update_attrs_tool(agent_id, file_schema: ContentLeakingFileSchema)

      args = %{
        "file_path" => "/doc.md",
        "attrs" => %{"content" => "rewritten"}
      }

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "cannot modify file content"
      assert message =~ "replace_text or replace_lines"
      assert message =~ "create_file"

      # Content was not changed
      {:ok, entry} = FileSystemServer.read_file({:agent, agent_id}, "/doc.md")
      assert entry.content == "body"
    end

    test "default FileEntry schema silently drops :content from cast", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/doc.md", "body", title: "Title")
      tool = update_attrs_tool(agent_id)

      # Default FileEntry.changeset/1 doesn't cast :content, so it's dropped
      # before the routing-layer check ever sees it.
      args = %{
        "file_path" => "/doc.md",
        "attrs" => %{"content" => "rewritten", "title" => "Updated"}
      }

      assert {:ok, json} = tool.function.(args, %{state: State.new!()})
      result = Jason.decode!(json)
      assert result["title"] == "Updated"

      {:ok, entry} = FileSystemServer.read_file({:agent, agent_id}, "/doc.md")
      assert entry.content == "body"
      assert entry.title == "Updated"
    end

    test "rejects invalid path", %{agent_id: agent_id} do
      tool = update_attrs_tool(agent_id)

      args = %{"file_path" => "no-slash.md", "attrs" => %{"title" => "x"}}

      assert {:error, message} = tool.function.(args, %{state: State.new!()})
      assert message =~ "must start with"
    end

    test "to_llm_map output is consistent across list_files, create_file, update_file_attrs",
         %{agent_id: agent_id} do
      tools =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files", "create_file", "update_file_attrs"],
          file_schema: FileEntry
        })

      create_tool = tool_named(tools, "create_file")
      list_tool = tool_named(tools, "list_files")
      update_tool = tool_named(tools, "update_file_attrs")

      {:ok, create_json} =
        create_tool.function.(
          %{"file_path" => "/doc.md", "content" => "hi"},
          %{state: State.new!()}
        )

      {:ok, list_json} = list_tool.function.(%{}, %{state: State.new!()})

      {:ok, update_json} =
        update_tool.function.(
          %{"file_path" => "/doc.md", "attrs" => %{"title" => "Title"}},
          %{state: State.new!()}
        )

      create_map = Jason.decode!(create_json)
      [list_map] = Jason.decode!(list_json)
      update_map = Jason.decode!(update_json)

      # All three should have the same shape (path, entry_type, file_type, etc.)
      assert Map.keys(create_map) -- [:title] == Map.keys(list_map) -- [:title]
      assert Map.keys(update_map) -- ["title"] == Map.keys(create_map) -- ["title"]
    end
  end

  describe "FileSchema callback contract" do
    test "FileEntry implements the FileSchema behaviour" do
      assert function_exported?(FileEntry, :changeset, 1)
      assert function_exported?(FileEntry, :to_llm_map, 1)
    end

    test "behaviours/0 lists FileSchema for FileEntry" do
      assert Sagents.FileSystem.FileSchema in FileEntry.module_info(:attributes)[:behaviour]
    end
  end
end
