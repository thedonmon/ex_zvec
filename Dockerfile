# Stage 1: Build zvec from source
# Separated so it's cached and not rebuilt on Elixir code changes
# NOTE: Build on linux/amd64 — zvec has FP16 NEON intrinsic issues
# on Linux ARM64 GCC (see ISSUES.md Issue 3)
FROM debian:bookworm-slim AS zvec-builder

RUN apt-get update && apt-get install -y \
    build-essential git ca-certificates curl libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install modern CMake (zvec's Arrow/Boost deps need >= 3.28)
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.sh \
    -o /tmp/cmake.sh && \
    chmod +x /tmp/cmake.sh && \
    /tmp/cmake.sh --skip-license --prefix=/usr/local && \
    rm /tmp/cmake.sh

RUN git clone --depth 1 https://github.com/alibaba/zvec.git /opt/zvec && \
    cd /opt/zvec && \
    git submodule update --init --recursive

WORKDIR /opt/zvec/build

# ENABLE_NATIVE=OFF: -march=native doesn't work under qemu/Rosetta emulation
RUN cmake .. \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DENABLE_NATIVE=OFF

# Build Arrow first (it downloads dependencies, can fail with parallel builds)
RUN make ARROW.BUILD -j1 2>&1 || \
    (cat /opt/zvec/build/thirdparty/arrow/arrow/src/ARROW.BUILD-stamp/ARROW.BUILD-configure-*.log 2>/dev/null; exit 1)

# Build everything else
RUN make -j$(nproc)

# Remove any .dylib/.so files to ensure static-only linking
RUN find /opt/zvec/build/lib -name "*.dylib" -delete 2>/dev/null; \
    find /opt/zvec/build/lib -name "*.so" -delete 2>/dev/null; \
    true

# Stage 2: Build the Elixir project + NIF
FROM elixir:1.17-otp-27-slim AS app-builder

RUN apt-get update && apt-get install -y \
    build-essential git curl ca-certificates \
    zlib1g-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy cmake from zvec builder (needed for cxx-build)
COPY --from=zvec-builder /usr/local/bin/cmake /usr/local/bin/cmake
COPY --from=zvec-builder /usr/local/share/cmake-3.31 /usr/local/share/cmake-3.31

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Copy zvec build artifacts from stage 1
COPY --from=zvec-builder /opt/zvec /opt/zvec
ENV ZVEC_DIR=/opt/zvec
ENV ZVEC_BUILD_DIR=/opt/zvec/build

WORKDIR /app

# Cache deps first
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get

# Cache Rust/NIF build (changes less often than Elixir code)
COPY native/ native/
RUN mix deps.compile

# Copy the rest and compile
COPY config/ config/
COPY lib/ lib/
COPY test/ test/
COPY .formatter.exs ./
RUN mix compile

# Stage 3: Test runner (default target)
FROM app-builder AS test
CMD ["mix", "test", "--trace"]

# Stage 4: Release build (for production)
FROM app-builder AS release-builder
ENV MIX_ENV=prod
RUN mix compile

# Stage 5: Minimal runtime image
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y \
    libstdc++6 zlib1g libbz2-1.0 \
    && rm -rf /var/lib/apt/lists/*

# In a real app, you'd copy a mix release here:
# COPY --from=release-builder /app/_build/prod/rel/my_app /app
# CMD ["/app/bin/my_app", "start"]
#
# For ex_zvec as a library, there's no standalone release.
# This stage is a template for downstream apps.
CMD ["echo", "ex_zvec runtime image - use as base for your app"]
