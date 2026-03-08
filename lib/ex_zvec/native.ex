defmodule ExZvec.Native do
  @moduledoc """
  Low-level Rustler NIF bindings to zvec.

  Most users should use `ExZvec.Collection` instead. These functions
  operate directly on NIF resource references and run on dirty CPU
  schedulers to avoid blocking the BEAM.
  """

  use Rustler,
    otp_app: :ex_zvec,
    crate: :ex_zvec,
    path: "native/ex_zvec"

  # -- Collection lifecycle --------------------------------------------------

  @doc "Open or create a zvec collection. Returns a NIF resource reference."
  def open_collection(_path, _name, _vector_dims, _schema_json),
    do: :erlang.nif_error(:nif_not_loaded)

  # -- CRUD ------------------------------------------------------------------

  @doc "Insert or update a document with its embedding and field values."
  def nif_upsert(_ref, _pk, _embedding, _fields_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Delete a document by primary key."
  def nif_remove(_ref, _pk),
    do: :erlang.nif_error(:nif_not_loaded)

  # -- Search ----------------------------------------------------------------

  @doc """
  Vector similarity search. Returns list of `{pk, score, fields_json}` tuples.

  Filter is a SQL-like expression for fields with inverted indexes:

      "scope = 'Global'"
      "tenant_id = 'org-123' AND source_type = 'article'"
  """
  def nif_search(_ref, _query_vector, _topk, _filter),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Fetch a single document by primary key. Returns `{pk, fields_json}`."
  def nif_fetch(_ref, _pk),
    do: :erlang.nif_error(:nif_not_loaded)

  # -- Maintenance -----------------------------------------------------------

  @doc "Flush writes to disk."
  def nif_flush(_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Optimize indexes (merge segments, rebuild HNSW graph)."
  def nif_optimize(_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get the number of documents in the collection."
  def nif_doc_count(_ref),
    do: :erlang.nif_error(:nif_not_loaded)
end
