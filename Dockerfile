# Pure Rust build — no C++ zvec dependency needed
FROM elixir:1.17-otp-27-slim AS app-builder

RUN apt-get update && apt-get install -y \
    build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

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

# Test runner (default target)
FROM app-builder AS test
CMD ["mix", "test", "--trace"]

# Release build (for production)
FROM app-builder AS release-builder
ENV MIX_ENV=prod
RUN mix compile

# Minimal runtime image
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# In a real app, you'd copy a mix release here:
# COPY --from=release-builder /app/_build/prod/rel/my_app /app
# CMD ["/app/bin/my_app", "start"]
CMD ["echo", "ex_zvec runtime image - use as base for your app"]
