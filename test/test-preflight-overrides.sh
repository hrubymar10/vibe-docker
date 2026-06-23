#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
TMPDIR_TEST="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR_TEST"
trap 'restore_local_state; rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
LOG="$TMP_ROOT/docker.log"
: > "$LOG"

restore_local_state() {
  if [[ -n "${BACKUP_LOCAL_COMPOSE:-}" && -f "$BACKUP_LOCAL_COMPOSE" ]]; then
    mv "$BACKUP_LOCAL_COMPOSE" "$ROOT/config/docker-compose.local.yml"
  else
    rm -f "$ROOT/config/docker-compose.local.yml"
  fi

  if [[ -n "${BACKUP_VIBE_NOTIFIER:-}" && -f "$BACKUP_VIBE_NOTIFIER" ]]; then
    mv "$BACKUP_VIBE_NOTIFIER" "$ROOT/config/vibe-notifier"
  else
    rm -f "$ROOT/config/vibe-notifier"
  fi
}

cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
LOG_FILE="${FAKE_DOCKER_LOG:?}"
printf 'COMPOSE_PROJECT_NAME=%s ' "${COMPOSE_PROJECT_NAME:-}" >> "$LOG_FILE"
printf '%q ' "$@" >> "$LOG_FILE"
printf '\n' >> "$LOG_FILE"

case "${1:-}" in
  info)
    exit 0
    ;;
  version)
    if [[ "${2:-}" == "--format" ]]; then
      echo 1.44
    fi
    exit 0
    ;;
  compose)
    exit 0
    ;;
  *)
    echo "unexpected docker call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/docker"

if [[ -f "$ROOT/config/docker-compose.local.yml" ]]; then
  BACKUP_LOCAL_COMPOSE="$TMP_ROOT/docker-compose.local.yml.bak"
  cp "$ROOT/config/docker-compose.local.yml" "$BACKUP_LOCAL_COMPOSE"
fi

if [[ -f "$ROOT/config/vibe-notifier" ]]; then
  BACKUP_VIBE_NOTIFIER="$TMP_ROOT/vibe-notifier.bak"
  cp "$ROOT/config/vibe-notifier" "$BACKUP_VIBE_NOTIFIER"
fi
rm -f "$ROOT/config/vibe-notifier"

HOME_DIR="$TMP_ROOT/home/tester"
mkdir -p "$HOME_DIR/.ssh" "$HOME_DIR/.agents" "$HOME_DIR/projects/secrets"
printf 'global agents\n' > "$HOME_DIR/AGENTS.md"
printf 'global claude\n' > "$HOME_DIR/CLAUDE.md"
printf 'known-host\n' > "$HOME_DIR/.ssh/known_hosts"
printf 'secret=1\n' > "$HOME_DIR/projects/.env"

cat > "$ROOT/config/docker-compose.local.yml" <<'EOF'
services:
  vibe:
    volumes:
      - ${HOST_HOME}/projects:${HOST_HOME}/projects
x-excludes:
  - ${HOST_HOME}/projects/.env
  - ${HOST_HOME}/projects/secrets
EOF

echo
echo "═══ preflight override generation ═══"
(
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export TMPDIR="$TMPDIR_TEST"
  export HOME="$HOME_DIR"
  export HOST_HOME="$HOME_DIR"
  export HOST_USER=tester
  export HOST_UID=1000
  export VIBE_HOME="$HOME_DIR/.vibe"
  export ALLOWED_BIND_MOUNTS=/tmp/already-set
  export GITHUB_TOKEN=dummy
  export GIT_USER_NAME='Test User'
  export GIT_USER_EMAIL='test@example.com'
  export GOPRIVATE=
  export GONOSUMDB=
  "$ROOT/bin/vibe-docker-ctrl" start > "$TMP_ROOT/start.out" 2> "$TMP_ROOT/start.err"
)

if [[ -x "$ROOT/config/vibe-notifier" ]]; then
  ok "vibe-notifier auto-created from example"
else
  fail "vibe-notifier was not auto-created"
fi

CONTEXT_FILES=("$TMPDIR_TEST"/vibe-docker-context.*)
if [[ -f "${CONTEXT_FILES[0]}" ]] && grep -Rqs '/AGENTS.md:.*AGENTS.md:ro' "$TMPDIR_TEST"/vibe-docker-context.* \
  && grep -Rqs '/CLAUDE.md:.*CLAUDE.md:ro' "$TMPDIR_TEST"/vibe-docker-context.*; then
  ok "global AGENTS.md and CLAUDE.md overrides created"
else
  fail "missing AGENTS.md/CLAUDE.md override files"
fi

if ls "$TMPDIR_TEST"/vibe-docker-ssh.* >/dev/null 2>&1 \
  && grep -Rqs '.ssh/known_hosts:.*known_hosts:ro' "$TMPDIR_TEST"/vibe-docker-ssh.*; then
  ok "known_hosts override created"
else
  fail "missing known_hosts override"
fi

if ls "$TMPDIR_TEST"/vibe-docker-agents.* >/dev/null 2>&1 \
  && grep -Rqs '/.agents:.*\.agents' "$TMPDIR_TEST"/vibe-docker-agents.*; then
  ok "~/.agents override created"
else
  fail "missing ~/.agents override"
fi

if ls "$TMPDIR_TEST"/vibe-docker-excludes.* >/dev/null 2>&1 \
  && grep -Rqs "/dev/null:$HOME_DIR/projects/.env:ro" "$TMPDIR_TEST"/vibe-docker-excludes.* \
  && grep -Rqs "$HOME_DIR/projects/secrets:ro,size=0" "$TMPDIR_TEST"/vibe-docker-excludes.*; then
  ok "x-excludes override created for file and directory"
else
  fail "missing x-excludes override"
fi

if grep -q ' build ' "$LOG" && grep -q ' up -d ' "$LOG"; then
  ok "start runs docker compose build and up"
else
  fail "start did not issue expected docker compose commands"
fi

if grep -q 'COMPOSE_PROJECT_NAME=vibe-docker' "$LOG"; then
  ok "compose project name is pinned"
else
  fail "compose project name was not pinned"
fi

if grep -qE ' compose .* config -q($| )' "$LOG"; then
  ok "compose files validated"
else
  fail "compose validation config -q call missing"
fi

# Validation uses `config -q`; preset ALLOWED_BIND_MOUNTS should only skip the
# later bare `config` call that derives bind mounts.
if awk '/ compose / && / config/ && !/(^| )-q( |$)/ { found=1 } END { exit found ? 0 : 1 }' "$LOG"; then
  fail "unexpected bind-mount derivation config call"
else
  ok "preset ALLOWED_BIND_MOUNTS skips bind-mount derivation"
fi

if grep -q "Container 'vibe-docker' is running." "$TMP_ROOT/start.out"; then
  ok "start prints success banner"
else
  fail "start output missing success banner"
fi

echo
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
