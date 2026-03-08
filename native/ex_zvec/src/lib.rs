use rustler::{NifResult, Resource, ResourceArc};
use std::sync::Mutex;

/// cxx bridge to our C++ wrapper around zvec.
///
/// Type mapping (Rust bridge -> C++ side):
///   &str       -> rust::Str
///   String     -> rust::String  (in shared structs)
///   &[f32]     -> rust::Slice<const float>
///   Vec<T>     -> rust::Vec<T>
///   UniquePtr  -> std::unique_ptr
#[cxx::bridge(namespace = "ex_zvec")]
mod ffi {
    /// Search result — shared struct generated on both sides.
    struct SearchResult {
        pk: String,
        score: f32,
        fields_json: String,
    }

    /// Fetch result — single document.
    struct FetchResult {
        pk: String,
        fields_json: String,
    }

    unsafe extern "C++" {
        include!("zvec_wrapper.h");

        type ZvecCollection;

        fn create_or_open_collection(
            path: &str,
            name: &str,
            vector_dims: u32,
            schema_json: &str,
        ) -> UniquePtr<ZvecCollection>;

        fn upsert(
            self: &ZvecCollection,
            pk: &str,
            embedding: &[f32],
            fields_json: &str,
        ) -> bool;

        fn remove(self: &ZvecCollection, pk: &str) -> bool;

        fn search(
            self: &ZvecCollection,
            query_vector: &[f32],
            topk: u32,
            filter: &str,
        ) -> Vec<SearchResult>;

        fn fetch(self: &ZvecCollection, pk: &str) -> FetchResult;

        fn flush(self: &ZvecCollection) -> bool;

        fn optimize(self: &ZvecCollection) -> bool;

        fn doc_count(self: &ZvecCollection) -> u64;
    }
}

// ---------------------------------------------------------------------------
// NIF resource: wraps a ZvecCollection behind a Mutex for thread safety
// ---------------------------------------------------------------------------

struct CollectionResource {
    inner: Mutex<cxx::UniquePtr<ffi::ZvecCollection>>,
}

// SAFETY: zvec::Collection uses internal thread pools and is thread-safe.
// The Mutex provides exclusive access to the UniquePtr.
unsafe impl Send for CollectionResource {}
unsafe impl Sync for CollectionResource {}

#[rustler::resource_impl]
impl Resource for CollectionResource {}

// ---------------------------------------------------------------------------
// NIF functions exposed to Elixir
// ---------------------------------------------------------------------------

#[rustler::nif]
fn open_collection(
    path: String,
    name: String,
    vector_dims: u32,
    schema_json: String,
) -> NifResult<ResourceArc<CollectionResource>> {
    let coll = ffi::create_or_open_collection(&path, &name, vector_dims, &schema_json);
    if coll.is_null() {
        return Err(rustler::Error::Term(Box::new("failed to open collection")));
    }
    Ok(ResourceArc::new(CollectionResource {
        inner: Mutex::new(coll),
    }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_upsert(
    resource: ResourceArc<CollectionResource>,
    pk: String,
    embedding: Vec<f32>,
    fields_json: String,
) -> NifResult<bool> {
    let guard = resource
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    Ok(guard.upsert(&pk, &embedding, &fields_json))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_remove(resource: ResourceArc<CollectionResource>, pk: String) -> NifResult<bool> {
    let guard = resource
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(guard.remove(&pk))
}

/// Search by vector similarity with optional filter string.
/// Returns list of {pk, score, fields_json}.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_search(
    resource: ResourceArc<CollectionResource>,
    query_vector: Vec<f32>,
    topk: u32,
    filter: String,
) -> NifResult<Vec<(String, f32, String)>> {
    let guard = resource
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    let results = guard.search(&query_vector, topk, &filter);

    Ok(results
        .into_iter()
        .map(|r| (r.pk, r.score, r.fields_json))
        .collect())
}

/// Fetch a single document by primary key.
/// Returns {:ok, {pk, fields_json}} or {:error, :not_found}.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_fetch(
    resource: ResourceArc<CollectionResource>,
    pk: String,
) -> NifResult<(String, String)> {
    let guard = resource
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    let r = guard.fetch(&pk);
    if r.pk.is_empty() {
        Err(rustler::Error::Term(Box::new("not_found")))
    } else {
        Ok((r.pk, r.fields_json))
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_flush(resource: ResourceArc<CollectionResource>) -> NifResult<bool> {
    let guard = resource
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(guard.flush())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_optimize(resource: ResourceArc<CollectionResource>) -> NifResult<bool> {
    let guard = resource
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(guard.optimize())
}

#[rustler::nif]
fn nif_doc_count(resource: ResourceArc<CollectionResource>) -> NifResult<u64> {
    let guard = resource
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(guard.doc_count())
}

rustler::init!("Elixir.ExZvec.Native");
