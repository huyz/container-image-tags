# Architecture

`container-image-tags` is organized as a pipeline with provider adapters. The
separation is intentionally explicit even where it adds lines of code:
input inference (how command line arguments are interpreted),
registry policy, transport mechanics, result construction, and rendering have
different correctness constraints.

## Processing pipeline

Each positional argument passes through these stages:

1. `resolve_input_baselines` classifies the syntax and resolves a container,
   local image, remote tag, complete digest, or local repository wildcard
   to the relevant manifest digest(s).
2. A wildcard may expand into several local image baselines. Duplicate
   repository digests are removed before registry query.
3. `process_resolved_baseline` normalizes the repository and digest and creates
   one associative result record.
4. `check_baseline_remote_tag` verifies a known tag or records the remote tag
   resolution that established the baseline.
5. The selected provider adapter performs the reverse-lookup scan, including its
   complete authentication and fallback policy.
6. The provider lookup context is copied into the canonical result record.
7. Human and JSON renderers consume that same record.

The executable contains dependency and option handling plus the final loop.
The pipeline itself lives in `lib/pipeline.sh`; result records and renderers live
in `lib/results.sh`.

## State boundaries

The canonical result is an associative array with four groups of fields:

- input and local-image identity;
- normalized repository, digest, and baseline source;
- registry classification and direct-tag check;
- scan mode, status, backend, provider metadata, and ordered tags.

Registry dispatch also accepts an optional associative lookup context. Legacy
module globals remain the internal provider protocol because Bash command
substitutions and existing focused module tests depend on their shell scope.
The pipeline does not read those globals: dispatch copies them into the lookup
context, which is then copied into the result record.

## Lookup outcomes

Every backend uses the same status contract:

| Status               | Meaning                                   | Broader fallback  |
| -------------------- | ----------------------------------------- | ----------------- |
| `LOOKUP_SUCCEEDED`   | Complete usable result                    | No                |
| `LOOKUP_NOT_FOUND`   | Authoritative absence                     | No                |
| `LOOKUP_UNAVAILABLE` | Backend could not answer                  | Yes               |
| `LOOKUP_DENIED`      | Intended authentication path may be tried | Provider-specific |
| `LOOKUP_STOPPED`     | Terminal limit or refused expensive scan  | No                |

Provider modules own the interpretation of these statuses. `lib/registries.sh`
only classifies a repository and selects the matching adapter entry point.

## Registry access matrix

Registry access currently combines several independent decisions. Keeping
their names separate helps avoid treating an authenticated path as necessarily
slow, or an anonymous path as necessarily fast.

| Axis            | Question                                                | Current control                                        |
| --------------- | ------------------------------------------------------- | ------------------------------------------------------ |
| Baseline source | Is the comparison digest local or resolved remotely?    | `--tag-resolution`                                     |
| Scan breadth    | Is reverse lookup skipped, bounded, or exhaustive?      | `--tag-scan`                                           |
| Credential use  | May a lookup identify the caller, and when?             | `--credential-policy`                                  |
| Backend         | Which provider, OCI, or Skopeo API performs the lookup? | Selected automatically                                 |
| Cost guard      | May an estimated long per-tag scan proceed unattended?  | `--allow-expensive-scan`                               |

The current default paths are below. Numbers show attempt order within each
lookup column. A “Skopeo fallback” step expands to the sequence in that row's
Skopeo column.

| Registry | Direct tag lookup order | Reverse digest lookup order | Native credential path | Skopeo fallback | Reverse-scan cost |
| --- | --- | --- | --- | --- | --- |
| Docker Hub | 1. Public Hub tag API<br>2. Environment PAT retry after access denial<br>3. Skopeo fallback | 1. Public paginated Hub API<br>2. Environment PAT retry after access denial<br>3. Interactive PAT or Skopeo fallback | 1. Exchange an environment or interactive PAT for a short-lived Hub token after access denial | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial | Hub API: **fast**<br>Skopeo: one request per tag |
| GHCR | 1. Public OCI manifest request<br>2. GitHub Packages API after access denial<br>3. Skopeo fallback | 1. Public OCI tag sample may satisfy `any`<br>2. GitHub Packages API<br>3. Public OCI tag listing and parallel manifest `HEAD` requests<br>4. Skopeo fallback<br>5. Interactive credential refresh, public OCI scan, or skip | 1. Use existing `gh` credentials for the Packages API<br>2. Refresh `gh` credentials interactively when selected | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial | Packages API: **fast**<br>OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |
| ACR | 1. Public ACR tag metadata API<br>2. Azure CLI metadata after access denial<br>3. Skopeo fallback | 1. Public ACR manifest metadata API<br>2. Azure CLI metadata after access denial<br>3. Skopeo fallback | 1. Query metadata through Azure CLI after access denial<br>2. Obtain a short-lived Azure token if Skopeo is denied | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived Azure token after access denial | Metadata API: **fast**<br>Skopeo: one request per tag |
| GCR | 1. Public GCR manifest map<br>2. Token-authenticated GCR manifest map after access denial<br>3. Skopeo fallback | 1. Public GCR manifest map<br>2. Token-authenticated GCR manifest map after access denial<br>3. Skopeo fallback | 1. Obtain a short-lived Google token after access denial<br>2. Reuse the token with the GCR manifest map | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived Google token after access denial | Manifest map: **fast**<br>Skopeo: one request per tag |
| GAR | 1. Public OCI manifest request<br>2. Token-authenticated OCI manifest request after access denial<br>3. Skopeo fallback | 1. Public OCI tag listing and parallel manifest `HEAD` requests<br>2. Token-authenticated OCI listing and parallel manifest `HEAD` requests after access denial<br>3. Skopeo fallback | 1. Obtain a short-lived Google token after access denial<br>2. Reuse the token with the OCI fast path | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived Google token after access denial | OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |
| Private ECR | 1. Signed ECR service API<br>2. Public OCI manifest request if the service API is unavailable<br>3. Skopeo fallback | 1. Signed ECR service API<br>2. Public OCI listing and parallel manifest `HEAD` requests if the service API is unavailable<br>3. Skopeo fallback | 1. Use AWS credentials with the signed service API<br>2. Obtain a short-lived AWS token if Skopeo is denied | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived AWS token after access denial | ECR API: **fast**<br>OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |
| ECR Public | 1. Public OCI manifest request<br>2. Skopeo fallback | 1. Signed ECR Public API when AWS credentials are detectable<br>2. Public OCI listing and parallel manifest `HEAD` requests<br>3. Skopeo fallback | 1. Use AWS credentials with the signed reverse-lookup API<br>2. Obtain a short-lived AWS token if Skopeo is denied | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived AWS token after access denial | ECR API: **fast**<br>OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |
| Other OCI | 1. Public OCI manifest request<br>2. Skopeo fallback | 1. Public OCI tag listing and parallel manifest `HEAD` requests<br>2. Skopeo fallback | Not applicable | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial | OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |

Here, “public” means that no user credential is supplied (i.e. anonymous). An OCI registry may
still issue a repository-scoped bearer token for public access, so “no user
credentials” is more precise than “no authentication.” A rate limit or an
authoritative not-found response is terminal; it must not trigger a broader or
credentialed fallback.

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
selection should stay automatic within those constraints because “fast” and
“authenticated” do not form opposite ends of one scale.

## `any` scan contract

`any` means the first matching tag heuristically classified as durable, not the
first arbitrary match. All matching floating tags encountered before that
durable tag are retained. A baseline tag whose direct check matched is seeded
as the first result—including a local tag—and is not probed again. If that tag
is floating, scanning continues; if it is durable under the observed repository
convention, it satisfies the scan immediately.

`select_matching_tags_for_scan` is the policy entry point for providers that
receive a complete metadata tag set. OCI and Skopeo use the same durability
helpers in the shared rolling worker scheduler so incremental scans preserve
candidate order and stop scheduling only after a durable match is observed.

## Runtime resources

All temporary files and directories are created beneath one mode-0700 runtime
directory. Callers still remove sensitive or bulky files promptly. The runtime
cleanup trap is the final safety net for early exits and interrupts. Tokens are
written to mode-0600 header or auth files and are never passed as process
arguments.
