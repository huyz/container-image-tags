# Architecture

`container-image-tags` is organized as a pipeline with provider adapters. The
separation is intentionally explicit even where it adds lines: input inference,
registry policy, transport mechanics, result construction, and rendering have
different correctness constraints.

## Processing pipeline

Each positional argument passes through these stages:

1. `resolve_input_baselines` classifies the syntax and resolves a container,
   local image, remote tag, complete digest, or local repository wildcard.
2. A wildcard may expand into several local image baselines. Duplicate
   repository digests are removed before registry work.
3. `process_resolved_baseline` normalizes the repository and digest and creates
   one associative result record.
4. `check_baseline_remote_tag` verifies a known tag or records the remote tag
   resolution that established the baseline.
5. The selected provider adapter performs the reverse lookup, including its
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

| Status | Meaning | Broader fallback |
| --- | --- | --- |
| `LOOKUP_SUCCEEDED` | Complete usable result | No |
| `LOOKUP_NOT_FOUND` | Authoritative absence | No |
| `LOOKUP_UNAVAILABLE` | Backend could not answer | Yes |
| `LOOKUP_DENIED` | Intended authentication path may be tried | Provider-specific |
| `LOOKUP_STOPPED` | Terminal limit or refused expensive scan | No |

Provider modules own the interpretation of these statuses. `lib/registries.sh`
only classifies a repository and selects the matching adapter entry point.

## Provider policies

| Kind | Direct lookup | Reverse lookup | Fallback ownership |
| --- | --- | --- | --- |
| Docker Hub | Hub tags API | Hub paginated tags API | Docker Hub adapter chooses PAT or Skopeo |
| GHCR | Anonymous OCI, then Packages API | Packages API or anonymous OCI | GHCR adapter applies forced-method policy and prompts |
| ACR | ACR metadata API | ACR manifest metadata | ACR adapter chooses Azure CLI or Skopeo |
| GCR | GCR manifest map | GCR manifest map | GCR adapter chooses Google/Skopeo |
| GAR | Skopeo registry API | Skopeo tag scan | GAR adapter owns lazy Google authentication |
| ECR | ECR service API or registry API | ECR service API | ECR adapter chooses AWS/Skopeo behavior |
| Other OCI | Anonymous OCI manifest HEAD | OCI tags plus manifest HEAD | OCI adapter chooses Skopeo fallback |

Provider-specific response parsing and authentication remain in provider
modules. Generic request resources and diagnostic extraction live in
`lib/runtime.sh`.

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
