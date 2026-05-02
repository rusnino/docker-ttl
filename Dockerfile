# syntax=docker/dockerfile:1

# TTL_VERSION has no default — must be supplied via --build-arg or the CI workflow.
# Example: docker buildx build --build-arg TTL_VERSION=v0.19.0 --platform linux/amd64 .
ARG TTL_VERSION

# ── Per-architecture runtime bases ───────────────────────────────────────────
# amd64: Alpine  — upstream ships a musl/static binary (zero runtime deps).
# arm64: Debian slim — upstream ships a glibc-linked binary; Debian has glibc
#        natively, so no compatibility shim is needed.
# Digests pin the exact multi-platform manifest; update via:
#   docker buildx imagetools inspect alpine:3.21 --format '{{json .Manifest}}' | jq -r '.digest'
#   docker buildx imagetools inspect debian:bookworm-slim --format '{{json .Manifest}}' | jq -r '.digest'
FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d        AS runtime-amd64
FROM debian:bookworm-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252 AS runtime-arm64

# ── Downloader (runs on build machine's native arch, never needs QEMU) ───────
FROM --platform=$BUILDPLATFORM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d AS downloader

ARG TTL_VERSION
ARG TARGETARCH

RUN [ -n "${TTL_VERSION}" ] || { echo "ERROR: TTL_VERSION build-arg is required" >&2; exit 1; }

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ASSET="ttl-x86_64-unknown-linux-musl.tar.gz" ;; \
        arm64) ASSET="ttl-aarch64-unknown-linux-gnu.tar.gz" ;; \
        *)     echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    BASE_URL="https://github.com/lance0/ttl/releases/download/${TTL_VERSION}"; \
    apk add --no-cache curl; \
    mkdir -p /tmp/ttl-install; \
    curl -fsSL "${BASE_URL}/SHA256SUMS"  -o /tmp/ttl-install/SHA256SUMS; \
    curl -fsSL "${BASE_URL}/${ASSET}"    -o "/tmp/ttl-install/${ASSET}"; \
    cd /tmp/ttl-install; \
    grep "${ASSET}" SHA256SUMS | sha256sum -c -; \
    mkdir -p /tmp/ttl-extract; \
    tar -xzf "${ASSET}" -C /tmp/ttl-extract; \
    BIN="$(find /tmp/ttl-extract -type f -name 'ttl' | head -1)"; \
    [ -n "$BIN" ] || { echo "ERROR: binary 'ttl' not found inside ${ASSET}" >&2; exit 1; }; \
    install -m 0755 "$BIN" /tmp/ttl-bin

# ── Final image — selects base via runtime-${TARGETARCH} ─────────────────────
FROM runtime-${TARGETARCH}

ARG TTL_VERSION

COPY --from=downloader /tmp/ttl-bin /usr/local/bin/ttl
COPY LICENSE      /usr/share/licenses/docker-ttl/LICENSE
COPY LICENSES/    /usr/share/licenses/ttl/

LABEL org.opencontainers.image.title="ttl" \
      org.opencontainers.image.description="Unofficial container image for ttl — a traceroute-like CLI tool written in Rust" \
      org.opencontainers.image.url="https://github.com/lance0/ttl" \
      org.opencontainers.image.source="https://github.com/rusnino/docker-ttl" \
      org.opencontainers.image.version="${TTL_VERSION}" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      org.opencontainers.image.vendor="Unofficial"

ENTRYPOINT ["ttl"]
