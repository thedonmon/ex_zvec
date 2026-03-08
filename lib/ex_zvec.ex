defmodule ExZvec do
  @moduledoc """
  Elixir bindings for zvec — Alibaba's embedded C++ vector database.

  ExZvec provides in-process vector similarity search on the BEAM via
  Rustler NIFs. No external services needed — the database runs embedded
  in your Elixir application.

  ## Quick Start

      # Open or create a collection
      {:ok, coll} = ExZvec.Collection.start_link(
        name: :my_vectors,
        path: "/tmp/my_vectors",
        collection: "embeddings",
        vector_dims: 1536
      )

      # Insert a document
      ExZvec.Collection.upsert(:my_vectors,
        pk: "doc-1",
        embedding: my_embedding,
        fields: %{
          "content" => "Elixir is a functional language",
          "title" => "About Elixir",
          "category" => "programming"
        }
      )

      # Search by vector similarity
      {:ok, results} = ExZvec.Collection.search(:my_vectors,
        vector: query_embedding,
        top_k: 10
      )

      # Search with filters
      {:ok, results} = ExZvec.Collection.search(:my_vectors,
        vector: query_embedding,
        top_k: 5,
        filter: "category = 'programming'"
      )

  ## Schema

  Collections have a fixed set of field types:

  - **Vector field** (`embedding`): HNSW-indexed FP32 vectors for similarity search
  - **String fields** (`content`, `title`): Stored but not indexed
  - **Filtered fields**: String fields with inverted indexes for SQL-like filtering
  - **Tags field**: Array of strings with inverted index

  See `ExZvec.Schema` to define custom schemas beyond the defaults.

  ## Scope Isolation

  Filtered fields enable multi-tenant isolation without separate collections:

      ExZvec.Collection.search(:my_vectors,
        vector: query_embedding,
        top_k: 10,
        filter: "tenant_id = 'org-42'"
      )

  ## Build Requirements

  You need zvec built from source:

      export ZVEC_DIR=/path/to/zvec          # zvec source root
      export ZVEC_BUILD_DIR=/path/to/zvec/build  # cmake build output
      mix compile
  """

  defdelegate start_link(opts), to: ExZvec.Collection
  defdelegate upsert(name, opts), to: ExZvec.Collection
  defdelegate remove(name, pk), to: ExZvec.Collection
  defdelegate search(name, opts), to: ExZvec.Collection
  defdelegate fetch(name, pk), to: ExZvec.Collection
  defdelegate flush(name), to: ExZvec.Collection
  defdelegate optimize(name), to: ExZvec.Collection
  defdelegate doc_count(name), to: ExZvec.Collection
end
