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
- Azure Container Registry: anonymous access, configured credentials, or an
  on-demand Azure CLI token
- Google Container Registry: direct digest/tag metadata lookup, with configured
  credentials or an on-demand Google Cloud CLI token as fallbacks
- Google Artifact Registry: anonymous access, configured credentials, or an
  on-demand Google Cloud CLI token
- Amazon ECR and ECR Public: anonymous access where available, configured
  credentials, or an on-demand AWS CLI token
- Other OCI registries: portable lookup through Skopeo

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
- Skopeo is required for generic OCI registries and private-registry fallback.
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

# Explicitly permit a long non-interactive Skopeo fallback scan.
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

Before Skopeo performs its generic per-tag fallback, it estimates the scan time
from the number of candidate tags and runs up to eight manifest lookups in
parallel. Interactive scans estimated above three minutes print an advisory and
continue. Non-interactive scans estimated above ten minutes fail fast; pass
`--allow-expensive-scan` to permit one explicitly.

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
`docker-hub-api`, `github-packages-api`, `oci-registry-api`, or `skopeo`; it is
`null` when no scan ran. `tag_scan.provider_metadata` contains provider-specific
response data when available, currently for successful GitHub Packages API
lookups, and is otherwise `null`.

Registry access starts anonymously where possible. Private-registry access can
reuse credentials configured by Docker, Skopeo, or Podman. When needed, the
script can request short-lived credentials from the relevant cloud CLI.
Credential values are not passed on command lines.

## Development

The executable owns argument parsing, local-input orchestration, and output.
The `lib` directory contains shared diagnostics (`common.sh`), local image
resolution (`local-images.sh`), generic OCI lookup (`skopeo.sh`), registry
adapters (`docker-hub.sh`, `ghcr.sh`, `acr.sh`, `gar.sh`, and `ecr.sh`), and
central registry classification and dispatch (`registries.sh`).

To add registry-specific support, source its adapter before `registries.sh`,
classify its repository host in `registry_classify`, and add it to the direct
tag and reverse-lookup dispatch functions. A direct tag lookup writes the
digest to stdout and returns status 0 when found, 1 when the tag does not
exist, or 2 when lookup fails. An exhaustive lookup populates `registry_tags`
plus `registry_lookup_result`, `registry_lookup_backend`, and optional
`registry_metadata`.

As of 2026-08-25, authored mostly by OpenAI GPT 5.6 Sol and DeepSeek V4 Flash.

If this project proves useful, it will be rewritten in go for portability and
fewer dependencies.

## License

[MIT](LICENSE)
