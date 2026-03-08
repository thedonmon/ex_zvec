# ExZvec

Elixir bindings for [zvec](https://github.com/alibaba/zvec) — Alibaba's embedded C++ vector database.

ExZvec brings high-performance vector similarity search directly into your BEAM application. No external services, no JVM, no network calls — the vector database runs in-process via Rustler NIFs.

## Features

- **In-process vector search** — HNSW-indexed similarity search embedded in your Elixir app
- **Configurable schema** — Define your own string, filtered, and tag fields
- **SQL-like filtering** — Filter search results by indexed fields (`category = 'science'`)
- **Multi-tenant isolation** — Use filtered fields for scope-based data isolation
- **BM25 text fallback** — Optional lightweight keyword search when embeddings aren't available
- **Persistent storage** — RocksDB-backed, survives restarts (point at a persistent volume)

## How It Works

ExZvec bridges Elixir to zvec through a multi-layer stack:

```
Elixir (GenServer) -> Rustler NIF -> Rust cxx bridge -> C++ wrapper -> zvec C++17 API
```

- **Elixir layer** (`ExZvec.Collection`) — GenServer managing a zvec collection, JSON encoding/decoding of fields
- **Rust layer** — Rustler NIF functions running on dirty CPU schedulers, cxx bridge to C++
- **C++ layer** — Thin wrapper around `zvec::Collection` that handles dynamic schemas and translates between `rust::` and `std::` types
- **zvec** — Alibaba's embedded vector database engine (HNSW indexes, RocksDB storage, SQL-like filtering via inverted indexes)

Everything is statically linked into a single NIF `.so`/`.dylib`. No external processes or services.

## Prerequisites

You need three things installed before building:

| Dependency | Version | What it's for |
|---|---|---|
| **Elixir** | >= 1.15 | Runtime |
| **Rust** | >= 1.70 | Compiling the NIF bridge (Rustler) |
| **CMake** | >= 3.14 | Building zvec from source |
| **C++ compiler** | C++17 support | Building zvec and the wrapper |

## Platform Setup

### macOS (Apple Silicon & Intel)

```bash
# Install Xcode command line tools (provides clang, cmake may be included)
xcode-select --install

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install CMake if not already present
brew install cmake
```

**macOS-specific notes:**
- Apple Silicon (M1/M2/M3/M4): Uses `-Wl,-force_load` for static factory registration
- The build links against system `libc++` and `libz`/`libbz2`
- `MetricType::COSINE` does not work on ARM64 due to a NEON normalizer issue in zvec — ExZvec uses `MetricType::IP` instead, which gives identical results with L2-normalized embeddings (OpenAI, Cohere, etc.)

### Linux (Ubuntu/Debian)

```bash
# Build essentials
sudo apt-get update
sudo apt-get install -y build-essential cmake git

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install Elixir (if not already)
# See https://elixir-lang.org/install.html for your distro
```

**Linux-specific notes:**
- Uses `--whole-archive` / `--no-whole-archive` for static factory registration
- Links against system `libstdc++`, `libz`, `libbz2`
- Tested on Ubuntu 22.04+ and Debian 12+

### Windows

Not currently supported. zvec's build system targets Unix-like systems. Use WSL2 with the Linux instructions above.

## Building zvec from Source

ExZvec statically links against zvec, which must be built separately. This is a one-time setup.

```bash
# 1. Clone zvec
git clone https://github.com/alibaba/zvec.git
cd zvec

# 2. Initialize submodules (rocksdb, arrow, protobuf, etc.)
git submodule update --init --recursive

# 3. Create build directory
mkdir build && cd build

# 4. Configure with CMake
#    -DBUILD_SHARED_LIBS=OFF    ensures static libraries (required)
#    -DCMAKE_POLICY_VERSION_MINIMUM=3.5  fixes CMake 4.x compatibility
cmake .. -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5

# 5. Build (this takes a while — zvec compiles rocksdb, arrow, protobuf, etc.)
make -j$(nproc)       # Linux
make -j$(sysctl -n hw.ncpu)  # macOS
```

**Troubleshooting the build:**

| Problem | Fix |
|---|---|
| `fatal: destination path already exists` during submodule init | `rm -rf` the stale directory, re-run `git submodule update --init --recursive` |
| CMake policy error about `< 3.5` | Add `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` |
| Linker can't find `libgflags.a` | The actual file is `libgflags_nothreads.a` — this is handled by the build script |
| `Library not loaded: @rpath/lib*.dylib` | Delete any `.dylib` files from `build/lib/` — we need static-only linking |

After building, verify the static libraries exist:

```bash
ls build/lib/libzvec_core.a     # combined core archive
ls build/lib/libzvec_db.a       # database layer
ls build/external/usr/local/lib/librocksdb.a  # third-party deps
```

## Installation

Add `ex_zvec` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_zvec, "~> 0.1.0"}
  ]
end
```

Set environment variables pointing to your zvec build, then compile:

```bash
export ZVEC_DIR=/path/to/zvec            # zvec source root
export ZVEC_BUILD_DIR=/path/to/zvec/build  # cmake build output (defaults to $ZVEC_DIR/build)

mix deps.get
mix compile
```

**Tip:** Add the exports to your shell profile (`~/.zshrc`, `~/.bashrc`) or use a `.envrc` with [direnv](https://direnv.net/) so you don't have to set them every time.

## Quick Start

```elixir
# Start a collection (creates on disk if new, opens if existing)
{:ok, _pid} = ExZvec.start_link(
  name: :my_vectors,
  path: "/tmp/my_vectors",
  collection: "embeddings",
  vector_dims: 1536
)

# Insert a document
ExZvec.upsert(:my_vectors,
  pk: "doc-1",
  embedding: my_embedding,   # list of 1536 floats
  fields: %{
    "content" => "Elixir is a functional language",
    "title" => "About Elixir",
    "category" => "programming"
  }
)

# Flush to disk (also happens automatically on GenServer shutdown)
ExZvec.flush(:my_vectors)

# Search by vector similarity
{:ok, results} = ExZvec.search(:my_vectors,
  vector: query_embedding,
  top_k: 10
)
# => {:ok, [%{pk: "doc-1", score: 0.95, fields: %{"content" => "...", ...}}, ...]}

# Search with filters
{:ok, results} = ExZvec.search(:my_vectors,
  vector: query_embedding,
  top_k: 5,
  filter: "category = 'programming'"
)

# Fetch by primary key
{:ok, doc} = ExZvec.fetch(:my_vectors, "doc-1")

# Delete
ExZvec.remove(:my_vectors, "doc-1")
```

## Custom Schema

By default, collections include `content`, `title`, `scope`, `scope_id`, `source_type`, and `tags` fields. Define your own:

```elixir
schema = ExZvec.Schema.new([
  {:string, "content"},          # stored, not indexed — returned in results
  {:string, "author"},           # stored, not indexed
  {:filtered, "category"},       # stored + inverted index — usable in filter expressions
  {:filtered, "tenant_id"},      # stored + inverted index
  {:tags, "labels"}              # array of strings + inverted index
])

ExZvec.start_link(
  name: :docs,
  path: "/data/zvec",
  collection: "documents",
  vector_dims: 768,
  schema: schema
)
```

### Field Types

| Type | zvec Storage | Indexed | Use Case |
|---|---|---|---|
| `{:string, name}` | `STRING` | No | Content, titles, descriptions — stored and returned in results |
| `{:filtered, name}` | `STRING` + `InvertIndex` | Yes | Filterable fields — use in SQL-like filter expressions |
| `{:tags, name}` | `ARRAY_STRING` + `InvertIndex` | Yes | Multi-value tags — pass as comma-separated string or list |

## Multi-Tenant Isolation

Use filtered fields to isolate data between tenants without separate collections:

```elixir
# Insert with tenant context
ExZvec.upsert(:docs,
  pk: "doc-1",
  embedding: embedding,
  fields: %{"content" => "...", "tenant_id" => "org-42"}
)

# Search only within a tenant — zvec uses inverted indexes, so this is fast
ExZvec.search(:docs,
  vector: query_vec,
  top_k: 10,
  filter: "tenant_id = 'org-42'"
)

# Combine filters
ExZvec.search(:docs,
  vector: query_vec,
  top_k: 10,
  filter: "tenant_id = 'org-42' AND category = 'engineering'"
)
```

## BM25 Text Search

ExZvec includes a lightweight ETS-based BM25 text index for keyword search when embeddings aren't available:

```elixir
{:ok, idx} = ExZvec.TextIndex.start_link(name: :text_search)

ExZvec.TextIndex.index_doc(:text_search, "doc-1",
  "Elixir is a functional programming language",
  %{source: "wiki"})

results = ExZvec.TextIndex.search(:text_search, "functional elixir")
# => [%{id: "doc-1", score: 2.34, metadata: %{source: "wiki"}}]
```

This is intentionally simple — not a replacement for Elasticsearch's full-text capabilities, but good enough for fallback/hybrid scoring.

## Deployment

Since zvec is statically linked into the NIF, there are no external services to deploy.

### What you need

- **A persistent volume** for the data directory (RocksDB + HNSW indexes live on disk)
- **The NIF compiled for your target platform** (the `.so`/`.dylib` is architecture-specific)

### Docker

Build in a multi-stage Dockerfile matching your deploy target:

```dockerfile
# Build stage
FROM elixir:1.17-otp-27 AS builder

RUN apt-get update && apt-get install -y build-essential cmake git curl

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Build zvec
RUN git clone https://github.com/alibaba/zvec.git /opt/zvec && \
    cd /opt/zvec && \
    git submodule update --init --recursive && \
    mkdir build && cd build && \
    cmake .. -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    make -j$(nproc)

ENV ZVEC_DIR=/opt/zvec
ENV ZVEC_BUILD_DIR=/opt/zvec/build

WORKDIR /app
COPY . .
RUN mix deps.get && mix release

# Runtime stage
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libstdc++6 zlib1g libbz2-1.0 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/_build/prod/rel/my_app /app
CMD ["/app/bin/my_app", "start"]
```

### RustlerPrecompiled (for published packages)

For distributing on Hex without requiring users to have Rust/CMake:

1. Set up GitHub Actions to build NIFs for each target:
   - `x86_64-linux-gnu`, `aarch64-linux-gnu`
   - `x86_64-apple-darwin`, `aarch64-apple-darwin`
2. Publish precompiled binaries alongside the Hex package
3. Users get automatic platform detection — no build toolchain needed

This is the approach used by `explorer`, `tokenizers`, and other Hex packages with NIFs.

### Production configuration

```elixir
# In config/runtime.exs
config :my_app,
  zvec_path: System.get_env("ZVEC_DATA_DIR", "/var/data/zvec"),
  zvec_dims: 1536
```

Point `ZVEC_DATA_DIR` at a persistent volume (EBS, GCE PD, PVC, etc.).

## Running Tests

```bash
export ZVEC_DIR=/path/to/zvec
export ZVEC_BUILD_DIR=/path/to/zvec/build

mix test
```

Tests include:
- **Schema tests** — field definition, validation, accessors (no NIF required)
- **TextIndex tests** — BM25 indexing, search, scoring (no NIF required)
- **Collection tests** — full integration: upsert, fetch, search, filtering, tenant isolation, remove, optimize

> **Note:** `mix test` may exit with code 139 (segfault) even though all tests pass.
> This is a cosmetic issue caused by C++ static destructor ordering (glog/protobuf/gflags)
> at process shutdown. It does not affect functionality. See [Known Limitations](#known-limitations).

## Known Limitations

- **COSINE metric on macOS ARM64** — `MetricType::COSINE` fails due to a NEON vector normalizer issue in zvec's `ailego` library. ExZvec uses `MetricType::IP` (inner product) instead. With L2-normalized embeddings (OpenAI, Cohere, Voyage, etc. all return normalized vectors), IP gives mathematically identical results to cosine similarity.

- **Single-node only** — zvec is an embedded database, not a distributed one. For horizontal scaling, shard at the application level.

- **Exit-time segfault** — The BEAM process may segfault on shutdown due to C++ static destructor ordering issues in glog/protobuf/gflags. This does not affect functionality — all operations work correctly during the lifetime of the process. In production (long-running) apps, this is not visible since you rarely shut down the VM. In tests, `mix test` may report exit code 139 even though all tests pass.

## License

MIT
