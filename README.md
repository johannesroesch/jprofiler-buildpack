# JProfiler Supply Buildpack for Cloud Foundry

A Cloud Foundry v2 **supply buildpack** that installs the JProfiler native
profiling agent into Java applications without modifying the application
artifact.

The buildpack runs *before* the SAP Java Buildpack during staging, downloads
and installs the JProfiler agent into its dependency directory, and writes a
runtime activation script.  The application code itself has no JProfiler
dependency.

---

## Purpose

Production Java applications on Cloud Foundry sometimes need CPU/memory
profiling to diagnose performance issues.  Embedding a profiling agent in the
application JAR is undesirable because:

- It couples a diagnostic tool to the deployment artifact.
- It may affect performance when profiling is not active.
- It requires a rebuild to enable or disable profiling.

This buildpack solves the problem by injecting the agent as a separate
buildpack.  Profiling is controlled entirely by environment variables in the CF
manifest, with no changes to application code or artifacts.

---

## Runtime integration decision: JAVA_TOOL_OPTIONS

This buildpack sets `JAVA_TOOL_OPTIONS` (not `JAVA_OPTS`) to inject
`-agentpath`.

`JAVA_TOOL_OPTIONS` is defined by the JVM Tool Interface (JVMTI) specification
and is read directly by the JVM at startup, independent of which Java Buildpack
assembles `JAVA_OPTS`.  This avoids ordering dependencies between the supply
buildpack's profile.d script and the SAP Java Buildpack's internal
`00_java_opts.sh` assembly script.

The existing `JAVA_OPTS` value (set in the CF app environment) is preserved as-
is; the two variables are additive from the JVM's perspective.

Full rationale: [docs/design.md](docs/design.md).

---

## Requirements

- Cloud Foundry with multi-buildpack support (v2 buildpack API, CF CLI v6+)
- SAP Java Buildpack (or any CF Java Buildpack) as the **final** buildpack
- `cf ssh` enabled on the Cloud Foundry foundation (for connecting JProfiler)
- Internet access during staging (to download the JProfiler agent)

---

## Cloud Foundry manifest

```yaml
applications:
  - name: my-app

    buildpacks:
      - https://github.example.com/example/jprofiler-buildpack.git
      - java_buildpack                          # or sap_java_buildpack

    env:
      JPROFILER_ENABLED: "true"
      JPROFILER_PORT: "8849"

      JAVA_OPTS: >-
        -Xshare:off
        -XX:MaxDirectMemorySize=384M
        --enable-native-access=ALL-UNNAMED
```

**The JProfiler buildpack MUST be listed before the Java Buildpack.**
CF processes supply buildpacks in order; the Java Buildpack is always the final
(main) buildpack.

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `JPROFILER_ENABLED` | `false` | Set to `true` to activate profiling |
| `JPROFILER_PORT` | `8849` | TCP port JProfiler listens on |
| `JPROFILER_NOWAIT` | `true` | If `true`, JVM starts immediately without waiting for a profiler connection |
| `JPROFILER_OPTIONS` | _(empty)_ | Additional JProfiler agent options (comma-separated key=value pairs) |

### Boolean values

`JPROFILER_ENABLED` and `JPROFILER_NOWAIT` accept: `true`, `1`, `yes`, `on`
(case-insensitive) as truthy values; anything else is treated as false.

### JPROFILER_OPTIONS example

```yaml
env:
  JPROFILER_OPTIONS: "loglevel=info,samplingmode=cpu"
```

This appends `,loglevel=info,samplingmode=cpu` to the `-agentpath` option
string, resulting in:

```
-agentpath:/home/vcap/deps/0/jprofiler/bin/linux-x64/libjprofilerti.so=port=8849,nowait,loglevel=info,samplingmode=cpu
```

### Staging-time vs runtime configuration

`JPROFILER_ENABLED` is evaluated at **both** staging time and runtime:

- At **staging**: if `false`, the agent archive is not downloaded (saves ~5 MB
  of staging time and cache space).
- At **runtime**: if `false`, the profile.d script exits immediately without
  setting `JAVA_TOOL_OPTIONS`, so the agent is not attached.

This means you can enable the buildpack at staging time and disable it at
runtime by setting `JPROFILER_ENABLED=false` in a running app's environment
without restaging.  Conversely, if profiling was not enabled at staging time,
restaging is required to install the agent.

---

## Connecting JProfiler

### 1. Deploy with profiling enabled

```yaml
env:
  JPROFILER_ENABLED: "true"
  JPROFILER_PORT: "8849"
```

Push or restage the application:

```bash
cf push my-app
# or, if the app is already running:
cf set-env my-app JPROFILER_ENABLED true
cf restage my-app
```

### 2. Establish an SSH tunnel

JProfiler listens on the port inside the container.  It is not exposed through
a CF route.  Use `cf ssh` to forward the port:

```bash
cf ssh my-app -L 8849:localhost:8849
```

The terminal will hold the SSH connection.  Keep it open while profiling.

### 3. Connect JProfiler GUI

In the JProfiler GUI, create a new session:

- **Session type**: Attach to a JVM
- **Host**: `localhost`
- **Port**: `8849`

### 4. Multiple application instances

If your application runs with multiple instances (`instances: N`), each
instance has a separate JProfiler agent listening on the same port.  To profile
a specific instance, select it by index:

```bash
cf ssh my-app --app-instance-index 1 -L 8849:localhost:8849
```

Instance indices are zero-based.

---

## Verification

SSH into the running container to verify the installation:

```bash
cf ssh my-app
```

### Check that the agent library is present

```bash
find /home/vcap/deps -name "libjprofilerti.so"
```

Expected output (exact path depends on `DEPS_IDX`):

```
/home/vcap/deps/0/jprofiler/bin/linux-x64/libjprofilerti.so
```

### Check that JAVA_TOOL_OPTIONS contains -agentpath

```bash
echo "$JAVA_TOOL_OPTIONS"
```

Expected output when profiling is enabled:

```
-agentpath:/home/vcap/deps/0/jprofiler/bin/linux-x64/libjprofilerti.so=port=8849,nowait
```

### Check the running JVM process

```bash
ps aux | grep java
```

The Java process arguments should contain `-agentpath:`.  If the process was
started by the CF launcher, you can also inspect `/proc/1/cmdline`:

```bash
cat /proc/1/cmdline | tr '\0' '\n'
```

Or list all open file handles to confirm the agent is loaded:

```bash
ls -la /proc/$(pgrep java)/fd | grep jprofiler
```

---

## Troubleshooting

### Agent library not found

**Symptom**: The profile.d script exits with
`JProfiler: agent library not found at /home/vcap/deps/…`

**Cause**: The agent was not installed during staging (e.g. `JPROFILER_ENABLED`
was `false` at staging time).

**Fix**: Set `JPROFILER_ENABLED=true` and `cf restage my-app`.

---

### JProfiler cannot connect

**Symptom**: JProfiler GUI shows "Connection refused" or times out.

**Checks**:

1. Is the SSH tunnel running? (`cf ssh my-app -L 8849:localhost:8849`)
2. Is the JVM running with `-agentpath`?  (`ps aux | grep java`)
3. Is `JPROFILER_NOWAIT=true`?  If `false`, the JVM waits for a profiler
   connection before starting.  The application will appear unresponsive until
   JProfiler connects.
4. Is the port correct?  The tunnel port and `JPROFILER_PORT` must match.

---

### cf ssh is disabled

**Symptom**: `cf ssh` returns `ssh support is disabled`.

**Cause**: `cf ssh` is disabled at the CF foundation or space level.

**Fix**: Ask your CF platform operator to enable SSH access:

```bash
cf enable-ssh my-app
cf restart my-app
```

Space-level SSH must also be enabled:

```bash
cf allow-space-ssh <space-name>
```

---

### Port already in use

**Symptom**: The JVM fails to start with a port-binding error, or another
process is using `JPROFILER_PORT`.

**Cause**: Another process (or another application instance) is already
listening on the same port inside the container.

**Fix**: Change `JPROFILER_PORT` to an unused port, e.g. `8850`.  Remember to
update the SSH tunnel command accordingly.

---

### Architecture mismatch

**Symptom**: Staging fails with `Unsupported CPU architecture`.

**Cause**: The CF Diego cell running the staging task uses a CPU architecture
not supported by this buildpack.

**Supported architectures**: `x86_64`, `aarch64` / `arm64`.

If you see this error on a supported architecture, open an issue.

---

### Java process does not contain -agentpath

**Symptom**: The JVM starts without `-agentpath`, even though
`JPROFILER_ENABLED=true`.

**Checks**:

1. Confirm the profile.d script exists:
   ```bash
   ls /home/vcap/app/.profile.d/
   ```
2. Confirm it is being sourced; look for this line in `cf logs`:
   ```
   -----> JProfiler profiling enabled on port 8849
   ```
3. Confirm `JAVA_TOOL_OPTIONS` is set in the container environment:
   ```bash
   echo "$JAVA_TOOL_OPTIONS"
   ```
4. Check whether the Java Buildpack ignores `JAVA_TOOL_OPTIONS`.  All
   standard JVMs honour this variable (it is part of the JVMTI specification);
   the buildpack does not need to do anything with it.

---

### Interaction with existing JAVA_OPTS

`JAVA_OPTS` and `JAVA_TOOL_OPTIONS` are independent.  This buildpack appends to
`JAVA_TOOL_OPTIONS` only.  Your existing `JAVA_OPTS` value is not modified.

If you see duplicate flags, verify that you have not also added `-agentpath`
manually to `JAVA_OPTS` or `JAVA_TOOL_OPTIONS`.

---

### Multiple application instances

Each instance of a CF application has its own container and its own JProfiler
agent process.  To profile a specific instance:

```bash
cf ssh my-app --app-instance-index 2 -L 8849:localhost:8849
```

Each SSH tunnel forwards to the agent in that specific container.  You cannot
profile all instances simultaneously through a single tunnel.

---

## Development

### Running tests

```bash
# Install Bats (macOS)
brew install bats-core

# Run all tests
bats test/

# Run a specific test file
bats test/supply.bats
```

### Running shellcheck

```bash
brew install shellcheck
shellcheck bin/detect bin/supply
```

### Bumping the JProfiler version

1. Update `JPROFILER_VERSION` in `bin/supply`.
2. Update the `KNOWN_SHA256` associative array in `bin/supply` with the new
   checksums from
   `https://download.ej-technologies.com/jprofiler/sha256sums_<version>.txt`.
3. Run the tests.
4. Commit and push.

---

## License

Apache 2.0 – see [LICENSE](LICENSE).
