# container-image-tags

`container-image-tags` resolves a local image or remote tag to a baseline
registry digest. For local images, it checks whether the known tag still points
to that digest. It can then find other current registry tags that point to the
baseline digest.

Arguments can be Docker container names or IDs, local image names or IDs, or
fully qualified `repository@sha256:...` digests. The script explains how it
interprets ambiguous input before starting registry work.

## Registry support

- Docker Hub: direct tag checks and digest-to-tag lookup through the tags API
- GitHub Container Registry: anonymous OCI lookup and an optional faster
  GitHub Packages API path
- Google Container Registry: direct digest/tag metadata lookup, with configured
  credentials or an on-demand Google Cloud CLI token as fallbacks
- Google Artifact Registry: anonymous access, configured credentials, or an
  on-demand Google Cloud CLI token
  - WARNING: less tested than the other registries; please report any issues
- Azure Container Registry: digest/tag metadata API, with configured
  credentials or an on-demand Azure CLI token as fallbacks
  - WARNING: less tested than the other registries; please report any issues
- Amazon ECR: signed digest/tag metadata API, with configured registry
  credentials or an on-demand AWS CLI token as fallbacks
- ECR Public: opportunistic digest metadata API when a configured AWS profile
  can resolve the registry alias cheaply, otherwise anonymous registry access
  - WARNING: less tested than the other registries; please report any issues
- Other OCI registries (e.g. Codeberg, LinuxServer.io): anonymous parallel manifest `HEAD` lookup,
  with Skopeo as the private/incompatible-registry fallback

## Requirements

The required tools are:

- Bash 4.4 or newer
- GNU `realpath` (coreutils)
- GNU `getopt`
- `curl`
- `jq`

Recommended:
- Docker CLI (for `auto` and `local` tag resolution) is required unless you
  only want to query a specific image digest or use `--tag-resolution remote`.

Optional:
- Skopeo is required only for private registries and registries incompatible
  with the anonymous OCI fast path.
- Depending on the registry, `gh` (GitHub Container Registry),
  `gcloud` (Google Container Registry), `az` (Azure Container Registry), or
  `aws` (Elastic Container Registry) can provide optional authenticated fast
  paths or short-lived credentials.

### Docker Hub authentication

Docker Hub scans start anonymously. When Hub refuses anonymous tag pagination,
set environment variables `DOCKER_HUB_USERNAME` and `DOCKER_HUB_PAT` (a Public Repo Read-only PAT is
sufficient) to retry its fast paginated tags API without a prompt. These
variables take precedence over the slower Skopeo fallback, including in
non-interactive runs. Interactive runs without them offer both choices when
Docker/Skopeo registry credentials are configured.

On macOS and Linux, Homebrew users can install all with:

```sh
brew install bash coreutils gnu-getopt curl jq docker skopeo gh gcloud-cli azure-cli awscli
```

## Installation

Clone the repository and symlink the executable into a directory on `PATH`:

```sh
git clone https://github.com/huyz/container-image-tags.git
cd container-image-tags
sudo ln -s "$PWD/container-image-tags" /usr/local/bin/container-image-tags
```

Keep the `lib` directory beside `container-image-tags`. The executable
resolves symlinks back to the checkout so it can load those modules.

## Usage

```text
container-image-tags [options] <container-or-image-or-digest> [...]
```

Examples:

```sh
# Check a container by name.
container-image-tags postgres

# Check an exact local image with tag.
container-image-tags --tag-resolution local postgres:17

# Ignore Docker's local state and resolve this tag through the registry.
container-image-tags --tag-resolution remote postgres:17

# Check every local tag for a repository (local image with any tag).
container-image-tags 'postgres:*'

# Query a registry digest directly.
container-image-tags 'ghcr.io/example/app@sha256:<64-hex-digit-digest>'

# Check all local containers for all remote tags.
container-image-tags --tag-scan=all $(docker ps -a --format '{{.Names}}')

# Explicitly permit a long non-interactive per-tag registry scan.
container-image-tags --tag-scan=all --allow-expensive-scan registry.example/app:1

# Return one machine-readable array containing every result.
container-image-tags --json --tag-scan=any postgres redis:7
```

Tag resolution defaults to `auto`: use a matching local image when present, or
announce a fallback and resolve the tag through the registry. Use
`--tag-resolution local` to require a local baseline, or `--tag-resolution
remote` to ignore Docker's local state. Remote registry queries used to compare
or find tags are still available with a local baseline.

Use `--tag-scan ask|never|any|all` to control reverse tag lookup. Use
`--ghcr-method auto|packages|anonymous` to select the GHCR strategy. Run
`container-image-tags --help` for the full option and input-resolution guide.

Generic public OCI scans list tags once, reuse one anonymous repository token,
and issue manifest `HEAD` requests with up to eight transfers in flight. Curl's
parallel engine reuses connections for exhaustive scans; `any` mode uses the
rolling worker pool so it can stop scheduling early. Skopeo uses the same pool
when the OCI fast path is unavailable. Interactive scans estimated above three
minutes print an advisory and continue. Non-interactive scans estimated above
ten minutes fail fast; pass `--allow-expensive-scan` to permit one explicitly.

For provisional benchmarking, `CIT_OCI_SCAN_ENGINE=parallel` forces curl's
parallel engine for an exhaustive OCI scan, while `CIT_OCI_SCAN_ENGINE=pool`
forces the rolling worker pool. The default, `auto`, retains the normal engine
selection; `any` scans always use the pool so they can stop scheduling early.

### JSON Output

Use `--json` for automation. Standard output is a single JSON array with one
object per resolved image; wildcard inputs may therefore add multiple objects.
Diagnostics continue to use standard error. JSON mode defaults to
`--tag-scan=all` even on an interactive terminal, while an explicit
`--tag-scan` value takes precedence. Each result includes the original input,
baseline source, local image and container details, repository digest, registry
classification, direct remote-tag check, and reverse-scan status and tags.

For example, the standard output from
`container-image-tags --json --tag-scan=any postgres:17` has this shape:

```json
[
  {
    "input": "postgres:17",
    "container": null,
    "local_image": {
      "id": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "version": "17.6",
      "tag": "17"
    },
    "repository": "postgres",
    "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
    "baseline_source": "local",
    "registry": {
      "kind": "docker-hub",
      "host": "docker.io"
    },
    "remote_tag_check": {
      "status": "match",
      "reference": "postgres:17",
      "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    },
    "tag_scan": {
      "mode": "any",
      "status": "completed",
      "backend": "docker-hub-api",
      "provider_metadata": null,
      "tags": [
        "17-alpine"
      ]
    }
  }
]
```

`tag_scan.status` is `completed`, `not_found`, `not_requested`, `declined`, or
`skipped`. `tag_scan.backend` identifies the implementation used for a scan:
`acr-api`, `docker-hub-api`, `ecr-api`, `github-packages-api`, `gcr-api`,
`oci-registry-api`, or `skopeo`; it is `null` when no scan ran.
`tag_scan.provider_metadata` contains
provider-specific response data when available, currently for successful
GitHub Packages API lookups, and is otherwise `null`.

Registry access starts anonymously where possible. Private-registry access can
reuse credentials configured by Docker, Skopeo, or Podman. When needed, the
script can request short-lived credentials from the relevant cloud CLI.
Credential values are not passed on command lines.

## Development

The executable owns argument parsing, local-input orchestration, and output.
The `lib` directory contains shared diagnostics and rolling workers
(`common.sh`), local image resolution (`local-images.sh`), anonymous generic
OCI lookup (`oci.sh`), its portable credential-aware fallback (`skopeo.sh`),
registry adapters (`docker-hub.sh`, `ghcr.sh`, `acr.sh`, `gar.sh`, and
`ecr.sh`), and central registry classification and dispatch (`registries.sh`).

To add registry-specific support, source its adapter before `registries.sh`,
classify its repository host in `registry_classify`, and add it to the direct
tag and reverse-lookup dispatch functions. Lookup helpers use the named status
contract in `common.sh`: `LOOKUP_SUCCEEDED` (0), `LOOKUP_NOT_FOUND` (1),
`LOOKUP_UNAVAILABLE` (2), `LOOKUP_DENIED` (3), and terminal
`LOOKUP_STOPPED` (4). Successful direct lookups write a digest to stdout;
successful exhaustive lookups populate `registry_tags` plus
`registry_lookup_result`, `registry_lookup_backend`, and optional
`registry_metadata`. User-choice helpers produce string actions so nonzero
exit statuses remain reserved for actual failures.

### Tests

The offline test suite uses [Bats Core](https://bats-core.readthedocs.io/) 1.5
or newer; CI pins Bats Core 1.14.0. On macOS, install the development
dependencies with:

```sh
brew install bats-core shellcheck
```

Run the same required checks used by CI from any directory:

```sh
tests/run static
tests/run  # Runs unit, integration, security tests
```

The required suite isolates `HOME`, Docker configuration, cloud configuration,
and all external commands. It does not use the network, a Docker daemon, or
real credentials. Narrower and optional tiers are also available:

```sh
tests/run unit
tests/run integration
tests/run security
tests/run stress
CIT_LIVE_TESTS=1 CIT_LIVE_GENERIC_OCI_REF='alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b' tests/run live
```

Live tests are opt-in and skipped unless their target environment variables are
configured. See [`docs/test-plan.md`](docs/test-plan.md) for the behavioral
matrix, test IDs, and completion requirements.

As of 2026-08-25, authored mostly by OpenAI GPT 5.6 Sol and DeepSeek V4 Flash.

If this project proves useful, it will be rewritten in go for portability and
fewer dependencies.

## License

[MIT](LICENSE)
