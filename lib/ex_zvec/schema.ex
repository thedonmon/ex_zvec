defmodule ExZvec.Schema do
  @moduledoc """
  Defines the field schema for a zvec collection.

  A schema specifies which fields a collection has beyond the required
  `pk` and `embedding` fields. Fields can be plain string storage or
  indexed for filtering.

  ## Default Schema

  If no schema is provided, ExZvec uses a sensible default:

  - `content` — string (stored, not indexed)
  - `title` — string (stored, not indexed)
  - `scope` — string with inverted index (for multi-tenant filtering)
  - `scope_id` — string with inverted index
  - `source_type` — string with inverted index
  - `tags` — array of strings with inverted index

  ## Custom Schemas

      schema = ExZvec.Schema.new([
        {:string, "content"},
        {:string, "title"},
        {:string, "author"},
        {:filtered, "category"},
        {:filtered, "tenant_id"},
        {:tags, "labels"}
      ])

      ExZvec.Collection.start_link(
        name: :my_coll,
        path: "/tmp/data",
        collection: "docs",
        vector_dims: 768,
        schema: schema
      )

  ## Field Types

  - `{:string, name}` — Stored string field, returned in search results
  - `{:filtered, name}` — String field with inverted index, can be used in filter expressions
  - `{:tags, name}` — Array of strings with inverted index, stored as comma-separated
  """

  @type field_type :: :string | :filtered | :tags
  @type field_def :: {field_type(), String.t()}

  @type t :: %__MODULE__{
          fields: [field_def()]
        }

  defstruct fields: []

  @default_fields [
    {:string, "content"},
    {:string, "title"},
    {:filtered, "scope"},
    {:filtered, "scope_id"},
    {:filtered, "source_type"},
    {:tags, "tags"}
  ]

  @doc """
  Create a new schema from a list of field definitions.

  ## Examples

      ExZvec.Schema.new([
        {:string, "content"},
        {:filtered, "tenant_id"},
        {:tags, "labels"}
      ])
  """
  @spec new([field_def()]) :: t()
  def new(fields) when is_list(fields) do
    Enum.each(fields, &validate_field!/1)
    %__MODULE__{fields: fields}
  end

  @doc "Returns the default schema with content, title, scope fields, and tags."
  @spec default() :: t()
  def default do
    %__MODULE__{fields: @default_fields}
  end

  @doc "Returns the list of all field names in the schema."
  @spec field_names(t()) :: [String.t()]
  def field_names(%__MODULE__{fields: fields}) do
    Enum.map(fields, fn {_type, name} -> name end)
  end

  @doc "Returns field names that are stored strings (returned in search results)."
  @spec string_fields(t()) :: [String.t()]
  def string_fields(%__MODULE__{fields: fields}) do
    for {type, name} <- fields, type in [:string, :filtered], do: name
  end

  @doc "Returns field names that have inverted indexes (usable in filters)."
  @spec filtered_fields(t()) :: [String.t()]
  def filtered_fields(%__MODULE__{fields: fields}) do
    for {type, name} <- fields, type in [:filtered, :tags], do: name
  end

  @doc "Returns tag field names (array string fields)."
  @spec tag_fields(t()) :: [String.t()]
  def tag_fields(%__MODULE__{fields: fields}) do
    for {:tags, name} <- fields, do: name
  end

  defp validate_field!({type, name})
       when type in [:string, :filtered, :tags] and is_binary(name) do
    :ok
  end

  defp validate_field!(field) do
    raise ArgumentError,
          "Invalid field definition: #{inspect(field)}. " <>
            "Expected {:string | :filtered | :tags, \"field_name\"}"
  end
end
