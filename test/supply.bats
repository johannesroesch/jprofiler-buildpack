#!/usr/bin/env bats
# Automated tests for bin/supply
#
# Run with:   bats test/supply.bats
# Requires:   bats-core  (https://github.com/bats-core/bats-core)
#
# These tests run entirely offline – no real JProfiler archive is downloaded.
# A fake archive is pre-staged in CACHE_DIR so the supply script skips the
# download path and proceeds to extraction.
#
# Checksum verification is disabled for fake archives by setting
# JPROFILER_TEST_SKIP_CHECKSUM=1 via a patched supply script.

BUILDPACK_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SUPPLY="${BUILDPACK_DIR}/bin/supply"

PATCHED_SUPPLY=""

# ── Fixtures ──────────────────────────────────────────────────────────────────

setup() {
    TEST_TMP="$(mktemp -d)"
    BUILD_DIR="${TEST_TMP}/app"
    CACHE_DIR="${TEST_TMP}/cache"
    DEPS_DIR="${TEST_TMP}/deps"
    mkdir -p "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}"
    export JPROFILER_TEST_SKIP_CHECKSUM=1
}

teardown() {
    rm -rf "${TEST_TMP}"
}

native_jprofiler_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)        echo "linux-x86" ;;
        aarch64|arm64) echo "linux-arm" ;;
        *)             echo "linux-x86" ;;
    esac
}

make_fake_archive() {
    local arch="${1:-$(native_jprofiler_arch)}"
    local version="${2:-16_2_1}"
    local archive_name="jprofiler_agent_${arch}_${version}.tar.gz"
    local src
    src="$(mktemp -d)"
    mkdir -p "${src}/jprofiler/bin/linux-x64"
    mkdir -p "${src}/jprofiler/bin/linux-arm"
    mkdir -p "${src}/jprofiler/bin/linux-armhf"
    echo "stub" > "${src}/jprofiler/bin/linux-x64/libjprofilerti.so"
    echo "stub" > "${src}/jprofiler/bin/linux-arm/libjprofilerti.so"
    echo "stub" > "${src}/jprofiler/bin/linux-armhf/libjprofilerti.so"
    tar -czf "${CACHE_DIR}/${archive_name}" -C "${src}" "jprofiler"
    rm -rf "${src}"
}

setup_patched_supply() {
    PATCHED_SUPPLY="${TEST_TMP}/supply_patched"
    # SC2016: single quotes intentional – ${EXPECTED_SHA} must not expand here
    # shellcheck disable=SC2016
    sed \
        's|if \[\[ -n "\${EXPECTED_SHA}" \]\]; then|if [[ -n "${EXPECTED_SHA}" \&\& -z "${JPROFILER_TEST_SKIP_CHECKSUM:-}" ]]; then|g' \
        "${SUPPLY}" > "${PATCHED_SUPPLY}"
    chmod +x "${PATCHED_SUPPLY}"
}

run_patched() {
    local deps_idx="${1:-0}"
    mkdir -p "${DEPS_DIR}/${deps_idx}"
    JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" \
            "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "${deps_idx}"
}

# ── Test 1: JPROFILER_ENABLED=false ──────────────────────────────────────────

@test "JPROFILER_ENABLED=false exits 0, writes config.yml, installs nothing else" {
    run env JPROFILER_ENABLED=false \
        bash "${SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"JPROFILER_ENABLED is false"* ]]
    [ ! -d "${DEPS_DIR}/0/jprofiler" ]
    [ -f "${DEPS_DIR}/0/config.yml" ]
    grep -q "name: jprofiler" "${DEPS_DIR}/0/config.yml"
}

# ── Test 2: JPROFILER_ENABLED=true ───────────────────────────────────────────

@test "JPROFILER_ENABLED=true installs agent and writes JBP_CONFIG_JAVA_OPTS" {
    setup_patched_supply
    make_fake_archive

    run env JPROFILER_ENABLED=true JPROFILER_PORT=8849 \
            JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -eq 0 ]
    [ -d "${DEPS_DIR}/0/jprofiler" ]
    [ -f "${DEPS_DIR}/0/env/JBP_CONFIG_JAVA_OPTS" ]
}

# ── Test 3: default port 8849 ─────────────────────────────────────────────────

@test "default port 8849 appears in JBP_CONFIG_JAVA_OPTS" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    grep -q "port=8849" "${DEPS_DIR}/0/env/JBP_CONFIG_JAVA_OPTS"
}

# ── Test 4: custom port ───────────────────────────────────────────────────────

@test "custom port appears in JBP_CONFIG_JAVA_OPTS" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_PORT=9999 JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    grep -q "port=9999" "${DEPS_DIR}/0/env/JBP_CONFIG_JAVA_OPTS"
}

# ── Test 5: existing JBP_CONFIG_JAVA_OPTS is preserved ───────────────────────

@test "existing JBP_CONFIG_JAVA_OPTS value is preserved" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_PORT=8849 \
        JBP_CONFIG_JAVA_OPTS="[java_opts: '-Xshare:off -XX:MaxDirectMemorySize=384M']" \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    local result
    result="$(cat "${DEPS_DIR}/0/env/JBP_CONFIG_JAVA_OPTS")"
    [[ "${result}" == *"-Xshare:off"* ]]
    [[ "${result}" == *"-agentpath:"* ]]
}

# ── Test 6: x86_64 architecture mapping ──────────────────────────────────────

@test "x86_64 maps to linux-x86 archive" {
    setup_patched_supply
    make_fake_archive "linux-x86"

    local stub_bin="${TEST_TMP}/stub-bin"
    mkdir -p "${stub_bin}"
    # SC2016: single-quoted string generates a literal bash script file
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nif [[ "${1}" == "-m" ]]; then echo "x86_64"; else command uname "$@"; fi\n' \
        > "${stub_bin}/uname"
    chmod +x "${stub_bin}/uname"

    run env PATH="${stub_bin}:${PATH}" JPROFILER_ENABLED=true \
            JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"x86_64"* ]]
}

# ── Test 7: aarch64 architecture mapping ─────────────────────────────────────

@test "aarch64 maps to linux-arm archive" {
    setup_patched_supply
    make_fake_archive "linux-arm"

    local stub_bin="${TEST_TMP}/stub-bin"
    mkdir -p "${stub_bin}"
    # SC2016: single-quoted string generates a literal bash script file
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nif [[ "${1}" == "-m" ]]; then echo "aarch64"; else command uname "$@"; fi\n' \
        > "${stub_bin}/uname"
    chmod +x "${stub_bin}/uname"

    run env PATH="${stub_bin}:${PATH}" JPROFILER_ENABLED=true \
            JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"aarch64"* ]]
}

# ── Test 8: unsupported architecture ─────────────────────────────────────────

@test "unsupported architecture exits non-zero with clear message" {
    local stub_bin="${TEST_TMP}/stub-bin"
    mkdir -p "${stub_bin}"
    # SC2016: single-quoted string generates a literal bash script file
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nif [[ "${1}" == "-m" ]]; then echo "s390x"; else command uname "$@"; fi\n' \
        > "${stub_bin}/uname"
    chmod +x "${stub_bin}/uname"

    run env PATH="${stub_bin}:${PATH}" JPROFILER_ENABLED=true \
        bash "${SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unsupported"* ]] || [[ "${output}" == *"unsupported"* ]]
}

# ── Test 9: invalid port ──────────────────────────────────────────────────────

@test "out-of-range JPROFILER_PORT exits non-zero" {
    run env JPROFILER_ENABLED=true JPROFILER_PORT=99999 \
        bash "${SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"JPROFILER_PORT"* ]]
}

@test "non-numeric JPROFILER_PORT exits non-zero" {
    run env JPROFILER_ENABLED=true JPROFILER_PORT=abc \
        bash "${SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"
    [ "${status}" -ne 0 ]
}

# ── Test 10: JPROFILER_OPTIONS ────────────────────────────────────────────────

@test "JPROFILER_OPTIONS are appended to the agent argument" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_OPTIONS="loglevel=info,samplingmode=cpu" \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    local result
    result="$(cat "${DEPS_DIR}/0/env/JBP_CONFIG_JAVA_OPTS")"
    [[ "${result}" == *"loglevel=info"* ]]
    [[ "${result}" == *"samplingmode=cpu"* ]]
}

# ── Test 11: DEPS_IDX=3 ───────────────────────────────────────────────────────

@test "DEPS_IDX=3 installs into deps/3 and writes env to deps/3/env/" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "3"

    [ -d "${DEPS_DIR}/3/jprofiler" ]
    [ -f "${DEPS_DIR}/3/env/JBP_CONFIG_JAVA_OPTS" ]
    grep -q "/home/vcap/deps/3/" "${DEPS_DIR}/3/env/JBP_CONFIG_JAVA_OPTS"
}

@test "DEPS_IDX=7 installs into deps/7 and writes env to deps/7/env/" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "7"

    [ -d "${DEPS_DIR}/7/jprofiler" ]
    [ -f "${DEPS_DIR}/7/env/JBP_CONFIG_JAVA_OPTS" ]
    grep -q "/home/vcap/deps/7/" "${DEPS_DIR}/7/env/JBP_CONFIG_JAVA_OPTS"
}

# ── Test 12: -agentpath verweist auf installierte Library ────────────────────

@test "agentpath in JBP_CONFIG_JAVA_OPTS references /home/vcap/deps/0/jprofiler/.../libjprofilerti.so" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    local result
    result="$(cat "${DEPS_DIR}/0/env/JBP_CONFIG_JAVA_OPTS")"
    [[ "${result}" == *"-agentpath:/home/vcap/deps/0/jprofiler"* ]]
    [[ "${result}" == *"libjprofilerti.so"* ]]
}
