// zvec_wrapper.cpp — Generic C++ wrapper around zvec::Collection.
//
// Schema is defined via JSON at collection creation time.
// Field values are passed as JSON strings for flexibility.
//
// Uses rust:: types (from cxx) at the API boundary, converts to std:: types
// internally for zvec calls.

#include "zvec_wrapper.h"
#include "ex_zvec/src/lib.rs.h"  // cxx-generated: SearchResult, FetchResult

#include <zvec/db/collection.h>
#include <zvec/db/doc.h>
#include <zvec/db/schema.h>
#include <zvec/db/index_params.h>
#include <zvec/db/query_params.h>
#include <zvec/db/type.h>

#include <filesystem>
#include <sstream>
#include <stdexcept>
#include <algorithm>

// Minimal JSON parsing — we only need simple flat objects.
// This avoids pulling in a heavy JSON library on the C++ side.
namespace json_util {

// Parse a flat JSON object: {"key": "value", ...}
// Values can be strings or comma-separated arrays stored as strings.
static std::vector<std::pair<std::string, std::string>> parse_object(const std::string& json) {
    std::vector<std::pair<std::string, std::string>> result;
    size_t i = 0;
    auto skip_ws = [&]() { while (i < json.size() && isspace(json[i])) i++; };

    skip_ws();
    if (i >= json.size() || json[i] != '{') return result;
    i++; // skip '{'

    while (i < json.size()) {
        skip_ws();
        if (json[i] == '}') break;
        if (json[i] == ',') { i++; continue; }

        // Parse key
        if (json[i] != '"') break;
        i++;
        size_t key_start = i;
        while (i < json.size() && json[i] != '"') i++;
        std::string key = json.substr(key_start, i - key_start);
        i++; // skip closing '"'

        skip_ws();
        if (json[i] != ':') break;
        i++; // skip ':'
        skip_ws();

        // Parse value (string)
        if (json[i] != '"') break;
        i++;
        size_t val_start = i;
        while (i < json.size() && json[i] != '"') {
            if (json[i] == '\\') i++; // skip escaped chars
            i++;
        }
        std::string val = json.substr(val_start, i - val_start);
        i++; // skip closing '"'

        result.emplace_back(std::move(key), std::move(val));
    }
    return result;
}

// Build a flat JSON object from key-value pairs.
static std::string build_object(const std::vector<std::pair<std::string, std::string>>& pairs) {
    std::string out = "{";
    for (size_t i = 0; i < pairs.size(); i++) {
        if (i > 0) out += ",";
        out += "\"" + pairs[i].first + "\":\"" + pairs[i].second + "\"";
    }
    out += "}";
    return out;
}

// Parse schema JSON: [{"type": "string", "name": "content"}, ...]
struct FieldDef {
    std::string type; // "string", "filtered", "tags"
    std::string name;
};

static std::vector<FieldDef> parse_schema(const std::string& json) {
    std::vector<FieldDef> fields;
    size_t i = 0;
    auto skip_ws = [&]() { while (i < json.size() && isspace(json[i])) i++; };

    skip_ws();
    if (i >= json.size() || json[i] != '[') return fields;
    i++; // skip '['

    while (i < json.size()) {
        skip_ws();
        if (json[i] == ']') break;
        if (json[i] == ',') { i++; continue; }

        // Parse one object
        if (json[i] != '{') break;
        // Find the closing brace
        size_t obj_start = i;
        int depth = 0;
        while (i < json.size()) {
            if (json[i] == '{') depth++;
            if (json[i] == '}') { depth--; if (depth == 0) { i++; break; } }
            i++;
        }
        std::string obj_str = json.substr(obj_start, i - obj_start);
        auto pairs = parse_object(obj_str);

        FieldDef fd;
        for (auto& p : pairs) {
            if (p.first == "type") fd.type = p.second;
            if (p.first == "name") fd.name = p.second;
        }
        if (!fd.name.empty()) {
            fields.push_back(std::move(fd));
        }
    }
    return fields;
}

} // namespace json_util

namespace ex_zvec {

// ---- Helpers --------------------------------------------------------------

static std::string to_std(rust::Str s) {
    return std::string(s.data(), s.size());
}

static std::vector<std::string> split_csv(const std::string& s) {
    std::vector<std::string> result;
    if (s.empty()) return result;
    std::istringstream stream(s);
    std::string token;
    while (std::getline(stream, token, ',')) {
        if (!token.empty()) {
            result.push_back(token);
        }
    }
    return result;
}

// ---- Impl ----------------------------------------------------------------

struct ZvecCollection::Impl {
    zvec::Collection::Ptr collection;
    uint32_t dims;
    std::vector<json_util::FieldDef> schema;

    // Cached field name lists for fast lookup
    std::vector<std::string> all_field_names;
    std::vector<std::string> output_field_names;
    std::vector<std::string> tag_field_names;

    bool is_tag_field(const std::string& name) const {
        return std::find(tag_field_names.begin(), tag_field_names.end(), name)
               != tag_field_names.end();
    }
};

// ---- Construction ---------------------------------------------------------

ZvecCollection::ZvecCollection(const std::string& path,
                               const std::string& name,
                               uint32_t vector_dims,
                               const std::string& schema_json)
    : impl_(std::make_unique<Impl>()) {
    impl_->dims = vector_dims;
    impl_->schema = json_util::parse_schema(schema_json);

    // Cache field name lists
    for (auto& f : impl_->schema) {
        impl_->all_field_names.push_back(f.name);
        impl_->output_field_names.push_back(f.name);
        if (f.type == "tags") {
            impl_->tag_field_names.push_back(f.name);
        }
    }

    auto full_path = path + "/" + name;

    // Try to open existing first
    if (std::filesystem::exists(full_path)) {
        zvec::CollectionOptions opts;
        auto result = zvec::Collection::Open(full_path, opts);
        if (result.has_value()) {
            impl_->collection = result.value();
            return;
        }
        // Fall through to create if open failed
    }

    // Create new collection with schema from JSON definition
    auto hnsw_params = std::make_shared<zvec::HnswIndexParams>(
        zvec::MetricType::IP, 16, 200);
    auto invert_params = std::make_shared<zvec::InvertIndexParams>();

    zvec::CollectionSchema coll_schema(name);

    // Add user-defined fields
    for (auto& field_def : impl_->schema) {
        if (field_def.type == "string") {
            auto f = std::make_shared<zvec::FieldSchema>(
                field_def.name, zvec::DataType::STRING);
            coll_schema.add_field(f);
        } else if (field_def.type == "filtered") {
            auto f = std::make_shared<zvec::FieldSchema>(
                field_def.name, zvec::DataType::STRING, false, invert_params);
            coll_schema.add_field(f);
        } else if (field_def.type == "tags") {
            auto f = std::make_shared<zvec::FieldSchema>(
                field_def.name, zvec::DataType::ARRAY_STRING, false, invert_params);
            coll_schema.add_field(f);
        }
    }

    // Always add the embedding vector field last
    auto embedding_field = std::make_shared<zvec::FieldSchema>(
        "embedding", zvec::DataType::VECTOR_FP32, vector_dims, false, hnsw_params);
    coll_schema.add_field(embedding_field);

    zvec::CollectionOptions opts;
    auto result = zvec::Collection::CreateAndOpen(full_path, coll_schema, opts);
    if (!result.has_value()) {
        throw std::runtime_error("Failed to create zvec collection: " + name);
    }
    impl_->collection = result.value();
}

ZvecCollection::~ZvecCollection() {
    if (impl_ && impl_->collection) {
        impl_->collection->Flush();
    }
}

// ---- CRUD -----------------------------------------------------------------

bool ZvecCollection::upsert(rust::Str pk,
                             rust::Slice<const float> embedding,
                             rust::Str fields_json) const {
    zvec::Doc doc;
    doc.set_pk(to_std(pk));
    doc.set<std::vector<float>>("embedding",
        std::vector<float>(embedding.data(), embedding.data() + embedding.size()));

    // Parse fields from JSON and set on document
    auto fields = json_util::parse_object(to_std(fields_json));
    for (auto& [key, value] : fields) {
        // Check if this is a tags field
        bool is_tags = false;
        for (auto& fd : impl_->schema) {
            if (fd.name == key && fd.type == "tags") {
                is_tags = true;
                break;
            }
        }

        if (is_tags) {
            doc.set<std::vector<std::string>>(key, split_csv(value));
        } else {
            doc.set<std::string>(key, value);
        }
    }

    std::vector<zvec::Doc> docs = {std::move(doc)};
    auto result = impl_->collection->Upsert(docs);
    return result.has_value();
}

bool ZvecCollection::remove(rust::Str pk) const {
    std::vector<std::string> pks = {to_std(pk)};
    auto result = impl_->collection->Delete(pks);
    return result.has_value();
}

rust::Vec<SearchResult> ZvecCollection::search(
    rust::Slice<const float> query_vector,
    uint32_t topk,
    rust::Str filter) const {

    zvec::VectorQuery query;
    query.topk_ = static_cast<int>(topk);
    query.field_name_ = "embedding";
    query.query_vector_.assign(
        reinterpret_cast<const char*>(query_vector.data()),
        query_vector.size() * sizeof(float));

    auto filter_str = to_std(filter);
    if (!filter_str.empty()) {
        query.filter_ = filter_str;
    }

    query.output_fields_ = impl_->output_field_names;

    auto result = impl_->collection->Query(query);

    rust::Vec<SearchResult> results;
    if (!result.has_value()) {
        return results;
    }

    for (auto& doc_ptr : result.value()) {
        SearchResult sr;
        sr.pk = rust::String(doc_ptr->pk());
        sr.score = doc_ptr->score();

        // Serialize all fields to JSON
        std::vector<std::pair<std::string, std::string>> field_pairs;
        for (auto& field_name : impl_->output_field_names) {
            if (impl_->is_tag_field(field_name)) {
                auto val = doc_ptr->get<std::vector<std::string>>(field_name);
                if (val) {
                    // Join array back to comma-separated
                    std::string joined;
                    for (size_t j = 0; j < val->size(); j++) {
                        if (j > 0) joined += ",";
                        joined += (*val)[j];
                    }
                    field_pairs.emplace_back(field_name, joined);
                }
            } else {
                auto val = doc_ptr->get<std::string>(field_name);
                if (val) {
                    field_pairs.emplace_back(field_name, *val);
                }
            }
        }
        sr.fields_json = rust::String(json_util::build_object(field_pairs));

        results.push_back(std::move(sr));
    }

    return results;
}

FetchResult ZvecCollection::fetch(rust::Str pk) const {
    auto pk_str = to_std(pk);

    std::vector<std::string> pks = {pk_str};
    auto result = impl_->collection->Fetch(pks);

    if (!result.has_value() || result.value().empty()) {
        // Return empty result instead of throwing — caller checks for empty pk
        FetchResult fr;
        fr.pk = rust::String();
        fr.fields_json = rust::String("{}");
        return fr;
    }

    auto it = result.value().begin();
    auto& doc_ptr = it->second;

    FetchResult fr;
    fr.pk = rust::String(doc_ptr->pk());

    // Serialize all fields to JSON
    std::vector<std::pair<std::string, std::string>> field_pairs;
    for (auto& field_name : impl_->output_field_names) {
        if (impl_->is_tag_field(field_name)) {
            auto val = doc_ptr->get<std::vector<std::string>>(field_name);
            if (val) {
                std::string joined;
                for (size_t j = 0; j < val->size(); j++) {
                    if (j > 0) joined += ",";
                    joined += (*val)[j];
                }
                field_pairs.emplace_back(field_name, joined);
            }
        } else {
            auto val = doc_ptr->get<std::string>(field_name);
            if (val) {
                field_pairs.emplace_back(field_name, *val);
            }
        }
    }
    fr.fields_json = rust::String(json_util::build_object(field_pairs));

    return fr;
}

bool ZvecCollection::flush() const {
    return impl_->collection->Flush().ok();
}

bool ZvecCollection::optimize() const {
    return impl_->collection->Optimize().ok();
}

uint64_t ZvecCollection::doc_count() const {
    auto result = impl_->collection->Stats();
    if (!result.has_value()) return 0;
    return result.value().doc_count;
}

// ---- Factory --------------------------------------------------------------

std::unique_ptr<ZvecCollection> create_or_open_collection(
    rust::Str path,
    rust::Str name,
    uint32_t vector_dims,
    rust::Str schema_json) {
    return std::make_unique<ZvecCollection>(
        to_std(path), to_std(name), vector_dims, to_std(schema_json));
}

}  // namespace ex_zvec
