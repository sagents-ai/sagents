defmodule Sagents.Middleware.FileSystemTest do
  use ExUnit.Case, async: false

  alias Sagents.Middleware.FileSystem
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
               "replace_file_text",
               "replace_file_lines",
               "find_in_file",
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

    test "rejects unknown tool name in enabled_tools", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 enabled_tools: ["list_files", "search_text"]
               )

      assert message =~ "Unknown tool name(s) in :enabled_tools"
      assert message =~ "search_text"
      # The valid tool list is included so users can spot the rename
      assert message =~ "find_in_file"
    end

    test "reports all unknown tool names in enabled_tools", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 enabled_tools: ["list_files", "bogus_one", "bogus_two"]
               )

      assert message =~ "bogus_one"
      assert message =~ "bogus_two"
    end

    test "rejects non-list :enabled_tools", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 enabled_tools: "list_files"
               )

      assert message =~ ":enabled_tools must be a list"
    end

    test "accepts an empty enabled_tools list", %{agent_id: agent_id} do
      assert {:ok, config} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 enabled_tools: []
               )

      assert config.enabled_tools == []
    end

    test "rejects unknown tool name in custom_tool_descriptions", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 custom_tool_descriptions: %{"search_text" => "old name"}
               )

      assert message =~ "Unknown tool name(s) in :custom_tool_descriptions"
      assert message =~ "search_text"
      # The valid tool list is included so users can spot the rename
      assert message =~ "find_in_file"
    end

    test "reports all unknown keys in custom_tool_descriptions", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 custom_tool_descriptions: %{
                   "read_file" => "valid",
                   "bogus_one" => "x",
                   "bogus_two" => "y"
                 }
               )

      assert message =~ "bogus_one"
      assert message =~ "bogus_two"
    end

    test "allows custom_tool_descriptions for tools not in enabled_tools", %{agent_id: agent_id} do
      # A description for a tool the user has temporarily disabled is still
      # allowed — we're catching typos and renames, not enforcing that every
      # described tool be enabled.
      assert {:ok, config} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 enabled_tools: ["list_files", "read_file"],
                 custom_tool_descriptions: %{"find_in_file" => "Custom find description"}
               )

      assert config.custom_tool_descriptions == %{"find_in_file" => "Custom find description"}
    end

    test "rejects non-map :custom_tool_descriptions", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 custom_tool_descriptions: [{"read_file", "x"}]
               )

      assert message =~ ":custom_tool_descriptions must be a map"
    end

    test "initializes with empty custom_display_texts by default", %{agent_id: agent_id} do
      assert {:ok, config} = FileSystem.init(agent_id: agent_id)
      assert config.custom_display_texts == %{}
    end

    test "initializes with custom display texts", %{agent_id: agent_id} do
      custom = %{"create_file" => "Writing document"}

      assert {:ok, config} =
               FileSystem.init(agent_id: agent_id, custom_display_texts: custom)

      assert config.custom_display_texts == custom
    end

    test "rejects unknown tool name in custom_display_texts", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 custom_display_texts: %{"search_text" => "Searching"}
               )

      assert message =~ "Unknown tool name(s) in :custom_display_texts"
      assert message =~ "search_text"
      assert message =~ "find_in_file"
    end

    test "rejects non-string value in custom_display_texts", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 custom_display_texts: %{"create_file" => :not_a_string}
               )

      assert message =~ ":custom_display_texts values must be strings"
    end

    test "rejects non-map :custom_display_texts", %{agent_id: agent_id} do
      assert {:error, message} =
               FileSystem.init(
                 filesystem_scope: {:agent, agent_id},
                 custom_display_texts: [{"create_file", "x"}]
               )

      assert message =~ ":custom_display_texts must be a map"
    end
  end

  describe "display_text configuration" do
    test "each tool uses its default display_text when no overrides", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      tools = FileSystem.tools(config)
      by_name = Map.new(tools, fn t -> {t.name, t.display_text} end)

      assert by_name["list_files"] == "Listing files"
      assert by_name["read_file"] == "Reading file"
      assert by_name["create_file"] == "Creating file"
      assert by_name["replace_file_text"] == "Replacing file text"
      assert by_name["replace_file_lines"] == "Replacing file lines"
      assert by_name["find_in_file"] == "Searching file"
      assert by_name["delete_file"] == "Deleting file"
      assert by_name["move_file"] == "Moving file"
    end

    test "overridden tools use custom display_text; others keep defaults",
         %{agent_id: agent_id} do
      {:ok, config} =
        FileSystem.init(
          agent_id: agent_id,
          custom_display_texts: %{
            "create_file" => "Writing document",
            "delete_file" => "Removing document"
          }
        )

      tools = FileSystem.tools(config)
      by_name = Map.new(tools, fn t -> {t.name, t.display_text} end)

      # Overridden
      assert by_name["create_file"] == "Writing document"
      assert by_name["delete_file"] == "Removing document"

      # Unaffected
      assert by_name["read_file"] == "Reading file"
      assert by_name["list_files"] == "Listing files"
    end
  end

  describe "system_prompt/1" do
    @all_tools [
      "list_files",
      "read_file",
      "create_file",
      "replace_file_text",
      "replace_file_lines",
      "find_in_file",
      "delete_file",
      "move_file"
    ]

    test "defaults include every tool and all sections" do
      prompt = FileSystem.system_prompt(%{})

      assert prompt =~ "Virtual Filesystem"
      assert prompt =~ "must start with a forward slash"
      assert prompt =~ "Pattern Filtering"
      assert prompt =~ "Best Practices"
      assert prompt =~ "Persistence Behavior"

      for tool <- @all_tools do
        assert prompt =~ tool, "expected default prompt to mention #{tool}"
      end
    end

    test "read-only subset omits write tools and their best-practices" do
      prompt = FileSystem.system_prompt(%{enabled_tools: ["list_files", "read_file"]})

      assert prompt =~ "list_files"
      assert prompt =~ "read_file"
      # list_files enabled → pattern filtering retained
      assert prompt =~ "Pattern Filtering"

      for tool <-
            ~w(create_file replace_file_text replace_file_lines find_in_file delete_file move_file) do
        refute prompt =~ tool, "did not expect #{tool} in read-only prompt"
      end
    end

    test "two-stage commit subset: list_files, read_file, create_file" do
      enabled = ["list_files", "read_file", "create_file"]
      prompt = FileSystem.system_prompt(%{enabled_tools: enabled})

      for tool <- enabled do
        assert prompt =~ tool
      end

      for tool <- ~w(replace_file_text replace_file_lines find_in_file delete_file move_file) do
        refute prompt =~ tool
      end
    end

    test "without list_files the pattern filtering section is omitted" do
      prompt = FileSystem.system_prompt(%{enabled_tools: ["read_file"]})

      refute prompt =~ "Pattern Filtering"
      refute prompt =~ "list_files"
      assert prompt =~ "read_file"
    end

    test "best practices section is omitted when no bullets apply" do
      # find_in_file has no best-practice bullets in the map, so a lone
      # find_in_file config should skip the whole section.
      prompt = FileSystem.system_prompt(%{enabled_tools: ["find_in_file"]})

      refute prompt =~ "Best Practices"
      assert prompt =~ "find_in_file"
    end

    test "each tool produces a prompt mentioning itself when enabled alone" do
      for tool <- @all_tools do
        prompt = FileSystem.system_prompt(%{enabled_tools: [tool]})
        assert prompt =~ tool, "prompt for [#{tool}] did not mention #{tool}"
      end
    end
  end

  describe "tools/1" do
    test "returns all eight filesystem tools by default", %{agent_id: agent_id} do
      tools =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: [
            "list_files",
            "read_file",
            "create_file",
            "replace_file_text",
            "replace_file_lines",
            "find_in_file",
            "delete_file",
            "move_file"
          ]
        })

      assert length(tools) == 8
      tool_names = Enum.map(tools, & &1.name)
      assert "list_files" in tool_names
      assert "read_file" in tool_names
      assert "create_file" in tool_names
      assert "replace_file_text" in tool_names
      assert "replace_file_lines" in tool_names
      assert "find_in_file" in tool_names
      assert "delete_file" in tool_names
      assert "move_file" in tool_names
    end

    test "returns only enabled tools", %{agent_id: agent_id} do
      tools =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files", "read_file"]
        })

      assert length(tools) == 2
      tool_names = Enum.map(tools, & &1.name)
      assert "list_files" in tool_names
      assert "read_file" in tool_names
      refute "create_file" in tool_names
      refute "replace_file_text" in tool_names
    end

    test "old tool names no longer resolve", %{agent_id: agent_id} do
      tools =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
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
          enabled_tools: ["list_files"]
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
      assert entry["mime_type"] == "text/markdown"
      assert is_integer(entry["size"])
    end

    test "reports empty filesystem", %{agent_id: agent_id} do
      list_files_tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files"]
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
          enabled_tools: ["list_files"]
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

    test "reads file with start_line", %{tool: tool} do
      args = %{"file_path" => "/test.txt", "start_line" => 3}

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

    test "reads file with start_line and limit", %{tool: tool} do
      args = %{"file_path" => "/test.txt", "start_line" => 2, "limit" => 2}

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
          enabled_tools: ["create_file"]
        })
        |> tool_named("create_file")

      %{tool: tool}
    end

    test "creates new file and returns JSON entry map", %{agent_id: agent_id, tool: tool} do
      args = %{"file_path" => "/new.txt", "content" => "Hello, World!"}

      assert {:ok, result} = tool.function.(args, %{state: State.new!()})
      entry_map = Jason.decode!(result)
      assert entry_map["path"] == "/new.txt"
      assert entry_map["mime_type"] == "text/markdown"
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
      assert message =~ "replace_file_text or replace_file_lines"
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

  describe "replace_file_text tool" do
    setup %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/edit.txt", "Hello World")

      tool =
        FileSystem.tools(%{
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["replace_file_text"]
        })
        |> tool_named("replace_file_text")

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
          enabled_tools: ["move_file"]
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

  defp get_find_in_file_tool(tools) when is_list(tools) do
    Enum.find(tools, fn tool -> tool.name == "find_in_file" end)
  end

  describe "find_in_file tool - basic search" do
    test "find_in_file tool is enabled in FileSystem", %{agent_id: agent_id} do
      # Initialize middleware
      {:ok, config} = FileSystem.init(agent_id: agent_id)

      # Find the find_in_file tool
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()
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
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

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
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      args = %{"pattern" => "NOTFOUND", "file_path" => "/test.txt"}
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
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

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
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

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
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

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
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      args = %{"pattern" => "[invalid(regex", "file_path" => "/test.txt"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "Invalid regex pattern"
    end

    test "returns error for non-existent file", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      args = %{"pattern" => "test", "file_path" => "/nonexistent.txt"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "File not found"
    end
  end

  describe "find_in_file tool - context lines" do
    test "includes context lines before and after matches", %{agent_id: agent_id} do
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Before context 1
      Before context 2
      MATCH HERE
      After context 1
      After context 2
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

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
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      # Request 2 context lines, but match is at line 1 (no lines before)
      args = %{"pattern" => "MATCH", "file_path" => "/test.txt", "context_lines" => 2}
      {:ok, result} = search_tool.function.(args, %{})

      assert result =~ "     1\tMATCH at start"
      assert result =~ "     2 |\tAfter"
    end
  end

  describe "find_in_file tool - max_results limiting" do
    test "limits results to max_results parameter", %{agent_id: agent_id} do
      # Create a file with many matches
      content =
        Enum.map(1..100, fn i -> "Line #{i}: MATCH #{i}" end)
        |> Enum.join("\n")

      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", content)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

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
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      # Use default max_results (50)
      args = %{"pattern" => "MATCH", "file_path" => "/test.txt"}
      {:ok, result} = search_tool.function.(args, %{})

      # Should show truncation notice
      assert result =~ "Results truncated"
    end
  end

  describe "find_in_file tool - parameter validation" do
    test "returns error when pattern is missing", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      args = %{"file_path" => "/test.txt"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "pattern is required"
    end

    test "returns error when file_path is missing", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      args = %{"pattern" => "TODO"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "file_path is required"
    end

    test "rejects wildcard '*' in file_path", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      args = %{"pattern" => "TODO", "file_path" => "/chapters/*"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "Wildcards and globs are not supported"
      assert error_msg =~ "list_files"
    end

    test "rejects glob characters '?' and '[' in file_path", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      assert {:error, msg1} =
               search_tool.function.(%{"pattern" => "x", "file_path" => "/file?.txt"}, %{})

      assert msg1 =~ "Wildcards and globs are not supported"

      assert {:error, msg2} =
               search_tool.function.(%{"pattern" => "x", "file_path" => "/file[1].txt"}, %{})

      assert msg2 =~ "Wildcards and globs are not supported"
    end

    test "handles invalid path", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      # Path without leading slash
      args = %{"pattern" => "test", "file_path" => "invalid/path.txt"}
      {:error, error_msg} = search_tool.function.(args, %{})

      assert error_msg =~ "Path must start with '/'"
    end
  end

  describe "find_in_file tool - tool registration" do
    test "find_in_file tool is included in default enabled tools", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)

      assert "find_in_file" in config.enabled_tools
    end

    test "find_in_file tool can be disabled via config", %{agent_id: agent_id} do
      {:ok, config} =
        FileSystem.init(
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files", "read_file", "create_file"]
        )

      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      assert search_tool == nil
    end

    test "find_in_file tool has correct schema", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      search_tool = config |> FileSystem.tools() |> get_find_in_file_tool()

      assert search_tool.name == "find_in_file"
      assert is_binary(search_tool.description)

      # Verify parameters schema
      schema = search_tool.parameters_schema
      assert schema["type"] == "object"
      assert "pattern" in schema["required"]
      assert "file_path" in schema["required"]

      properties = schema["properties"]
      assert Map.has_key?(properties, "pattern")
      assert Map.has_key?(properties, "file_path")
      assert Map.has_key?(properties, "case_sensitive")
      assert Map.has_key?(properties, "context_lines")
      assert Map.has_key?(properties, "max_results")
    end
  end

  describe "find_in_file tool - integration scenarios" do
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
      search_tool = Enum.find(tools, fn tool -> tool.name == "find_in_file" end)
      args = %{"pattern" => "TODO", "file_path" => "/project.md"}
      {:ok, search_result} = search_tool.function.(args, %{})

      # Verify we found the TODOs (line numbers padded to 6 chars with tab separator)
      assert search_result =~ "     7\tTODO: Complete this section"
      assert search_result =~ "    13\tTODO: Add examples"

      # Now read the file to get more context
      read_tool = Enum.find(tools, fn tool -> tool.name == "read_file" end)
      read_args = %{"file_path" => "/project.md", "start_line" => 7, "limit" => 3}
      {:ok, read_result} = read_tool.function.(read_args, %{})

      # Should see the TODO line in context
      assert read_result =~ "TODO: Complete this section"
    end

    test "list_files then find_in_file workflow across multiple files", %{agent_id: agent_id} do
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
      tools = FileSystem.tools(config)

      # An LLM searching multiple files calls list_files first, then find_in_file
      # for each path it wants to inspect. This test verifies that compositional
      # workflow rather than a single multi-file call.
      list_tool = Enum.find(tools, fn tool -> tool.name == "list_files" end)
      {:ok, _list_result} = list_tool.function.(%{}, %{})

      search_tool = get_find_in_file_tool(tools)

      # Search "/config.json" for the literal "error" substring (case-insensitive)
      {:ok, config_result} =
        search_tool.function.(
          %{"pattern" => "error", "file_path" => "/config.json", "case_sensitive" => false},
          %{}
        )

      assert config_result =~ "/config.json"
      assert config_result =~ "     2\t  \"error_log\": true,"

      # Search "/app.log" for ERROR lines (case-insensitive)
      {:ok, log_result} =
        search_tool.function.(
          %{"pattern" => "error", "file_path" => "/app.log", "case_sensitive" => false},
          %{}
        )

      assert log_result =~ "/app.log"
      assert log_result =~ "     2\t2024-01-01 10:05:00 ERROR: Connection failed"
      assert log_result =~ "     4\t2024-01-01 10:15:00 ERROR: Timeout occurred"
    end
  end

  defp get_replace_lines_tool(tools) when is_list(tools) do
    Enum.find(tools, fn tool -> tool.name == "replace_file_lines" end)
  end

  describe "replace_file_lines tool - basic functionality" do
    test "replace_file_lines tool is enabled in FileSystem", %{agent_id: agent_id} do
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

  describe "replace_file_lines tool - boundary conditions" do
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
      # Heredoc produces "Line 1\nLine 2\nLine 3\n" — 3 content lines plus a
      # terminating newline. The file has 3 lines; the trailing \n is not a
      # fourth line. Replacing line 3 with new content produces a file that
      # still ends with \n.
      FileSystemServer.write_file({:agent, agent_id}, "/test.txt", """
      Line 1
      Line 2
      Line 3
      """)

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 3,
        "end_line" => 3,
        "new_content" => "REPLACED LAST LINE"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})
      assert result =~ "Replaced 1 lines (3-3)"

      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      assert content == "Line 1\nLine 2\nREPLACED LAST LINE\n"
    end

    test "errors when asked to replace a line beyond content length", %{agent_id: agent_id} do
      # Regression: previously a 3-line file with trailing \n was treated as
      # having 4 lines (phantom terminator). The tool silently allowed edits
      # at line 4, producing off-by-one bugs when LLMs mis-counted.
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
        "new_content" => "past the end"
      }

      {:error, msg} = replace_lines_tool.function.(args, %{})
      assert msg =~ "start_line 4 is beyond content length (3 lines)"
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
        "end_line" => 3,
        "new_content" => "Completely new content"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})
      assert result =~ "Replaced 3 lines (1-3)"

      {:ok, %{content: content}} = FileSystemServer.read_file({:agent, agent_id}, "/test.txt")
      # Trailing newline preserved since the original file had one.
      assert content == "Completely new content\n"
    end

    test "returns a post-edit preview with line numbers and surrounding context", %{
      agent_id: agent_id
    } do
      # Preview lets the model verify the edit landed correctly without a
      # follow-up read_file. Should include lines around the affected range
      # with post-edit line numbers.
      FileSystemServer.write_file(
        {:agent, agent_id},
        "/test.txt",
        "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf\nhotel\nindia\n"
      )

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      args = %{
        "file_path" => "/test.txt",
        "start_line" => 5,
        "end_line" => 5,
        "new_content" => "ECHO-REPLACED"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})

      assert result =~ "Context after edit:"
      # Edited line 5 + 2 context lines each side → expect lines 3..7.
      assert result =~ "     3\tcharlie"
      assert result =~ "     4\tdelta"
      assert result =~ "     5\tECHO-REPLACED"
      assert result =~ "     6\tfoxtrot"
      assert result =~ "     7\tgolf"
      # Lines outside the ±2 window should not appear.
      refute result =~ "     2\tbravo"
      refute result =~ "     8\thotel"
    end

    test "preview expands correctly when replacement adds lines", %{agent_id: agent_id} do
      FileSystemServer.write_file(
        {:agent, agent_id},
        "/test.txt",
        "a\nb\nc\nd\ne\n"
      )

      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      # Replace line 3 with 3 new lines — preview should show all 3 new
      # lines plus ±2 context.
      args = %{
        "file_path" => "/test.txt",
        "start_line" => 3,
        "end_line" => 3,
        "new_content" => "C1\nC2\nC3"
      }

      {:ok, result} = replace_lines_tool.function.(args, %{})

      # The 3 inserted lines all appear with their post-edit numbers.
      assert result =~ "     3\tC1"
      assert result =~ "     4\tC2"
      assert result =~ "     5\tC3"
      # Context on each side (±2).
      assert result =~ "     1\ta"
      assert result =~ "     2\tb"
      assert result =~ "     6\td"
      assert result =~ "     7\te"
    end

    test "deletes the range when new_content is empty", %{agent_id: agent_id} do
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
      assert content == "Line 1\nLine 3\n"
    end
  end

  describe "replace_file_lines tool - error cases" do
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
      assert error_msg =~ "start_line 10 is beyond content length"
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
      assert error_msg =~ "end_line 10 is beyond content length"
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

  describe "replace_file_lines tool - integration scenarios" do
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
      replace_lines_tool = Enum.find(tools, fn tool -> tool.name == "replace_file_lines" end)

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

    test "replace_file_lines can be disabled via config", %{agent_id: agent_id} do
      {:ok, config} =
        FileSystem.init(
          filesystem_scope: {:agent, agent_id},
          enabled_tools: ["list_files", "read_file", "create_file"]
        )

      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()
      assert replace_lines_tool == nil
    end

    test "replace_file_lines tool has correct schema", %{agent_id: agent_id} do
      {:ok, config} = FileSystem.init(agent_id: agent_id)
      replace_lines_tool = config |> FileSystem.tools() |> get_replace_lines_tool()

      assert replace_lines_tool.name == "replace_file_lines"
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
end
