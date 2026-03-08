defmodule ExZvec.TextIndexTest do
  use ExUnit.Case, async: false

  alias ExZvec.TextIndex

  setup do
    {:ok, pid} =
      TextIndex.start_link(
        name: :"text_index_#{System.unique_integer([:positive])}",
        table_name: :"test_text_#{System.unique_integer([:positive])}"
      )

    %{pid: pid}
  end

  describe "index and search" do
    test "indexes and retrieves documents by keyword", %{pid: pid} do
      TextIndex.index_doc(pid, "doc-1", "Elixir is a functional programming language", %{source: "wiki"})
      TextIndex.index_doc(pid, "doc-2", "Rust is a systems programming language", %{source: "wiki"})
      TextIndex.index_doc(pid, "doc-3", "Elixir runs on the BEAM virtual machine", %{source: "blog"})

      # Small delay for async casts
      Process.sleep(50)

      results = TextIndex.search(pid, "elixir programming")

      assert length(results) > 0
      ids = Enum.map(results, & &1.id)
      assert "doc-1" in ids
    end

    test "returns results sorted by BM25 score", %{pid: pid} do
      TextIndex.index_doc(pid, "a", "elixir elixir elixir")
      TextIndex.index_doc(pid, "b", "elixir once")
      Process.sleep(50)

      results = TextIndex.search(pid, "elixir")
      assert length(results) == 2
      # "a" should score higher (more occurrences)
      assert hd(results).id == "a"
    end

    test "returns empty for no matches", %{pid: pid} do
      TextIndex.index_doc(pid, "doc-1", "hello world")
      Process.sleep(50)

      assert TextIndex.search(pid, "nonexistent") == []
    end

    test "respects max_results", %{pid: pid} do
      for i <- 1..10 do
        TextIndex.index_doc(pid, "doc-#{i}", "common keyword here")
      end

      Process.sleep(50)

      results = TextIndex.search(pid, "common keyword", max_results: 3)
      assert length(results) == 3
    end
  end

  describe "remove" do
    test "removes a document from the index", %{pid: pid} do
      TextIndex.index_doc(pid, "doc-1", "unique special term")
      Process.sleep(50)

      assert length(TextIndex.search(pid, "unique special")) > 0

      TextIndex.remove_doc(pid, "doc-1")
      Process.sleep(50)

      assert TextIndex.search(pid, "unique special") == []
    end
  end

  describe "metadata" do
    test "returns metadata with search results", %{pid: pid} do
      TextIndex.index_doc(pid, "doc-1", "some content here", %{category: "test", priority: "high"})
      Process.sleep(50)

      [result] = TextIndex.search(pid, "content")
      assert result.metadata.category == "test"
      assert result.metadata.priority == "high"
    end
  end
end
