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

The downloader fetches `SHA256SUMS` from the same upstream release. Before running `sha256sum -c`, it uses `awk '$2==asset'` to extract the exact line for the expected filename and explicitly fails with a clear error message if the entry is not found. This catches format changes (renamed assets, missing entries) before `sha256sum` sees an empty input. A checksum mismatch also causes the build to fail immediately.

---

## CI: two-workflow design

### Problem with a single scheduled workflow

The original approach ran `build.yml` on a fixed 6-hour cron. Even with a GHCR already-published check, the maximum lag between an upstream release and the image being available was 6 hours.

Shortening the cron (e.g. every 15 minutes) in `build.yml` directly would mean spinning up a full runner job every 15 minutes even when nothing changed — wasteful even with an early-exit check.

### Solution: watcher + build separation

```
watch-upstream.yml  (every 15 min)
    │
    ├─ query GitHub API → latest lance0/ttl tag
    ├─ check vX.Y.Z, X.Y.Z, latest across all configured registries
    │     ├─ all tags present → exit (nothing to do)
    │     └─ any tag missing → gh workflow run build.yml \
    │                            --field version=vX.Y.Z \
    │                            --field force=<true|false> \
    │                            --field publish_latest=true
    │
    └─ (build.yml is triggered only when needed)

build.yml  (workflow_dispatch only — no schedule)
    │
    ├─ check-version job:  resolve + validate + normalize version, check GHCR
    ├─ skip-summary job:   writes summary when build-and-push is skipped
    └─ build-and-push job: QEMU setup, multi-platform build, push + attestations
```

The watcher is lightweight by design: no checkout, no Docker setup, just a small set of registry API calls. The full build job only runs when any expected tag is missing from any configured registry.

### Registry checks and source of truth

`build.yml` uses GHCR as its internal source of truth for `already_published` — GHCR is controlled by the same `GITHUB_TOKEN` and needs no extra credentials. Docker Hub and the optional registries are push targets, not state sources for `build.yml`.

The watcher, however, checks **all three expected tags** (`vX.Y.Z`, `X.Y.Z`, `latest`) in **every configured registry**. If any tag is missing from any registry, a build is triggered with the appropriate `force` value.

The `force` decision is based on whether GHCR's **versioned tag** (`vX.Y.Z`) specifically is present — tracked via the `versioned_missing` output of the GHCR check step:

- **`versioned_missing=true`** → `force=false`: `build.yml` will detect `already_published=false` and proceed naturally.
- **`versioned_missing=false`** (bare/latest tag or another registry missing) → `force=true`: overrides the `already_published` guard so `build.yml` pushes all tags to all registries.

This means a deleted Docker Hub tag, Codeberg tag, or Quay.io tag is automatically detected and recovered within 15 minutes without manual intervention.

### Fail-safe on GHCR token failure

If the GHCR token exchange fails (network issue, new repo not yet visible), both the watcher and `build.yml` default to `already_published=false` and proceed with the build. This prevents a transient API failure from silently skipping a real new release.

### `force` and `publish_latest` inputs

`build.yml` exposes two boolean inputs that control rebuild behaviour:

**`force`** (default `false`) — bypasses the `already_published` guard in `build-and-push`:

```yaml
if: >-
  needs.check-version.outputs.already_published != 'true' ||
  inputs.force == 'true'
```

The watcher passes `force=false` when GHCR's versioned tag (`vX.Y.Z`) is missing (build runs naturally via `already_published=false`) and `force=true` when GHCR has `vX.Y.Z` but a bare/latest tag or another registry is missing (forces `build-and-push` to run and push all tags to all registries).

**`publish_latest`** (default `true`) — controls whether the `latest` tag is included in the push. The watcher always passes `publish_latest=true` (it only dispatches for the current upstream latest). For manual forced rebuilds of old versions, set `publish_latest=false` to avoid rolling back the `latest` tag to an older release.

```
force=true  publish_latest=false  →  rebuilds vX.Y.Z tags only, latest untouched
force=true  publish_latest=true   →  rebuilds and moves latest (dangerous for old versions)
```

### Observability: step summary and skip summary

Every `build-and-push` run writes a `GITHUB_STEP_SUMMARY` with a per-registry outcome table (✅ success / ❌ failure / ⏭️ not configured). This makes silent `continue-on-error` failures on optional registries visible without digging into step logs.

When `build-and-push` is skipped (already published, force=false), a separate `skip-summary` job runs instead and explains the skip in the summary, answering the "why did nothing happen?" question for manual UI runs.

---

## Registry strategy

### Primary registries (Docker Hub + GHCR)

Built directly via `docker/build-push-action`. Both registries receive the same multi-platform manifest in a single build pass. GitHub Actions cache (`type=gha`) is used to speed up layer reuse across runs.

### Optional registries (Codeberg, Quay.io)

Mirrored from Docker Hub via `docker buildx imagetools create` — this copies the manifest and layer references without a full rebuild. Steps are skipped when the corresponding secrets are absent.

The `secrets` context is unavailable in step-level `if:` conditions in GitHub Actions. Secret presence is therefore mapped to plain environment booleans at the job level:

```yaml
env:
  HAS_CODEBERG: ${{ secrets.CODEBERG_NAMESPACE != '' && secrets.CODEBERG_USERNAME != '' && secrets.CODEBERG_TOKEN != '' }}
  HAS_QUAY:     ${{ secrets.QUAY_NAMESPACE != '' && secrets.QUAY_USERNAME != '' && secrets.QUAY_TOKEN != '' }}
```

All three secrets must be present for a registry to be considered configured. This matches the watcher's criteria — a partial set (e.g. namespace set but token absent) would otherwise cause the watcher to see the registry as missing and continuously trigger builds that `build.yml` would then skip.

### Quay.io robot accounts

Quay.io push requires a robot account (username format: `namespace+robotname`). The first push creates the repository on Quay.io; it must be manually set to Public afterward in the Quay.io UI.

---

## Security

- Binaries are verified against the upstream `SHA256SUMS` file at build time using exact field matching (`awk '$2==asset'`). A mismatch fails the build.
- `curl` exists only in the `downloader` stage and is never present in the final image.
- License files (`LICENSE`, `LICENSES/`) are copied into the image at `/usr/share/licenses/` so that consumers of the image have access to the applicable license texts without needing the repository.
- SBOM and provenance attestations are generated by `docker/build-push-action` (`sbom: true`, `provenance: true`) and stored as OCI referrers alongside the image manifest. They do not change image digests or tag behaviour. The exact SBOM format is determined by the action version; no specific format is pinned in the workflow config.
- No secrets or credentials are baked into the image or the repository.
- For production workloads, pin by digest rather than tag to avoid tag mutation:
  ```sh
  docker run --rm --cap-add=NET_RAW ghcr.io/rusnino/ttl@sha256:<digest> 1.1.1.1
  ```
- `--cap-add=NET_RAW` is required for raw ICMP socket access. It does not grant full `--privileged` access.
