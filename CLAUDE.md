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

The Dockerfile uses four `FROM` stages:

1. **`runtime-amd64`** — `alpine:3.21` pinned by digest (musl, no extra deps needed)
2. **`runtime-arm64`** — `debian:bookworm-slim` pinned by digest (glibc; the upstream arm64 binary is glibc-linked)
3. **`downloader`** — runs on `$BUILDPLATFORM` (never needs QEMU). Downloads the correct upstream release asset for `$TARGETARCH`, verifies its SHA256 against upstream's `SHA256SUMS` file, and extracts the binary.
4. **Final stage** — resolves to `runtime-${TARGETARCH}`, copies `/tmp/ttl-bin` from `downloader`.

The split between `downloader` and the runtime bases is intentional: it keeps `curl` out of the final image and avoids QEMU for the download step.

## CI workflows

### `watch-upstream.yml` — upstream poller

Runs every 15 minutes. Queries the upstream GitHub API for the latest `lance0/ttl` release, checks all three expected tags (`vX.Y.Z`, `X.Y.Z`, `latest`) across all configured registries, and dispatches `build.yml` when any tag is missing from any registry.

### `build.yml` — build and push

Triggered exclusively via `workflow_dispatch` (by the watcher or manually). Three jobs:

**`check-version`** — resolves the version (manual input or latest upstream), validates it against `^v[0-9]+\.[0-9]+\.[0-9]+`, normalizes to both `vX.Y.Z` and `X.Y.Z` forms, checks GHCR. Outputs: `version`, `version_bare`, `already_published`.

**`skip-summary`** — runs only when `build-and-push` is skipped (`already_published=true` and `force=false`). Writes a `GITHUB_STEP_SUMMARY` explaining the skip and how to force a rebuild.

**`build-and-push`** — runs when GHCR does not have the version yet, or when `force=true`. Key inputs: `force` (default `false`) bypasses the `already_published` guard; `publish_latest` (default `true`) controls whether the `latest` tag is pushed — set to `false` when rebuilding an old version to avoid rolling back `latest`. Builds for `linux/amd64,linux/arm64` with SBOM and SLSA provenance attestations, pushes to Docker Hub + GHCR, then optionally mirrors to Codeberg and Quay.io via `docker buildx imagetools create` (no rebuild). Writes a per-registry outcome table to `GITHUB_STEP_SUMMARY`.

Key constraint: `secrets` context is not available in step-level `if:` conditions — optional registry presence is mapped to env booleans (`HAS_CODEBERG`, `HAS_QUAY`) in the job `env:` block. A registry is considered configured only when all three secrets (namespace + username + token) are set.

When manually rebuilding an older version, always use `force=true` and `publish_latest=false` — omitting `publish_latest=false` will roll back the `latest` tag to the older release.

## Required secrets

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub login |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `DOCKERHUB_NAMESPACE` | Docker Hub namespace (image pushed as `namespace/ttl`) |

`GITHUB_TOKEN` is automatic. Codeberg and Quay.io secrets are optional — steps are skipped when absent.
