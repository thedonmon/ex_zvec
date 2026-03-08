#pragma once

#include "rust/cxx.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Generic C++ wrapper around zvec::Collection.
// Schema is configurable via JSON passed at creation time.
// Fields are stored/retrieved as JSON strings for flexibility.

namespace ex_zvec {

// Forward-declared; defined by cxx codegen from shared structs in lib.rs
struct SearchResult;
struct FetchResult;

class ZvecCollection {
public:
    ZvecCollection(const std::string& path,
                   const std::string& name,
                   uint32_t vector_dims,
                   const std::string& schema_json);
    ~ZvecCollection();

    // Insert or update a document. fields_json is a JSON object of field values.
    bool upsert(rust::Str pk,
                rust::Slice<const float> embedding,
                rust::Str fields_json) const;

    // Delete a document by primary key.
    bool remove(rust::Str pk) const;

    // Vector similarity search with optional SQL-like filter.
    // Returns results with fields serialized as JSON.
    rust::Vec<SearchResult> search(rust::Slice<const float> query_vector,
                                    uint32_t topk,
                                    rust::Str filter) const;

    // Fetch a single document by primary key.
    FetchResult fetch(rust::Str pk) const;

    // Flush writes to disk.
    bool flush() const;

    // Optimize indexes (merge segments, rebuild).
    bool optimize() const;

    // Get the number of documents in the collection.
    uint64_t doc_count() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Factory: create a new collection or open an existing one.
// schema_json defines the fields beyond pk and embedding.
std::unique_ptr<ZvecCollection> create_or_open_collection(
    rust::Str path,
    rust::Str name,
    uint32_t vector_dims,
    rust::Str schema_json);

}  // namespace ex_zvec
