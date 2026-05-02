# ttl — Unofficial Container Image

> **This is an unofficial, community-maintained container image.**
> It is not affiliated with, endorsed by, or produced by the upstream
> [ttl](https://github.com/lance0/ttl) project or its authors.

`ttl` is a traceroute-like CLI tool written in Rust. This repository automates
building and publishing multi-platform OCI images from the upstream
[release assets](https://github.com/lance0/ttl/releases).

## Registries

| Registry       | Image                                      |
|----------------|--------------------------------------------|
| Docker Hub     | `docker.io/<your-namespace>/ttl`           |
| GHCR           | `ghcr.io/rusnino/ttl`                      |
| Codeberg       | `codeberg.org/<your-namespace>/ttl`        |
| Quay.io        | `quay.io/<your-namespace>/ttl`             |

## Usage

```sh
# Basic hop trace to a host
docker run --rm --cap-add=NET_RAW ghcr.io/rusnino/ttl 1.1.1.1

# 5-hop trace with a final report
docker run --rm --cap-add=NET_RAW ghcr.io/rusnino/ttl 1.1.1.1 -c 5 --report

# Pin to a specific version
docker run --rm --cap-add=NET_RAW ghcr.io/rusnino/ttl:v0.19.0 8.8.8.8
```

### Docker Compose

```yaml
services:
  ttl:
    image: ghcr.io/rusnino/ttl:latest
    cap_add:
      - NET_RAW
    command: ["1.1.1.1", "-c", "5", "--report"]
```

### Why `--cap-add=NET_RAW`?

`ttl` uses raw ICMP sockets to send and receive probe packets. On Linux,
opening a raw socket requires the `CAP_NET_RAW` capability (or running as
root). Without it the container exits immediately with a permission error.

`--cap-add=NET_RAW` grants only that specific capability to the container
process — it does not give full root or `--privileged` access.

## Tags

| Tag        | Description                                  |
|------------|----------------------------------------------|
| `latest`   | Most recent upstream stable release          |
| `vX.Y.Z`   | Specific release with `v` prefix (e.g. `v0.19.0`) |
| `X.Y.Z`    | Same image without `v` prefix (e.g. `0.19.0`) |

## Supported Platforms

| Platform      | Base image           | Upstream asset                                   |
|---------------|----------------------|--------------------------------------------------|
| `linux/amd64` | `alpine:3.21` (digest-pinned) | `ttl-x86_64-unknown-linux-musl.tar.gz` (static/musl) |
| `linux/arm64` | `debian:bookworm-slim` (digest-pinned) | `ttl-aarch64-unknown-linux-gnu.tar.gz` (glibc)  |

## Update Policy

Two GitHub Actions workflows keep the image current:

- **`watch-upstream.yml`** — polls the upstream GitHub API every 15 minutes. Checks all three expected tags (`vX.Y.Z`, `X.Y.Z`, `latest`) across all configured registries and triggers a build if any tag is missing from any registry.
- **`build.yml`** — does the actual multi-platform build and push. Triggered by the watcher or manually from the **Actions** tab (optionally with a specific version). Manual runs are idempotent by default; set `force=true` to rebuild an already-existing version. When rebuilding an old version, also set `publish_latest=false` to avoid rolling back the `latest` tag.

New upstream releases are typically picked up within 15 minutes.

## Repository Secrets

Configure the following secrets under **Settings → Secrets and variables →
Actions** before the first workflow run.

### Required (Docker Hub + GHCR)

| Secret               | Description                                      |
|----------------------|--------------------------------------------------|
| `DOCKERHUB_USERNAME` | Docker Hub login username                        |
| `DOCKERHUB_TOKEN`    | Docker Hub access token (not your password)      |
| `DOCKERHUB_NAMESPACE`| Docker Hub namespace/org the image is pushed to  |

`GITHUB_TOKEN` is provided automatically — no configuration needed for GHCR.

### Optional (Codeberg + Quay.io)

These registries are skipped automatically unless all three corresponding secrets are set. Set all three whenever you are ready to publish there.

| Secret               | Description                                              |
|----------------------|----------------------------------------------------------|
| `CODEBERG_USERNAME`  | Codeberg login username                                  |
| `CODEBERG_TOKEN`     | Codeberg access token                                    |
| `CODEBERG_NAMESPACE` | Codeberg namespace/org                                   |
| `QUAY_USERNAME`      | Quay.io robot account name (format: `namespace+robot`)   |
| `QUAY_TOKEN`         | Quay.io robot account token                              |
| `QUAY_NAMESPACE`     | Quay.io namespace/org                                    |

> **Quay.io note:** Create a robot account in the Quay.io UI and grant it
> write access to the target repository. The robot username is always in the
> form `namespace+robotname`. The first push creates the repository; make sure
> to set it to **Public** in the Quay.io settings afterward if you want a
> public image.

## Releases

Each published version creates a [GitHub Release](https://github.com/rusnino/docker-ttl/releases) with:
- Release notes linking to the upstream changelog
- `digests.txt` — multi-platform manifest digest and per-platform digests for reproducible pinning

Forced rebuilds (e.g. after a base image rotation) update the existing release with fresh digests.

## Security

- Release binaries are downloaded from the official upstream GitHub Releases
  page and verified against the upstream `SHA256SUMS` file before installation.
  A checksum mismatch causes the build to fail.
- `curl` is installed only in the downloader build stage and is not present in the final runtime image.
- License files for both this wrapper (`LICENSE`) and the upstream binary (`LICENSES/`) are included inside the image at `/usr/share/licenses/`.
- SBOM and provenance attestations are attached to every published image as OCI referrers.
- No secrets or credentials are baked into the image or the repository.
- For production use, pin images by digest rather than tag (digests are available in the GitHub Release):
  ```sh
  docker run --rm --cap-add=NET_RAW ghcr.io/rusnino/ttl@sha256:<digest> 1.1.1.1
  ```

## Licensing

The **build scripts and CI configuration** in this repository are released
under the MIT License — see [LICENSE](LICENSE).

The **`ttl` binary** distributed inside the container images is copyright
lance0 and licensed under **MIT OR Apache-2.0**. Full upstream license texts
are included in [`LICENSES/`](LICENSES/) and also shipped inside every image at `/usr/share/licenses/ttl/`:

- [`LICENSES/upstream-MIT.txt`](LICENSES/upstream-MIT.txt)
- [`LICENSES/upstream-APACHE-2.0.txt`](LICENSES/upstream-APACHE-2.0.txt)

## Disclaimer

This container image is **unofficial** and is **not** produced by, endorsed
by, or affiliated with the upstream `ttl` project or its author. For the
authoritative source, visit https://github.com/lance0/ttl.
