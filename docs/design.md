# Design Notes

## Overview

This repository automates building and publishing multi-platform OCI images for [`ttl`](https://github.com/lance0/ttl), an upstream Rust CLI tool. The repo owns no source code — it fetches upstream release binaries, verifies them, and packages them into container images.

---

## Dockerfile: multi-stage design

### Problem

The upstream project ships two distinct binary flavors:

| Platform | Asset | Linked against |
|---|---|---|
| `linux/amd64` | `ttl-x86_64-unknown-linux-musl.tar.gz` | musl (fully static) |
| `linux/arm64` | `ttl-aarch64-unknown-linux-gnu.tar.gz` | glibc |

A single Alpine base image works for amd64 (Alpine uses musl), but Alpine lacks glibc for arm64. Using a glibc compatibility shim (`gcompat`) on Alpine was tried and caused subtle runtime failures. Debian slim has glibc natively and is the correct base for arm64.

### Solution: per-arch runtime bases, digest-pinned

```
FROM alpine:3.21@sha256:<digest>        AS runtime-amd64
FROM debian:bookworm-slim@sha256:<digest> AS runtime-arm64
```

The final stage resolves the correct base at build time:

```
FROM runtime-${TARGETARCH}
```

Docker substitutes `TARGETARCH` (`amd64` or `arm64`) and selects the appropriate base. This is a native Docker Buildx feature — no shell conditionals needed.

Both bases are pinned by multi-platform manifest digest (not just tag) so that a forced rebuild of the same `ttl` version always produces an identical rootfs. Without pinning, `alpine:latest` or even `alpine:3.21` can silently update between runs, making two images with the same tag differ. To rotate to a new base version, update the digests in the Dockerfile:

```sh
docker buildx imagetools inspect alpine:3.21 --format '{{json .Manifest}}' | jq -r '.digest'
docker buildx imagetools inspect debian:bookworm-slim --format '{{json .Manifest}}' | jq -r '.digest'
```

### Downloader stage

The download and SHA256 verification runs in a separate `downloader` stage with `--platform=$BUILDPLATFORM`. This means:

- The download always runs on the build machine's native architecture.
- No QEMU emulation is needed for the download step (QEMU is only needed for final-stage assembly).
- `curl` is installed as an Alpine apk package in the downloader stage and never appears in any runtime layer.

### Checksum verification

The downloader fetches `SHA256SUMS` from the same upstream release and runs `sha256sum -c` before extracting the binary. A mismatch causes the build to fail immediately.

---

## CI: two-workflow design

### Problem with a single scheduled workflow

The original approach ran `build.yml` on a fixed 6-hour cron. Even with a GHCR already-published check, the maximum lag between an upstream release and the image being available was 6 hours.

Shortening the cron (e.g. every 15 minutes) in `build.yml` directly would mean spinning up a full runner job every 15 minutes even when nothing changed — wasteful even with an early-exit check.

### Solution: watcher + build separation

```
watch-upstream.yml  (every 15 min, ~10 s per run when no new release)
    │
    ├─ query GitHub API → latest lance0/ttl tag
    ├─ check GHCR manifest for that tag
    │     ├─ exists  → exit (nothing to do)
    │     └─ missing → gh workflow run build.yml --field version=vX.Y.Z
    │
    └─ (build.yml is triggered only when needed)

build.yml  (workflow_dispatch only — no schedule)
    │
    ├─ check-version job: resolve + normalize version, check GHCR
    └─ build-and-push job: QEMU setup, multi-platform build, push
```

The watcher is lightweight by design: no checkout, no Docker setup, just two API calls. The full build job only runs when a new version is confirmed missing from GHCR.

### Why GHCR is the source of truth for "already published"

The watcher and `build.yml` both check GHCR (not Docker Hub) to determine whether a build is needed. GHCR is controlled by the same `GITHUB_TOKEN` used throughout the workflow, making the check reliable without additional credentials. Docker Hub is treated as a push target, not a state source.

### Fail-safe on GHCR token failure

If the GHCR token exchange fails (network issue, new repo not yet visible), both the watcher and `build.yml` default to `already_published=false` and proceed with the build. This prevents a transient API failure from silently skipping a real new release.

### `force` input separates forced rebuild from watcher trigger

`build.yml` exposes a `force` boolean input (default `false`). The `build-and-push` job condition is:

```yaml
if: >-
  needs.check-version.outputs.already_published != 'true' ||
  inputs.force == 'true'
```

The watcher always passes `--field force=false`, so it remains idempotent even though it uses `workflow_dispatch`. A human triggering the workflow from the Actions UI can set `force=true` to rebuild an already-published version — useful for base image updates, binary integrity checks, or recovering from a partial push.

---

## Registry strategy

### Primary registries (Docker Hub + GHCR)

Built directly via `docker/build-push-action`. Both registries receive the same multi-platform manifest in a single build pass. GitHub Actions cache (`type=gha`) is used to speed up layer reuse across runs.

### Optional registries (Codeberg, Quay.io)

Mirrored from Docker Hub via `docker buildx imagetools create` — this copies the manifest and layer references without a full rebuild. Steps are skipped when the corresponding secrets are absent.

The `secrets` context is unavailable in step-level `if:` conditions in GitHub Actions. Secret presence is therefore mapped to plain environment booleans at the job level:

```yaml
env:
  HAS_CODEBERG: ${{ secrets.CODEBERG_TOKEN != '' }}
  HAS_QUAY:     ${{ secrets.QUAY_TOKEN != '' }}
```

These booleans are then safe to use in step `if:` conditions.

### Quay.io robot accounts

Quay.io push requires a robot account (username format: `namespace+robotname`). The first push creates the repository on Quay.io; it must be manually set to Public afterward in the Quay.io UI.

---

## Security

- Binaries are verified against the upstream `SHA256SUMS` file at build time. A mismatch fails the build.
- `curl` exists only in the `downloader` stage and is never present in the final image.
- No secrets or credentials are baked into the image or the repository.
- For production workloads, pin by digest rather than tag to avoid tag mutation:
  ```sh
  docker run --rm --cap-add=NET_RAW ghcr.io/rusnino/ttl@sha256:<digest> 1.1.1.1
  ```
- `--cap-add=NET_RAW` is required for raw ICMP socket access. It does not grant full `--privileged` access.
