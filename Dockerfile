# syntax=docker/dockerfile:1.7

# ---- build ----
FROM rust:1-bookworm AS build
WORKDIR /app
ENV SQLX_OFFLINE=true

COPY . .
# Cache mounts keep the cargo registry and target/ between builds, so only
# changed crates recompile. target/ is a mount, not part of the image layer,
# so the binary is copied out in the same RUN.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release --locked --bin linkforge \
 && cp target/release/linkforge /usr/local/bin/linkforge

# ---- runtime ----
# :nonroot runs as uid 65532. No shell, no package manager.
FROM gcr.io/distroless/cc-debian12:nonroot
WORKDIR /app
COPY --from=build /usr/local/bin/linkforge /app/linkforge
COPY configs /app/configs
ENV APP_ENV=production
EXPOSE 3000
# Exec form: the binary is PID 1 and receives SIGTERM directly.
# Shell form would wrap it in /bin/sh, which doesn't forward the signal.
ENTRYPOINT ["/app/linkforge"]