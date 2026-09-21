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
# JPROFILER_TEST_SKIP_CHECKSUM=1 in setup() and patching the supply script.

BUILDPACK_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SUPPLY="${BUILDPACK_DIR}/bin/supply"

PATCHED_SUPPLY=""   # set per-test by setup_patched_supply

# ── Fixtures ─────────────────────────────────────────────────────────────────

setup() {
    TEST_TMP="$(mktemp -d)"
    BUILD_DIR="${TEST_TMP}/app"
    CACHE_DIR="${TEST_TMP}/cache"
    DEPS_DIR="${TEST_TMP}/deps"
    mkdir -p "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}"

    # Skip checksum verification for all fake-archive tests
    export JPROFILER_TEST_SKIP_CHECKSUM=1
}

teardown() {
    rm -rf "${TEST_TMP}"
}

# Determine which arch the native supply script would choose.
native_jprofiler_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)         echo "linux-x86" ;;
        aarch64|arm64)  echo "linux-arm" ;;
        *)              echo "linux-x86" ;;
    esac
}

# Create a fake cached archive that mimics the real JProfiler tarball layout.
# Stubs for all native-lib sub-dirs are included so find … libjprofilerti.so
# always succeeds regardless of which sub-path the real build uses.
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

# Patch the supply script so that when JPROFILER_TEST_SKIP_CHECKSUM=1 is set
# the embedded-SHA check is bypassed (fake archives do not match real sums).
setup_patched_supply() {
    PATCHED_SUPPLY="${TEST_TMP}/supply_patched"
    # SC2016: single quotes are intentional – ${EXPECTED_SHA} must not expand here.
    # shellcheck disable=SC2016
    sed \
        's|if \[\[ -n "\${EXPECTED_SHA}" \]\]; then|if [[ -n "${EXPECTED_SHA}" \&\& -z "${JPROFILER_TEST_SKIP_CHECKSUM:-}" ]]; then|g' \
        "${SUPPLY}" > "${PATCHED_SUPPLY}"
    chmod +x "${PATCHED_SUPPLY}"
}

# Read the staging-baked agent lib path out of the generated profile.d script.
agent_runtime_path() {
    grep '_JPROFILER_AGENT_LIB=' "${BUILD_DIR}/.profile.d/000_jprofiler.sh" \
        | head -1 \
        | sed 's/.*_JPROFILER_AGENT_LIB="\(.*\)"/\1/'
}

# Create a stub .so and patch the profile.d script to point at it.
# We cannot create /home/vcap/... on the host, so we redirect the baked-in
# path to a writable temp location and update the script in-place.
stub_agent_lib() {
    local runtime_path
    runtime_path="$(agent_runtime_path)"

    # Create stub in TEST_TMP (always writable)
    local stub_dir stub_lib
    # SC2155: declare and assign separately
    stub_dir="${TEST_TMP}/stub-deps$(dirname "${runtime_path}")"
    mkdir -p "${stub_dir}"
    stub_lib="${stub_dir}/$(basename "${runtime_path}")"
    echo "stub" > "${stub_lib}"

    # Rewrite the _JPROFILER_AGENT_LIB line in the profile.d script to point
    # at the local stub so the file-existence check passes.
    local profile_script
    profile_script="${BUILD_DIR}/.profile.d/000_jprofiler.sh"
    sed -i.bak \
        "s|_JPROFILER_AGENT_LIB=\"${runtime_path}\"|_JPROFILER_AGENT_LIB=\"${stub_lib}\"|" \
        "${profile_script}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1 – JPROFILER_ENABLED=false: no-op, successful exit
# ─────────────────────────────────────────────────────────────────────────────
@test "JPROFILER_ENABLED=false exits 0 and installs nothing" {
    # No patching needed – the no-op path exits before any archive is touched.
    run env JPROFILER_ENABLED=false \
        bash "${SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"JPROFILER_ENABLED is false"* ]] || \
        [[ "${output}" == *"skipping"* ]] || \
        [[ "${output}" == *"no-op"* ]]
    [ ! -d "${DEPS_DIR}/0/jprofiler" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2 – JPROFILER_ENABLED=true: full installation
# ─────────────────────────────────────────────────────────────────────────────
@test "JPROFILER_ENABLED=true installs agent and creates profile.d script" {
    setup_patched_supply
    make_fake_archive

    run env JPROFILER_ENABLED=true JPROFILER_PORT=8849 \
            JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -eq 0 ]
    [ -f "${BUILD_DIR}/.profile.d/000_jprofiler.sh" ]
    [ -d "${DEPS_DIR}/0/jprofiler" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3 – default port 8849
# ─────────────────────────────────────────────────────────────────────────────
@test "default port 8849 is baked into profile.d script" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    grep -q '_JPROFILER_DEFAULT_PORT="8849"' \
        "${BUILD_DIR}/.profile.d/000_jprofiler.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4 – custom port
# ─────────────────────────────────────────────────────────────────────────────
@test "custom port is baked into profile.d script" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_PORT=9999 \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    grep -q '_JPROFILER_DEFAULT_PORT="9999"' \
        "${BUILD_DIR}/.profile.d/000_jprofiler.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5 – preservation of existing JAVA_TOOL_OPTIONS
# ─────────────────────────────────────────────────────────────────────────────
@test "profile.d script appends to existing JAVA_TOOL_OPTIONS" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_PORT=8849 \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    stub_agent_lib

    local profile_script="${BUILD_DIR}/.profile.d/000_jprofiler.sh"

    # Set variables explicitly in the current shell scope before sourcing.
    # Using VAR=val source is insufficient because bash's temp-assignment for
    # builtins does not persist the exported value back to the outer scope.
    # SC2030: bats runs tests in subshells; these assignments are intentionally
    # local to the test scope.
    # shellcheck disable=SC2030
    export JPROFILER_ENABLED=true
    # shellcheck disable=SC2030
    export JPROFILER_PORT=8849
    # shellcheck disable=SC2030
    export JPROFILER_NOWAIT=true
    # shellcheck disable=SC2030
    export JAVA_TOOL_OPTIONS="-Xshare:off -XX:MaxDirectMemorySize=384M"
    # shellcheck disable=SC1090
    source "${profile_script}"

    # SC2031: JAVA_TOOL_OPTIONS was set in this subshell and is visible here.
    # shellcheck disable=SC2031
    [[ "${JAVA_TOOL_OPTIONS}" == *"-Xshare:off"* ]]
    # shellcheck disable=SC2031
    [[ "${JAVA_TOOL_OPTIONS}" == *"-agentpath:"* ]]

    unset JPROFILER_ENABLED JPROFILER_PORT JPROFILER_NOWAIT JAVA_TOOL_OPTIONS
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6 – x86_64 architecture mapping
# ─────────────────────────────────────────────────────────────────────────────
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

    run env PATH="${stub_bin}:${PATH}" \
            JPROFILER_ENABLED=true \
            JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"x86_64"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7 – aarch64 architecture mapping
# ─────────────────────────────────────────────────────────────────────────────
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

    run env PATH="${stub_bin}:${PATH}" \
            JPROFILER_ENABLED=true \
            JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"aarch64"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 8 – unsupported architecture
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# Test 9 – invalid JPROFILER_PORT
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# Test 10 – JPROFILER_OPTIONS appear in JAVA_TOOL_OPTIONS at runtime
# ─────────────────────────────────────────────────────────────────────────────
@test "JPROFILER_OPTIONS are appended to the agent argument at runtime" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_OPTIONS="loglevel=info,samplingmode=cpu" \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    stub_agent_lib

    local profile_script="${BUILD_DIR}/.profile.d/000_jprofiler.sh"
    # Set variables explicitly in the current shell scope (see test 5 for why).
    # SC2030/SC2031: bats runs each test in a subshell; these are intentional
    # local assignments visible within the same subshell.
    # shellcheck disable=SC2030,SC2031
    export JPROFILER_ENABLED=true JPROFILER_PORT=8849 JPROFILER_NOWAIT=true \
        JPROFILER_OPTIONS="loglevel=info,samplingmode=cpu"
    unset JAVA_TOOL_OPTIONS
    # shellcheck disable=SC1090
    source "${profile_script}"

    # shellcheck disable=SC2031
    [[ "${JAVA_TOOL_OPTIONS}" == *"loglevel=info"* ]]
    # shellcheck disable=SC2031
    [[ "${JAVA_TOOL_OPTIONS}" == *"samplingmode=cpu"* ]]

    unset JPROFILER_ENABLED JPROFILER_PORT JPROFILER_NOWAIT JPROFILER_OPTIONS JAVA_TOOL_OPTIONS
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 11 – arbitrary DEPS_IDX: DEPS_IDX=3
# ─────────────────────────────────────────────────────────────────────────────
@test "DEPS_IDX=3 installs into deps/3 and bakes /home/vcap/deps/3/ into profile.d" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true JPROFILER_PORT=8849 \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "3"

    [ -d "${DEPS_DIR}/3/jprofiler" ]
    grep -q "/home/vcap/deps/3/" "${BUILD_DIR}/.profile.d/000_jprofiler.sh"
}

@test "DEPS_IDX=7 installs into deps/7 and bakes /home/vcap/deps/7/ into profile.d" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "7"

    [ -d "${DEPS_DIR}/7/jprofiler" ]
    grep -q "/home/vcap/deps/7/" "${BUILD_DIR}/.profile.d/000_jprofiler.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 12 – generated -agentpath points to the installed library
# ─────────────────────────────────────────────────────────────────────────────
@test "agentpath in profile.d references /home/vcap/deps/0/jprofiler/.../libjprofilerti.so" {
    setup_patched_supply
    make_fake_archive

    JPROFILER_ENABLED=true \
        JPROFILER_TEST_SKIP_CHECKSUM=1 \
        bash "${PATCHED_SUPPLY}" "${BUILD_DIR}" "${CACHE_DIR}" "${DEPS_DIR}" "0"

    local profile_script="${BUILD_DIR}/.profile.d/000_jprofiler.sh"
    grep -q '_JPROFILER_AGENT_LIB="/home/vcap/deps/0/jprofiler' "${profile_script}"
    grep -q "libjprofilerti.so" "${profile_script}"
}
