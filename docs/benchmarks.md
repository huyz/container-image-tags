# Benchmarks

## OCI scan engine comparison

On 2026-08-27, the two exhaustive OCI scan implementations were compared
against Codeberg's public Forgejo repository:

- Code snapshot: `37a207de3b1b016c502b209d09fefb8c6d24b640`
- Temporary selector: `CIT_OCI_SCAN_ENGINE=parallel|pool` (removed by
  `f1f3cf7ed54b64fa6a076f59ddc11e5772218873` after this comparison)
- Repository: `codeberg.org/forgejo/forgejo`
- Selected tag: `11.0.16`
- Immutable digest: `sha256:946243edbab116d5bb78b73ea68af6f3d69229ba1b1ed958dd82c3481167f3e0`
- Scan: `--tag-resolution=remote --tag-scan=all --json`
- Two timed runs per implementation
- Skopeo fallback disabled so both measurements exercised the OCI path

The original run did not record the host specification, tool versions, network
location, or candidate-tag count. Those omissions limit exact reproduction and
should be treated as part of the uncertainty in the figures below.

The historical code can still be rerun with the same engine selector and
immutable input. From a clean checkout of the recorded snapshot, use each
engine twice:

```sh
for engine in parallel pool; do
  for run in 1 2; do
    printf 'engine=%s run=%s\n' "$engine" "$run"
    /usr/bin/time -p env CIT_OCI_SCAN_ENGINE="$engine" \
      SKOPEO=/nonexistent/container-image-tags-skopeo \
      ./container-image-tags --tag-resolution=remote --tag-scan=all \
      --allow-expensive-scan --json \
      codeberg.org/forgejo/forgejo@sha256:946243edbab116d5bb78b73ea68af6f3d69229ba1b1ed958dd82c3481167f3e0
  done
done
```

For a new comparison, record the checked-out commit, UTC timestamp, host and
network location, candidate count, and the output of `uname -a`,
`bash --version`, `curl --version`, and `jq --version`. Save each JSON result
and confirm identical tags and the `oci-registry-api` backend before comparing
wall-clock time. Run the implementations in alternating order to reduce cache
and transient-network bias; two samples remain exploratory rather than
statistically strong evidence.

The resolved repository digest was held constant for every run. Both implementations
completed through the `oci-registry-api` backend and returned the same matching
tags: `11`, `11.0`, and `11.0.16`.

| Implementation | Run 1 | Run 2 | Average |
| --- | ---: | ---: | ---: |
| Curl native parallel transfers | 22.04s | 21.79s | **21.91s** |
| Rolling worker pool | 41.86s | 42.74s | **42.30s** |

Curl's parallel engine was 1.93x faster, saving about 20.4 seconds per scan
(48.2% lower wall-clock time). The result supports automatic selection of curl
parallel transfers for exhaustive scans when the installed curl supports them,
with the rolling pool retained as the compatibility fallback. `any` and
`any-durable` scans continue to use the pool because they can stop scheduling
after the requested match.

These measurements are network-dependent and are intended as directional
evidence rather than a performance guarantee for every OCI registry.
