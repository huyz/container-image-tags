# `container-image-tags` modules

The executable owns argument parsing, local-input orchestration, and output.
The sourced modules own these narrower responsibilities:

- `common.sh`: shared diagnostics and prompts
- `local-images.sh`: Docker image/reference resolution
- `skopeo.sh`: generic OCI fallback
- `docker-hub.sh`: Docker Hub API and authentication
- `ghcr.sh`: GitHub Packages and anonymous GHCR APIs
- `registries.sh`: registry classification and dispatch

To add a registry fast path, source its module before `registries.sh`, classify
its repository host in `registry_classify`, and add it to the direct-tag and
reverse-lookup dispatch functions. A direct tag lookup returns the digest on
stdout with status 0, status 1 when the tag does not exist, or status 2 when
the lookup fails. An exhaustive lookup populates `registry_tags` and may also
populate `registry_lookup_status` and `registry_metadata` for registry-specific
output.

Digest comparisons must always use the complete digest. A module may strip or
add the `sha256:` algorithm label at an API boundary, but it must not use
prefix matching.
