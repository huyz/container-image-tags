# Changelog

All notable changes to `container-image-tags` are documented in this file.

## v0.3.0 — 2026-09-07

### Added

- Explicit scan-completion results in human and JSON output, distinguishing a
  complete scan, first match, durable match, and exhausted bounded search.
- Stronger policy-attempt contracts, runtime process-tree cleanup, live OCI
  validation, and regression coverage for incomplete or malformed responses.

### Changed

- Scoped registry lookup and input-resolution state to individual requests and
  snapshots local Docker image metadata with one inspection.
- Consolidated Google authentication, delayed Skopeo session setup until an
  eligible attempt needs it, and separated fast reusable sessions from
  denial-gated credential fallbacks.
- Improved startup dependency diagnostics, option errors, installation
  guidance, test-plan status, and benchmark provenance.

### Fixed

- Prevented incomplete Skopeo scans and bounded scans without a durable match
  from being reported as successful goal completion.
- Rejected malformed Docker Hub tag responses and cross-repository pagination,
  and preserved interrupted GHCR pagination as non-authoritative.
- Prevented stale cross-input state, renderer dependence on lookup globals,
  orphaned worker descendants, and unset AWS command failures.

## v0.2.0 — 2026-09-01

### Added

- Anonymous native OCI fallbacks for Docker Hub, ACR, and GCR, including
  repository-scoped Docker Hub token exchange through `registry-1.docker.io`.
- Anonymous indexed `dockerImages.get` lookup for public GAR repositories, with
  a Google-token retry only when public access is denied.

### Changed

- Made access denial mechanism-specific so one public backend no longer
  suppresses other eligible public mechanisms.
- Made `if-required` exhaust applicable public mechanisms before using an
  unlocked credentialed path; `if-faster` can still prefer a cheaper indexed
  credentialed path to a public bulk scan.
- Removed the redundant interactive GHCR anonymous-scan choice after automatic
  anonymous OCI lookup has already run.
- Reworked the registry architecture matrix and authentication documentation
  around explicit attempt order, backend capabilities, and fallback behavior.

## v0.1.1 — 2026-08-31

### Changed

- Broadened durable-tag detection, mainly so commit-like hexadecimal and
  date-like sequences may appear anywhere in a tag.

## v0.1.0 — 2026-08-28

### Added

- Inaugural release of `container-image-tags`, resolving local containers,
  images, remote tags, and repository digests to current registry tags.
- Registry-specific metadata paths for Docker Hub, GHCR, ACR, GCR, GAR, private
  ECR, and ECR Public, plus generic OCI and Skopeo fallback mechanisms.
- Configurable tag-scan breadth and credential policy, including bounded
  durable-tag scans, cost guards, structured JSON output, and interactive
  recovery where appropriate.
- Offline unit, integration, security, and stress suites covering registry
  adapters, policy decisions, concurrency, credential handling, and cleanup.
