# Comprehensive Test Plan

## Purpose

This document is the implementation plan and acceptance specification for the
`container-image-tags` test suite. An implementing agent should be able to work
through it in order without reverse-engineering the intended test architecture
or deciding which behaviors are release-critical.

The suite must protect the observable CLI and module contracts while remaining
deterministic, offline-first, and safe to run without Docker, cloud accounts, or
registry credentials. Optional live tests supplement the offline suite; they do
not replace it and must not gate ordinary pull requests.

## Authority and baseline

Before implementing a phase:

1. Read `AGENTS.md` and use the repository's required version-control tool.
2. Re-read `README.md`, `container-image-tags`, and the modules covered by that
   phase. If behavior has changed since this document was written, update the
   applicable test cases and this plan together.
3. Treat documented CLI behavior and the contracts below as public behavior.
   When code and documentation disagree, stop and resolve the intended behavior
   rather than encoding an accidental result in a test.

When a new test exposes a product defect, do not weaken the assertion to match
the defect. Keep the smallest reproducing test, record the observed and intended
behavior, and confirm whether the implementation task is authorized to include
the product fix. Keep test-infrastructure changes and unrelated product fixes
separable in history.

The current module contract is:

| Status | Value | Meaning | Fallback permitted |
| --- | ---: | --- | --- |
| `LOOKUP_SUCCEEDED` | 0 | Complete, usable result | No |
| `LOOKUP_NOT_FOUND` | 1 | Authoritative absence | No |
| `LOOKUP_UNAVAILABLE` | 2 | Backend could not provide a result | Yes |
| `LOOKUP_DENIED` | 3 | Authentication or authorization required | Only through the intended authentication path |
| `LOOKUP_STOPPED` | 4 | Terminal condition such as rate limiting or refused expensive scan | No |

Successful direct lookup helpers print one complete digest to stdout.
Successful reverse lookup helpers populate or print complete tag results as
specified by their caller. Choice helpers print a string action; nonzero exit
statuses are reserved for failures to obtain a choice.

## Quality invariants

Every layer of the suite must preserve these invariants:

- Preserve deterministic registry order unless the documented backend sorts or
  deduplicates its result.
- `any` accepts a confirmed direct tag or stops after the first other match.
- `any-durable` retains matches through the first heuristically durable tag.
- `all` either produces a complete result or fails; it must not silently return
  a partial result after worker failures.
- `LOOKUP_STOPPED` is terminal and never invokes a more request-intensive
  fallback.
- Registry access is anonymous first wherever the implementation promises it.
- Cloud authentication is lazy and occurs only after the expected denial or
  provider-specific precondition.
- Credential values never appear in process arguments, stdout, stderr, debug
  output, or world-readable files.
- JSON mode emits one valid JSON array on stdout. Diagnostics remain on stderr.
- Human output, JSON output, and exit status describe the same outcome.
- Temporary files, authfiles, and child processes are cleaned up.
- Tests do not depend on network access, the user's Docker daemon, credential
  helpers, cloud configuration, terminal state, or home directory.

## Scope

The required suite covers:

- CLI option parsing, defaults, input inference, and multi-input orchestration.
- Local Docker image and container metadata resolution.
- Registry classification and dispatch.
- Docker Hub, GHCR, ACR, GCR, GAR, private ECR, ECR Public, generic OCI, and
  Skopeo paths.
- Authentication selection and fallback behavior.
- Rolling-worker and curl-parallel behavior.
- Interactive choices, progress, and expensive-scan protection.
- Human and JSON output contracts.
- Credential handling, temporary-file permissions, and cleanup.
- Installation through a symlink and dependency diagnostics.
- Linux, macOS, Bash 4.4, and current Bash compatibility.

The initial suite does not need to:

- Measure line coverage or set a percentage gate.
- Reformat the repository to satisfy a new formatter.
- Exercise private cloud accounts in pull-request CI.
- Implement a general-purpose Docker, curl, Skopeo, or cloud CLI emulator.
- Verify registry service availability through ordinary offline tests.

## Priorities and test IDs

Use these priorities:

- **P0:** release-blocking contract, security boundary, destructive regression,
  or central dispatch behavior.
- **P1:** important provider/error branch or stable diagnostic behavior.
- **P2:** optional compatibility, stress, or live validation.

Use IDs of the form `<AREA>-NNN`, for example `CLI-001`, `OCI-014`, or
`SEC-007`. Include the ID at the start of each Bats test description. The test
name should state the condition and expected outcome rather than an internal
function name alone.

## Test architecture

### Framework

Use Bats Core without third-party assertion plugins. Pin a released Bats Core
version in CI rather than installing an unversioned latest release. Keep the
small assertion library in this repository so local and CI behavior match.

Tests may source individual modules for focused unit coverage. Run each sourced
unit case in its own Bats process so readonly globals, sourced functions, traps,
and module state cannot leak between cases. End-to-end tests must invoke the
real `container-image-tags` executable.

### Proposed layout

```text
tests/
├── run
├── test-helper.bash
├── helpers/
│   ├── assertions.bash
│   ├── environment.bash
│   ├── fixtures.bash
│   ├── stubs.bash
│   └── tty.bash
├── fixtures/
│   ├── acr/
│   ├── docker/
│   ├── docker-hub/
│   ├── ecr/
│   ├── gcr/
│   ├── ghcr/
│   ├── oci/
│   └── skopeo/
├── unit/
│   ├── common.bats
│   ├── runtime.bats
│   ├── results.bats
│   ├── local-images.bats
│   ├── registries.bats
│   ├── docker-hub.bats
│   ├── ghcr.bats
│   ├── acr.bats
│   ├── gcr-gar.bats
│   ├── ecr.bats
│   ├── oci.bats
│   └── skopeo.bats
├── integration/
│   ├── cli-options.bats
│   ├── input-resolution.bats
│   ├── output.bats
│   └── installation.bats
├── security/
│   └── credentials-and-cleanup.bats
├── stress/
│   └── concurrency.bats
└── live/
    └── public-registries.bats
```

The implementation may split a large file, but it must retain the IDs and
coverage described here.

### Entry points

Create `tests/run` as the stable local and CI entry point:

```text
tests/run                 # required unit, integration, and security tests
tests/run unit            # required unit tests only
tests/run integration     # required offline end-to-end tests only
tests/run security        # required security tests only
tests/run stress          # repeated concurrency tests
tests/run live            # explicitly enabled network tests
```

`tests/run` must resolve its physical repository path, work from any current
directory, preserve the caller's environment only where explicitly supported,
and fail if required test dependencies are missing. Live tests must additionally
require `CIT_LIVE_TESTS=1` so they cannot run accidentally.

## Harness requirements

### Isolation

For every test:

- Create a unique temporary root and remove it during teardown.
- Set isolated values for `HOME`, `XDG_CONFIG_HOME`, `DOCKER_CONFIG`, and any
  tool-specific state directories.
- Put a per-test fake executable directory first on `PATH`.
- Set explicit `GETOPT`, `REALPATH`, `CURL`, `JQ`, `DOCKER`, `SKOPEO`, `GH`,
  `GCLOUD`, `AZ`, and `AWS` paths as applicable.
- Clear Docker Hub credentials and known cloud credential environment variables
  unless the case sets them intentionally.
- Set a fixed `COLUMNS` for stable separators.
- Record stdout, stderr, exit status, calls, and generated files separately.
- Never read or modify the user's actual Docker or cloud configuration.

Teardown must report leaked processes or files before removing the temporary
root so failures remain diagnosable.

### Assertions

Implement at least these repository-local assertions:

- Exact exit status.
- Exact stdout or stderr.
- Substring and regular-expression match.
- Valid JSON and jq predicate.
- Exact ordered argv for a stubbed command.
- Command called exactly, at least, or at most N times.
- Command not called.
- File exists or does not exist.
- File mode equals an expected octal mode.
- Value is absent from stdout, stderr, argv logs, and files.
- No child process remains after the command exits.

Use exact assertions for stable contracts and semantic assertions for JSON.
Avoid full-output snapshots when a small focused assertion communicates the
contract more clearly.

### Stub command protocol

Stub only the command surface that production code actually uses. Every fake
tool must:

1. Log each argument without lossy shell re-parsing. Prefer one file per call
   with NUL-delimited arguments.
2. Select a response by exact operation or URL, not by prefix matching.
3. Return fixture-controlled stdout, stderr, and status.
4. Support an optional barrier or delay for concurrency cases.
5. Fail loudly on an unexpected invocation or unsupported option sequence.

The fake curl must model exact request method, URL, response status, headers,
body, and transport status. It only needs to understand options used by this
repository, including header files, output files, response-header files,
`--data-urlencode`, HEAD requests, and the parallel transfer configuration.
URL-addressed fixtures should be preferred over a shared call counter so
parallel tests remain deterministic.

The fake Docker CLI must model the exact `container inspect`, `image inspect`,
and `image ls` forms used by `lib/local-images.sh`. The fake Skopeo CLI must
distinguish `login`, `list-tags`, `inspect --raw`, and `manifest-digest`.

Cloud and GitHub CLI stubs must validate complete argv, including region,
account, repository, pagination, output, and no-pager flags.

### Interactive tests

For unit tests, override `is_interactive_session` after sourcing the module:

```bash
function is_interactive_session { return 0; } # interactive
function is_interactive_session { return 1; } # non-interactive
```

Choice helpers read `/dev/tty`; provide a small PTY helper for those cases.
Only one end-to-end smoke test needs to prove actual TTY detection. All other
TTY-dependent behavior should use the shared helper or PTY fixture so CI does
not rely on its runner terminal.

## Required static and smoke checks

| ID | Priority | Case | Expected result |
| --- | --- | --- | --- |
| STATIC-001 | P0 | Parse the executable and every `lib/*.sh` using Bash 4.4 | No syntax errors |
| STATIC-002 | P0 | Parse using the current supported Bash | No syntax errors |
| STATIC-003 | P0 | Run ShellCheck on the integrated executable and every standalone shell module/helper, with sourced files resolved | No unapproved findings |
| STATIC-004 | P0 | Run a repository-local trailing-whitespace check and inspect changes with the version-control tool required by `AGENTS.md` | No whitespace errors |
| SMOKE-001 | P0 | Run `container-image-tags --help` with required tools stubbed | Status 0; documented modes and inputs present |
| SMOKE-002 | P0 | Invoke through a symlink outside the checkout | Modules load from the physical checkout |
| SMOKE-003 | P1 | Invoke from a different current directory | Behavior does not depend on cwd |

Do not introduce a repository-wide formatting gate as part of the test-suite
change unless formatting is handled in a separate, intentionally scoped change.

## Shared contracts and scheduler

Implement these cases in `tests/unit/common.bats`:

| ID | Priority | Case | Expected result |
| --- | --- | --- | --- |
| COMMON-001 | P0 | Source `common.sh` | Named statuses equal 0 through 4 as documented |
| COMMON-002 | P0 | Successful helper call | Result is on stdout and status is `LOOKUP_SUCCEEDED` |
| COMMON-003 | P0 | Terminal helper result | Caller propagates `LOOKUP_STOPPED`; no fallback call |
| COMMON-004 | P1 | `debug`, `verbose`, `notice`, and `warn` | Correct gating, prefix, stream, and newline |
| COMMON-005 | P0 | Interactive choices `1`, `d`, `a`, and default/`n` | Prints `any`, `any-durable`, `all`, and `none` respectively |
| COMMON-006 | P0 | Choice requested without a terminal | Nonzero status and no string action |
| COMMON-007 | P1 | Uppercase and long-form accepted choices | Documented equivalent action |
| COMMON-008 | P0 | Mixed floating aliases and two-/three-component semver tags | Greatest recurring precision is inferred as durable |
| COMMON-009 | P0 | Repository whose releases use two components | Two-component release tags are treated as durable |
| COMMON-010 | P0 | Durable direct-tag classification without a repository sample | Full semver, date, and commit-like tags pass; channels and short semver do not |
| COMMON-011 | P0 | `any-durable` with a confirmed local tag plus floating and durable registry matches | Local tag and incidental floating matches precede the first durable tag |
| COMMON-012 | P0 | `any` with a confirmed floating direct tag or provider matches | Direct tag or first provider match is returned immediately |
| POOL-001 | P0 | More candidates than workers | Active workers never exceed the supplied cap |
| POOL-002 | P0 | Workers complete out of order | Matching tags are emitted in candidate order |
| POOL-003 | P0 | `any-durable` finds a durable match | No new work is scheduled afterward; in-flight work drains |
| POOL-004 | P0 | Caller filters a candidate before scheduling | Only the supplied candidate set is scheduled |
| POOL-005 | P0 | One exhaustive worker fails | Complete lookup returns `LOOKUP_UNAVAILABLE`, not partial success |
| POOL-006 | P0 | Worker returns `LOOKUP_STOPPED` | Scheduling stops and terminal status propagates |
| POOL-007 | P0 | `any-durable` has a durable match plus an unrelated failure | Match succeeds according to the documented bounded-mode contract |
| POOL-008 | P1 | Empty candidate list | Empty result, no workers, no division or strict-mode failure |
| POOL-009 | P1 | Quiet non-interactive run | No spinner or carriage-return progress |
| POOL-010 | P1 | Interactive run | Bounded progress appears and finishes with a newline |
| POOL-011 | P0 | Worker count returns to zero under `set -e` | No arithmetic-status abort |
| POOL-012 | P0 | Normal and terminal completion | Worker temporary directory is removed and no child remains |
| POOL-013 | P0 | `any-durable` sees floating matches before a durable match | All matches through the first durable tag are returned; later candidates are not scheduled |
| POOL-014 | P0 | `any` sees a matching floating tag | Only the first match is returned; later candidates are not scheduled |

The stress tier must repeat `POOL-002`, `POOL-003`, `POOL-005`, and `POOL-006`
at least 25 times with varied deterministic delays.

## CLI options and defaults

Implement these end-to-end cases in `tests/integration/cli-options.bats`:

| ID | Priority | Case | Expected result |
| --- | --- | --- | --- |
| CLI-001 | P0 | `-h` and `--help` | Status 0 and equivalent help |
| CLI-002 | P0 | No positional input | Usage on stderr and status 1 |
| CLI-003 | P0 | Unknown option or getopt failure | Usage and status 2 |
| CLI-004 | P0 | Invalid `--tag-resolution` | Explicit accepted-value error |
| CLI-005 | P0 | Invalid `--tag-scan` | Explicit accepted-value error |
| CLI-006 | P0 | Valid and invalid `--credential-policy` values | Four documented values accepted; ambiguous legacy names rejected |
| CLI-007 | P1 | Short and long verbose/debug flags | Correct diagnostics enabled independently |
| CLI-008 | P0 | JSON with no explicit scan mode | Defaults to `any-durable` even interactively |
| CLI-009 | P0 | Non-interactive human mode without explicit scan mode | Defaults to `any-durable` |
| CLI-010 | P0 | Interactive human mode without explicit scan mode | Defaults to `ask` |
| CLI-011 | P0 | Explicit scan mode in any environment | Explicit value wins |
| CLI-012 | P0 | Non-remote resolution with Docker missing | Dependency diagnostic before processing input |
| CLI-013 | P0 | Remote resolution with Docker missing | Docker is not required |
| CLI-014 | P1 | Missing curl, jq, getopt, or realpath | Correct installation diagnostic and nonzero status |
| CLI-015 | P0 | Bash older than 4.4 | Clear version error before module execution |

## Input resolution and local Docker metadata

Implement unit cases in `tests/unit/local-images.bats` and end-to-end cases in
`tests/integration/input-resolution.bats`.

| ID | Priority | Case | Expected result |
| --- | --- | --- | --- |
| INPUT-001 | P0 | Complete `repository@sha256:<64 lowercase hex>` | Accepted without Docker; baseline source `input` |
| INPUT-002 | P0 | Unsupported digest algorithm | Explicit rejection before registry work |
| INPUT-003 | P0 | Short, uppercase, or malformed repository digest | Exact grammar rejection |
| INPUT-004 | P0 | SHA-like value matches a container | Container wins; referenced image is inspected |
| INPUT-005 | P0 | SHA-like value misses container but matches image | Image wins |
| INPUT-006 | P0 | SHA-like value matches neither but maps to RepoDigest | Repository is recovered from local metadata |
| INPUT-007 | P1 | Digest maps to multiple repositories | Deterministic first result plus warning |
| INPUT-008 | P0 | Short SHA cannot be recovered | Requires complete digest/reference; no prefix lookup |
| INPUT-009 | P0 | SHA-like input in remote mode | Rejected without registry repository |
| INPUT-010 | P0 | Explicit tagged input in `local` mode | Local image required; no remote baseline fallback |
| INPUT-011 | P0 | Explicit tagged input in `auto` mode, local hit | Local baseline; no remote resolution |
| INPUT-012 | P0 | Explicit tagged input in `auto` mode, local miss | Notice precedes remote work; remote baseline used |
| INPUT-013 | P0 | Explicit tagged input in `remote` mode | Docker ignored; remote baseline used |
| INPUT-014 | P0 | Untagged repository with local `:latest` | `:latest` wins; no wildcard broadening |
| INPUT-015 | P0 | Untagged repository without `:latest` but with local tags | Expands to local `repository:*` |
| INPUT-016 | P0 | Untagged repository with no local match in `auto` | Falls back to remote `:latest` |
| INPUT-017 | P0 | Explicit `repository:*` | Processes each distinct local image |
| INPUT-018 | P0 | Explicit wildcard in remote mode | Rejected before network work |
| INPUT-019 | P0 | Bare name matches container and image repository | Container-name interpretation wins |
| INPUT-020 | P0 | Bare name in remote mode | Always interpreted as repository `:latest` |
| INPUT-021 | P0 | Wildcard images share a RepoDigest | Digest processed once with notice |
| INPUT-022 | P1 | Wildcard match has no RepoDigest | Warn and continue with remaining matches |
| INPUT-023 | P0 | Single resolved image has no RepoDigest | Nonzero exit and useful context |
| INPUT-024 | P0 | Multiple positional inputs | State resets; result order follows input order |
| INPUT-025 | P1 | Multiple human results | Stable separator width from fixed `COLUMNS` |
| INPUT-026 | P0 | Remote tag returns invalid or unsupported digest | Reject before reverse lookup |

Local-image unit fixtures must cover:

- RepoDigests with and without a registry host.
- Multiple tags and dangling `<none>` tags.
- OCI version, revision, and ref-name labels.
- Duplicate image IDs returned by Docker.
- Exact repository equality where one name is a prefix of another.
- Docker command failure, empty fields, and malformed metadata.

## Registry classification and dispatch

Implement table-driven cases in `tests/unit/registries.bats`.

Classification inputs must include:

- Unqualified Docker Hub names and `docker.io`, `index.docker.io`, and
  `registry-1.docker.io` aliases.
- GHCR.
- ACR public and sovereign-cloud suffixes.
- `gcr.io` and each regional GCR hostname.
- `*-docker.pkg.dev` GAR repositories.
- ECR Private standard, FIPS, China, and `on.aws` hostnames.
- ECR Public.
- Generic DNS hosts, explicit ports, and localhost.
- Near-miss names that must remain generic.

| ID | Priority | Case | Expected result |
| --- | --- | --- | --- |
| DISPATCH-001 | P0 | Each classification input | Exact kind, normalized repository, and host |
| DISPATCH-002 | P0 | Direct lookup for each kind | Only the intended adapter is called |
| DISPATCH-003 | P0 | Reverse lookup for each kind | Correct initial backend name |
| DISPATCH-004 | P0 | `LOOKUP_NOT_FOUND` | Authoritative not-found result; no fallback |
| DISPATCH-005 | P0 | `LOOKUP_UNAVAILABLE` | Intended fallback only; backend updated |
| DISPATCH-006 | P0 | `LOOKUP_DENIED` | Intended auth path only |
| DISPATCH-007 | P0 | `LOOKUP_STOPPED` | Immediate abort; no fallback |
| DISPATCH-008 | P0 | New lookup begins after a prior result | Shared result, metadata, and error fields reset |
| DISPATCH-009 | P0 | `any-durable` with a confirmed durable direct tag | Direct tag satisfies the lookup without invoking a reverse backend |
| DISPATCH-014 | P0 | Direct adapter returns through an explicit context | Status, digest, and error are copied exactly |
| DISPATCH-015 | P0 | Reverse adapter returns through an explicit context | Result, backend, metadata, and ordered tags are copied exactly |
| DISPATCH-016 | P0 | `any` with a confirmed floating direct tag | Direct tag satisfies the lookup without invoking a reverse backend |
| DISPATCH-010 | P1 | Provider metadata unsupported | Metadata remains empty/null |

## Docker Hub

Implement in `tests/unit/docker-hub.bats`:

- `HUB-001` P0: normalize official and namespaced repositories exactly.
- `HUB-002` P0: direct tag lookup returns a complete matching digest.
- `HUB-003` P0: direct lookup distinguishes 404 from unavailable responses.
- `HUB-004` P0: reverse lookup paginates until `next` is empty.
- `HUB-005` P0: full digest equality rejects a prefix collision.
- `HUB-006` P0: `any-durable` retains floating matches and stops after a durable match.
- `HUB-007` P0: `all` retains matching tags across pages in response order.
- `HUB-008` P0: anonymous access is attempted before credentials.
- `HUB-009` P0: environment username/PAT retries the exact refused page.
- `HUB-010` P0: credential exchange validates the response token.
- `HUB-011` P0: bearer token is supplied through a mode-0600 header file, not
  argv.
- `HUB-012` P0: non-interactive refusal uses configured Skopeo credentials when
  available.
- `HUB-013` P0: non-interactive refusal without an allowed path fails clearly.
- `HUB-014` P1: interactive choices produce authenticated, Skopeo, or skip
  actions.
- `HUB-015` P0: skip affects only the current input.
- `HUB-016` P1: malformed/error bodies are bounded and rendered safely.
- `HUB-017` P0: 429 or other terminal policy never starts an exhaustive
  fallback.
- `HUB-018` P0: `any` returns the first matching floating tag without
  requesting another page.
- `HUB-019` P0: denied direct lookup exhausts automatic paths before an
  interactive PAT retry of the exact tag.
- `HUB-020` P0: an authoritative not-found or stopped direct fallback never
  prompts for another credential.

## GHCR

Implement in `tests/unit/ghcr.bats`:

- `GHCR-001` P0: package names are URL encoded exactly.
- `GHCR-002` P0: organization and user endpoints are tried as documented.
- `GHCR-003` P0: paginated arrays are combined; newest matching active version
  wins.
- `GHCR-004` P0: lookup by complete digest and by exact tag.
- `GHCR-005` P0: reachable API with no match returns `LOOKUP_NOT_FOUND`.
- `GHCR-006` P0: unavailable `gh` or failed endpoints return
  `LOOKUP_UNAVAILABLE`.
- `GHCR-007` P0: `never` delegates to public OCI and never calls the Packages
  API.
- `GHCR-008` P0: `require` skips public OCI and starts with Packages.
- `GHCR-009` P0: unavailable public OCI changes backend without authorizing
  credentials.
- `GHCR-010` P0: Packages result populates provider metadata and tags.
- `GHCR-011` P1: no-tag active package metadata prints the documented note.
- `GHCR-012` P0: anonymous and skip string choices dispatch correctly.
- `GHCR-013` P0: skip affects only the current input.
- `GHCR-014` P0: a stopped anonymous lookup never invokes Packages or Skopeo.
- `GHCR-015` P0: denied direct lookup exhausts existing `gh` and registry
  credentials before offering scope refresh and retrying the exact tag.
- `GHCR-016` P0: Packages `any-durable` returns matching tags through the first durable
  tag.
- `GHCR-017` P0: `if-faster` `any-durable` lets a one-page OCI sample satisfy a
  confirmed two-component direct tag before Packages pagination.
- `GHCR-018` P0: an authoritative not-found or stopped direct fallback never
  prompts for scope refresh.

## ACR

Implement in `tests/unit/acr.bats`:

- `ACR-001` P0: extract registry name and optional sovereign-cloud suffix.
- `ACR-002` P0: construct exact anonymous `_tags` and `_manifests` metadata
  URLs.
- `ACR-003` P0: HTTP 200 returns the response body.
- `ACR-004` P0: HTTP 401/403 returns `LOOKUP_DENIED` and then permits Azure CLI
  metadata lookup.
- `ACR-005` P0: HTTP 404 returns `LOOKUP_NOT_FOUND` without Azure or Skopeo.
- `ACR-006` P0: HTTP 429 returns `LOOKUP_STOPPED` without fallback.
- `ACR-007` P1: transport, malformed, and other HTTP errors return
  `LOOKUP_UNAVAILABLE`.
- `ACR-008` P0: Azure CLI argv contains exact registry, image, output, and suffix
  options.
- `ACR-009` P0: Azure CLI not-found text maps to `LOOKUP_NOT_FOUND`.
- `ACR-010` P1: Azure CLI failure maps to `LOOKUP_UNAVAILABLE` with bounded
  debug context.
- `ACR-011` P0: direct metadata accepts documented response shapes and exactly
  one digest.
- `ACR-012` P0: manifest metadata must return the requested complete digest.
- `ACR-013` P0: `any-durable` returns matches through one durable tag; `all`
  deduplicates deterministically.
- `ACR-014` P0: unavailable API falls back to lazy-auth Skopeo and changes
  backend to `skopeo`.
- `ACR-015` P0: anonymous Skopeo attempt precedes configured credentials and
  Azure short-lived login.
- `ACR-016` P0: Azure token travels over stdin to Skopeo; authfile is mode 0600.
- `ACR-017` P0: successful metadata reverse lookup reports backend `acr-api`.

## GCR and GAR

Implement in `tests/unit/gcr-gar.bats`:

- `GCR-001` P0: exact GCR metadata URL and anonymous-first request.
- `GCR-002` P0: validate GCR response shape before extracting data.
- `GCR-003` P0: direct tag selection uses exact tag membership and complete
  digest.
- `GCR-004` P0: reverse lookup matches the complete digest and implements
  `any-durable`/`all` correctly.
- `GCR-005` P0: 404, denial, rate limiting, malformed response, and transport
  failure map to the named statuses.
- `GCR-006` P0: unavailable or denied GCR metadata follows the intended GAR /
  Skopeo authentication fallback.
- `GCR-007` P0: GCR success reports `gcr-api`; fallback reports `skopeo`.
- `GAR-001` P0: public GAR access does not invoke `gcloud`.
- `GAR-002` P0: denial triggers configured credentials before `gcloud`.
- `GAR-003` P0: `gcloud auth print-access-token --quiet` is invoked exactly.
- `GAR-004` P0: username is `oauth2accesstoken`; token travels over stdin.
- `GAR-005` P1: debug denial detail is requested only in debug mode.
- `GAR-006` P0: terminal and not-found outcomes do not trigger inappropriate
  fallback.
- `GAR-007` P0: access denial obtains one Google token and reuses it with the
  OCI fast path before Skopeo.
- `GAR-008` P0: the DockerImage API request encodes the exact location, project,
  repository, nested image path, and complete digest; its token uses a mode-0600
  header file rather than process arguments.
- `GAR-009` P0: domain-scoped project paths are restored to the API project ID
  without confusing nested image paths.
- `GAR-010` P0: malformed success, denial, rate limiting, and metadata 404 map
  to safe statuses; metadata 404 remains eligible for OCI verification.
- `GAR-011` P0: DockerImage tags require the exact repository prefix, preserve
  provider order, deduplicate, and apply bounded scan semantics.
- `GAR-012` P0: `if-faster` uses available Google credentials for the indexed
  reverse API before public OCI.
- `GAR-013` P0: `if-faster` without configured Google credentials quietly
  retains public OCI behavior.
- `GAR-014` P0: `if-required` attempts public OCI before obtaining a Google
  token and querying DockerImage metadata.
- `GAR-015` P0: unavailable or absent metadata falls back to public OCI without
  claiming an authoritative not-found result.
- `GAR-016` P0: successful GAR metadata reverse lookup reports backend
  `gar-api`.

## Private ECR and ECR Public

Implement in `tests/unit/ecr.bats`. Treat the private and public paths as
separate matrices.

Private ECR:

- `ECR-001` P0: extract valid account IDs and reject malformed accounts.
- `ECR-002` P0: extract regions from standard, FIPS, China, and `on.aws` hosts.
- `ECR-003` P0: direct tag lookup calls `aws ecr describe-images` with exact
  registry, repository, imageTag, region, output, and no-pager arguments.
- `ECR-004` P0: reverse lookup uses imageDigest and returns exact matching tags.
- `ECR-005` P0: missing image maps to `LOOKUP_NOT_FOUND` without fallback.
- `ECR-006` P0: throttling variants map to `LOOKUP_STOPPED` without fallback.
- `ECR-007` P1: other CLI failures and invalid JSON map to
  `LOOKUP_UNAVAILABLE`.
- `ECR-008` P0: multiple current digests or image records are rejected as
  unavailable rather than guessed.
- `ECR-009` P0: tags are deduplicated; `any-durable` returns matches through one
  durable tag.
- `ECR-010` P0: unavailable metadata falls back to Skopeo and updates backend.
- `ECR-011` P0: AWS login password travels over stdin and never argv.
- `ECR-012` P0: configured registry credentials precede AWS CLI login.

ECR Public:

- `ECRP-001` P0: detect supported AWS credential environment variables.
- `ECRP-002` P1: absent variables query configured profiles without exposing
  profile data.
- `ECRP-003` P0: without possible AWS credentials, skip metadata alias lookup
  and preserve anonymous registry behavior.
- `ECRP-004` P0: alias lookup uses `ecr-public describe-registries`, `us-east-1`,
  page size 1000, and no pagination.
- `ECRP-005` P0: accept exactly one active alias with one 12-digit registry ID.
- `ECRP-006` P0: missing, inactive, malformed, or ambiguous aliases are
  unavailable and fall back.
- `ECRP-007` P0: metadata lookup strips only the alias component from the
  repository path.
- `ECRP-008` P0: public reverse lookup uses exact registry ID, repository,
  digest, and `us-east-1`.
- `ECRP-009` P0: not found and throttled outcomes remain authoritative/terminal.
- `ECRP-010` P0: successful reverse lookup reports `ecr-api`; unavailable lookup
  reports `skopeo` after fallback.
- `ECRP-011` P0: direct public-tag resolution uses OCI before Skopeo and does
  not unexpectedly call the metadata API.
- `ECRP-012` P0: public login password uses stdin and fixed `us-east-1`.
- `ECRP-013` P0: unavailable signed metadata uses public OCI before Skopeo.

## Generic OCI registry path

Implement in `tests/unit/oci.bats`:

- `OCI-001` P0: parse headers case-insensitively and use the final HTTP status.
- `OCI-002` P0: parse only `rel="next"` links.
- `OCI-003` P0: reject cross-host, insecure, or malformed pagination links.
- `OCI-004` P0: header files use mode 0600 and contain the complete Accept
  header.
- `OCI-005` P0: Bearer challenge parsing handles realm, service, scope, missing
  values, and mixed case.
- `OCI-006` P0: empty or wildcard scope becomes
  `repository:<repository>:pull`.
- `OCI-007` P0: token request URL-encodes service and scope exactly.
- `OCI-008` P0: accept `token` or `access_token`; reject empty/malformed token.
- `OCI-009` P0: tag listing retries the exact first page after obtaining one
  repository token.
- `OCI-010` P0: tag pagination handles same-host absolute and relative links.
- `OCI-011` P0: every page must contain a tags array; partial results fall back
  rather than succeeding.
- `OCI-012` P0: 404 is not found; 401/403 is denied; 429 is stopped; other
  failures are unavailable.
- `OCI-013` P0: manifest tags are URL encoded exactly.
- `OCI-014` P0: manifest HEAD extracts a complete `Docker-Content-Digest`.
- `OCI-015` P0: missing or malformed digest is unavailable.
- `OCI-016` P0: curl parallel support selects the parallel engine for `all`.
- `OCI-017` P0: older curl and bounded scan modes select the rolling pool.
- `OCI-018` P0: curl parallel uses at most eight transfers.
- `OCI-019` P0: parallel output is correlated with its original tag and emitted
  deterministically.
- `OCI-020` P0: a per-tag 429 terminates curl promptly, cancels queued work, and
  returns `LOOKUP_STOPPED`.
- `OCI-021` P0: 429 never triggers Skopeo fallback.
- `OCI-022` P0: private, incompatible, malformed, or incomplete fast paths fall
  back to Skopeo once.
- `OCI-023` P0: Bearer token never appears in argv or diagnostics.
- `OCI-024` P0: request, response, and header temporary files are removed on all
  handled exits.

## Skopeo and credential policy

Implement in `tests/unit/skopeo.bats`:

- `SKOPEO-001` P0: availability and configured-login probes use exact commands.
- `SKOPEO-002` P0: raw manifest bytes feed `manifest-digest`; no JSON
  reserialization occurs.
- `SKOPEO-003` P0: Darwin inspect paths add `--override-os linux` exactly once.
- `SKOPEO-004` P0: non-Darwin inspect and all list-tags calls omit the override.
- `SKOPEO-005` P0: inspect errors map denial, not-found, and unavailable text to
  named statuses.
- `SKOPEO-006` P0: list-tags runs once, then candidates use the shared pool.
- `SKOPEO-007` P0: `any-durable` retains matches through the first durable candidate;
  `all` requires complete worker results.
- `SKOPEO-008` P0: empty and mode-0600 anonymous/session authfiles are created.
- `SKOPEO-009` P0: lazy order is session credentials, isolated anonymous,
  configured credentials, then provider short-lived auth.
- `SKOPEO-010` P0: not-found, unavailable, and stopped results do not invoke a
  credential acquisition path intended only for denial.
- `SKOPEO-011` P0: authfiles are removed on normal exit and interrupt.
- `SKOPEO-012` P1: duration formatting covers seconds, minutes, and mixed values.
- `SKOPEO-013` P0: expensive interactive scan warns and continues.
- `SKOPEO-014` P0: expensive non-interactive scan stops before manifest work.
- `SKOPEO-015` P0: `--allow-expensive-scan` permits only that guard and emits a
  notice.
- `SKOPEO-016` P1: below-threshold scans do not emit an advisory.
- `SKOPEO-017` P0: `never` uses only the isolated public Skopeo context.
- `SKOPEO-018` P0: `require` skips public Skopeo and uses configured
  credentials.
- `SKOPEO-019` P0: `LOOKUP_UNAVAILABLE` may change backend but never authorizes
  credentials under `if-required`.

## Human and JSON output

Implement in `tests/integration/output.bats`.

Human output tests should use focused exact sections rather than snapshotting
all prose:

- `OUTPUT-001` P0: interpretation notice appears before registry work.
- `OUTPUT-002` P0: local baseline reports image/container fields and direct tag
  match, mismatch, not-found, or unavailable state correctly.
- `OUTPUT-003` P0: remote baseline reports resolution without repeating a local
  check.
- `OUTPUT-004` P0: bounded and `all` headings are distinct.
- `OUTPUT-005` P1: no-match output is explicit.
- `OUTPUT-006` P1: provider metadata is printed only for supported GHCR results.
- `OUTPUT-007` P0: warning, notice, error, verbose, and debug messages use their
  intended stream and gating.
- `OUTPUT-008` P0: one skipped provider does not suppress later inputs.

JSON tests must parse stdout with jq and assert fields semantically:

- `JSON-001` P0: stdout is one valid array and stderr remains separate.
- `JSON-002` P0: one object per resolved image in input/expansion order.
- `JSON-003` P0: local and remote baseline fields have correct nullability.
- `JSON-004` P0: direct check statuses cover resolved, match, mismatch,
  not-found, and unavailable.
- `JSON-005` P0: scan statuses cover completed, not-found, not-requested,
  declined, and skipped.
- `JSON-006` P0: backend is one of `acr-api`, `direct-tag-check`,
  `docker-hub-api`, `ecr-api`, `gar-api`, `github-packages-api`, `gcr-api`,
  `oci-registry-api`, `skopeo`, or null where no scan ran.
- `JSON-007` P0: backend changes to the actual fallback backend.
- `JSON-008` P0: tags are an array with exact values and order.
- `JSON-009` P0: GHCR provider metadata is parsed JSON; other providers use
  null.
- `JSON-010` P0: diagnostics, spinners, and cloud CLI notices never contaminate
  stdout.
- `JSON-011` P1: wildcard and multiple inputs still produce one array.

## Security and cleanup

Implement in `tests/security/credentials-and-cleanup.bats`. Use distinct canary
values for every credential type and fail if any appears unexpectedly.

| ID | Priority | Case | Expected result |
| --- | --- | --- | --- |
| SEC-001 | P0 | Docker Hub bearer token | Absent from argv/output; header file mode 0600 |
| SEC-002 | P0 | OCI bearer token | Absent from argv/output; header file mode 0600 |
| SEC-003 | P0 | Azure access token | Passed via stdin to Skopeo, never argv/output |
| SEC-004 | P0 | Google access token | Passed via stdin/authfile, never argv/output |
| SEC-005 | P0 | AWS login password | Passed via stdin, never argv/output |
| SEC-006 | P0 | GAR API bearer token | Absent from argv/output; header file mode 0600 |
| SEC-007 | P0 | Lazy Skopeo authfiles | Mode 0600 and contain only isolated session data |
| SEC-008 | P0 | Normal success and handled failures | Temporary credential/header files removed |
| SEC-009 | P0 | SIGINT during active workers | Status 130, children terminate, authfiles removed |
| SEC-010 | P1 | Registry error body with control/newline content | Diagnostic is bounded and cannot forge extra records |
| SEC-011 | P0 | Existing user config fixtures | Never modified by the command |
| SEC-012 | P0 | Debug mode | Does not weaken any secret-redaction assertion |

Inspect both command logs and the temporary tree before teardown. A clean
stdout assertion alone is insufficient.
GHCR anonymous access uses the shared OCI token path and is covered by
`SEC-002` and `OCI-023`.

## Offline end-to-end scenarios

After unit coverage exists, add compact scenarios that invoke the real CLI with
all external tools stubbed:

1. Local Docker Hub image whose tag still matches, plus `all` reverse results.
2. Missing local tagged image that falls back to remote resolution in `auto`.
3. Complete digest input through GHCR Packages metadata.
4. Public GCR metadata success without invoking `gcloud` or Skopeo.
5. Public ACR metadata success with backend `acr-api`.
6. Private ACR denial, Azure metadata attempt, then successful result.
7. Private ECR signed metadata success with backend `ecr-api`.
8. ECR Public alias resolution success, then public OCI and Skopeo fallbacks.
9. Generic OCI success with Skopeo set to an executable that fails if called.
10. Generic OCI incompatibility followed by one Skopeo fallback.
11. Terminal 429 proving no provider or Skopeo fallback runs.
12. Multiple inputs where one provider is skipped and later inputs complete.

Each scenario must assert exit status, semantic output, stderr ordering, and the
complete external call sequence.

## Optional live tests

Live tests are P2 and must be isolated under `tests/live`. They require
`CIT_LIVE_TESTS=1`, use only public references by default, and must never infer
success from cached local Docker metadata.

Provide environment variables for targets rather than embedding private
repositories:

```text
CIT_LIVE_DOCKER_HUB_REF
CIT_LIVE_GHCR_REF
CIT_LIVE_GCR_REF
CIT_LIVE_GAR_REF
CIT_LIVE_ACR_REF
CIT_LIVE_ECR_PUBLIC_REF
CIT_LIVE_GENERIC_OCI_REF
```

For each configured target, record the exact reference and whether the test is
anonymous, authenticated, fast-path, or fallback validation. Skip unconfigured
targets with an explicit reason. Never print secret values.

At minimum, manual pre-release validation should include:

- A public Docker Hub direct and reverse lookup.
- A public GCR metadata lookup without `gcloud`.
- A public generic OCI lookup with Skopeo forbidden.
- A public ACR metadata lookup if a stable target is configured.
- An ECR Public metadata or documented fallback lookup if a stable target and
  non-personal AWS profile are configured.

Live tests should assert durable properties such as a tag resolving to the
digest obtained moments earlier. Do not hard-code mutable digests or assume a
particular number of tags.

## CI plan

Add CI only after `tests/run` is stable locally.

Required pull-request jobs:

1. **Static:** Bash syntax, ShellCheck, and whitespace checks.
2. **Linux minimum:** Bash 4.4 with required command dependencies.
3. **Linux current:** current supported Bash, full offline suite.
4. **macOS current:** full offline suite, including Darwin Skopeo argv cases.
5. **Security:** may be part of the full jobs but must remain visibly named in
   output.

CI requirements:

- Pin action revisions and the Bats Core version.
- Cache only downloaded test dependencies, never test output or authfiles.
- Do not expose repository or user secrets to pull-request tests.
- Set job timeouts.
- Upload diagnostic call logs only on failure, after running canary-secret
  checks.
- Keep stress tests in a separate scheduled/manual job.
- Keep live tests manual or scheduled and non-blocking until their stability is
  demonstrated.

## Implementation phases

### Phase 1: Harness and first vertical slice

Implement:

- Test layout, `tests/run`, isolation, assertions, and exact argv logging.
- Fake Docker, curl, jq pass-through, and Skopeo primitives.
- Static checks.
- The first six shared-contract cases (`COMMON-001` through `COMMON-006`).
- One complete offline Docker Hub CLI scenario.

Exit criteria:

- Tests run from any current directory.
- No network, Docker daemon, home-directory, or credential access occurs.
- A deliberate unexpected stub call fails with a useful diagnostic.

### Phase 2: Core resolution and scheduler

Implement:

- All common/pool, CLI, input-resolution, local-image, classification, and
  dispatch cases.
- Stress-mode infrastructure.

Exit criteria:

- Every input inference branch is covered.
- Every named lookup status is covered at the dispatch boundary.
- Scheduler ordering, cap, early stop, terminal stop, and cleanup are proven.

### Phase 3: Provider adapters

Implement provider files in this order to maximize helper reuse:

1. Skopeo and credential policy.
2. Generic OCI.
3. Docker Hub.
4. GHCR.
5. GCR/GAR.
6. ACR.
7. Private ECR and ECR Public.

Exit criteria:

- Every adapter has success, not-found, unavailable, denied where applicable,
  and stopped coverage.
- Every fallback is tested in both the permitted and forbidden direction.
- ACR and ECR metadata backends have exact cloud/HTTP argv coverage.

### Phase 4: Output, security, and complete integration

Implement:

- Human and JSON contracts.
- Secret canaries, file modes, cleanup, and interruption.
- All twelve offline end-to-end scenarios.

Exit criteria:

- JSON stdout is clean under every diagnostic mode.
- All credential canaries are absent from argv and output.
- Temporary credentials and child processes do not leak.

### Phase 5: CI, stress, and live validation

Implement:

- Required CI matrix.
- Scheduled/manual stress job.
- Opt-in live runner and documented configuration.
- README development instructions for installing Bats and running each tier.

Exit criteria:

- Required jobs pass from a fresh checkout.
- Pull-request jobs are deterministic and offline.
- Live failures cannot conceal or override required offline results.

## Completion criteria

The comprehensive test-suite effort is complete when:

- Every required ID in this document is implemented or explicitly removed from
  the plan with a documented behavioral reason.
- Every CLI inference and registry dispatch branch maps to at least one test ID.
- Every named lookup status is tested at helper and caller boundaries.
- Every registry backend has success and failure fixtures.
- Exact digests, deterministic ordering, bounded/`all` scans, anonymous-first access,
  terminal-stop behavior, and fallback selection have P0 regressions.
- JSON schemas and backend names are asserted semantically.
- Credential canaries prove secrets are absent from arguments and output.
- Required tests run without network, Docker, cloud accounts, or user state.
- Bash 4.4, current Linux Bash, and macOS jobs pass.
- Stress and live tiers are separately invocable and cannot run accidentally.
- README instructions reproduce the CI commands locally.
- The final implementation reports any behavior defects discovered by the new
  tests separately from test-infrastructure changes.

Line coverage may be measured for information after the suite is complete, but
it is not a substitute for satisfying this behavior and risk matrix.
