defmodule ExZvec.CollectionTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Integration tests for ExZvec.Collection.

  These tests require zvec to be compiled and linked.
  Set ZVEC_DIR and ZVEC_BUILD_DIR environment variables.
  """

  @test_dims 4
  @test_dir System.tmp_dir!() |> Path.join("ex_zvec_coll_test_#{System.unique_integer([:positive])}")

  setup_all do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    {:ok, _pid} =
      ExZvec.Collection.start_link(
        name: :test_collection,
        path: @test_dir,
        collection: "test_vectors",
        vector_dims: @test_dims,
        schema:
          ExZvec.Schema.new([
            {:string, "content"},
            {:string, "title"},
            {:filtered, "category"},
            {:filtered, "tenant_id"},
            {:tags, "labels"}
          ])
      )

    # Seed all test data up front
    ExZvec.Collection.upsert(:test_collection,
      pk: "doc-1",
      embedding: [1.0, 0.0, 0.0, 0.0],
      fields: %{
        "content" => "Elixir is a dynamic functional language",
        "title" => "About Elixir",
        "category" => "programming",
        "tenant_id" => "org-1",
        "labels" => "elixir,beam,functional"
      }
    )

    ExZvec.Collection.upsert(:test_collection,
      pk: "doc-2",
      embedding: [0.0, 1.0, 0.0, 0.0],
      fields: %{
        "content" => "Rust is a systems language",
        "title" => "About Rust",
        "category" => "programming",
        "tenant_id" => "org-2",
        "labels" => "rust,systems"
      }
    )

    ExZvec.Collection.upsert(:test_collection,
      pk: "doc-3",
      embedding: [0.9, 0.1, 0.0, 0.0],
      fields: %{
        "content" => "BEAM virtual machine",
        "title" => "About BEAM",
        "category" => "infrastructure",
        "tenant_id" => "org-1",
        "labels" => "beam,erlang"
      }
    )

    ExZvec.Collection.upsert(:test_collection,
      pk: "doc-4",
      embedding: [0.5, 0.5, 0.0, 0.0],
      fields: %{
        "content" => "Docker containers",
        "title" => "About Docker",
        "category" => "infrastructure",
        "tenant_id" => "org-2",
        "labels" => "docker,containers"
      }
    )

    ExZvec.Collection.flush(:test_collection)
    Process.sleep(200)

    :ok
  end

  test "fetch retrieves a document by pk" do
    {:ok, result} = ExZvec.Collection.fetch(:test_collection, "doc-1")
    assert result.pk == "doc-1"
    assert result.fields["content"] == "Elixir is a dynamic functional language"
    assert result.fields["title"] == "About Elixir"
    assert result.fields["category"] == "programming"
    assert result.fields["labels"] == "elixir,beam,functional"
  end

  test "fetch returns error for non-existent document" do
    assert {:error, :not_found} =
             ExZvec.Collection.fetch(:test_collection, "nonexistent-pk")
  end

  test "upsert auto-generates pk" do
    {:ok, pk} =
      ExZvec.Collection.upsert(:test_collection,
        embedding: [0.0, 0.0, 0.0, 1.0],
        fields: %{
          "content" => "Auto-generated ID",
          "title" => "",
          "category" => "test",
          "tenant_id" => "",
          "labels" => ""
        }
      )

    assert is_binary(pk)
    assert byte_size(pk) == 32
  end

  test "search finds similar vectors" do
    {:ok, results} =
      ExZvec.Collection.search(:test_collection,
        vector: [1.0, 0.0, 0.0, 0.0],
        top_k: 4
      )

    assert length(results) > 0
    # doc-1 [1,0,0,0] and doc-3 [0.9,0.1,0,0] should rank highest
    pks = Enum.map(results, & &1.pk)
    assert "doc-1" in pks
    assert "doc-3" in pks
  end

  test "search results include scores" do
    {:ok, results} =
      ExZvec.Collection.search(:test_collection,
        vector: [1.0, 0.0, 0.0, 0.0],
        top_k: 4
      )

    Enum.each(results, fn r ->
      assert is_float(r.score)
      assert is_binary(r.pk)
      assert is_map(r.fields)
    end)
  end

  test "search with category filter" do
    {:ok, results} =
      ExZvec.Collection.search(:test_collection,
        vector: [0.5, 0.5, 0.0, 0.0],
        top_k: 10,
        filter: "category = 'infrastructure'"
      )

    pks = Enum.map(results, & &1.pk)
    assert "doc-3" in pks or "doc-4" in pks

    # Programming docs should not appear
    refute "doc-1" in pks
    refute "doc-2" in pks
  end

  test "search with tenant isolation" do
    {:ok, results} =
      ExZvec.Collection.search(:test_collection,
        vector: [0.5, 0.5, 0.0, 0.0],
        top_k: 10,
        filter: "tenant_id = 'org-1'"
      )

    pks = Enum.map(results, & &1.pk)
    # Only org-1 docs
    assert "doc-1" in pks or "doc-3" in pks
    refute "doc-2" in pks
    refute "doc-4" in pks
  end

  test "search respects min_score" do
    {:ok, results} =
      ExZvec.Collection.search(:test_collection,
        vector: [1.0, 0.0, 0.0, 0.0],
        top_k: 10,
        min_score: 0.9
      )

    Enum.each(results, fn r ->
      assert r.score >= 0.9
    end)
  end

  test "doc_count returns correct count" do
    count = ExZvec.Collection.doc_count(:test_collection)
    assert is_integer(count)
    assert count >= 4
  end

  test "optimize does not crash" do
    assert :ok = ExZvec.Collection.optimize(:test_collection)
    Process.sleep(100)
  end

  test "remove deletes a document" do
    # Insert a doc specifically for deletion
    {:ok, _} =
      ExZvec.Collection.upsert(:test_collection,
        pk: "to-delete",
        embedding: [0.0, 0.0, 1.0, 0.0],
        fields: %{
          "content" => "Will be deleted",
          "title" => "",
          "category" => "temp",
          "tenant_id" => "",
          "labels" => ""
        }
      )

    ExZvec.Collection.flush(:test_collection)

    count_before = ExZvec.Collection.doc_count(:test_collection)
    :ok = ExZvec.Collection.remove(:test_collection, "to-delete")
    count_after = ExZvec.Collection.doc_count(:test_collection)

    assert count_after == count_before - 1
  end
end
