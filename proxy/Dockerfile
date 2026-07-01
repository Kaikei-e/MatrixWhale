# proxy/Dockerfile — builds Plecto (Rust, WASM-extensible L7 proxy) from the local clone at
# proxy/plecto/ (see proxy/plecto.toml). Plecto's crates are unpublished, so this is a source
# build from the clone, not `cargo install` from crates.io.

FROM rust:1.96.0-bookworm AS builder

# Defensive: crates/host/build.rs unconditionally builds + componentizes the example filter
# guests for wasm32-unknown-unknown as part of every plecto-host build (plecto-server ->
# plecto-control -> plecto-host are all non-dev path deps), even though this milestone only
# needs the `plecto` binary. rust-toolchain.toml's `targets` list should auto-provision this;
# this is a no-op fallback if that doesn't trigger.
RUN rustup target add wasm32-unknown-unknown

WORKDIR /build

# Copy the WHOLE cloned repo, not just the plecto/ workspace subdir: crates/server/Cargo.toml
# declares [[example]] targets whose paths reach outside plecto/ (../../examples/...,
# ../../../bench/harnesses/...). Cargo resolves every declared target path at manifest-parse
# time regardless of -p/--bin filtering, so a partial copy breaks the build before compilation
# starts. Preserve the repo's sibling layout (plecto/, examples/, bench/, ...).
COPY plecto/ ./repo

WORKDIR /build/repo/plecto

RUN cargo build --release -p plecto-server

# Runtime: plain debian-slim is enough — Plecto's TLS stack is rustls + ring (pure Rust, no
# OpenSSL), and this milestone doesn't even configure [[tls]], so there's no runtime crypto/cert
# dependency at all.
FROM debian:bookworm-slim AS runtime

COPY --from=builder /build/repo/plecto/target/release/plecto /usr/local/bin/plecto
COPY plecto.toml /etc/plecto/plecto.toml

EXPOSE 80 9090

CMD ["plecto", "/etc/plecto/plecto.toml", "0.0.0.0:80"]
