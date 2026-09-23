# proxy/Dockerfile — runs Plecto (Rust, WASM-extensible L7 proxy; see proxy/plecto.toml) from a
# pinned GitHub Releases binary instead of building from source, so contributors don't need the
# proxy/plecto/ clone and image builds don't recompile Plecto. To bump: update PLECTO_VERSION and
# PLECTO_SHA256 below (checksum is the matching *.tar.gz.sha256 asset on the release page,
# https://github.com/Kaikei-e/PlectoProxy/releases).

FROM debian:bookworm-slim AS fetcher

ARG PLECTO_VERSION=v0.11.5
ARG PLECTO_SHA256=8c1e6707b962f123a757ecdc5477e62f38c66f11b342c4eb1bc65b74f1f4f382

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /dl

# "-x86_64-unknown-linux-gnu" (not the "-capabilities" variant) is the minimal runtime profile:
# proxy/plecto.toml configures no [[filter]]/[[tls]], so no WASM capability runtime is needed.
RUN curl -fsSLO "https://github.com/Kaikei-e/PlectoProxy/releases/download/${PLECTO_VERSION}/plecto-${PLECTO_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    && echo "${PLECTO_SHA256}  plecto-${PLECTO_VERSION}-x86_64-unknown-linux-gnu.tar.gz" | sha256sum -c - \
    && tar xzf "plecto-${PLECTO_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    && mv "plecto-${PLECTO_VERSION}-x86_64-unknown-linux-gnu/plecto" /dl/plecto \
    && chmod +x /dl/plecto

# Runtime: plain debian-slim is enough — Plecto's TLS stack is rustls + ring (pure Rust, no
# OpenSSL), and this milestone doesn't even configure [[tls]], so there's no runtime crypto/cert
# dependency at all.
FROM debian:bookworm-slim AS runtime

RUN useradd -r -u 10001 -s /usr/sbin/nologin plecto

COPY --from=fetcher /dl/plecto /usr/local/bin/plecto
COPY plecto.toml /etc/plecto/plecto.toml

USER plecto

EXPOSE 8080 9090

CMD ["plecto", "/etc/plecto/plecto.toml"]
