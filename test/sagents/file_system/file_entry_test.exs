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
      assert entry.dirty_content == false
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

    test "rejects paths with null bytes in segments" do
      assert {:error, error} = FileEntry.new_memory_file("/bad\0name/file.txt", "data")
      assert error =~ "invalid segment"
    end

    test "rejects paths with leading whitespace in segments" do
      assert {:error, error} = FileEntry.new_memory_file("/ leading/file.txt", "data")
      assert error =~ "invalid segment"
    end

    test "rejects paths with trailing whitespace in segments" do
      assert {:error, error} = FileEntry.new_memory_file("/trailing /file.txt", "data")
      assert error =~ "invalid segment"
    end

    test "rejects paths with empty segments (double slashes)" do
      assert {:error, error} = FileEntry.new_memory_file("/path//file.txt", "data")
      assert error =~ "invalid segment"
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
      assert entry.dirty_content == true
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
    test "marks a dirty persisted file as clean" do
      path = "/Memories/file.txt"
      content = "data"

      assert {:ok, entry} = FileEntry.new_persisted_file(path, content)
      assert entry.dirty_content == true

      clean_entry = FileEntry.mark_clean(entry)

      assert clean_entry.dirty_content == false
      assert clean_entry.content == content
      assert clean_entry.persistence == :persisted
    end

    test "clears dirty_non_content flag" do
      assert {:ok, entry} = FileEntry.new_persisted_file("/Memories/file.txt", "data")
      entry = %{entry | dirty_non_content: true}

      clean_entry = FileEntry.mark_clean(entry)

      assert clean_entry.dirty_content == false
      assert clean_entry.dirty_non_content == false
    end
  end

  describe "dirty_non_content flag" do
    test "defaults to false on new persisted file" do
      assert {:ok, entry} = FileEntry.new_persisted_file("/Memories/file.txt", "data")
      assert entry.dirty_non_content == false
    end

    test "defaults to false on new memory file" do
      assert {:ok, entry} = FileEntry.new_memory_file("/scratch/file.txt", "data")
      assert entry.dirty_non_content == false
    end

    test "update_content does not set dirty_non_content" do
      assert {:ok, entry} = FileEntry.new_persisted_file("/Memories/file.txt", "original")
      entry = FileEntry.mark_clean(entry)

      assert {:ok, updated} = FileEntry.update_content(entry, "changed")

      assert updated.dirty_content == true
      assert updated.dirty_non_content == false
    end
  end

  describe "update_content/3" do
    test "updates memory file content without marking dirty" do
      path = "/scratch/file.txt"
      original_content = "original"
      new_content = "updated"

      assert {:ok, entry} = FileEntry.new_memory_file(path, original_content)
      assert entry.dirty_content == false

      assert {:ok, updated_entry} = FileEntry.update_content(entry, new_content)

      assert updated_entry.content == new_content
      assert updated_entry.dirty_content == false
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
      # persistence, loaded, and dirty_content have defaults, so they won't error
    end

    test "accepts valid attributes" do
      attrs = %{
        path: "/valid/path.txt",
        content: "data",
        persistence: :memory,
        loaded: true,
        dirty_content: false
      }

      changeset = FileEntry.changeset(%FileEntry{}, attrs)
      assert changeset.valid?
    end
  end

  describe "update_entry_changeset/2" do
    test "casts title" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data")
      changeset = FileEntry.update_entry_changeset(entry, %{title: "New Title"})
      assert changeset.valid?
      assert changeset.changes == %{title: "New Title"}
    end

    test "casts id" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data")
      changeset = FileEntry.update_entry_changeset(entry, %{id: "abc-123"})
      assert changeset.valid?
      assert changeset.changes == %{id: "abc-123"}
    end

    test "casts file_type" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data")
      changeset = FileEntry.update_entry_changeset(entry, %{file_type: "json"})
      assert changeset.valid?
      assert changeset.changes == %{file_type: "json"}
    end

    test "casts multiple attrs at once" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data")

      changeset =
        FileEntry.update_entry_changeset(entry, %{title: "Doc", id: "x", file_type: "pdf"})

      assert changeset.valid?
      assert changeset.changes == %{title: "Doc", id: "x", file_type: "pdf"}
    end

    test "ignores unknown keys" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data")

      changeset =
        FileEntry.update_entry_changeset(entry, %{title: "New", content: "hack", path: "/bad"})

      assert changeset.valid?
      assert changeset.changes == %{title: "New"}
    end

    test "returns empty changes when attrs match current values" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data", title: "Same")
      changeset = FileEntry.update_entry_changeset(entry, %{title: "Same"})
      assert changeset.valid?
      assert changeset.changes == %{}
    end
  end

  describe "state transitions" do
    test "memory file lifecycle" do
      path = "/scratch/temp.txt"

      # Create
      assert {:ok, entry} = FileEntry.new_memory_file(path, "initial")
      assert [entry.persistence, entry.loaded, entry.dirty_content] == [:memory, true, false]

      # Update
      assert {:ok, updated} = FileEntry.update_content(entry, "modified")

      assert [updated.persistence, updated.loaded, updated.dirty_content] == [
               :memory,
               true,
               false
             ]

      # Memory files never become dirty
      assert updated.dirty_content == false
    end

    test "persisted file lifecycle" do
      path = "/Memories/file.txt"

      # Create (dirty)
      assert {:ok, entry} = FileEntry.new_persisted_file(path, "initial")
      assert [entry.persistence, entry.loaded, entry.dirty_content] == [:persisted, true, true]

      # Mark clean (after persist)
      clean = FileEntry.mark_clean(entry)
      assert [clean.persistence, clean.loaded, clean.dirty_content] == [:persisted, true, false]

      # Modify (becomes dirty)
      assert {:ok, modified} = FileEntry.update_content(clean, "modified")

      assert [modified.persistence, modified.loaded, modified.dirty_content] == [
               :persisted,
               true,
               true
             ]

      # Mark clean again
      clean_again = FileEntry.mark_clean(modified)

      assert [clean_again.persistence, clean_again.loaded, clean_again.dirty_content] ==
               [:persisted, true, false]
    end

    test "indexed file lazy load lifecycle" do
      path = "/Memories/file.txt"

      # Index (not loaded)
      assert {:ok, entry} = FileEntry.new_indexed_file(path)
      assert [entry.persistence, entry.loaded, entry.dirty_content] == [:persisted, false, false]
      assert entry.content == nil

      # Load
      assert {:ok, loaded} = FileEntry.mark_loaded(entry, "loaded content")

      assert [loaded.persistence, loaded.loaded, loaded.dirty_content] == [
               :persisted,
               true,
               false
             ]

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
      assert entry.dirty_content == true
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
      assert entry.dirty_content == false
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
      assert updated.dirty_content == true
      # Custom metadata preserved
      assert updated.metadata.custom == %{"tags" => ["draft"], "author" => "Alice"}
      # created_at preserved
      assert updated.metadata.created_at == entry.metadata.created_at
      # modified_at updated
      assert DateTime.compare(updated.metadata.modified_at, entry.metadata.modified_at) in [
               :gt,
               :eq
             ]
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

  describe "id field" do
    test "defaults to nil on all factory functions" do
      {:ok, mem} = FileEntry.new_memory_file("/test.txt", "data")
      assert mem.id == nil

      {:ok, per} = FileEntry.new_persisted_file("/test.txt", "data")
      assert per.id == nil

      {:ok, idx} = FileEntry.new_indexed_file("/test.txt")
      assert idx.id == nil

      {:ok, dir} = FileEntry.new_directory("/test")
      assert dir.id == nil
    end

    test "factory functions accept id option" do
      {:ok, mem} = FileEntry.new_memory_file("/test.txt", "data", id: "mem-1")
      assert mem.id == "mem-1"

      {:ok, per} = FileEntry.new_persisted_file("/test.txt", "data", id: "per-1")
      assert per.id == "per-1"

      {:ok, idx} = FileEntry.new_indexed_file("/test.txt", id: "idx-1")
      assert idx.id == "idx-1"

      {:ok, dir} = FileEntry.new_directory("/test", id: "dir-1")
      assert dir.id == "dir-1"
    end

    test "survives update_content" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data", id: "abc")
      {:ok, updated} = FileEntry.update_content(entry, "new data")
      assert updated.id == "abc"
    end

    test "survives mark_loaded" do
      {:ok, entry} = FileEntry.new_indexed_file("/test.txt", id: "abc")
      {:ok, loaded} = FileEntry.mark_loaded(entry, "content")
      assert loaded.id == "abc"
    end
  end

  describe "file_type field" do
    test "defaults to markdown for file factory functions" do
      {:ok, mem} = FileEntry.new_memory_file("/test.txt", "data")
      assert mem.file_type == "markdown"

      {:ok, per} = FileEntry.new_persisted_file("/test.txt", "data")
      assert per.file_type == "markdown"

      {:ok, idx} = FileEntry.new_indexed_file("/test.txt")
      assert idx.file_type == "markdown"
    end

    test "defaults to nil for directories" do
      {:ok, dir} = FileEntry.new_directory("/test")
      assert dir.file_type == nil
    end

    test "factory functions accept file_type option" do
      {:ok, mem} = FileEntry.new_memory_file("/test.json", "[]", file_type: "json")
      assert mem.file_type == "json"

      {:ok, per} = FileEntry.new_persisted_file("/test.pdf", "data", file_type: "pdf")
      assert per.file_type == "pdf"

      {:ok, idx} = FileEntry.new_indexed_file("/test.png", file_type: "image")
      assert idx.file_type == "image"
    end

    test "survives update_content" do
      {:ok, entry} = FileEntry.new_memory_file("/test.txt", "data", file_type: "json")
      {:ok, updated} = FileEntry.update_content(entry, "new data")
      assert updated.file_type == "json"
    end

    test "survives mark_loaded" do
      {:ok, entry} = FileEntry.new_indexed_file("/test.txt", file_type: "pdf")
      {:ok, loaded} = FileEntry.mark_loaded(entry, "content")
      assert loaded.file_type == "pdf"
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
