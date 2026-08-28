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

### How registry operations determine the path

Direct and reverse lookup have different protocol costs:

- A direct `tag -> digest` lookup is cheap through the OCI Distribution API.
  One manifest `HEAD` request can return `Docker-Content-Digest` (possibly
  after exchanging a public repository-scoped bearer token).
- A reverse `digest -> tags` lookup is not defined by the OCI Distribution
  API. Its generic implementation must list the repository's tags and then
  request each candidate manifest to discover its digest. Bounded scans can
  stop early; `all` is inherently one manifest request per tag.
- A provider metadata API is preferred when it returns the tag and digest
  relationship directly. That avoids per-tag manifest requests and may also
  expose an authoritative not-found response.

In this document, **native OCI** means the explicit Distribution API client in
`lib/oci.sh`; it does not mean that no OCI protocol is involved elsewhere.
Skopeo normally talks to the same registry protocol internally, but it owns
transport compatibility, credential discovery, and manifest handling. A row
without a native OCI step may therefore still reach registry manifest
endpoints through its Skopeo fallback.

#### Native OCI versus the Skopeo fallback

Native OCI and Skopeo are two implementations of the same portable registry
operations. For a direct lookup, each resolves one tag to its exact manifest
digest. For a reverse lookup, each lists the repository's tags and resolves
the manifest digest of every candidate required by the scan mode. Both paths
therefore preserve full-digest equality, provider tag order, the `any`,
`any-durable`, and `all` stopping contracts, an eight-worker concurrency
limit, and the expensive-scan preflight.

Skopeo is not a provider metadata fast path. In particular, it does not replace
the Docker Hub, GitHub Packages, ACR, GCR, GAR, or ECR indexes described below. A
Skopeo reverse lookup still performs a tag-list request followed by as many
manifest inspections as the scan requires. Its value is broader registry and
credential compatibility when the deliberately narrow native client cannot
finish the operation.

| Capability | Native OCI | Skopeo fallback | Practical consequence |
| --- | --- | --- | --- |
| Registry model | Calls OCI Distribution v2 endpoints directly with `curl`. | Uses Skopeo's `docker://` transport, which normally calls the same Distribution endpoints. | Choosing Skopeo usually changes the client implementation, not the registry-side algorithm. |
| Direct `tag -> digest` | Sends a manifest `HEAD` and reads the exact `Docker-Content-Digest` response header. | Downloads the raw manifest with `skopeo inspect --raw` and computes its digest with `skopeo manifest-digest`. | Native OCI transfers less data; Skopeo can accommodate manifest and transport behavior outside the native client's assumptions. |
| Reverse `digest -> tags` | Paginates `tags/list`, then sends one manifest `HEAD` for each required candidate. | Runs `skopeo list-tags`, then one raw manifest inspection and digest calculation for each required candidate. | Both are linear in the number of inspected tags; Skopeo is compatibility fallback, not a reverse-lookup acceleration. |
| Public access | Sends no user credential. It can answer one Bearer challenge by obtaining a public repository-scoped token. | Uses a temporary empty authfile so cached credentials cannot leak into the public attempt. | Both support genuinely public-first operation even when the registry calls its public bearer exchange "authentication." |
| Existing credentials | Does not search credential stores or invoke credential helpers. | Can use credentials known to Skopeo or Podman and, through Skopeo's discovery, Docker configuration and credential helpers. | A private generic registry normally needs Skopeo unless a provider adapter supplies a token directly to native OCI. |
| Provider credentials | Can use a bearer token explicitly supplied by a provider adapter, as the Google adapters do. | Can store a short-lived ACR, Google, or ECR credential obtained by a provider callback in a session-only authfile. | Provider tokens may make either client authenticated; "native" does not mean "anonymous," and "Skopeo" does not mean "authenticated." |
| Manifest and platform handling | Accepts an explicit set of OCI and Docker manifest media types and relies on registry response headers. | Delegates media-type, registry, and raw-manifest handling to Skopeo; on macOS the tool passes `--override-os linux` to match the Docker Desktop default environment. | Skopeo is the safer compatibility attempt for a registry or manifest shape the native client does not recognize. |
| Concurrency and cost | Uses parallel manifest `HEAD` requests; exhaustive scans use curl's native parallel engine when available so connections may be reused or multiplexed. | Starts one Skopeo inspection process per candidate through the shared rolling worker pool. | Native OCI is expected to be lighter and is estimated at one second per parallel batch; Skopeo uses a conservative two seconds per tag before parallelism. |
| Failure classification | Classifies actual HTTP status codes and required headers: denial, absence, rate limit, or unsupported/unavailable behavior. | Maps bounded patterns in Skopeo's command diagnostics, such as 401/403, 404, and 429, to the shared lookup statuses. | Native OCI has more structured failure evidence; an unfamiliar Skopeo diagnostic is conservatively treated as unavailable. |
| Runtime dependency | Uses the program's existing `curl` and `jq` requirements. | Requires the optional external Skopeo executable. | A missing Skopeo leaves native and provider paths usable, but removes the generic compatibility and configured-credential fallback. |
| Secret isolation | Writes bearer headers to mode-0600 temporary files rather than process arguments. | Separates a mode-0600 empty public authfile from a mode-0600 session authfile and supplies login secrets on standard input. | Neither path intentionally exposes tokens in process arguments, and a public Skopeo attempt cannot silently become credentialed. |

"Skopeo fallback" consequently describes two different transitions, both
governed by the same status contract:

1. After `LOOKUP_UNAVAILABLE`, Skopeo may be tried with its isolated empty
   authfile as a different public client. This is a compatibility fallback;
   unavailability alone never authorizes user credentials.
2. After `LOOKUP_DENIED`, the credential policy may permit Skopeo to use
   configured registry credentials. If that attempt is also denied, a
   provider adapter may obtain a short-lived credential and put it in the
   session authfile.

An already acquired in-session credential is reused first when the credential
policy permits it. Otherwise the public Skopeo attempt precedes configured
credentials. `LOOKUP_NOT_FOUND` and `LOOKUP_STOPPED` are terminal: neither
selects another backend nor broadens credential use. Thus the word "fallback"
does not mean "always authenticated," and Skopeo itself has no hidden
anonymous-to-authenticated transition outside this sequence.

The path matrix below assumes the default `--credential-policy=if-faster`.
Other policies can reorder or remove public and credentialed attempts. Numbers
show attempt order within each lookup column. A "Skopeo fallback" step expands
to the sequence in that row's Skopeo column.

| Registry | Direct tag lookup order | Reverse digest lookup order | Provider credential path | Skopeo fallback | Reverse-scan cost |
| --- | --- | --- | --- | --- | --- |
| Docker Hub | 1. Public Hub tag API<br>2. Environment PAT retry after access denial<br>3. Skopeo fallback | 1. Public paginated Hub API<br>2. Environment PAT retry after access denial<br>3. Interactive PAT or Skopeo fallback | 1. Exchange an environment or interactive PAT for a short-lived Hub token after access denial | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial | Hub API: **fast**<br>Skopeo: one request per tag |
| GHCR | 1. Public native OCI manifest request<br>2. GitHub Packages API after access denial<br>3. Skopeo fallback | 1. Public native OCI tag sample may satisfy `any-durable`<br>2. GitHub Packages API<br>3. Public native OCI tag listing and parallel manifest `HEAD` requests<br>4. Skopeo fallback<br>5. Interactive credential refresh, public native OCI scan, or skip | 1. Use existing `gh` credentials for the Packages API<br>2. Refresh `gh` credentials interactively when selected | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial | Packages API: **fast**<br>Native OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |
| ACR | 1. Public ACR tag metadata API<br>2. Azure CLI metadata after access denial<br>3. Skopeo fallback | 1. Public ACR manifest metadata API<br>2. Azure CLI metadata after access denial<br>3. Skopeo fallback | 1. Query metadata through Azure CLI after access denial<br>2. Obtain a short-lived Azure token if Skopeo is denied | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived Azure token after access denial | Metadata API: **fast**<br>Skopeo: one request per tag |
| GCR | 1. Public GCR manifest map<br>2. Token-authenticated GCR manifest map after access denial<br>3. Skopeo fallback | 1. Public GCR manifest map<br>2. Token-authenticated GCR manifest map after access denial<br>3. Skopeo fallback | 1. Obtain a short-lived Google token after access denial<br>2. Reuse the token with the GCR manifest map | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived Google token after access denial | Manifest map: **fast**<br>Skopeo: one request per tag |
| GAR | 1. Public native OCI manifest request<br>2. Token-authenticated native OCI manifest request after access denial<br>3. Skopeo fallback | 1. Authenticated GAR DockerImage API when configured Google credentials are available<br>2. Public native OCI tag listing and parallel manifest `HEAD` requests<br>3. Authenticated GAR DockerImage API after access denial, if not already tried<br>4. Token-authenticated native OCI listing and parallel manifest `HEAD` requests<br>5. Skopeo fallback | 1. Probe an existing Google Cloud CLI token for the faster DockerImage API under `if-faster`<br>2. Obtain a short-lived Google token after access denial or under `require`<br>3. Reuse the token with the GAR API and native OCI paths | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived Google token after access denial | DockerImage API: **fast**<br>Native OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |
| Private ECR | 1. Signed ECR service API<br>2. Public native OCI manifest request if the service API is unavailable<br>3. Skopeo fallback | 1. Signed ECR service API<br>2. Public native OCI listing and parallel manifest `HEAD` requests if the service API is unavailable<br>3. Skopeo fallback | 1. Use AWS credentials with the signed service API<br>2. Obtain a short-lived AWS token if Skopeo is denied | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived AWS token after access denial | ECR API: **fast**<br>Native OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |
| ECR Public | 1. Public native OCI manifest request<br>2. Skopeo fallback | 1. Signed ECR Public API when AWS credentials are detectable<br>2. Public native OCI listing and parallel manifest `HEAD` requests<br>3. Skopeo fallback | 1. Use AWS credentials with the signed reverse-lookup API<br>2. Obtain a short-lived AWS token if Skopeo is denied | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial<br>4. Obtain a short-lived AWS token after access denial | ECR API: **fast**<br>Native OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |
| Other OCI | 1. Public native OCI manifest request<br>2. Skopeo fallback | 1. Public native OCI tag listing and parallel manifest `HEAD` requests<br>2. Skopeo fallback | Not applicable | 1. Reuse an in-session token, if present<br>2. Try isolated public access<br>3. Try configured registry credentials after access denial | Native OCI: one request per tag, parallel for `all`<br>Skopeo: one request per tag |

### Why each registry uses those paths

This matrix connects known registry operations to the choices above. The same
decision rule applies to every row: use a direct provider index when it is
available and materially cheaper; otherwise use native OCI for public access
and Skopeo for credential and compatibility fallbacks.

| Registry | Relevant operation characteristics | Direct path rationale | Reverse path rationale |
| --- | --- | --- | --- |
| Docker Hub | The Hub tag endpoint returns the digest for one exact tag. Paginated tag records also pair each tag with its digest, although deep anonymous pagination can require sign-in. | Use the Hub tag API because it answers `tag -> digest` directly; a manifest request would duplicate data already present in one tag record. | Use the paginated Hub tag API because every page can be filtered by digest without requesting each manifest. Retry the refused page with a PAT, or use Skopeo when the Hub API cannot complete. |
| GHCR | Public packages expose OCI Distribution endpoints. The GitHub Packages API exposes a package-version digest and all of its current tags together, but requires usable `gh` credentials with `read:packages`. | Use native OCI first because one public manifest request is the cheapest exact lookup and does not require GitHub credentials. Use the Packages API after public access is denied so private packages remain reachable. | Under `if-faster`, use the Packages API because its version objects avoid one manifest request per tag. A public native OCI sample can satisfy `any-durable`; a full native OCI scan remains the no-user-credential fallback, while Skopeo handles transport and credential compatibility. |
| ACR | ACR's artifact metadata endpoints accept either an exact tag or an exact manifest digest. The Azure CLI can query the corresponding metadata for authenticated registries. | Use tag metadata because it returns the digest directly and can distinguish absence without fetching a manifest. | Use manifest metadata because it returns the tags attached to the requested digest in one operation. Native OCI would replace that indexed lookup with tag listing plus per-tag manifest requests, so it provides no fast-path benefit. |
| GCR | GCR extends `tags/list` with a `manifest` object keyed by complete digest; each entry contains its current tags. This is richer than the standard OCI tags-list response. | Search the manifest map for exact tag membership and return its digest. One map request replaces a manifest request and already supports public access. | Index the same map by the requested digest and return its tags. Reuse the map with a Google token after denial; there is no reason to expand it into per-tag native OCI requests. |
| GAR | GAR supports standard OCI Distribution operations and accepts a short-lived Google token on those operations. Its authenticated Artifact Registry API also exposes a digest-addressed DockerImage resource containing the tags attached to that image. | Use one native OCI manifest request, anonymously when allowed and with a Google token after denial. The authenticated metadata API would not reduce this already constant-cost operation. | Under `if-faster`, use `dockerImages.get` when configured Google credentials are available because one indexed request replaces tag listing plus per-tag manifest requests. Public access remains native OCI. An API 404 is verified through OCI because remote or virtual repositories may resolve an upstream image absent from their own metadata index. |
| Private ECR | Signed `DescribeImages` accepts a tag or digest and returns image details containing both the digest and current tags. The registry endpoint is private, so a public OCI request will normally be denied. | Under `if-faster`, use signed `DescribeImages` because it is both authoritative and a single indexed lookup. The public native OCI attempt after service-API unavailability is best-effort policy/backend fallback; configured registry credentials or AWS-backed Skopeo are the realistic private-registry fallback. | Use signed `DescribeImages` because it directly implements `digest -> tags`. A native OCI scan is retained only as a best-effort fallback or when a public-first credential policy requires that ordering; it is not expected to outperform or usually access private ECR anonymously. |
| ECR Public | The Distribution endpoint is public. The ECR Public service API can return image details by digest, but it is signed and first requires resolving the repository alias to a registry ID. | Use one public native OCI manifest request because it avoids AWS credentials and alias discovery. The signed API offers no direct-lookup advantage large enough to justify those prerequisites. | When AWS credentials and an unambiguous alias are available, use the signed API because it returns the tags for a digest directly. Otherwise use public OCI tag listing plus manifest requests. |
| Other OCI | Only standard OCI Distribution behavior is assumed; there is no known provider index that pairs tags and digests. | Use one public native OCI manifest request, then Skopeo for private or incompatible registries. | List tags and request candidate manifests because that is the only portable reverse algorithm. Use Skopeo when the native client cannot complete the registry-specific exchange. |

Here, "public" means that no user credential is supplied (i.e. anonymous). An
OCI registry may still issue a repository-scoped bearer token for public
access, so "no user credentials" is more precise than "no authentication." A
rate limit or an authoritative not-found response is terminal; it must not
trigger a broader or credentialed fallback.

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

`any` stops at the first matching tag in provider order. A baseline tag whose
direct check matched satisfies the scan immediately, even when it is floating.

`any-durable` means the first matching tag heuristically classified as durable.
All matching floating tags encountered before that
durable tag are retained. A baseline tag whose direct check matched is seeded
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
