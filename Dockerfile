# syntax=docker/dockerfile:1

# TTL_VERSION has no default — it must be supplied via --build-arg or the CI workflow.
# Example: docker buildx build --build-arg TTL_VERSION=v0.19.0 --platform linux/amd64 .
ARG TTL_VERSION

FROM alpine:3.21

ARG TTL_VERSION
ARG TARGETARCH

# Fail fast if TTL_VERSION was not supplied — avoids a confusing 404 from curl.
RUN [ -n "${TTL_VERSION}" ] || { echo "ERROR: TTL_VERSION build-arg is required" >&2; exit 1; }

# arm64 upstream binary is glibc-linked; gcompat + libgcc provide the compatibility shim on musl Alpine.
# amd64 upstream binary is musl/static and needs no extra runtime deps.
RUN case "${TARGETARCH}" in \
        arm64) apk add --no-cache gcompat libgcc ;; \
        amd64) : ;; \
        *) echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ASSET="ttl-x86_64-unknown-linux-musl.tar.gz" ;; \
        arm64) ASSET="ttl-aarch64-unknown-linux-gnu.tar.gz" ;; \
        *) echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    BASE_URL="https://github.com/lance0/ttl/releases/download/${TTL_VERSION}"; \
    apk add --no-cache --virtual .build-deps curl; \
    mkdir -p /tmp/ttl-install; \
    curl -fsSL "${BASE_URL}/SHA256SUMS"  -o /tmp/ttl-install/SHA256SUMS; \
    curl -fsSL "${BASE_URL}/${ASSET}"    -o "/tmp/ttl-install/${ASSET}"; \
    cd /tmp/ttl-install; \
    grep "${ASSET}" SHA256SUMS | sha256sum -c -; \
    mkdir -p /tmp/ttl-extract; \
    tar -xzf "${ASSET}" -C /tmp/ttl-extract; \
    BIN="$(find /tmp/ttl-extract -type f -name 'ttl' | head -1)"; \
    [ -n "$BIN" ] || { echo "ERROR: binary 'ttl' not found inside ${ASSET}" >&2; exit 1; }; \
    install -m 0755 "$BIN" /usr/local/bin/ttl; \
    rm -rf /tmp/ttl-install /tmp/ttl-extract; \
    apk del .build-deps; \
    ttl --version

LABEL org.opencontainers.image.title="ttl" \
      org.opencontainers.image.description="Unofficial container image for ttl — a traceroute-like CLI tool written in Rust" \
      org.opencontainers.image.url="https://github.com/lance0/ttl" \
      org.opencontainers.image.source="https://github.com/rusnino/docker-ttl" \
      org.opencontainers.image.version="${TTL_VERSION}" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      org.opencontainers.image.vendor="Unofficial"

ENTRYPOINT ["ttl"]
