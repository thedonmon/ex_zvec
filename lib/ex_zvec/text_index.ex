defmodule ExZvec.TextIndex do
  @moduledoc """
  Lightweight ETS-based BM25 text index for hybrid search.

  Provides keyword-based text search as a complement to vector similarity.
  Useful when embeddings are unavailable or for boosting results with
  keyword relevance.

  This is intentionally simple — not a replacement for Elasticsearch's
  full-text capabilities, but good enough for fallback/hybrid scoring.

  ## Usage

      {:ok, idx} = ExZvec.TextIndex.start_link(name: :my_text_index)

      ExZvec.TextIndex.index_doc(:my_text_index, "doc-1",
        "Elixir is a functional programming language",
        %{source: "wiki"}
      )

      results = ExZvec.TextIndex.search(:my_text_index, "functional elixir")
      # => [%{id: "doc-1", score: 2.34, metadata: %{source: "wiki"}}]
  """

  use GenServer

  @bm25_k1 1.2
  @bm25_b 0.75

  # -- Client API ------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Index a document for text search."
  def index_doc(pid \\ __MODULE__, id, content, metadata \\ %{}) do
    GenServer.cast(pid, {:index, id, content, metadata})
  end

  @doc "Remove a document from the text index."
  def remove_doc(pid \\ __MODULE__, id) do
    GenServer.cast(pid, {:remove, id})
  end

  @doc """
  Search by text query. Returns `[%{id, score, metadata}]` sorted by BM25 score.

  ## Options

  - `:max_results` — Maximum number of results. Default 10.
  - `:min_score` — Minimum BM25 score. Default 0.0.
  """
  def search(pid \\ __MODULE__, query, opts \\ []) do
    GenServer.call(pid, {:search, query, opts})
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, :ex_zvec_text)

    docs_table = :ets.new(:"#{table_name}_docs", [:set, :protected])
    terms_table = :ets.new(:"#{table_name}_terms", [:set, :protected])

    state = %{
      docs: docs_table,
      terms: terms_table,
      doc_count: 0,
      avg_doc_length: 0.0,
      total_length: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:index, id, content, metadata}, state) do
    tokens = tokenize(content)
    doc_length = length(tokens)
    term_freqs = Enum.frequencies(tokens)

    # Remove old entry if exists
    state = do_remove(id, state)

    # Insert doc record
    :ets.insert(state.docs, {id, term_freqs, doc_length, metadata})

    # Update inverted index
    for term <- Map.keys(term_freqs) do
      existing =
        case :ets.lookup(state.terms, term) do
          [{^term, set}] -> set
          [] -> MapSet.new()
        end

      :ets.insert(state.terms, {term, MapSet.put(existing, id)})
    end

    new_count = state.doc_count + 1
    new_total = state.total_length + doc_length
    new_avg = if new_count > 0, do: new_total / new_count, else: 0.0

    {:noreply, %{state | doc_count: new_count, total_length: new_total, avg_doc_length: new_avg}}
  end

  def handle_cast({:remove, id}, state) do
    {:noreply, do_remove(id, state)}
  end

  @impl true
  def handle_call({:search, query, opts}, _from, state) do
    max_results = Keyword.get(opts, :max_results, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    query_terms = tokenize(query)
    n = state.doc_count

    if n == 0 or query_terms == [] do
      {:reply, [], state}
    else
      candidate_ids =
        query_terms
        |> Enum.flat_map(fn term ->
          case :ets.lookup(state.terms, term) do
            [{^term, set}] -> MapSet.to_list(set)
            [] -> []
          end
        end)
        |> Enum.uniq()

      results =
        candidate_ids
        |> Enum.map(fn id ->
          case :ets.lookup(state.docs, id) do
            [{^id, term_freqs, doc_length, metadata}] ->
              score = bm25_score(query_terms, term_freqs, doc_length, n, state)
              %{id: id, score: score, metadata: metadata}

            [] ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&(&1.score >= min_score))
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(max_results)

      {:reply, results, state}
    end
  end

  # -- BM25 scoring ----------------------------------------------------------

  defp bm25_score(query_terms, term_freqs, doc_length, n, state) do
    avg_dl = state.avg_doc_length

    Enum.reduce(query_terms, 0.0, fn term, acc ->
      tf = Map.get(term_freqs, term, 0)

      df =
        case :ets.lookup(state.terms, term) do
          [{^term, set}] -> MapSet.size(set)
          [] -> 0
        end

      if df == 0 do
        acc
      else
        idf = :math.log((n - df + 0.5) / (df + 0.5) + 1.0)

        tf_norm =
          tf * (@bm25_k1 + 1) /
            (tf + @bm25_k1 * (1 - @bm25_b + @bm25_b * doc_length / max(avg_dl, 1.0)))

        acc + idf * tf_norm
      end
    end)
  end

  # -- Helpers ---------------------------------------------------------------

  defp do_remove(id, state) do
    case :ets.lookup(state.docs, id) do
      [{^id, term_freqs, doc_length, _metadata}] ->
        for term <- Map.keys(term_freqs) do
          case :ets.lookup(state.terms, term) do
            [{^term, set}] ->
              new_set = MapSet.delete(set, id)

              if MapSet.size(new_set) == 0 do
                :ets.delete(state.terms, term)
              else
                :ets.insert(state.terms, {term, new_set})
              end

            [] ->
              :ok
          end
        end

        :ets.delete(state.docs, id)

        new_count = max(state.doc_count - 1, 0)
        new_total = max(state.total_length - doc_length, 0)
        new_avg = if new_count > 0, do: new_total / new_count, else: 0.0

        %{state | doc_count: new_count, total_length: new_total, avg_doc_length: new_avg}

      [] ->
        state
    end
  end

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
  end

  defp tokenize(_), do: []
end
