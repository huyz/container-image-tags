# Changelog

All notable changes to `container-image-tags` are documented in this file.

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
