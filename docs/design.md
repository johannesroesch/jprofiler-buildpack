## Runtime integration design: JAVA_TOOL_OPTIONS vs JAVA_OPTS

### The problem

A Cloud Foundry supply buildpack runs *before* the final buildpack (SAP Java
Buildpack) during staging.  The buildpack needs to inject a JVM `-agentpath`
flag at container startup *without* modifying the application artifact.

The obvious approach is:

1. Write a `.profile.d` script that appends to `JAVA_OPTS`.
2. The SAP Java Buildpack reads `JAVA_OPTS` and passes it to the JVM.

This is **not reliable** for the following reasons.

---

### How the CF launcher sources profile.d scripts

The CF lifecycle launcher (`launcher`) generates a bash wrapper that:

```bash
cd /home/vcap/app
for env_file in ../profile.d/*; do source "$env_file"; done   # /home/vcap/profile.d/*
for env_file in  .profile.d/*; do source "$env_file"; done    # /home/vcap/app/.profile.d/*
source .profile 2>/dev/null || true
exec <start_command>
```

Scripts in `/home/vcap/profile.d/` (the global profile.d, populated by the CF
buildpack runner from `contentsDir/profile.d`) run **first**, then scripts in
`/home/vcap/app/.profile.d/` (populated from `BUILD_DIR/.profile.d/`).

A supply buildpack writes its profile.d script into `${BUILD_DIR}/.profile.d/`
(it cannot write into `contentsDir/profile.d/` because that path is not passed
to `bin/supply`).  Therefore supply buildpack scripts run **after** the global
profile.d scripts.

---

### Why JAVA_OPTS alone is unreliable

The SAP Java Buildpack installs `00_java_opts.sh` (name starting with `00`) in
`/home/vcap/profile.d/` (the global dir).  That script:

- Reads `JAVA_OPTS` from the environment (user-supplied app env vars).
- Assembles a final `JAVA_OPTS` value including JRE/container flags.
- Exports the assembled value.

Because `00_java_opts.sh` runs **before** `/home/vcap/app/.profile.d/` scripts,
any value appended to `JAVA_OPTS` by a supply-buildpack profile.d script would
run *after* the buildpack's assembly.

In theory a script named `zzz_jprofiler.sh` that appends to `JAVA_OPTS` after
the buildpack's assembly would work.  However:

- This relies on alphabetical sort ordering of profile.d scripts across two
  separate directories, which is fragile.
- The SAP Java Buildpack's `javaexec` launcher tokenises `JAVA_OPTS` at
  `exec` time; appending after assembly should work, but depends on
  undocumented internal behaviour.
- The approach breaks if the buildpack switches to reading `JAVA_OPTS` at
  staging time or embeds it in a wrapper script.

---

### The chosen solution: JAVA_TOOL_OPTIONS

`JAVA_TOOL_OPTIONS` is specified by the **JVM Tool Interface (JVMTI)** standard.
The JVM reads it directly at process startup, *before* any JVM initialisation.
It accepts a subset of JVM flags including `-agentpath`.

Key properties:

| Property | `JAVA_OPTS` | `JAVA_TOOL_OPTIONS` |
|---|---|---|
| Read by | Java Buildpack | JVM itself |
| Timing | Staging/profile.d assembly | JVM startup (after profile.d) |
| Ordering dependency | Yes (profile.d order) | No |
| Works with any JVM | No | Yes |
| Printed to stderr | No | Yes (`Picked up JAVA_TOOL_OPTIONS:`) |

The JVM prints `Picked up JAVA_TOOL_OPTIONS: ...` to stderr when this variable
is set.  This is informational and expected.

Because `JAVA_TOOL_OPTIONS` is appended to (not replaced) at runtime by our
profile.d script, any pre-existing value set in the CF app environment is
preserved.

---

### Profile.d script location

Supply buildpack writes to `${BUILD_DIR}/.profile.d/000_jprofiler.sh`.

At runtime this becomes `/home/vcap/app/.profile.d/000_jprofiler.sh` and is
sourced by the CF launcher after `/home/vcap/profile.d/` scripts.  The `000_`
prefix ensures this script runs early among app-level profile.d scripts.

---

### Runtime path resolution

During staging, `DEPS_DIR` is a temporary path (e.g. `/tmp/buildpacks/.../deps`).
At runtime, supply buildpack dependency directories are mounted at
`/home/vcap/deps/<DEPS_IDX>/`.

The supply script derives the relative sub-path of `libjprofilerti.so` under
`DEPS_DIR` and prefixes it with `/home/vcap/deps/` to produce the stable
runtime path, which is embedded as a literal in the generated profile.d script.

---

### SAP Java Buildpack and JAVA_OPTS

The application may also set `JAVA_OPTS` in its CF environment.  The SAP Java
Buildpack includes the user's `JAVA_OPTS` in its final JVM invocation.  This
buildpack does **not** touch `JAVA_OPTS`; it only sets `JAVA_TOOL_OPTIONS`.
Both variables are additive from the JVM's perspective, so no flags are lost.
