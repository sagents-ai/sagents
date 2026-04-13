defmodule Sagents.FileSystem.FileEntryTest do
  use ExUnit.Case, async: true

  alias Sagents.FileSystem.FileEntry
  alias Sagents.FileSystem.FileMetadata

  describe "new_file/3" do
    test "creates a file entry" do
      path = "/scratch/temp.txt"
      content = "temporary data"

      assert {:ok, entry} = FileEntry.new_file(path, content)

      assert entry.path == path
      assert entry.content == content
      assert entry.loaded == true
      # New files are always dirty so any registered backend picks them up.
      assert entry.dirty_content == true
      assert %FileMetadata{} = entry.metadata
      assert entry.metadata.size == byte_size(content)
    end

    test "creates file with custom mime_type" do
      path = "/data.json"
      content = ~s({"key": "value"})

      assert {:ok, entry} =
               FileEntry.new_file(path, content, mime_type: "application/json")

      assert entry.metadata.mime_type == "application/json"
    end

    test "validates path format" do
      # Path must start with /
      assert {:error, error} = FileEntry.new_file("invalid/path", "data")
      assert error =~ "path"
      assert error =~ "must start with /"
    end

    test "rejects paths with .." do
      assert {:error, error} = FileEntry.new_file("/path/../etc/passwd", "data")
      assert error =~ "path"
      assert error =~ "cannot contain .."
    end

    test "rejects paths with null bytes in segments" do
      assert {:error, error} = FileEntry.new_file("/bad\0name/file.txt", "data")
      assert error =~ "invalid segment"
    end

    test "rejects paths with leading whitespace in segments" do
      assert {:error, error} = FileEntry.new_file("/ leading/file.txt", "data")
      assert error =~ "invalid segment"
    end

    test "rejects paths with trailing whitespace in segments" do
      assert {:error, error} = FileEntry.new_file("/trailing /file.txt", "data")
      assert error =~ "invalid segment"
    end

    test "rejects paths with empty segments (double slashes)" do
      assert {:error, error} = FileEntry.new_file("/path//file.txt", "data")
      assert error =~ "invalid segment"
    end
  end

  describe "new_indexed_file/1" do
    test "creates an unloaded file entry for indexing" do
      path = "/Memories/file.txt"

      assert {:ok, entry} = FileEntry.new_indexed_file(path)

      assert entry.path == path
      assert entry.content == nil
      assert entry.loaded == false
      assert entry.dirty_content == false
      assert entry.metadata == nil
    end
  end

  describe "mark_loaded/2" do
    test "marks an indexed file as loaded with content" do
      path = "/Memories/file.txt"
      content = "now loaded"

      assert {:ok, entry} = FileEntry.new_indexed_file(path)
      assert entry.loaded == false
      assert entry.content == nil

      assert {:ok, loaded_entry} = FileEntry.mark_loaded(entry, content)

      assert loaded_entry.path == path
      assert loaded_entry.content == content
      assert loaded_entry.loaded == true
      assert %FileMetadata{} = loaded_entry.metadata
      assert loaded_entry.metadata.size == byte_size(content)
    end
  end

  describe "mark_clean/1" do
    test "marks a dirty file as clean" do
      path = "/Memories/file.txt"
      content = "data"

      assert {:ok, entry} = FileEntry.new_file(path, content)
      assert entry.dirty_content == true

      clean_entry = FileEntry.mark_clean(entry)

      assert clean_entry.dirty_content == false
      assert clean_entry.content == content
    end
  end

  describe "update_content/3" do
    test "updates content and marks dirty" do
      path = "/Memories/file.txt"
      original_content = "original"
      new_content = "updated"

      # Create and mark clean first
      assert {:ok, entry} = FileEntry.new_file(path, original_content)
      clean_entry = FileEntry.mark_clean(entry)
      assert clean_entry.dirty_content == false

      # Update content
      assert {:ok, updated_entry} = FileEntry.update_content(clean_entry, new_content)

      assert updated_entry.content == new_content
      assert updated_entry.dirty_content == true
      assert updated_entry.loaded == true
      assert updated_entry.metadata.size == byte_size(new_content)
    end

    test "updates with custom metadata options" do
      path = "/file.txt"
      assert {:ok, entry} = FileEntry.new_file(path, "data")

      assert {:ok, updated} =
               FileEntry.update_content(entry, "new data", mime_type: "text/markdown")

      assert updated.metadata.mime_type == "text/markdown"
    end
  end

  describe "internal_changeset/2" do
    test "validates required fields" do
      changeset = FileEntry.internal_changeset(%FileEntry{}, %{})
      refute changeset.valid?
      assert changeset.errors[:path]
      # loaded and dirty_content have defaults, so they won't error
    end

    test "accepts valid attributes" do
      attrs = %{
        path: "/valid/path.txt",
        content: "data",
        loaded: true,
        dirty_content: false
      }

      changeset = FileEntry.internal_changeset(%FileEntry{}, attrs)
      assert changeset.valid?
    end
  end

  describe "to_llm_map/1" do
    test "returns expected fields" do
      {:ok, entry} = FileEntry.new_file("/Characters/Hero", "data")
      result = FileEntry.to_llm_map(entry)

      assert result.path == "/Characters/Hero"
      assert result.mime_type == "text/markdown"
      assert is_integer(result.size)
    end

    test "uses provided mime_type" do
      {:ok, entry} = FileEntry.new_file("/x.json", "[]", mime_type: "application/json")
      assert FileEntry.to_llm_map(entry).mime_type == "application/json"
    end
  end

  describe "state transitions" do
    test "file create/update/clean lifecycle" do
      path = "/Memories/file.txt"

      # Create (dirty)
      assert {:ok, entry} = FileEntry.new_file(path, "initial")
      assert [entry.loaded, entry.dirty_content] == [true, true]

      # Mark clean (after persist)
      clean = FileEntry.mark_clean(entry)
      assert [clean.loaded, clean.dirty_content] == [true, false]

      # Modify (becomes dirty)
      assert {:ok, modified} = FileEntry.update_content(clean, "modified")

      assert [modified.loaded, modified.dirty_content] == [true, true]

      # Mark clean again
      clean_again = FileEntry.mark_clean(modified)

      assert [clean_again.loaded, clean_again.dirty_content] == [true, false]
    end

    test "indexed file lazy load lifecycle" do
      path = "/Memories/file.txt"

      # Index (not loaded)
      assert {:ok, entry} = FileEntry.new_indexed_file(path)
      assert [entry.loaded, entry.dirty_content] == [false, false]
      assert entry.content == nil

      # Load
      assert {:ok, loaded} = FileEntry.mark_loaded(entry, "loaded content")

      assert [loaded.loaded, loaded.dirty_content] == [true, false]

      assert loaded.content == "loaded content"
    end
  end

  describe "valid_name?/1" do
    test "accepts normal names" do
      assert FileEntry.valid_name?("My Document")
      assert FileEntry.valid_name?("hero-character")
      assert FileEntry.valid_name?("Notes (Draft)")
      assert FileEntry.valid_name?("café")
    end

    test "rejects empty string" do
      refute FileEntry.valid_name?("")
    end

    test "rejects names containing /" do
      refute FileEntry.valid_name?("path/segment")
    end

    test "rejects names containing null bytes" do
      refute FileEntry.valid_name?("bad\0name")
    end

    test "rejects names with leading/trailing whitespace" do
      refute FileEntry.valid_name?(" leading")
      refute FileEntry.valid_name?("trailing ")
      refute FileEntry.valid_name?("  both  ")
    end

    test "rejects non-binary values" do
      refute FileEntry.valid_name?(nil)
      refute FileEntry.valid_name?(123)
    end
  end

  describe "update_content/3 preserves metadata" do
    test "preserves created_at and updates modified_at" do
      {:ok, entry} = FileEntry.new_file("/test.txt", "original")

      clean = FileEntry.mark_clean(entry)

      assert {:ok, updated} = FileEntry.update_content(clean, "modified")

      assert updated.content == "modified"
      assert updated.dirty_content == true
      # created_at preserved
      assert updated.metadata.created_at == entry.metadata.created_at
      # modified_at updated
      assert DateTime.compare(updated.metadata.modified_at, entry.metadata.modified_at) in [
               :gt,
               :eq
             ]
    end
  end

  describe "new_indexed_file/2 with options" do
    test "accepts metadata" do
      {:ok, metadata} = FileMetadata.new("", mime_type: "application/json")

      {:ok, entry} =
        FileEntry.new_indexed_file("/test.txt", metadata: metadata)

      assert entry.metadata.mime_type == "application/json"
    end
  end
end
