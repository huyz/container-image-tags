# container-image-tags

`container-image-tags` checks whether a known local container-image tag still
points to the same remote registry digest. It can then find other current
registry tags that point to that digest.

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

Digest comparisons always use the complete digest; they are never prefix
matches.

## Requirements

The required tools are:

- Bash 4.4 or newer
- Docker CLI
- `curl`
- `jq`
- GNU `getopt`
- `realpath`

Skopeo is required for generic OCI registries and private-registry fallback.
Depending on the registry, `gh`, `az`, `gcloud`, or `aws` can provide optional
authenticated fast paths or short-lived credentials.

On macOS, Homebrew users can install the core requirements with:

```sh
brew install bash coreutils gnu-getopt jq
```

Install Docker and Skopeo separately if they are not already available.

## Installation

Clone the repository and symlink the executable into a directory on `PATH`:

```sh
git clone https://github.com/huyz/container-image-tags.git
cd container-image-tags
mkdir -p ~/bin
ln -s "$PWD/container-image-tags.sh" ~/bin/container-image-tags
```

Keep the `.container-image-tags` directory beside `container-image-tags.sh`.
The executable resolves symlinks back to the checkout so it can load those
modules.

## Usage

```text
container-image-tags [options] <container-or-image-or-digest> [...]
```

Examples:

```sh
# Check a container by name.
container-image-tags postgres

# Check an exact local image tag.
container-image-tags postgres:17

# Check every local tag in a repository.
container-image-tags 'postgres:*'

# Query a registry digest directly.
container-image-tags 'ghcr.io/example/app@sha256:<64-hex-digit-digest>'

# Check all local containers.
container-image-tags $(docker ps -a --format '{{.Names}}')
```

Use `--tag-scan ask|never|any|all` to control reverse tag lookup. Use
`--ghcr-method auto|packages|anonymous` to select the GHCR strategy. Run
`container-image-tags --help` for the full option and input-resolution guide.

Registry access starts anonymously where possible. Private-registry access can
reuse credentials configured by Docker, Skopeo, or Podman. When needed, the
script can request short-lived credentials from the relevant cloud CLI.
Credential values are not passed on command lines.

## History

This repository retains the complete file history from
[`huyz/trustytools`](https://github.com/huyz/trustytools), including the
original `docker-image-tags.sh` name and its later rename to
`container-image-tags.sh`.

## License

[MIT](LICENSE)
