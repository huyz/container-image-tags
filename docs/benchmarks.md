# Benchmarks

## OCI scan engine comparison

On 2026-08-27, the two exhaustive OCI scan implementations were compared
against Codeberg's public Forgejo repository:

- Repository: `codeberg.org/forgejo/forgejo`
- Baseline: `11.0.16`
- Immutable digest: `sha256:946243edbab116d5bb78b73ea68af6f3d69229ba1b1ed958dd82c3481167f3e0`
- Scan: `--tag-resolution=remote --tag-scan=all --json`
- Two timed runs per implementation
- Skopeo fallback disabled so both measurements exercised the OCI path

The baseline digest was held constant for every run. Both implementations
completed through the `oci-registry-api` backend and returned the same matching
tags: `11`, `11.0`, and `11.0.16`.

| Implementation | Run 1 | Run 2 | Average |
| --- | ---: | ---: | ---: |
| Curl native parallel transfers | 22.04s | 21.79s | **21.91s** |
| Rolling worker pool | 41.86s | 42.74s | **42.30s** |

Curl's parallel engine was 1.93x faster, saving about 20.4 seconds per scan
(48.2% lower wall-clock time). The result supports automatic selection of curl
parallel transfers for exhaustive scans when the installed curl supports them,
with the rolling pool retained as the compatibility fallback. `any` scans
continue to use the pool because they can stop scheduling after a match
of durable tag.

These measurements are network-dependent and are intended as directional
evidence rather than a performance guarantee for every OCI registry.
