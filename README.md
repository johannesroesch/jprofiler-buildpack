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

## Runtime integration: JBP_CONFIG_JAVA_OPTS

This buildpack injects `-agentpath` by writing `JBP_CONFIG_JAVA_OPTS` to
`${DEPS_DIR}/${DEPS_IDX}/env/` during staging.

The CF buildpack runner picks up env-files from supply buildpacks and sets them
as environment variables before the final buildpack runs.  The SAP Java
Buildpack reads `JBP_CONFIG_JAVA_OPTS` at staging time and bakes its
`java_opts` value into the hardcoded `JAVA_OPTS` literal in the generated
start command.  Because this happens at staging, `-agentpath` ends up only in
the main JVM invocation — pre-start JVM processes such as `keytool` are not
affected.

`JAVA_TOOL_OPTIONS` was tried first but was rejected: it is read by every JVM
in the container, including pre-start `keytool` processes that randomly claim
the profiler port before the application JVM starts.

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
      - https://github.com/johannesroesch/jprofiler-buildpack.git
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

### Staging-time configuration

`JPROFILER_ENABLED` is evaluated **only at staging time**:

- If `false`, the agent archive is not downloaded and `-agentpath` is not
  injected into the start command.
- If `true`, the agent is installed and `-agentpath` is baked into the
  hardcoded `JAVA_OPTS` literal in the start command.

Because the injection happens at staging, changing `JPROFILER_ENABLED` after
deployment **requires a restage** — a plain `cf restart` is not sufficient.

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

### Check that the start command contains -agentpath

After `cf push`, inspect the start command logged by the SAP Java Buildpack
during staging.  It should contain `-agentpath:` in the `JAVA_OPTS` literal:

```
JAVA_OPTS="... -agentpath:/home/vcap/deps/0/jprofiler/bin/linux-x64/libjprofilerti.so=port=8849,nowait ..."
```

You can also check inside the running container:

```bash
cf ssh my-app
ps aux | grep java
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

1. Confirm the staging log showed `JBP_CONFIG_JAVA_OPTS` was set. Look for:
   ```
   -----> JProfiler Supply Buildpack
          Injected into JBP_CONFIG_JAVA_OPTS: [java_opts: '-agentpath:...']
   ```
2. Confirm `-agentpath` is in the start command baked by the SAP Java Buildpack:
   ```bash
   cf ssh my-app -- bash -c 'cat /proc/1/cmdline | tr "\0" "\n"'
   ```
3. If `JPROFILER_ENABLED` was `false` at staging time, the agent was not
   installed.  Restage with `JPROFILER_ENABLED=true`.

---

### Interaction with existing JAVA_OPTS

Set `JBP_CONFIG_JAVA_OPTS` in your CF manifest to pass additional JVM flags.
The buildpack merges them with `-agentpath` — it does not overwrite your value.

```yaml
env:
  JBP_CONFIG_JAVA_OPTS: "[java_opts: '-Xshare:off -XX:MaxDirectMemorySize=384M']"
  JPROFILER_ENABLED: "true"
```

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
