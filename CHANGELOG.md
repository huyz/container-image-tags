# Changelog

All notable changes to `container-image-tags` are documented in this file.

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
