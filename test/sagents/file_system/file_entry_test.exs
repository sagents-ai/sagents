defmodule Sagents.FileSystem.FileEntryTest do
  use ExUnit.Case, async: true

  alias Sagents.FileSystem.FileEntry
  alias Sagents.FileSystem.FileMetadata

  describe "new_memory_file/3" do
    test "creates a memory file entry" do
      path = "/scratch/temp.txt"
      content = "temporary data"

      assert {:ok, entry} = FileEntry.new_memory_file(path, content)

      assert entry.path == path
      assert entry.content == content
      assert entry.persistence == :memory
      assert entry.loaded == true
      assert entry.dirty == false
      assert %FileMetadata{} = entry.metadata
      assert entry.metadata.size == byte_size(content)
    end

    test "creates memory file with custom metadata" do
      path = "/data.json"
      content = ~s({"key": "value"})

      assert {:ok, entry} =
               FileEntry.new_memory_file(path, content, mime_type: "application/json")

      assert entry.metadata.mime_type == "application/json"
    end

    test "validates path format" do
      # Path must start with /
      assert {:error, error} = FileEntry.new_memory_file("invalid/path", "data")
      assert error =~ "path"
      assert error =~ "must start with /"
    end

    test "rejects paths with .." do
      assert {:error, error} = FileEntry.new_memory_file("/path/../etc/passwd", "data")
      assert error =~ "path"
      assert error =~ "cannot contain .."
    end
  end

  describe "new_persisted_file/3" do
    test "creates a persisted file entry marked as dirty" do
      path = "/Memories/important.txt"
      content = "important data"

      assert {:ok, entry} = FileEntry.new_persisted_file(path, content)

      assert entry.path == path
      assert entry.content == content
      assert entry.persistence == :persisted
      assert entry.loaded == true
      assert entry.dirty == true
      assert %FileMetadata{} = entry.metadata
    end

    test "creates persisted file with custom options" do
      path = "/Memories/notes.md"
      content = "# Notes"
      custom = %{"author" => "Alice"}

      assert {:ok, entry} =
               FileEntry.new_persisted_file(path, content,
                 mime_type: "text/markdown",
                 custom: custom
               )

      assert entry.metadata.mime_type == "text/markdown"
      assert entry.metadata.custom == custom
    end
  end

  describe "new_indexed_file/1" do
    test "creates an unloaded file entry for indexing" do
      path = "/Memories/file.txt"

      assert {:ok, entry} = FileEntry.new_indexed_file(path)

      assert entry.path == path
      assert entry.content == nil
      assert entry.persistence == :persisted
      assert entry.loaded == false
      assert entry.dirty == false
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
    test "marks a dirty persisted file as clean" do
      path = "/Memories/file.txt"
      content = "data"

      assert {:ok, entry} = FileEntry.new_persisted_file(path, content)
      assert entry.dirty == true

      clean_entry = FileEntry.mark_clean(entry)

      assert clean_entry.dirty == false
      assert clean_entry.content == content
      assert clean_entry.persistence == :persisted
    end
  end

  describe "update_content/3" do
    test "updates memory file content without marking dirty" do
      path = "/scratch/file.txt"
      original_content = "original"
      new_content = "updated"

      assert {:ok, entry} = FileEntry.new_memory_file(path, original_content)
      assert entry.dirty == false

      assert {:ok, updated_entry} = FileEntry.update_content(entry, new_content)

      assert updated_entry.content == new_content
      assert updated_entry.dirty == false
      assert updated_entry.loaded == true
      assert updated_entry.metadata.size == byte_size(new_content)
    end

    test "updates persisted file content and marks dirty" do
      path = "/Memories/file.txt"
      original_content = "original"
      new_content = "updated"

      # Create and mark clean first
      assert {:ok, entry} = FileEntry.new_persisted_file(path, original_content)
      clean_entry = FileEntry.mark_clean(entry)
      assert clean_entry.dirty == false

      # Update content
      assert {:ok, updated_entry} = FileEntry.update_content(clean_entry, new_content)

      assert updated_entry.content == new_content
      assert updated_entry.dirty == true
      assert updated_entry.loaded == true
      assert updated_entry.metadata.size == byte_size(new_content)
    end

    test "updates with custom metadata options" do
      path = "/file.txt"
      assert {:ok, entry} = FileEntry.new_memory_file(path, "data")

      assert {:ok, updated} =
               FileEntry.update_content(entry, "new data", mime_type: "text/markdown")

      assert updated.metadata.mime_type == "text/markdown"
    end
  end

  describe "changeset/2" do
    test "validates required fields" do
      changeset = FileEntry.changeset(%FileEntry{}, %{})
      refute changeset.valid?
      assert changeset.errors[:path]
      # persistence, loaded, and dirty have defaults, so they won't error
    end

    test "accepts valid attributes" do
      attrs = %{
        path: "/valid/path.txt",
        content: "data",
        persistence: :memory,
        loaded: true,
        dirty: false
      }

      changeset = FileEntry.changeset(%FileEntry{}, attrs)
      assert changeset.valid?
    end
  end

  describe "state transitions" do
    test "memory file lifecycle" do
      path = "/scratch/temp.txt"

      # Create
      assert {:ok, entry} = FileEntry.new_memory_file(path, "initial")
      assert [entry.persistence, entry.loaded, entry.dirty] == [:memory, true, false]

      # Update
      assert {:ok, updated} = FileEntry.update_content(entry, "modified")
      assert [updated.persistence, updated.loaded, updated.dirty] == [:memory, true, false]

      # Memory files never become dirty
      assert updated.dirty == false
    end

    test "persisted file lifecycle" do
      path = "/Memories/file.txt"

      # Create (dirty)
      assert {:ok, entry} = FileEntry.new_persisted_file(path, "initial")
      assert [entry.persistence, entry.loaded, entry.dirty] == [:persisted, true, true]

      # Mark clean (after persist)
      clean = FileEntry.mark_clean(entry)
      assert [clean.persistence, clean.loaded, clean.dirty] == [:persisted, true, false]

      # Modify (becomes dirty)
      assert {:ok, modified} = FileEntry.update_content(clean, "modified")
      assert [modified.persistence, modified.loaded, modified.dirty] == [:persisted, true, true]

      # Mark clean again
      clean_again = FileEntry.mark_clean(modified)

      assert [clean_again.persistence, clean_again.loaded, clean_again.dirty] ==
               [:persisted, true, false]
    end

    test "indexed file lazy load lifecycle" do
      path = "/Memories/file.txt"

      # Index (not loaded)
      assert {:ok, entry} = FileEntry.new_indexed_file(path)
      assert [entry.persistence, entry.loaded, entry.dirty] == [:persisted, false, false]
      assert entry.content == nil

      # Load
      assert {:ok, loaded} = FileEntry.mark_loaded(entry, "loaded content")
      assert [loaded.persistence, loaded.loaded, loaded.dirty] == [:persisted, true, false]
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

  describe "new_directory/2" do
    test "creates a directory entry" do
      assert {:ok, entry} = FileEntry.new_directory("/Characters")

      assert entry.path == "/Characters"
      assert entry.entry_type == :directory
      assert entry.content == nil
      assert entry.loaded == true
      assert entry.persistence == :persisted
      assert entry.dirty == true
    end

    test "creates directory with title and custom metadata" do
      assert {:ok, entry} =
               FileEntry.new_directory("/Characters",
                 title: "Characters",
                 custom: %{"position" => 1}
               )

      assert entry.title == "Characters"
      assert entry.metadata.custom == %{"position" => 1}
    end

    test "creates memory directory" do
      assert {:ok, entry} = FileEntry.new_directory("/temp", persistence: :memory)

      assert entry.persistence == :memory
      assert entry.dirty == false
    end
  end

  describe "directory?/1" do
    test "returns true for directory entries" do
      {:ok, entry} = FileEntry.new_directory("/test")
      assert FileEntry.directory?(entry)
    end

    test "returns false for file entries" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data")
      refute FileEntry.directory?(entry)
    end
  end

  describe "update_content/3 with directories" do
    test "rejects content updates on directory entries" do
      {:ok, dir} = FileEntry.new_directory("/test")
      assert {:error, :directory_has_no_content} = FileEntry.update_content(dir, "some content")
    end
  end

  describe "update_content/3 preserves metadata" do
    test "preserves custom metadata on content update" do
      {:ok, entry} =
        FileEntry.new_persisted_file("/test.txt", "original",
          custom: %{"tags" => ["draft"], "author" => "Alice"}
        )

      clean = FileEntry.mark_clean(entry)

      assert {:ok, updated} = FileEntry.update_content(clean, "modified")

      assert updated.content == "modified"
      assert updated.dirty == true
      # Custom metadata preserved
      assert updated.metadata.custom == %{"tags" => ["draft"], "author" => "Alice"}
      # created_at preserved
      assert updated.metadata.created_at == entry.metadata.created_at
      # modified_at updated
      assert DateTime.compare(updated.metadata.modified_at, entry.metadata.modified_at) in [:gt, :eq]
    end
  end

  describe "title field" do
    test "new_memory_file accepts title option" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data", title: "My Doc")
      assert entry.title == "My Doc"
    end

    test "new_persisted_file accepts title option" do
      {:ok, entry} = FileEntry.new_persisted_file("/test.txt", "data", title: "My Doc")
      assert entry.title == "My Doc"
    end

    test "title defaults to nil" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data")
      assert entry.title == nil
    end
  end

  describe "new_indexed_file/2 with options" do
    test "accepts title and entry_type" do
      {:ok, entry} =
        FileEntry.new_indexed_file("/Characters",
          title: "Characters",
          entry_type: :directory
        )

      assert entry.title == "Characters"
      assert entry.entry_type == :directory
      assert entry.loaded == true
      assert entry.content == nil
    end

    test "accepts metadata" do
      {:ok, metadata} = FileMetadata.new("", custom: %{"position" => 1})

      {:ok, entry} =
        FileEntry.new_indexed_file("/test.txt", metadata: metadata)

      assert entry.metadata.custom == %{"position" => 1}
    end
  end

  describe "mark_loaded/2 preserves metadata" do
    test "preserves custom metadata when loading content" do
      {:ok, metadata} = FileMetadata.new("", custom: %{"tags" => ["important"]})

      {:ok, entry} = FileEntry.new_indexed_file("/test.txt", metadata: metadata)

      assert {:ok, loaded} = FileEntry.mark_loaded(entry, "loaded content")

      assert loaded.content == "loaded content"
      assert loaded.loaded == true
      # Custom metadata preserved
      assert loaded.metadata.custom == %{"tags" => ["important"]}
    end
  end
end
