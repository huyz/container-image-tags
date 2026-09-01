# Architecture

`container-image-tags` is organized as a pipeline with provider adapters. The
separation is intentionally explicit even where it adds lines of code:
input inference (how command line arguments are interpreted),
registry policy, transport mechanics, result construction, and rendering have
different correctness constraints.

## Processing pipeline

Each positional argument passes through these stages:

1. `resolve_input_subjects` classifies the syntax and resolves a container,
   local image, remote tag, complete digest, or local repository wildcard
   to the relevant repository digest(s).
2. A wildcard may expand into several locally resolved repository digests. Duplicate
   repository digests are removed before registry query.
3. `process_resolved_subject` normalizes the repository and digest and creates
   one associative result record.
4. `check_subject_remote_tag` verifies a known tag or records the remote tag
   resolution that established the resolved repository digest.
5. The selected provider advertises atomic attempts and capabilities to the
   central policy engine. The engine performs the direct or reverse lookup,
   including credential eligibility, ordering, fallback, terminal outcomes,
   and whether interactive recovery may run.
6. The provider lookup context is copied into the canonical result record.
7. Human and JSON renderers consume that same record.

The executable contains dependency and option handling plus the final loop.
The pipeline itself lives in `lib/pipeline.sh`; result records and renderers live
in `lib/results.sh`. `lib/scan-policy.sh` owns durable-tag and scan-selection
semantics, while `lib/scheduler.sh` owns bounded per-tag worker execution.

## State boundaries

The canonical result is an associative array with four groups of fields:

- input and local-image identity;
- normalized repository, digest, and subject source;
- registry classification and direct-tag check;
- scan mode, status, backend, provider metadata, and ordered tags.

Registry dispatch requires a caller-owned associative lookup context. The same
request/result contract is used for direct and reverse operations. Provider
callbacks receive the request plus an associative result and return a named
lookup status. Legacy module globals remain inside a few transport mechanisms
whose Bash command substitutions depend on shell scope; the policy engine does
not use them as its protocol. The pipeline consumes only the completed lookup
context, which is copied into the canonical result record.

## Central registry policy engine

`lib/policy-engine.sh` is the complete registry-independent flowchart. A
provider does not call another provider or fallback mechanism. Instead, its
`*_register_policy_attempts` function advertises atomic attempts with this
universal declaration:

| Field | Meaning |
| --- | --- |
| ID and callback | Stable plan identity and the atomic operation to invoke |
| Backend | Backend reported if the attempt answers |
| Access class | `local`, `public`, `session`, `fast-credential`, `credential`, or `interactive` |
| Cost | Relative ordering among currently eligible attempts |
| Authoritative | Whether `LOOKUP_NOT_FOUND` terminates the whole lookup |
| Availability callback | Lazy check for an optional CLI, token, or configured credential |

The engine applies one algorithm to both user operations:

1. Add built-in local shortcuts and the selected provider's declarations.
2. Remove attempts forbidden by `--credential-policy` or current state.
3. Select the lowest-cost remaining attempt, using declaration order only to
   break equal-cost ties, and then check its availability lazily.
4. On success, return its result and actual backend. On authoritative absence
   or `LOOKUP_STOPPED`, terminate.
5. On `LOOKUP_UNAVAILABLE`, try another permitted mechanism without unlocking
   credentials. On `LOOKUP_DENIED`, unlock conditional credential attempts,
   stop retrying public access, and permit interactive recovery only in a real
   terminal.
6. Repeat until a terminal result is reached or no attempt remains.

An adaptive probe may return `POLICY_DEFERRED` after advertising measured
continuations. This is how GHCR compares its remaining Packages pages with an
OCI scan without selecting the backend inside the provider. The engine simply
repeats step 2 and chooses the cheapest newly advertised continuation.

Provider modules consequently own mechanisms and provider-specific prompt
content. The engine owns when a prompt is eligible and every transition into
or away from that interactive attempt.

## Lookup outcomes

Every backend uses the same status contract:

| Status               | Meaning                                   | Broader fallback  |
| -------------------- | ----------------------------------------- | ----------------- |
| `LOOKUP_SUCCEEDED`   | Complete usable result                    | No                |
| `LOOKUP_NOT_FOUND`   | Authoritative absence                     | No                |
| `LOOKUP_UNAVAILABLE` | Backend could not answer                  | Yes               |
| `LOOKUP_DENIED`      | Conditional credential paths become eligible | Yes, by engine |
| `LOOKUP_STOPPED`     | Terminal limit or refused expensive scan  | No                |

`lib/policy-engine.sh` owns the interpretation of these statuses.
`lib/registries.sh` classifies a repository, builds the common request, asks the
matching provider to advertise attempts, and copies the engine result into the
caller-owned context.

## Registry access matrix

This section covers only the reverse scan from a known digest to its current
tags. Digest resolution is outside the matrix.

Three algorithms appear in the cells:

- **Indexed metadata** asks a provider API for the tags attached to the digest.
  It avoids per-tag manifest requests and is normally the cheapest path.
- **Native OCI scan** uses `lib/oci.sh` to list tags, then sends a manifest
  `HEAD` for each candidate required by the scan mode. It uses up to eight
  workers. `any` and `any-durable` can stop early; `all` is linear in the
  repository's tag count.
- **Skopeo scan** runs `skopeo list-tags`, then inspects each required candidate
  manifest. It has the same stopping and eight-worker contracts as native OCI,
  but is a compatibility and credential-discovery fallback, not a faster
  reverse algorithm (in fact it is usually slower than native OCI).

The rows below are attempt priority, not unconditional calls. Read each
registry column from top to bottom and skip any row whose condition is false.
The default `--credential-policy=if-faster` permits an existing credential only
when it unlocks a cheaper indexed path; ordinary credential and interactive
rows require an earlier `LOOKUP_DENIED`. `if-required` starts with public rows,
`never` removes all credentialed rows, and `require` removes all public rows.
The engine stops as soon as a row succeeds or returns a terminal outcome.

| Step / condition | Docker Hub | GHCR | ACR | GCR | GAR | Private ECR | ECR Public | Other OCI |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **0. Satisfy the scan locally** | If the already-confirmed input tag satisfies `any`, or satisfies `any-durable` and is durable, return it. `all` always continues. | Same | Same | Same | Same | Same | Same | Same |
| **1. Reuse an in-run provider session** | Reuse a Docker Hub API token obtained for an earlier input. | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| **2. Try the provider-specific primary path** | Public paginated Hub tags API. Each record already pairs a tag with its digest; bounded modes can stop between pages. For `all`, measure page 1 and guard the estimated remaining pages. Hub typically denies further requests after ~10 pages. | With usable `gh` credentials under `if-faster` or `require`, search only the first GitHub Packages page for the digest. A complete miss is authoritative; an incomplete miss continues at step 3. | Public ACR manifest-metadata request by digest. One response contains the attached tags. | Public GCR `tags/list` extension. Its digest-keyed manifest map contains the attached tags in one response. | Under `if-faster` or `require`, use an existing Google token with `dockerImages.get`. A 404 is non-authoritative because remote or virtual repositories may resolve an upstream image. | Under `if-faster` or `require`, call signed `DescribeImages` by digest. The response contains all current tags. | Under `if-faster` or `require`, use the signed ECR Public API when AWS credentials are detectable and the repository alias resolves unambiguously. | N/A |
| **3. Continue the measured GHCR path** | N/A | If step 2 pagination indicates more Packages pages, anonymously inventory OCI tags while it remains cheaper than the remaining Packages pages. Register both measured continuations, then commit to the cheaper one first: more Packages pages, or manifest `HEAD`s over the already-listed OCI tags. Either bulk continuation runs the expensive-work guard. | N/A | N/A | N/A | N/A | N/A | N/A |
| **4. Try the public native OCI path** | N/A; the Hub API is the preferred public index. | Use when the Packages probe is unavailable or not permitted, after any measured continuation is unavailable, or after a Packages continuation is denied. A denial from an OCI continuation suppresses this duplicate public attempt. | N/A; ACR metadata is the preferred public index. | N/A; the GCR manifest map is the preferred public index. | List tags and inspect candidate manifests. This also verifies a non-authoritative GAR API miss. | N/A; authentication probe only: the expected denial unlocks credentialed paths under `if-required` or after the signed API is unavailable. | Normal fallback when the signed API is unavailable or credentials are not permitted. | Primary algorithm: list tags and inspect candidate manifests. |
| **5. Try provider credentials**<br>After `LOOKUP_DENIED`, or immediately under `require` | Exchange `DOCKER_HUB_USERNAME` and `DOCKER_HUB_PAT` for a short-lived Hub token, then resume the paginated Hub API scan. | Search GitHub Packages pages using existing `gh` credentials with `read:packages`. | Ask Azure CLI for the digest-addressed manifest metadata. | Obtain a short-lived Google token and repeat the GCR manifest-map request. | Obtain a Google token and try `dockerImages.get`, unless that API was already attempted. Its 404 remains non-authoritative. | Call signed `DescribeImages`, unless the same API was already attempted. | Call the signed ECR Public API, unless it was already attempted. | N/A |
| **6. Try credentialed native OCI**<br>After step 5 cannot answer | N/A | N/A | N/A | N/A | Reuse the Google token to list tags and inspect candidate manifests through native OCI. | N/A | N/A | N/A |
| **7. Reuse the Skopeo session authfile** | If the session authfile already contains this registry, run the generic Skopeo scan. | Same | Same | Same | Same | Same | Same | Same |
| **8. Try isolated public Skopeo** | Run the generic scan with an explicitly empty authfile only when earlier public access was unavailable, not denied. | Same | Same | Same | Same | Same | Same | Same |
| **9. Try configured Skopeo credentials**<br>After `LOOKUP_DENIED`, or immediately under `require` | Let Skopeo use its default credential context, including Skopeo/Podman auth and Docker credential helpers. | Same | Same | Same | Same | Same | Same | Same |
| **10. Give Skopeo a provider credential**<br>After denial (or under `require`) and configured credentials cannot answer | N/A | N/A | Obtain a short-lived ACR credential, store it only in the session authfile, then run the generic scan. | Obtain a short-lived Google credential, store it only in the session authfile, then run the generic scan. | Obtain a short-lived Google credential, store it only in the session authfile, then run the generic scan. | Obtain a short-lived ECR credential, store it only in the session authfile, then run the generic scan. | Obtain a short-lived ECR Public credential, store it only in the session authfile, then run the generic scan. | N/A |
| **11. Offer interactive recovery**<br>Only after denial and all automatic paths | Collect a Docker Hub username/PAT and retry the Hub API, or let the user skip this input. | Offer to refresh `gh` with `read:packages` and retry Packages, explicitly choose the slower anonymous OCI scan, or skip this input. | N/A | N/A | N/A | N/A | N/A | N/A |

Every per-tag OCI or Skopeo scan performs an expensive-work preflight. A
non-interactive estimate over ten minutes returns `LOOKUP_STOPPED` unless
`--allow-expensive-scan` was supplied; an interactive estimate over three
minutes warns and continues. Docker Hub and GHCR apply the same policy to
measured remaining API pages.

Fallback is determined by the result of the current row:

| Result | Effect on the remaining rows |
| --- | --- |
| `LOOKUP_SUCCEEDED` | Return the selected tags immediately. |
| `LOOKUP_NOT_FOUND` | Stop when the mechanism is authoritative. GAR's metadata miss is deliberately converted to `LOOKUP_UNAVAILABLE` so OCI can verify remote and virtual repositories. |
| `LOOKUP_STOPPED` | Stop immediately. Rate limiting and a refused expensive scan never select a more request-intensive backend. |
| `LOOKUP_UNAVAILABLE` | Try the next permitted mechanism. This can change clients or backends but cannot authorize credentials. |
| `LOOKUP_DENIED` | Record the denial and permit credentialed rows according to `--credential-policy`. A denial from a public row also suppresses later public rows. |

Here, **public** means that no user credential is supplied; a registry may
still issue a repository-scoped bearer token for public access. Native OCI
keeps bearer headers in mode-0600 temporary files; Skopeo separates an empty
public authfile from the session authfile and receives login secrets on
standard input.

Provider-specific response parsing and authentication remain in provider
modules. Generic request resources and diagnostic extraction live in
`lib/runtime.sh`.

### Credential policy

`--credential-policy` describes only whether user credentials may be used.
Backend selection remains automatic within that constraint:

| Mode | Public requests | User credentials | Backend preference | Failure behavior |
| --- | --- | --- | --- | --- |
| `never` | Always tried | Never read, request, or use them | Best public path only | Fail when public access cannot answer |
| `if-required` | Always tried first | Use configured or short-lived credentials only after `LOOKUP_DENIED` | Best path that preserves public-first access | `LOOKUP_UNAVAILABLE` may change public backend but never authorizes credentials |
| `if-faster` | Tried unless a credentialed native path is materially faster or more complete | May be used proactively only for that faster native path; otherwise only after `LOOKUP_DENIED` | Fastest complete path satisfying the credential constraint | Preserve terminal not-found, stopped, and rate-limit outcomes |
| `require` | Skipped | Required from the first registry operation | Best credentialed provider path | Fail when credentials are unavailable |

This policy should remain orthogonal to `--tag-scan` and
`--allow-expensive-scan`. Scan breadth determines completeness; the expensive
scan guard determines whether a costly chosen path may proceed. Backend
selection should stay automatic within those constraints because "fast" and
"authenticated" do not form opposite ends of one scale.

## Bounded scan contracts

`any` stops at the first matching tag in provider order. A directly confirmed tag whose
direct check matched satisfies the scan immediately, even when it is floating.

`any-durable` means the first matching tag heuristically classified as durable.
All matching floating tags encountered before that
durable tag are retained. A directly confirmed tag whose direct check matched is seeded
as the first result—including a local tag—and is not probed again. If that tag
is floating, scanning continues; if it is durable under the observed repository
convention, it satisfies the scan immediately.

`select_matching_tags_for_scan` is the policy entry point for providers that
receive a complete metadata tag set. OCI and Skopeo use the same durability
helpers in the shared rolling worker scheduler so incremental scans preserve
candidate order and stop scheduling after the match required by the selected
bounded mode is observed.

## Runtime resources

All temporary files and directories are created beneath one mode-0700 runtime
directory. Callers still remove sensitive or bulky files promptly. The runtime
cleanup trap is the final safety net for early exits and interrupts. Tokens are
written to mode-0600 header or auth files and are never passed as process
arguments.
