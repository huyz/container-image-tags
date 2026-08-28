# container-image-tags

`container-image-tags` resolves a local image or remote tag to a resolved
repository digest. For local images, it checks the registry whether the known tag
still points to that digest. It can then find other current registry tags
that point to that digest.

Arguments can be local Docker container names or IDs, local image names or IDs,
or fully qualified `repository@sha256:...` digests.

## Registry support

- **Docker Hub**: direct tag checks and digest-to-tag lookup through the tags API
- **GitHub Container Registry**: anonymous OCI lookup and an optional faster
  GitHub Packages API path
- **Google Container Registry**: direct digest/tag metadata lookup, with configured
  credentials or an on-demand Google Cloud CLI token as fallbacks
- **Google Artifact Registry**: authenticated digest/tag metadata lookup plus
  public and token-authenticated OCI paths, with Skopeo as a compatibility
  fallback
- **Azure Container Registry**: digest/tag metadata API, with configured
  credentials or an on-demand Azure CLI token as fallbacks
- **Amazon ECR**: signed digest/tag metadata API, with configured registry
  credentials or an on-demand AWS CLI token as fallbacks
- **Amazon ECR Public**: opportunistic digest metadata API when a configured
    AWS profile can resolve the registry alias cheaply, otherwise anonymous
    registry access
- Other **OCI-compatible registries** (e.g. **Codeberg**, **LinuxServer.io**):
    anonymous parallel manifest `HEAD` lookup, with Skopeo as the private/
    incompatible-registry fallback

NOTE: only the Docker Hub and GitHub Container Registry paths are fully tested.
Please report any issues.

## Requirements

Generally, this script supports macOS and Linux, maybe other systems if you
can install the more common GNU tools.

The required tools are:

- Bash 4.4 or newer
- GNU `realpath` (coreutils), `timeout`, `getopt`
- `curl` 7.66.0 or later
- `jq`
- Perl 5

Recommended:
- Docker CLI (for `auto` and `local` tag resolution) is required unless you
  only want to query a specific image digest or use `--tag-resolution remote`.

Optional:
- Skopeo is required only when a native provider path cannot answer a private
  lookup, or when a registry is incompatible with the OCI fast path.
- Depending on the registry, `gh` (GitHub Container Registry),
  `gcloud` (Google Container Registry), `az` (Azure Container Registry), or
  `aws` (Elastic Container Registry) can provide optional authenticated fast
  paths or short-lived credentials.

Registry-facing commands have a 600-second wall-clock deadline by default,
including curl, Docker, Skopeo, GitHub CLI, and cloud CLI operations. Set
Set `CIT_NETWORK_TIMEOUT_SECONDS` to a non-negative integer to choose another
limit, or to `0` to disable the deadline.

On macOS and Linux, Homebrew users can install all with:

```sh
brew install bash coreutils gnu-getopt curl jq perl docker skopeo gh gcloud-cli azure-cli awscli
```

### Docker Hub authentication

Docker Hub scans start anonymously. If Hub refuses further anonymous tag pagination (around 10
successive requests), you will be prompted for a Hub username and PAT before a retry. To avoid the
prompt and avoid the slower Skopeo fallback, set the environment variables `DOCKER_HUB_USERNAME` and
`DOCKER_HUB_PAT` (a Public Repo Read-only PAT is sufficient) before running this app.

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

# Explicitly permit a long non-interactive bulk lookup.
container-image-tags --tag-scan=all --allow-expensive-scan registry.example/app:1

# Return one machine-readable array containing every result.
container-image-tags --json --tag-scan=any postgres redis:7
```

Tag resolution defaults to `auto`: use a matching local image when present, or
announce a fallback and resolve the tag through the registry. Use
`--tag-resolution local` to require local resolution, or `--tag-resolution
remote` to ignore Docker's local state. Remote registry queries used to compare
or find tags are still available after local resolution.

Use `--tag-scan ask|never|any|any-durable|all` to control reverse tag lookup. Use
`--credential-policy never|if-required|if-faster|require` to control when user
credentials may be used; the default is `if-faster`. Run
`container-image-tags --help` for the full option and input-resolution guide.
See [Architecture](docs/architecture.md) for the processing pipeline, result
record, provider boundaries, current registry-access matrix, credential-policy
design direction, fallback ownership, and runtime-resource model.

`any` stops at the first matching tag, including a floating alias such as
`latest`. `any-durable` retains the previous bounded-scan behavior: it stops at
a tag heuristically assumed durable. The heuristic infers the most precise recurring semantic
version shape in the tags exposed by the registry: for a repository containing
both `1.796` and `1.796.0`, the three-component tag is treated as durable and
the shorter tag as floating. Known channels such as `latest`, `main`, `dev`,
`stable`, and `edge` are floating; complete commit-like and date-like tags are
durable. A directly checked three-or-more-component version can satisfy `any-durable`
immediately. For shorter version schemes, the first registry tag page supplies
the repository convention and can satisfy `any-durable` without further pagination or
manifest probes. These classifications express publisher convention, not a
registry guarantee. `all` remains exhaustive and returns every matching tag.

While searching, `any-durable` retains every matching tag encountered in candidate
order, including floating tags, and stops after the first durable match. A
confirmed floating tag is included without probing it again. Thus a
result may contain `latest`, `1.796`, and `1.796.0`; the final tag is the durable
match that satisfied the scan.

Generic public OCI scans list tags once, reuse one anonymous repository token,
and issue manifest `HEAD` requests with up to eight transfers in flight. Curl's
parallel engine reuses connections for exhaustive scans; `any` and
`any-durable` check candidate tags with the rolling worker pool so they can stop
scheduling after the requested match. Skopeo uses the same pool
when the OCI fast path is unavailable. Tag pagination stops early when the
observed lower bound alone proves that the subsequent scan is too expensive.
Docker Hub similarly estimates exhaustive pagination from its first page.

GHCR Packages pages are searched as they arrive. Under the default
`if-faster` credential policy, an unresolved multi-page Packages lookup lists
the current OCI tags, compares the measured Packages page cost with the
conservative parallel OCI estimate, and selects the cheaper remaining path.
OCI inventory pagination stops as soon as its observed lower-bound scan cost
already exceeds the Packages estimate.
Neither package pages nor provider tag arrays are assumed chronological; OCI
tag pagination is lexical. Interactive bulk work estimated above three minutes
prints an advisory and continues. Non-interactive work estimated above ten
minutes fails fast; pass `--allow-expensive-scan` to permit one explicitly.

The engine is selected automatically; bounded scans always use the pool so they
can stop scheduling early. See [Benchmarks](docs/benchmarks.md) for the
Codeberg comparison that informed this choice.

### JSON Output

Use `--json` for automation. Standard output is a single JSON array with one
object per resolved image; wildcard inputs may therefore add multiple objects.
Diagnostics continue to use standard error. JSON mode defaults to
`--tag-scan=any-durable` even on an interactive terminal, while an explicit
`--tag-scan` value takes precedence. Each result includes the original input,
subject source, local image and container details, repository digest, registry
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
    "subject_source": "local",
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
`acr-api`, `direct-tag-check`, `docker-hub-api`, `ecr-api`, `gar-api`,
`github-packages-api`, `gcr-api`, `oci-registry-api`, or `skopeo`; it is `null`
when no scan ran.
`tag_scan.provider_metadata` contains
provider-specific response data when available, currently for successful
GitHub Packages API lookups, and is otherwise `null`.

Registry access starts anonymously where possible. Private-registry access can
reuse credentials configured by Docker, Skopeo, or Podman. When needed, the
script can request short-lived credentials from the relevant cloud CLI.
Credential values are not passed on command lines.

## Development

The executable owns argument parsing, local-input orchestration, and output.
The `lib` directory contains shared statuses and diagnostics (`common.sh`),
durable-tag and scan selection (`scan-policy.sh`), bounded workers
(`scheduler.sh`), local image resolution (`local-images.sh`), anonymous generic
OCI lookup (`oci.sh`), its portable credential-aware fallback (`skopeo.sh`),
registry adapters (`docker-hub.sh`, `ghcr.sh`, `acr.sh`, `gar.sh`, and
`ecr.sh`), the universal ordering and fallback engine (`policy-engine.sh`), and
central registry classification and request construction (`registries.sh`).

To add registry-specific support, source its adapter before `registries.sh`,
classify its repository host in `registry_classify`, and give it one capability
registration function whose atomic callbacks share the direct/reverse request
and result API. Lookup helpers use the named status
contract in `common.sh`: `LOOKUP_SUCCEEDED` (0), `LOOKUP_NOT_FOUND` (1),
`LOOKUP_UNAVAILABLE` (2), `LOOKUP_DENIED` (3), and terminal
`LOOKUP_STOPPED` (4). `policy-engine.sh` alone interprets these statuses and
decides eligibility, ordering, fallback, and interactive-recovery timing. Each
dispatch caller supplies a lightweight associative lookup context that receives
status, digest, errors, tags, backend, and optional provider metadata.

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
