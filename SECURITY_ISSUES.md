# Known Security Issues & Trade-offs

This document lists known security limitations, intentional trade-offs, and escape vectors in the `vibe-docker` sandbox.

`vibe-docker` improves isolation. It does **not** make arbitrary code execution safe.

## 1. Volume driver bind escape (socket-proxy)

**Status:** Open — no upstream fix available  
**Severity:** Medium  
**Requires:** Direct HTTP API calls via curl or another raw client (not exploitable via the `docker` CLI wrapper, which now also covers absolute-path invocations of `/usr/bin/docker`)

The socket-proxy `allowbindmountfrom` restriction checks `HostConfig.Binds` and `HostConfig.Mounts` with `Type: "bind"`. It does **not** inspect volume driver options. An attacker can:

1. `POST /volumes/create` with `Driver: "local"`, `DriverOpts: {"type": "none", "device": "/any/host/path", "o": "bind"}`
2. `POST /containers/create` with `Mounts: [{Type: "volume", Source: "escape-vol", ...}]`
3. The proxy allows both requests, so the volume mount bypasses `allowbindmountfrom`

**Impact:** Read/write access to arbitrary host paths through the Docker API.

**Mitigations in place:**
- `scripts/docker-wrapper.sh` blocks `docker run`, `docker build`, `docker cp` at the CLI layer. (`docker volume` is still allowlisted; this is the residual gap exploited above.)
- The real docker binary is at `/usr/libexec/docker-real/docker` and `/usr/bin/docker` is the wrapper, so the allowlist cannot be bypassed by invoking the binary at an absolute path.
- Exploitation requires raw HTTP requests to `tcp://vibe-filter-proxy:2375`, not normal `docker` CLI usage

## 2. Git push to feature branches and force push

**Status:** By design  
**Severity:** Low

The git wrapper blocks push only to protected branches (`main`, `master` by default, configurable via `GIT_PROTECTED_BRANCHES`). Pushes to other branches are allowed, including force push.

**Impact:** vibe can push or force-push to any non-protected branch.

**Rationale:** This is intentional for normal feature-branch workflows.

## 2a. Git wrapper bypass via direct `git-real` invocation

**Status:** Accepted trade-off (paired with #3)  
**Severity:** Low (the wrapper is a usability hint, not a security boundary)

The real git binary at `/usr/libexec/git-real/git` keeps its default `0755 root:root` permissions, so the unprivileged container user can invoke it directly and skip the protected-branch check:

```bash
/usr/libexec/git-real/git push -f origin main   # bypasses the wrapper
```

We considered locking it down to `0700 root:root` and routing the wrapper through `sudo`, but that only buys partial defense (because of #3 below — `NOPASSWD: ALL` sudo lets the same caller run `sudo /usr/libexec/git-real/git push …` anyway), at the cost of friction on every git invocation.

**Impact:** Force push to protected branches is possible from inside the container with whatever credentials are configured.

**Rationale:** This sandbox aims to catch *bad-prompt* mistakes — e.g., vibe misreading state and prompting itself to `git push` from `master` — not to defeat a deliberately adversarial vibe. The wrapper covers the accidental case; the bypass requires explicit knowledge of the absolute path. See the README "Scope" section for the threat model.

**Real fix:** Enforce branch protection server-side (a pre-receive hook on the upstream that rejects pushes to protected refs from this token). The in-container wrapper is best-effort.

## 3. Passwordless sudo inside container

**Status:** By design  
**Severity:** Low (container-scoped)

The container user has `NOPASSWD: ALL` sudo access.

**Impact:** Full root access inside the container.

**Why this is still bounded:**
- the container is not privileged
- host PID/network/user namespace modes are blocked by the filter proxy
- dangerous Docker capabilities are blocked at container-create time

**Rationale:** Required for useful development workflows inside the sandbox.

## 4. Tokens visible in environment and config files

**Status:** Accepted trade-off  
**Severity:** Low (container-scoped)

`GITHUB_TOKEN` and similar credentials can be visible in:
- process environment (`env`, `/proc/*/environ`)
- generated git credential helper scripts
- `~/.docker/config.json` for ghcr.io auth

`GITLAB_TOKEN` (when set, for the `glab` CLI) is visible the same way:
- process environment
- the generated git credential helper script (`~/.git-credential-gitlab`, which references `$GITLAB_TOKEN`)

**Impact:** Any process already running inside the container can read them.

**Mitigations:** Scope is limited to the container unless secrets are exfiltrated over the network.

## 5. vibe auth/config directory is mounted read-write

**Status:** Required for operation  
**Severity:** Medium

`VIBE_HOME` (default: `~/.vibe`) is bind-mounted read-write into the container. This directory may contain:
- `config.toml`
- `.env`
- `agents/`
- `logs/`
- `trusted_folders.toml`

**Impact:** A compromised process inside the container can read or modify vibe auth/config/session state.

**Rationale:** vibe needs write access to its own state directory for normal operation.

## 6. No network egress filtering

**Status:** By design  
**Severity:** Low

The container has unrestricted outbound network access.

**Impact:** A compromised process could exfiltrate data or reach arbitrary services.

**Rationale:** Required for package installs, git operations, API calls, model providers, and normal development workflows.

## 7. Docker API surface is still broad

**Status:** Accepted trade-off  
**Severity:** Medium

The socket-proxy allows a substantial subset of the Docker API. The filter proxy only inspects container-create request bodies.

**Impact:** vibe can still create/delete containers, pull/delete images, and create/delete networks and volumes via raw API requests. Dangerous container settings are filtered, but the broader API surface remains available.

**Mitigations in place:**
- `scripts/docker-wrapper.sh` restricts normal CLI usage to a safer allowlist
- `docker-filter-proxy` blocks dangerous container-create configurations
- socket-proxy restricts bind mounts to allowed directories
- practical exploitation requires raw HTTP, not normal CLI flows

## 8. `docker inspect` and `docker logs` remain informative

**Status:** Accepted trade-off  
**Severity:** Low to Medium

The in-container Docker wrapper allows commands like:
- `docker inspect`
- `docker logs`

**Impact:**
- `docker inspect` can reveal environment variables and other metadata for containers the sandbox can see
- `docker logs` can expose output from those containers

**Rationale:** These commands are often useful for legitimate debugging. Restricting them further would trade off utility for tighter isolation.

## 9. Installed vibe extensions/packages are fully trusted code

**Status:** By design  
**Severity:** Medium

vibe packages, extensions, prompts, and skills can influence agent behavior and may execute arbitrary code.

**Impact:** Installing untrusted extensions/packages weakens the sandbox model from the inside.

**Mitigations:**
- review third-party package source before installing
- prefer local, trusted packages
- keep secrets out of mounted repos when possible

## Security layers summary

```text
vibe process
  └─ docker-wrapper.sh      CLI filter: blocks run/build/cp/volume
      └─ docker-filter-proxy  Body inspection: blocks privileged/host-ns/caps
          └─ socket-proxy      URL filter + bind mount allowlist
              └─ Docker daemon
```

```text
vibe process
  └─ git-wrapper.sh         Blocks push to protected branches
      └─ /usr/libexec/git-real/git
```

Each layer is defense-in-depth. Bypassing one layer still leaves the others in place. The git wrapper is **best-effort only** — see #2a — because `git-real` is callable directly by the unprivileged user and `NOPASSWD: ALL` sudo (#3) provides another path around it. Real branch protection must be enforced server-side.

## Practical advice

- mount only the project roots you actually need
- use `x-excludes` in `config/docker-compose.local.yml` for secrets
- keep API keys in env vars or vibe auth files, not in project trees
- treat installed vibe extensions/packages as fully trusted code only
