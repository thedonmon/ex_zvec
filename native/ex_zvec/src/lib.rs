use rustler::{NifResult, Resource, ResourceArc};
use std::collections::HashMap;
use std::panic::{RefUnwindSafe, UnwindSafe};

use zvec_rs::{Collection, CollectionConfig, HnswParams, MetricType};

// ---------------------------------------------------------------------------
// NIF resource: wraps a zvec-rs Collection
// ---------------------------------------------------------------------------

struct CollectionResource {
    inner: Collection,
}

// SAFETY: zvec-rs Collection uses per-node RwLocks and atomics internally.
// All concurrent access is handled within the Collection type.
unsafe impl Send for CollectionResource {}
unsafe impl Sync for CollectionResource {}
impl UnwindSafe for CollectionResource {}
impl RefUnwindSafe for CollectionResource {}

#[rustler::resource_impl]
impl Resource for CollectionResource {}

// ---------------------------------------------------------------------------
// JSON helpers for field serialization
// ---------------------------------------------------------------------------

fn parse_fields_json(json: &str) -> HashMap<String, String> {
    if json.is_empty() || json == "{}" {
        return HashMap::new();
    }
    serde_json::from_str(json).unwrap_or_default()
}

fn fields_to_json(fields: &HashMap<String, String>) -> String {
    serde_json::to_string(fields).unwrap_or_else(|_| "{}".to_string())
}

// ---------------------------------------------------------------------------
// NIF functions exposed to Elixir
// ---------------------------------------------------------------------------

/// Open or create a persistent collection at path/name.
#[rustler::nif]
fn open_collection(
    path: String,
    name: String,
    vector_dims: u32,
    _schema_json: String,
) -> NifResult<ResourceArc<CollectionResource>> {
    let config = CollectionConfig::new(vector_dims as usize)
        .with_metric(MetricType::IP)
        .with_hnsw_params(HnswParams::new(16, 200).with_ef_search(50));

    let collection = Collection::open(&path, &name, config)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    Ok(ResourceArc::new(CollectionResource {
        inner: collection,
    }))
}

/// Insert or update a document.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_upsert(
    resource: ResourceArc<CollectionResource>,
    pk: String,
    embedding: Vec<f32>,
    fields_json: String,
) -> bool {
    let fields = parse_fields_json(&fields_json);
    resource.inner.upsert(&pk, &embedding, fields);
    true
}

/// Remove a document by primary key.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_remove(resource: ResourceArc<CollectionResource>, pk: String) -> bool {
    resource.inner.remove(&pk)
}

/// Search by vector similarity with optional filter.
/// Returns list of {pk, score, fields_json} tuples.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_search(
    resource: ResourceArc<CollectionResource>,
    query_vector: Vec<f32>,
    topk: u32,
    filter: String,
) -> NifResult<Vec<(String, f32, String)>> {
    let filter_expr = if filter.is_empty() {
        None
    } else {
        Some(filter.as_str())
    };

    let results = resource
        .inner
        .search(&query_vector, topk as usize, filter_expr)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    Ok(results
        .into_iter()
        .map(|hit| {
            let json = fields_to_json(&hit.fields);
            (hit.pk, hit.score, json)
        })
        .collect())
}

/// Fetch a single document by primary key.
/// Returns {pk, fields_json} or raises error.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_fetch(
    resource: ResourceArc<CollectionResource>,
    pk: String,
) -> NifResult<(String, String)> {
    match resource.inner.fetch(&pk) {
        Some(fields) => {
            let json = fields_to_json(&fields);
            Ok((pk, json))
        }
        None => Err(rustler::Error::Term(Box::new("not_found"))),
    }
}

/// Flush writes to disk.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_flush(resource: ResourceArc<CollectionResource>) -> NifResult<bool> {
    resource.inner.flush()
        .map_err(|e| rustler::Error::Term(Box::new(e)))
}

/// Optimize index (flush + compact).
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_optimize(resource: ResourceArc<CollectionResource>) -> NifResult<bool> {
    resource.inner.optimize()
        .map_err(|e| rustler::Error::Term(Box::new(e)))
}

/// Get document count.
#[rustler::nif]
fn nif_doc_count(resource: ResourceArc<CollectionResource>) -> u64 {
    resource.inner.doc_count() as u64
}

rustler::init!("Elixir.ExZvec.Native");
