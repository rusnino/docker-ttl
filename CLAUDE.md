# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An unofficial, community-maintained Docker image for [`ttl`](https://github.com/lance0/ttl) — a traceroute-like CLI tool written in Rust. The repo contains only a Dockerfile and two GitHub Actions workflows; there is no application source code.

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

1. **`runtime-amd64`** — `alpine:3.21` pinned by digest (musl, no extra deps needed)
2. **`runtime-arm64`** — `debian:bookworm-slim` pinned by digest (glibc; the upstream arm64 binary is glibc-linked)
3. **`downloader`** — runs on `$BUILDPLATFORM` (never needs QEMU). Downloads the correct upstream release asset for `$TARGETARCH`, verifies its SHA256 against upstream's `SHA256SUMS` file, and extracts the binary.
4. **Final stage** — resolves to `runtime-${TARGETARCH}`, copies `/tmp/ttl-bin` from `downloader`.

The split between `downloader` and the runtime bases is intentional: it keeps `curl` out of the final image and avoids QEMU for the download step.

## CI workflows

### `watch-upstream.yml` — upstream poller

Runs every 15 minutes. Queries the GitHub API for the latest `lance0/ttl` release, checks GHCR for the versioned manifest, and dispatches `build.yml` only when the version is not yet published. Requires `actions: write` to trigger `workflow_dispatch` via `gh workflow run`.

### `build.yml` — build and push

Triggered exclusively via `workflow_dispatch` (by the watcher or manually). Two jobs:

**`check-version`** — resolves the version (manual input or latest upstream), normalizes to both `vX.Y.Z` and `X.Y.Z` forms, checks GHCR. Outputs: `version`, `version_bare`, `already_published`.

**`build-and-push`** — skipped when `already_published=true` unless triggered manually (useful for forced rebuilds). Builds for `linux/amd64,linux/arm64` and pushes to Docker Hub + GHCR. Then optionally mirrors to Codeberg and Quay.io via `docker buildx imagetools create` (no rebuild).

Key constraint: `secrets` context is not available in step-level `if:` conditions — optional registry presence is mapped to env booleans (`HAS_CODEBERG`, `HAS_QUAY`) in the job `env:` block.

## Required secrets

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub login |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `DOCKERHUB_NAMESPACE` | Docker Hub namespace (image pushed as `namespace/ttl`) |

`GITHUB_TOKEN` is automatic. Codeberg and Quay.io secrets are optional — steps are skipped when absent.
