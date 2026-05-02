# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An unofficial, community-maintained Docker image for [`ttl`](https://github.com/lance0/ttl) — a traceroute-like CLI tool written in Rust. The repo contains only a Dockerfile and a GitHub Actions workflow; there is no application source code.

## Local build

`TTL_VERSION` is a required build arg — the Dockerfile errors without it.

```sh
# Build for a single platform (fast, no QEMU)
docker buildx build --build-arg TTL_VERSION=v0.19.0 --platform linux/amd64 -t ttl:local .

# Build and load both platforms (requires QEMU)
docker buildx build --build-arg TTL_VERSION=v0.19.0 --platform linux/amd64,linux/arm64 -t ttl:local .

# Run the result
docker run --rm --cap-add=NET_RAW ttl:local 1.1.1.1
```

## Dockerfile architecture

The Dockerfile is a three-stage build:

1. **`runtime-amd64`** — `alpine:latest` (musl, no extra deps needed)
2. **`runtime-arm64`** — `debian:bookworm-slim` (glibc; the upstream arm64 binary is glibc-linked)
3. **`downloader`** — runs on `$BUILDPLATFORM` (never needs QEMU). Downloads the correct upstream release asset for `$TARGETARCH`, verifies its SHA256 against upstream's `SHA256SUMS` file, and extracts the binary.
4. **Final stage** — resolves to `runtime-${TARGETARCH}`, copies `/tmp/ttl-bin` from `downloader`.

The split between `downloader` and the runtime bases is intentional: it keeps `curl` out of the final image and avoids QEMU for the download step.

## CI workflow (`.github/workflows/build.yml`)

Two jobs:

**`check-version`** — resolves the version (manual input or latest upstream GitHub release), normalizes it to both `vX.Y.Z` and `X.Y.Z` forms, and checks GHCR to see if the tag already exists. Outputs: `version`, `version_bare`, `already_published`.

**`build-and-push`** — skipped on scheduled runs when `already_published=true`; always runs on `workflow_dispatch`. Builds for `linux/amd64,linux/arm64` and pushes to Docker Hub + GHCR. Then optionally mirrors (via `docker buildx imagetools create`, no rebuild) to Codeberg and Quay.io.

Key constraint: `secrets` context is not available in step-level `if:` conditions — optional registry presence is mapped to env booleans (`HAS_CODEBERG`, `HAS_QUAY`) in the job `env:` block.

## Required secrets

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub login |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `DOCKERHUB_NAMESPACE` | Docker Hub namespace (image pushed as `namespace/ttl`) |

`GITHUB_TOKEN` is automatic. Codeberg and Quay.io secrets are optional — steps are skipped when absent.
