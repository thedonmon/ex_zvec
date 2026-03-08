defmodule ExZvec.SchemaTest do
  use ExUnit.Case, async: true

  alias ExZvec.Schema

  describe "new/1" do
    test "creates a schema from field definitions" do
      schema =
        Schema.new([
          {:string, "content"},
          {:filtered, "category"},
          {:tags, "labels"}
        ])

      assert Schema.field_names(schema) == ["content", "category", "labels"]
    end

    test "raises on invalid field type" do
      assert_raise ArgumentError, fn ->
        Schema.new([{:invalid, "field"}])
      end
    end

    test "raises on non-string field name" do
      assert_raise ArgumentError, fn ->
        Schema.new([{:string, :not_a_string}])
      end
    end
  end

  describe "default/0" do
    test "returns the default schema" do
      schema = Schema.default()
      names = Schema.field_names(schema)

      assert "content" in names
      assert "title" in names
      assert "scope" in names
      assert "scope_id" in names
      assert "source_type" in names
      assert "tags" in names
    end
  end

  describe "field accessors" do
    setup do
      schema =
        Schema.new([
          {:string, "content"},
          {:string, "title"},
          {:filtered, "category"},
          {:filtered, "tenant_id"},
          {:tags, "labels"}
        ])

      %{schema: schema}
    end

    test "string_fields includes string and filtered fields", %{schema: schema} do
      fields = Schema.string_fields(schema)
      assert "content" in fields
      assert "title" in fields
      assert "category" in fields
      assert "tenant_id" in fields
      refute "labels" in fields
    end

    test "filtered_fields includes filtered and tags fields", %{schema: schema} do
      fields = Schema.filtered_fields(schema)
      assert "category" in fields
      assert "tenant_id" in fields
      assert "labels" in fields
      refute "content" in fields
    end

    test "tag_fields returns only tag fields", %{schema: schema} do
      assert Schema.tag_fields(schema) == ["labels"]
    end
  end
end
