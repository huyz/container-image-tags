# container-image-tags

[![Tests](https://github.com/huyz/container-image-tags/actions/workflows/test.yml/badge.svg)](https://github.com/huyz/container-image-tags/actions/workflows/test.yml)
[![Stress tests](https://github.com/huyz/container-image-tags/actions/workflows/stress.yml/badge.svg)](https://github.com/huyz/container-image-tags/actions/workflows/stress.yml)

**Find out what is actually running behind a Docker tag—and which tags still reference that image.**

You pulled `postgres:17` last month. That tag may have moved since then.
`container-image-tags` checks whether it still points to your
local image, then can find version tags that match the image you already have.

```sh
# Has this local image's tag (e.g. "17") moved at the registry?
# Are there any better tags still applicable and more durable
# (i.e., less likely to be moved in the future; e.g., "17.11-trixie")
container-image-tags postgres:17

# Find every current tag at the registry for that container's image
container-image-tags --tag-scan=all my-postgres-container
```

This is a metadata lookup tool: it does not pull image layers, start containers,
or update your images. macOS and Linux are supported.

You could do the same exhaustive searches yourself with a simple loop using curl
(see [Stack Overflow: How to find all image tags of a running Docker container?](
    https://stackoverflow.com/questions/56646899/how-to-find-all-image-tags-of-a-running-docker-container))
but this tool makes your searches faster and more convenient. It queries quicker
registry-provided metadata APIs, parallelizes requests, and handles fallbacks
(both to get past limits for anonymous queries and in case a service is unavailable).

## Confidence and current limits

This is an AI-assisted project. I've reviewed, refactored, and refined the
implementation to be confident of its correctness and ensure the code is easy to
follow and maintain — just as for a hand-coded codebase.

An offline test suites covers all supported registry adapters.
As for real-world validation, Docker Hub and GHCR are the most tested providers.

## Quick start

On macOS with Homebrew:

```sh
# For macOS, you need the newer Bash (4.4+) on your `PATH`, not `/bin/bash`.
brew install bash coreutils gnu-getopt curl jq perl

git clone https://github.com/huyz/container-image-tags.git
cd container-image-tags
./container-image-tags --version
```

Linux requires the same runtime tools: Bash 4.4+, GNU `realpath`, `timeout` and
`getopt`, curl 7.66.0+, jq, and Perl 5. Install them through your distribution's
package manager (or Homebrew as well).

This tool can inspect what you have **locally** by using the Docker CLI so that
you can simply pass a container name or local image reference:

```shell
# Queries the local Docker daemon to find the image underlying the local
# container named "my-postgres", check that its local tag still points to the
# same image manifest digest (i.e. the same `repository@sha256:…`) at the
# remote registry, and prompts you whether you want to look for any or all
# other alias tags.
./container-image-tags my-postgres
```

Or you can check a **remote tag**, irrespective of what you have running locally.
And just for demonstration, let's force anonymous lookup only:

```shell
# Public registry lookup: no local lookup and no user credentials.
./container-image-tags --tag-resolution=remote --credential-policy=never \
  postgres:17
```

This resolves what `postgres:17` points to **now** and asks you if you want
to find alias tags for that digest. For example, if you select the
`first matching durable tag` you may get:

```text
Remote tags (partial scan):
17
17.11-trixie
```

If you select `all`, you may get:

```text
Other remote tags:
17.11-trixie
17.11
17-trixie
17
```

Keep `lib/` beside the executable. To use the command without specifying its
path, you can symlink it to a directory in your `PATH`:
```sh
ln -s /path/to/container-image-tags/container-image-tags ~/.local/bin/container-image-tags
```

Other CLI tools for registries (e.g., `gh`, `aws`, etc.) and Skopeo (for registry-agnostic
fallbacks) are optional; see [Authentication](#authentication-you-control-the-tradeoff).

## How it works

1. **Identify the image.** A container or local image supplies its saved
   repository digest. A remote tag is resolved at the registry; alternatively,
   you can specify an explicit `repository@sha256:…`.
2. **Check the known tag.** For a local image, compare its saved digest with the
   tag's current digest at the registry. A mismatch means the tag moved. (Any
   following scan still uses the digest of the local image.)
3. **Find alias tags for that same digest.** Search the same repository for
   current tags with a matching digest, stopping at the breadth you chose.

By default, `--tag-resolution=auto` uses local Docker state when available and
announces a remote fallback otherwise. Use `local` to require a local image or
`remote` to ignore local state. (Not to be confused, local resolution does not
imply an offline-only mode: the tag check and reverse scan still contact the
registry.)
 
## Scope and registry support

Registry adapters cover Docker Hub, HCR (GitHub), GCR (Google), GAR (Google),
ACR (Azure), ECR and ECR Public (AWS), plus a generic OCI path (standard
container-registry API lookup) and Skopeo fallback. ECR Public's metadata
shortcut needs configured AWS access; otherwise the public OCI path is
available.

- Results describe a repository's **current tags in one registry**, not historical
  tags that were moved or deleted, and not equivalent images in other registries.
- Matching means **manifest-digest equality**. Tags match only when their
  digests are identical. A multi-platform index has a different digest from each
  platform-specific image it contains (e.g. `amd64`, `arm64`). Local images are
  not matched by their Image ID from your local Docker daemon.
- A container lookup uses a tag from its image's saved metadata, not necessarily
  the original launch reference. Pass an explicit local `image:tag` to choose
  which tag to check when an image has several.
- Registries can change tags during a scan (rare), restrict access, or rate-limit
  requests. An exhaustive scan is not an atomic snapshot.

## Choose how much to search

| `--tag-scan` | Result you are asking for |
| --- | --- |
| `never` | Only resolve the image and check its known tag; no reverse lookup. |
| `any` | Stop at the first matching tag, even a floating alias such as `latest`. |
| `any-durable` | Stop at a matching tag judged durable by a heuristic. May also output floating matches encountered along the way. |
| `all` | Exhaustively find current matching tags at the registry. |
| `ask` | Ask interactively which scan breadth to use. |

The default is `ask` in an interactive terminal, and `any-durable` otherwise
or with `--json`. An explicit `--tag-scan` always wins.

"Durable" is a naming heuristic, **not an immutability guarantee**, e.g. a tag that looks
like a fine-grained version, a date, or a commit. For example,
when a repository publishes both `1.796` and `1.796.0`, the more precise tag is
treated as durable and the shorter one as floating. A durable tag is no guarantee,
as publishers can still move any tag; so record the digest if you need a truly
immutable reference.

Where bulk-work cost can be estimated, interactive scans over three minutes
warn and continue. Non-interactive scans estimated over ten minutes stop unless
you pass `--allow-expensive-scan`. Separately, registry-facing commands have a
600-second deadline each; set `CIT_NETWORK_TIMEOUT_SECONDS` to another
non-negative integer, or `0` to disable it. This is not a total-run deadline.

## Why lookups can be fast—and when they are not

Resolving one tag to a digest is cheap. Going the other way is the hard part:
the standard OCI registry API does not offer a digest-to-tags query. A generic
client must list tags, then check their manifests individually.

The tool avoids that work where the registry offers richer metadata:

| Registry path | Work needed to find matching tags |
| --- | --- |
| Docker Hub tags API | Fetch pages containing both tags and digests; no manifest request per tag. Large repositories can still require many pages. |
| GitHub Container Registry (GHCR), via GitHub Packages | Search package-version pages containing digests and their tags. Requires GitHub credentials; a long version history can still be expensive. |
| Azure Container Registry (ACR), Google Artifact Registry (GAR), Amazon ECR; Google Container Registry (GCR) | Read tags associated with a digest from provider metadata instead of inspecting each tag. Access requirements vary by provider. |
| Generic OCI, including Codeberg and LinuxServer.io | List tags, then compare manifest digests using lightweight `HEAD` requests, with up to eight in flight. No image layers are downloaded. |

Under the default credential policy (`if-faster` — see below), a GHCR reverse
lookup first fetches a page from the Packages API when `gh` is available. If
that page does not contain a match, and more pages remain, it compares the
measured cost of continuing with this API against an estimated cost of the
alternate method of scanning current OCI tags, then chooses the cheaper
permitted path. An unavailable Packages method can fall back to public OCI
method.

Bounded scans stop scheduling new work once the requested match is found
depending on `--tag-scan`. A known tag that hasn't moved at the registry can
satisfy `any` immediately, or `any-durable` if appropriate. Exhaustive OCI scans
reuse connections through curl's parallel engine.

**Skopeo is the compatibility fallback**, including access through configured
registry credentials. For reverse scans, this still involves one query for each
tag; authenticating for it does not speed up reverse scans.

## Authentication: you control the tradeoff

Credentials can serve two different purposes: access to a private repository, or
access to a faster metadata API for a public repository. You're not required to
log in to try a public (anonymous) lookup. Public access may obtain an
anonymous, repository-scoped bearer token; this does not use your account
credentials. However, some registries throttle or limit anonymous requests while
offering a faster API to authenticated users.

The default is **`--credential-policy=if-faster`**. It favors using your
credentials at the applicable registries for a faster or more complete provider
API, even if there's a (slower) anonymous means.

| Policy | When user credentials may be used |
| --- | --- |
| `never` | Never. Only public/anonymous access; no authentication prompts. |
| `if-required` | Start public; permit credentials only after an explicit access denial. |
| `if-faster` (default) | Permit credentials proactively for a faster or more complete native API; otherwise only after an explicit access denial. |
| `require` | Only credentialed access; no public/anonymous requests. Fail if no permitted path can answer. |


### Where credentials come from

- **Docker Hub:** under the default policy, start with the public tags API.
  After denial, the tool will try `DOCKER_HUB_USERNAME` and `DOCKER_HUB_PAT` if
  supplied, falling back to Skopeo paths. If automatic paths cannot recover from denial,
  an interactive run will prompt for a username/PAT to retry; a PAT lets the scan
  continue when Hub refuses further anonymous pagination.
  Give read-only access for the repositories you need.
- **GHCR:** the Packages path uses the `gh` CLI's configured authentication
  with package-read access (`read:packages`). Public OCI lookups need no GitHub
  login. After denied automatic paths, an interactive run will prompt to
  `gh auth refresh -s read:packages`.
- **Cloud registries:** `gcloud` (GAR/GCR), `az` (ACR), and `aws` (ECR) can
  supply provider metadata or short-lived credentials from your configured
  account. `if-faster` permits proactive GAR/ECR metadata access where available;
  other conditional credential paths wait for denial.
- **Skopeo fallback:** can try anonymous queries and reuse credentials configured
  through Docker, Podman, or Skopeo, including supported credential helpers.

Provider tokens use standard input or private temporary files rather than
subprocess arguments. Session auth files are separate from your saved logins
and cleaned up on exit. For your security, supplying secrets through environment
variables requires care; do not paste PATs into command lines or bug reports.

Requests go to registry/provider APIs and their authentication services.
`--credential-policy=never` disables user credentials, not network access.

## More examples

```sh
# Query a digest directly, without requiring a local Docker.
container-image-tags --tag-resolution=remote \
  'ghcr.io/example/app@sha256:<64-hex-digit-digest>'

# Check the tags of every local image from the `postgres` repository
container-image-tags 'postgres:*'

# Return a single machine-readable array for multiple inputs.
container-image-tags --json --tag-scan=any postgres:17 redis:7

# Check all local containers and find all their current matching tags.
container-image-tags --tag-scan=all $(docker ps -a --format '{{.Names}}')

# Explicitly permit a long unattended lookup.
container-image-tags --tag-scan=all --allow-expensive-scan registry.example/app:1
```

Run `container-image-tags --help` for the complete option and input-resolution
guide. Container names and IDs, local image names and IDs, remote tags, and
fully qualified SHA-256 repository digests are supported.

### JSON for automation

`--json` writes one array to standard output; diagnostics go to standard error.
Each resolved image has its input, source, repository digest, local metadata
when available, direct tag-check status, and scan mode, status, backend, and tags.
Wildcard inputs can produce multiple results.

Inspect `remote_tag_check.status` and `tag_scan.status`, not just the exit code:
a successful invocation does not mean the original tag still matches, or that
an exhaustive scan ran. A completed `any` scan is still only a partial search.

<details>
<summary>Example JSON and scan status fields</summary>

Illustrative output for `--json --tag-scan=any postgres:17` with a matching
local image (digests and version are placeholders):

```json
[
  {
    "input": "postgres:17",
    "container": null,
    "local_image": {
      "id": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "version": "17.6",
      "revision": null,
      "refname": null,
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
      "backend": "direct-tag-check",
      "provider_metadata": null,
      "tags": ["17"]
    }
  }
]
```

`tag_scan.status` is `completed`, `not_found`, `not_requested`, `declined`, or
`skipped`. `tag_scan.backend` is `acr-api`, `direct-tag-check`, `docker-hub-api`,
`ecr-api`, `gar-api`, `github-packages-api`, `gcr-api`, `oci-registry-api`, or
`skopeo`; it is `null` when no scan ran. `provider_metadata` currently contains
additional data for successful GitHub Packages API lookups, otherwise `null`.

</details>

## Development

See [releases](https://github.com/huyz/container-image-tags/releases) for release
notes and [architecture](docs/architecture.md) for the complete per-provider
attempt order and implementation contracts.

The executable and `lib/` are Bash source. Provider adapters implement registry
operations; a shared policy engine controls credential eligibility, attempt
ordering, and fallback. The [architecture guide](docs/architecture.md) covers
module boundaries and adding providers.

The offline suite uses Bats Core 1.5+; CI pins 1.14.0. On macOS:

```sh
brew install bats-core shellcheck
tests/run static
tests/run  # Unit, integration, and security tests
```

The harness isolates user configuration and replaces external-service commands
with fixtures. Individual suites are available through `tests/run unit`,
`integration`, `security`, or `stress`. Stress tests also run in a separate
scheduled/manual workflow. Live tests require explicit opt-in and a configured
target; see the [test plan](docs/test-plan.md) for details.

## License

[MIT](LICENSE)
