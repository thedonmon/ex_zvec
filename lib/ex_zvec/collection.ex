defmodule ExZvec.Collection do
  @moduledoc """
  A GenServer wrapping a single zvec collection.

  Each collection is an independent vector store with its own schema,
  HNSW index, and on-disk storage. Start one per logical dataset:

      {:ok, _pid} = ExZvec.Collection.start_link(
        name: :products,
        path: "/data/zvec",
        collection: "product_embeddings",
        vector_dims: 768,
        schema: ExZvec.Schema.new([
          {:string, "name"},
          {:string, "description"},
          {:filtered, "category"},
          {:tags, "labels"}
        ])
      )

  ## Options

  - `:name` — GenServer name (atom or via tuple). Required.
  - `:path` — Directory for on-disk storage. Created if missing.
  - `:collection` — Collection name (subdirectory under path).
  - `:vector_dims` — Embedding dimensionality (e.g., 1536 for OpenAI).
  - `:schema` — `ExZvec.Schema` struct. Defaults to `ExZvec.Schema.default()`.
  """

  use GenServer

  require Logger

  alias ExZvec.Native
  alias ExZvec.Schema

  defstruct [:ref, :schema, :name]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Insert or update a document.

  ## Options

  - `:pk` — Primary key (string). Auto-generated if omitted.
  - `:embedding` — List of floats (must match collection's vector_dims).
  - `:fields` — Map of field name => value. Values are strings or list of strings (for tags).

  Returns `{:ok, pk}` or `{:error, reason}`.
  """
  def upsert(name, opts) do
    GenServer.call(name, {:upsert, opts}, 15_000)
  end

  @doc "Remove a document by primary key."
  def remove(name, pk) do
    GenServer.call(name, {:remove, pk}, 10_000)
  end

  @doc """
  Vector similarity search.

  ## Options

  - `:vector` — Query embedding (list of floats). Required.
  - `:top_k` — Number of results. Default 10.
  - `:filter` — SQL-like filter string. Default "" (no filter).
  - `:min_score` — Minimum score threshold. Default 0.0.

  Returns `{:ok, results}` where each result is:

      %{
        pk: "doc-1",
        score: 0.92,
        fields: %{"content" => "...", "title" => "..."}
      }
  """
  def search(name, opts) do
    GenServer.call(name, {:search, opts}, 30_000)
  end

  @doc """
  Fetch a single document by primary key.

  Returns `{:ok, result}` or `{:error, :not_found}`.
  """
  def fetch(name, pk) do
    GenServer.call(name, {:fetch, pk}, 10_000)
  end

  @doc "Flush writes to disk."
  def flush(name) do
    GenServer.call(name, :flush, 10_000)
  end

  @doc "Trigger async index optimization (merge segments, rebuild HNSW)."
  def optimize(name) do
    GenServer.cast(name, :optimize)
  end

  @doc "Get the number of documents in the collection."
  def doc_count(name) do
    GenServer.call(name, :doc_count, 5_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    collection = Keyword.fetch!(opts, :collection)
    vector_dims = Keyword.get(opts, :vector_dims, 1536)
    schema = Keyword.get(opts, :schema, Schema.default())
    name = Keyword.fetch!(opts, :name)

    File.mkdir_p!(path)

    schema_json = schema_to_json(schema)
    ref = Native.open_collection(path, collection, vector_dims, schema_json)

    state = %__MODULE__{
      ref: ref,
      schema: schema,
      name: name
    }

    Logger.info("ExZvec collection '#{collection}' opened at #{path} (dims=#{vector_dims})")
    {:ok, state}
  end

  @impl true
  def handle_call({:upsert, opts}, _from, state) do
    pk = Keyword.get(opts, :pk) || generate_id()
    embedding = Keyword.fetch!(opts, :embedding)
    fields = Keyword.get(opts, :fields, %{})

    # Encode tags as comma-separated within the fields map
    fields = encode_tag_fields(fields, state.schema)
    fields_json = Jason.encode!(fields)

    case Native.nif_upsert(state.ref, pk, embedding, fields_json) do
      true -> {:reply, {:ok, pk}, state}
      false -> {:reply, {:error, :upsert_failed}, state}
    end
  end

  def handle_call({:remove, pk}, _from, state) do
    Native.nif_remove(state.ref, pk)
    {:reply, :ok, state}
  end

  def handle_call({:search, opts}, _from, state) do
    vector = Keyword.fetch!(opts, :vector)
    top_k = Keyword.get(opts, :top_k, 10)
    filter = Keyword.get(opts, :filter, "")
    min_score = Keyword.get(opts, :min_score, 0.0)

    raw_results = Native.nif_search(state.ref, vector, top_k, filter)

    results =
      raw_results
      |> Enum.map(fn {pk, score, fields_json} ->
        fields = Jason.decode!(fields_json)
        %{pk: pk, score: score, fields: fields}
      end)
      |> Enum.filter(&(&1.score >= min_score))

    {:reply, {:ok, results}, state}
  end

  def handle_call({:fetch, pk}, _from, state) do
    try do
      {fetched_pk, fields_json} = Native.nif_fetch(state.ref, pk)
      fields = Jason.decode!(fields_json)
      {:reply, {:ok, %{pk: fetched_pk, fields: fields}}, state}
    catch
      :error, %ErlangError{} -> {:reply, {:error, :not_found}, state}
      _, _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:flush, _from, state) do
    result = Native.nif_flush(state.ref)
    {:reply, result, state}
  end

  def handle_call(:doc_count, _from, state) do
    {:reply, Native.nif_doc_count(state.ref), state}
  end

  @impl true
  def handle_cast(:optimize, state) do
    Task.start(fn ->
      Native.nif_optimize(state.ref)
      Logger.info("ExZvec optimization complete for #{inspect(state.name)}")
    end)

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp schema_to_json(%Schema{fields: fields}) do
    encoded =
      Enum.map(fields, fn {type, name} ->
        %{"type" => Atom.to_string(type), "name" => name}
      end)

    Jason.encode!(encoded)
  end

  # Convert list values in tag fields to comma-separated strings
  defp encode_tag_fields(fields, %Schema{} = schema) do
    tag_names = Schema.tag_fields(schema) |> MapSet.new()

    Map.new(fields, fn {key, value} ->
      if key in tag_names and is_list(value) do
        {key, Enum.join(value, ",")}
      else
        {key, value}
      end
    end)
  end
end
