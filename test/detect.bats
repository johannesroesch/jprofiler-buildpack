#!/usr/bin/env bats
# Tests for bin/detect

BUILDPACK_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
DETECT="${BUILDPACK_DIR}/bin/detect"

@test "detect outputs 'JProfiler'" {
    run bash "${DETECT}"
    [ "$status" -eq 0 ]
    [ "$output" = "JProfiler" ]
}

@test "detect exits 0" {
    run bash "${DETECT}"
    [ "$status" -eq 0 ]
}
