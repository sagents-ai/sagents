defmodule Sagents.TextLinesTest do
  use ExUnit.Case, async: true

  alias Sagents.TextLines

  describe "split/1" do
    test "nil returns single empty line" do
      assert {[""], 1} = TextLines.split(nil)
    end

    test "empty string returns single empty line" do
      assert {[""], 1} = TextLines.split("")
    end

    test "single line" do
      assert {["hello"], 1} = TextLines.split("hello")
    end

    test "multiple lines" do
      assert {["a", "b", "c"], 3} = TextLines.split("a\nb\nc")
    end

    test "trailing newline is a terminator, not a separate line" do
      # POSIX-convention files end with "\n". String.split produces a phantom
      # empty element; `split/1` drops it so line counts match editor
      # conventions and LLMs don't try to edit a line that isn't there.
      assert {["a", "b"], 2} = TextLines.split("a\nb\n")
      assert {["a", "b", "c"], 3} = TextLines.split("a\nb\nc\n")
    end

    test "body with multiple trailing newlines keeps the intentional empties" do
      # Only the terminator is dropped — intentional blank lines stay.
      assert {["a", ""], 2} = TextLines.split("a\n\n")
      assert {["a", "", ""], 3} = TextLines.split("a\n\n\n")
    end
  end

  describe "render/2" do
    test "formats lines with right-aligned 6-char numbers and tab separator" do
      body = "first\nsecond\nthird"
      {formatted, 1, 3, 3} = TextLines.render(body)

      assert formatted =~ "     1\tfirst"
      assert formatted =~ "     2\tsecond"
      assert formatted =~ "     3\tthird"
    end

    test "paginates with offset and limit" do
      body = "a\nb\nc\nd\ne"
      {formatted, 2, 3, 5} = TextLines.render(body, start_line: 2, limit: 2)

      assert formatted =~ "Showing lines 2 to 3 of 5"
      assert formatted =~ "     2\tb"
      assert formatted =~ "     3\tc"
      refute formatted =~ "     1\ta"
      refute formatted =~ "     4\td"
    end

    test "no header when showing entire document" do
      body = "one\ntwo"
      {formatted, 1, 2, 2} = TextLines.render(body)

      refute formatted =~ "Showing lines"
    end

    test "offset beyond content returns empty-ish result" do
      body = "a\nb"
      {formatted, 100, 99, 2} = TextLines.render(body, start_line: 100)

      assert formatted =~ "Showing lines 100 to 99 of 2"
    end

    test "nil body renders as single empty line" do
      {formatted, 1, 1, 1} = TextLines.render(nil)
      assert formatted =~ "     1\t"
    end
  end

  describe "count_occurrences/2" do
    test "zero occurrences" do
      assert 0 = TextLines.count_occurrences("hello world", "xyz")
    end

    test "one occurrence" do
      assert 1 = TextLines.count_occurrences("hello world", "world")
    end

    test "multiple occurrences" do
      assert 3 = TextLines.count_occurrences("abcabcabc", "abc")
    end
  end

  describe "replace_text/4" do
    test "replaces single occurrence" do
      assert {:ok, "hello planet", 1} = TextLines.replace_text("hello world", "world", "planet")
    end

    test "errors on zero matches" do
      assert {:error, msg} = TextLines.replace_text("hello world", "xyz", "abc")
      assert msg =~ "String not found"
    end

    test "errors on multiple matches without replace_all" do
      assert {:error, msg} = TextLines.replace_text("aa bb aa", "aa", "cc")
      assert msg =~ "appears 2 times"
    end

    test "replaces all with replace_all: true" do
      assert {:ok, "cc bb cc", 2} = TextLines.replace_text("aa bb aa", "aa", "cc", true)
    end
  end

  describe "find/3" do
    test "literal match returns line numbers and context" do
      body = "alpha\nbeta\ngamma\ndelta\nepsilon"
      assert {:ok, [match], false} = TextLines.find(body, "gamma")

      assert match.line_number == 3
      assert match.line == "gamma"
      assert match.context_before == ["alpha", "beta"]
      assert match.context_after == ["delta", "epsilon"]
    end

    test "multiple matches" do
      body = "foo\nbar\nfoo\nbaz\nfoo"
      assert {:ok, matches, false} = TextLines.find(body, "foo")
      assert length(matches) == 3
      assert Enum.map(matches, & &1.line_number) == [1, 3, 5]
    end

    test "regex match" do
      body = "apple 42\nbanana 99\ncherry 7"
      assert {:ok, matches, false} = TextLines.find(body, "\\d{2,}", regex: true)
      assert length(matches) == 2
      assert Enum.map(matches, & &1.line_number) == [1, 2]

      assert {:ok, all_matches, false} = TextLines.find(body, "\\d+", regex: true)
      assert length(all_matches) == 3
    end

    test "case insensitive" do
      body = "Hello\nworld"
      assert {:ok, [match], false} = TextLines.find(body, "hello", case_sensitive: false)
      assert match.line_number == 1
    end

    test "respects max_matches" do
      body = Enum.map_join(1..50, "\n", fn i -> "line #{i}" end)
      assert {:ok, matches, true} = TextLines.find(body, "line", max_matches: 5)
      assert length(matches) == 5
    end

    test "no matches returns empty list" do
      assert {:ok, [], false} = TextLines.find("hello world", "xyz")
    end

    test "invalid regex returns error" do
      assert {:error, msg} = TextLines.find("hello", "[invalid", regex: true)
      assert msg =~ "Invalid regex"
    end

    test "context at start of document is truncated" do
      body = "first\nsecond\nthird\nfourth"
      assert {:ok, [match], false} = TextLines.find(body, "first")
      assert match.context_before == []
      assert match.context_after == ["second", "third"]
    end

    test "context at end of document is truncated" do
      body = "first\nsecond\nthird\nfourth"
      assert {:ok, [match], false} = TextLines.find(body, "fourth")
      assert match.context_before == ["second", "third"]
      assert match.context_after == []
    end
  end
end
