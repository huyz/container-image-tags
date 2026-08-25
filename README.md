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
- Google Artifact Registry and Google Container Registry: anonymous access,
  configured credentials, or an on-demand Google Cloud CLI token
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
- Depending on the registry, `gh` (GitHub Container Registry), `gcloud` (Google Container Registry),
`az` (Azure Container Registry), or `aws` (Elastic Container Registry) can provide optional
authenticated fast paths or short-lived credentials.

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

# Check all local containers.
container-image-tags $(docker ps -a --format '{{.Names}}')
```

Tag resolution defaults to `auto`: use a matching local image when present, or
announce a fallback and resolve the tag through the registry. Use
`--tag-resolution local` to require a local baseline, or `--tag-resolution
remote` to ignore Docker's local state. Remote registry queries used to compare
or find tags are still available with a local baseline.

Use `--tag-scan ask|never|any|all` to control reverse tag lookup. Use
`--ghcr-method auto|packages|anonymous` to select the GHCR strategy. Run
`container-image-tags --help` for the full option and input-resolution guide.

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
and may also populate `registry_lookup_status` and `registry_metadata`.

As of 2026-08-25, authored mostly by OpenAI GPT 5.6 Sol and DeepSeek V4 Flash.

If this project proves useful, it will be rewritten in go for portability and
fewer dependencies.

## License

[MIT](LICENSE)
