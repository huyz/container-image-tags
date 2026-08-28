#!/usr/bin/env bats

load ../test-helper.bash

function load_results {
    load_common
    # shellcheck source=../../lib/results.sh
    source "$REPO_ROOT/lib/results.sh"
}

@test "RESULT-001 canonical result renders JSON without lookup globals" {
    load_results
    local -A result=()
    result_init result
    result[input]='registry.example/app:latest'
    result[container]=
    result[image_id]=
    result[image_version]=
    result[image_revision]=
    result[image_refname]=
    result[local_tag]=latest
    result[repository]='registry.example/app'
    result[digest]='sha256:full'
    result[subject_source]=remote
    result[registry_kind]=other
    result[registry_host]='registry.example'
    result[remote_check_status]=resolved
    result[remote_check_reference]='registry.example/app:latest'
    result[remote_check_digest]='sha256:full'
    result[scan_mode]=any
    result[scan_status]=completed
    result[scan_backend]=oci-registry-api
    result[provider_metadata]=
    result[tags]=$'latest\n1.2.3'

    run result_to_json result
    assert_status 0
    assert_valid_json
    assert_json '.tag_scan.tags == ["latest", "1.2.3"] and .subject_source == "remote"'
}

@test "RESULT-002 scan context is copied into the canonical result" {
    load_results
    local -A result=() scan=()
    result_init result
    scan[result]=completed
    scan[backend]=gcr-api
    scan[metadata]='{"source":"provider"}'
    scan[tags]=$'stable\n2026-08-27'

    result_capture_scan result scan
    [[ "${result[scan_backend]}" == gcr-api ]]
    [[ "${result[provider_metadata]}" == '{"source":"provider"}' ]]
    [[ "${result[tags]}" == $'stable\n2026-08-27' ]]
}
