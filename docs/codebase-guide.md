# Codebase reading and verification guide

This guide is for a developer who wants to understand the design, find the
relevant code quickly, and gather evidence that a change or behavior is
correct. It is a navigation guide, not a second architecture specification.
Use it with the [architecture reference](architecture.md), which defines the
registry attempt order and internal contracts, and the [test plan](test-plan.md),
which defines the intended behavioral coverage.

## A useful mental model

The program answers two different questions:

1. **Direct lookup:** what repository digest does a known tag currently name?
2. **Reverse lookup:** which current tags name a known repository digest?

Each input moves through the same high-level pipeline:

```text
CLI input
  -> input inference and local Docker resolution
  -> normalized repository digest
  -> registry classification
  -> direct tag check, when applicable
  -> reverse tag scan, when requested
  -> canonical result record
  -> human or JSON rendering
```

The important design boundary is inside registry work. Provider modules do not
choose their own fallback paths. Each provider declares atomic attempts; the
central policy engine decides which attempts are allowed, their order, and
which outcomes may fall back. This keeps credential policy, cost, and terminal
outcomes consistent across providers.

The other important boundary is the canonical result record. Human and JSON
output consume the same record, so rendering does not independently reinterpret
provider state.

## A first reading pass

For a focused first pass, read these in order:

1. Read the README sections **How it works**, **Choose how much to search**,
   **Why lookups can be fast**, and **Authentication**. These describe the
   public behavior and vocabulary.
2. Read the top of `container-image-tags`, then `initialize_runtime`, the option
   defaults, and the final input loop. This shows dependencies, module loading,
   CLI defaults, and the small amount of orchestration kept in the executable.
3. Read `lib/pipeline.sh` from `process_input` backward through
   `resolve_input_subjects`, then forward through `process_resolved_subject`.
   This is the easiest way to see one input's complete lifecycle.
4. Read `lib/registries.sh` and `lib/policy-engine.sh` together. Follow one
   direct request and one reverse request from request construction through
   attempt selection and result copying.
5. Read one provider's `*_register_policy_attempts` function before reading its
   transport callbacks. Docker Hub is a useful metadata-API example; generic
   OCI is a useful per-tag scan example.
6. Read `lib/scan-policy.sh`, `lib/scheduler.sh`, and `lib/results.sh` to connect
   bounded scans, concurrency, completion, and output.
7. Read the corresponding Bats tests alongside each module. The test names are
   concise statements of the expected contract.

This pass gives the design before the HTTP and cloud-CLI details. The full
provider attempt order is easier to understand in the architecture reference's
registry matrix than by jumping between adapter callbacks.

## Where the code sits

| Area | Primary files | What to look for |
| --- | --- | --- |
| Executable and CLI | `container-image-tags` | Dependency discovery, module source order, option validation and defaults, final multi-input loop |
| Input inference | `lib/pipeline.sh`, `lib/local-images.sh` | Syntax precedence, local-versus-remote resolution, wildcard expansion, exact repository-digest recovery |
| Pipeline orchestration | `lib/pipeline.sh` | Direct check before reverse scan, per-input dynamic scope, canonical result population |
| Registry dispatch | `lib/registries.sh` | Repository classification, normalized policy requests, provider registration dispatch |
| Registry-independent policy | `lib/policy-engine.sh` | Credential eligibility, cost ordering, authoritative absence, fallback, terminal outcomes, adaptive attempts |
| Scan semantics | `lib/scan-policy.sh` | `any`, `any-durable`, `all`, durability heuristic, explicit completion states |
| Concurrent per-tag work | `lib/scheduler.sh`, `lib/oci.sh`, `lib/skopeo.sh` | Eight-worker bound, early stop, deterministic result order, complete-result requirements |
| Expensive-work guard | `lib/cost-policy.sh` | Duration estimates, interactive warning, non-interactive refusal |
| Runtime and transport | `lib/runtime.sh` | Private temporary directory, child tracking, deadlines, HTTP response capture, bounded diagnostics |
| Canonical output | `lib/results.sh` | Result fields, human renderer, JSON renderer, provider metadata |
| Generic registry mechanisms | `lib/oci.sh`, `lib/skopeo.sh` | Anonymous OCI requests, bearer challenges, tag pagination, manifest inspection, credential-context isolation |
| Provider adapters | `lib/docker-hub.sh`, `lib/ghcr.sh`, `lib/acr.sh`, `lib/gcr.sh`, `lib/gar.sh`, `lib/ecr.sh` | Response validation, provider authentication, atomic policy callbacks and declarations |
| Shared Google authentication | `lib/google-auth.sh` | Short-lived token acquisition and Skopeo login handling for GCR/GAR |
| Shared contracts | `lib/common.sh` | Lookup statuses, diagnostic channels, interactive-session definition |
| Test harness | `tests/test-helper.bash`, `tests/helpers/` | Isolated home/config directories, fake tools, exact argv and output assertions |
| Behavioral evidence | `tests/unit/`, `tests/integration/`, `tests/security/`, `tests/stress/`, `tests/live/` | Focused module contracts through optional real-service validation |
| CI evidence | `.github/workflows/test.yml`, `.github/workflows/stress.yml` | Linux, macOS, Bash 4.4, static, offline, and scheduled concurrency coverage |

## Trace one request through the code

Start at the executable's loop, which calls `process_input` once for each
argument.

### 1. Resolve the subject

`process_input` gives each input its own dynamically scoped state and calls
`resolve_input_subjects`. Resolution deliberately has an explicit precedence:
complete digest reference, SHA-like local identity, tagged or wildcard image
reference, local container name, then untagged repository. Local inspection is
in `lib/local-images.sh`; remote tag resolution already goes through the common
registry policy path.

A wildcard can produce several local images. Before registry work, duplicate
repository digests are removed so identical subjects are checked once.

### 2. Build a canonical subject result

`process_resolved_subject` normalizes the resolved repository and digest,
classifies the registry, initializes a result record, and captures the subject
fields. The result record—not transport globals—is the rendering boundary.

### 3. Check the known tag

`check_subject_remote_tag` calls `registry_resolve_tag_digest` for locally
resolved tags. It records `match`, `mismatch`, or `not_found`. A tag that was
itself resolved remotely is recorded as `resolved` without repeating the same
lookup.

### 4. Find tags for the digest

When scanning is requested, `registry_find_tags_by_digest` builds a reverse
request containing the digest, scan mode, known tag, and whether that tag was
confirmed. It asks the selected provider to register attempts and passes the
plan to `policy_build_and_execute_lookup`.

The policy engine repeatedly chooses the cheapest currently permitted attempt.
The five public lookup outcomes are the key control-flow contract:

| Outcome | Meaning for the plan |
| --- | --- |
| `LOOKUP_SUCCEEDED` | Validate and return the mechanism's result |
| `LOOKUP_NOT_FOUND` | Stop if authoritative; otherwise try another mechanism |
| `LOOKUP_UNAVAILABLE` | Try another permitted mechanism; do not unlock credentials |
| `LOOKUP_DENIED` | Record denial and make conditionally permitted credential attempts eligible |
| `LOOKUP_STOPPED` | Stop immediately; do not choose a more request-intensive fallback |

For a concrete provider trace, begin at its `*_register_policy_attempts`
function. Each `policy_add_attempt` line states the callback, reported backend,
access class, relative cost, authority, and optional lazy availability check.
Only then open the selected callback to inspect its request and response
handling.

### 5. Preserve scan meaning

Metadata APIs can return all tag/digest pairs at once and use
`select_matching_tags_for_scan`. OCI and Skopeo scans inspect tag manifests
incrementally and use the shared rolling scheduler. Both paths must implement
the same scan contract:

- `any` stops at the first match;
- `any-durable` retains matches through the first tag classified as durable;
- `all` requires a complete scan and must reject partial results.

The completion field is separate from lookup status. It distinguishes all
candidates checked, first match, durable match, and a completed bounded scan
whose goal was exhausted. Do not infer completeness from `status` or a
non-empty tag list alone.

### 6. Render once

The completed lookup context is copied into the canonical record by
`result_capture_scan`. `render_scan_human` and `result_to_json` then consume
that record. When changing an externally visible field, inspect both renderers
and their integration tests together.

## State and ownership boundaries

This is Bash, so understanding state ownership makes review much easier:

- `process_input` owns the transient subject variables for one CLI argument.
  Bash dynamic scope lets resolution helpers populate them without making them
  process-wide state.
- `policy_build_and_execute_lookup` owns the attempt tables for one lookup.
  Provider registration cannot leak a plan into a later request.
- Registry callers pass named associative request and result contexts. These
  are the protocol between dispatch, policy, and pipeline layers.
- Some transport helpers still use dynamically scoped `registry_*` variables
  for compatibility. `policy_execute_lookup` bounds those variables to a
  single execution.
- `lib/runtime.sh` owns temporary resources and child processes. Its exit trap
  is the final cleanup safety net; sensitive files should still be removed as
  soon as their mechanism is finished.

When reviewing a change, ask whether state lives at the narrowest one of these
boundaries and whether a later input or fallback attempt could observe stale
values.

## Build confidence in correctness

Confidence comes from several kinds of evidence, not from the full test command
alone.

### Start with the invariant

Before checking an implementation, state the invariant it must preserve. The
highest-value invariants in this repository are:

- repository digests are complete and compared exactly;
- provider responses are validated before fields are trusted;
- result order is deterministic even when worker completion order is not;
- bounded scans report why they stopped, while `all` never accepts partial
  success;
- `LOOKUP_UNAVAILABLE` may change mechanisms but never authorizes credentials;
- `LOOKUP_STOPPED` is terminal;
- anonymous/public access precedes credentials where the selected credential
  policy requires it;
- credentials do not appear in argv, output, diagnostics, or world-readable
  files;
- human output, JSON, and exit status describe the same outcome;
- per-input, per-lookup, temporary-file, and child-process state is cleaned up.

The test plan's **Quality invariants** section is the longer authoritative list.

### Use the narrowest useful evidence

Run a focused test file while reading or editing one boundary:

```sh
bats tests/unit/policy-engine.bats
bats tests/unit/registries.bats
bats tests/integration/input-resolution.bats
bats tests/integration/output.bats
```

Run one named contract when the file is large:

```sh
bats --filter 'POLICY-ENGINE-002' tests/unit/policy-engine.bats
bats --filter 'JSON-012' tests/integration/output.bats
```

List the implemented test contracts without reading every test body:

```sh
rg -n '^@test ' tests
```

Tests source modules individually when that gives a precise unit boundary and
invoke the real executable for end-to-end behavior. The harness gives every
test an isolated `HOME`, Docker config, and fake executable directory; ordinary
offline tests do not use the user's Docker daemon, cloud configuration,
credentials, or the network.

### Escalate validation with risk

Use this ladder after the focused check:

```sh
tests/run static       # Bash parsing, ShellCheck, and trailing whitespace
tests/run unit         # Shared contracts, dispatch, policy, and adapters
tests/run integration  # Real CLI with isolated fake dependencies
tests/run security     # Credential transport, permissions, cleanup, diagnostics
tests/run stress       # Repeated scheduling, ordering, early-stop, failure cases
tests/run              # All required offline unit, integration, and security tests
```

Suggested minimums:

| Change | Focused evidence | Broader evidence |
| --- | --- | --- |
| Documentation only | Link and command inspection | `tests/run static` |
| Input or CLI behavior | Matching integration file | `tests/run static`, `tests/run integration` |
| Provider parser or request | Matching provider unit file | `tests/run static`, `tests/run unit` |
| Policy or fallback | Policy and dispatch unit files | `tests/run static`, `tests/run unit`, `tests/run integration` |
| Scan or concurrency | Common/OCI/Skopeo unit files | `tests/run static`, `tests/run unit`, `tests/run stress` |
| Credentials or cleanup | Matching adapter plus security test | `tests/run static`, `tests/run unit`, `tests/run security` |
| Output schema or status | Results unit and output integration files | `tests/run static`, `tests/run` |

The required offline suite is run in CI on Linux, macOS, and Bash 4.4. Static
checks are a separate CI job, and concurrency stress tests have a scheduled and
manual workflow.

### Treat live checks as a separate evidence class

Offline fixtures prove the program's behavior for exact modeled requests and
responses. They do not prove that a registry's current undocumented behavior,
authentication service, rate limits, or latency have not changed.

Live tests are opt-in and never part of the ordinary suite. The current generic
OCI canary requires a public tagged reference and its independently known
complete digest:

```sh
CIT_LIVE_TESTS=1 \
CIT_LIVE_GENERIC_OCI_REF=registry.example/repository:tag \
CIT_LIVE_GENERIC_OCI_DIGEST=sha256:<64-lowercase-hex-characters> \
tests/run live
```

Read `tests/live/public-registries.bats` before using it. The canary forces
anonymous access, disables Skopeo, performs a complete scan, and verifies the
digest, backend, completion, and expected tag. Use a target whose expected
digest was obtained independently; otherwise the check can only confirm
self-consistency.

## Fast spot checks by concern

### Did input precedence or multi-input isolation change?

Read `resolve_input_subjects` and `process_input`, then run:

```sh
bats tests/integration/input-resolution.bats
```

Pay special attention to complete versus abbreviated digests, registry ports,
local container-versus-image precedence, wildcard deduplication, and state
reset between positional arguments.

### Did registry classification or provider dispatch change?

Read `registry_classify`, `registry_register_policy_attempts`, and the affected
provider registration function, then run:

```sh
bats tests/unit/registries.bats
```

Quickly display every policy declaration with:

```sh
rg -n 'register_policy_attempts|policy_add_attempt' lib/*.sh
```

Compare the result with the architecture reference's registry access matrix.

### Did authentication eligibility or fallback change?

Read `policy_attempt_is_permitted`, `policy_select_attempt`, and
`policy_execute_lookup`, then run:

```sh
bats tests/unit/policy-engine.bats
bats tests/unit/registries.bats
```

Check the attempt order under all four credential policies. Keep three ideas
separate: a mechanism is unavailable, a mechanism denied access, and a lookup
was stopped by a terminal limit.

### Did tag selection or completeness change?

Read `select_matching_tags_for_scan`, `capture_tag_scan_result`, and
`tags_by_digest_with_rolling_pool`, then run:

```sh
bats tests/unit/common.bats
bats tests/integration/output.bats
```

Inspect `any`, `any-durable`, and `all` separately. A particularly valuable
case is a completed `any-durable` scan that finds floating matches but no
durable one: it is exhausted, not a lookup failure.

### Did concurrent scanning change?

Read `lib/scheduler.sh` plus the OCI and Skopeo caller, then run:

```sh
bats tests/unit/oci.bats
bats tests/unit/skopeo.bats
tests/run stress
```

Look for the worker cap, candidate-order reconstruction, stopping of new work,
terminal-status propagation, vanished-tag handling, and cleanup after worker
death. For exhaustive OCI scans, also inspect the native curl-parallel path;
bounded scans use the rolling pool so they can stop scheduling early.

### Did output change?

Read all of `lib/results.sh` and the point where `lib/pipeline.sh` captures scan
state, then run:

```sh
bats tests/unit/results.bats
bats tests/integration/output.bats
```

Check that diagnostics remain on stderr and JSON remains one array on stdout.
Verify `status`, `completion`, `backend`, `provider_metadata`, and ordered
`tags` as independent fields.

### Did secret handling, temporary files, or cancellation change?

Read `lib/runtime.sh`, the provider's authentication helper, and any Skopeo
authfile code, then run:

```sh
tests/run security
bats tests/unit/runtime.bats
```

Search for tokens being passed as command arguments, missing mode checks,
temporary files created outside the runtime directory, and children not
registered for cleanup.

### Did one provider change?

Read in this order:

1. the provider's `*_register_policy_attempts` function;
2. the declared callback and availability functions;
3. its response validation and normalization;
4. the matching provider unit file;
5. cross-provider dispatch tests in `tests/unit/registries.bats`;
6. the provider column in the architecture matrix.

The provider test mapping is mostly direct: `docker-hub.sh` to
`docker-hub.bats`, `ghcr.sh` to `ghcr.bats`, `acr.sh` to `acr.bats`, GCR/GAR to
`gcr-gar.bats`, and ECR/ECR Public to `ecr.bats`. Generic OCI and Skopeo each
have their own unit file.

## How to review a change

For a quick review:

1. Identify the public behavior and the invariant that could regress.
2. Trace the request from the nearest public entry point to the narrowest
   mechanism changed.
3. Check that policy remains in the policy engine and provider mechanics remain
   in the adapter.
4. Check complete digest equality and validate every external response before
   use.
5. Follow every nonzero status to confirm whether it terminates, falls back, or
   unlocks credentials.
6. Follow the lookup context into the canonical result and both renderers when
   visible behavior changes.
7. Read the existing test with the closest contract ID; add or adjust the
   smallest reproducer rather than broad snapshots.
8. Run the focused test, static checks, and the broader suite appropriate to
   the risk table above.
9. State separately what was proven offline, exercised under stress, and
   verified against a live service.

## Limits of the evidence

- The test plan includes both implemented tests and planned cases. A row in the
  plan is not proof of coverage; an implemented ID appears in an `@test` name,
  except for the static checks implemented directly by `tests/run static`.
- The durability classification is a documented heuristic, not a registry
  guarantee that a tag will never move.
- Passing provider fixtures proves handling of those modeled responses, not the
  present behavior of an external registry.
- Benchmarks are directional and network-dependent. Read
  [the benchmark notes](benchmarks.md) before treating them as performance
  evidence.
- `--debug` helps identify the selected policy attempt, but a manual CLI run may
  access the network or configured credentials according to its options. Use
  isolated offline tests for routine spot checks.
