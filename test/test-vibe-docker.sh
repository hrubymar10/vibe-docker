#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo
echo "═══ Mount boundary check ═══"
check_mount() {
  local workdir="$1" src="$2" expect="$3"
  if [[ "$workdir" == "$src" || "$workdir" == "$src/"* ]]; then result="match"; else result="nomatch"; fi
  if [[ "$result" == "$expect" ]]; then ok "'$workdir' vs '$src'"; else fail "'$workdir' vs '$src' → $result (expected $expect)"; fi
}
check_mount "$HOME/projects"                 "$HOME/projects"            match
check_mount "$HOME/projects/sub"             "$HOME/projects"            match
check_mount "${HOME}x"                       "$HOME"                     nomatch
check_mount "$HOME-evil"                     "$HOME"                     nomatch
check_mount "/etc/passwd"                    "$HOME"                     nomatch

echo
echo "═══ Credential helper: #!/bin/bash + special chars ═══"
GIT_AUTH_USER="user'quotes" GIT_AUTH_TOKEN='pass$word!&' bash << 'BASH'
  printf '#!/bin/bash\nprintf "username=%%s\\npassword=%%s\\n" %s %s\n' \
    "$(printf '%q' "$GIT_AUTH_USER")" "$(printf '%q' "$GIT_AUTH_TOKEN")" > /tmp/test-cred-helper
BASH
chmod 700 /tmp/test-cred-helper
output=$(bash /tmp/test-cred-helper)
if [[ "$output" == $'username=user\'quotes\npassword=pass$word!&' ]]; then
  ok "cred helper: special chars (quotes, dollar, bang)"
else
  fail "cred helper special chars: got '$output'"
fi

GIT_AUTH_USER="bob" GIT_AUTH_TOKEN="simple-token" bash << 'BASH'
  printf '#!/bin/bash\nprintf "username=%%s\\npassword=%%s\\n" %s %s\n' \
    "$(printf '%q' "$GIT_AUTH_USER")" "$(printf '%q' "$GIT_AUTH_TOKEN")" > /tmp/test-cred-helper
BASH
chmod 700 /tmp/test-cred-helper
output=$(bash /tmp/test-cred-helper)
if [[ "$output" == $'username=bob\npassword=simple-token' ]]; then
  ok "cred helper: plain credentials"
else
  fail "cred helper plain: got '$output'"
fi
rm -f /tmp/test-cred-helper

echo
echo "═══ Session cleanup path ═══"
SESSION_ID="1234"
cat > /tmp/vibe-session-cleanup-test.sh <<'BASH'
#!/bin/bash
f="/tmp/vibe-session-${1}.pid"
echo $$ > "$f"
[[ -f "$f" ]]
BASH
chmod +x /tmp/vibe-session-cleanup-test.sh
if /tmp/vibe-session-cleanup-test.sh "$SESSION_ID" && [[ -f "/tmp/vibe-session-${SESSION_ID}.pid" ]]; then
  ok "vibe session pid file format"
else
  fail "vibe session pid file format"
fi
rm -f "/tmp/vibe-session-${SESSION_ID}.pid" /tmp/vibe-session-cleanup-test.sh

echo
echo "═══ vibe-session teardown wrapper ═══"
if grep -q '^trap cleanup HUP TERM INT EXIT$' scripts/vibe-session.sh \
  && grep -q '^exec 3<&0$' scripts/vibe-session.sh \
  && grep -q '^vibe "\$@" <&3 &$' scripts/vibe-session.sh \
  && grep -q '^wait "\$VIBE_PID" 2>/dev/null$' scripts/vibe-session.sh; then
  ok "vibe-session keeps a supervising shell around vibe"
else
  fail "vibe-session missing supervising-shell teardown logic"
fi

echo
echo "═══ Mistral Vibe install and environment ═══"
if grep -q 'UV_TOOL_BIN_DIR=/usr/local/bin uv tool install mistral-vibe' Dockerfile \
  && grep -q 'mistral-vibe==${VIBE_VERSION}' Dockerfile; then
  ok "Dockerfile installs mistral-vibe with uv and supports version pinning"
else
  fail "Dockerfile missing uv mistral-vibe install stanza"
fi

if grep -q '/this-is-vibe-docker-env' Dockerfile; then
  ok "Dockerfile creates vibe environment marker"
else
  fail "Dockerfile missing vibe environment marker"
fi

if grep -q 'VIBE_HOME="${VIBE_HOME:-$HOST_HOME/.vibe}"' scripts/entrypoint.sh \
  && grep -q 'VIBE_HOME: ${VIBE_HOME_HOST}' docker-compose.yml; then
  ok "VIBE_HOME defaults and compose passthrough are configured"
else
  fail "VIBE_HOME defaults or compose passthrough are missing"
fi

if grep -q 'MISTRAL_API_KEY: ${MISTRAL_API_KEY:-}' docker-compose.yml; then
  ok "MISTRAL_API_KEY is passed through"
else
  fail "MISTRAL_API_KEY passthrough missing"
fi

echo
echo "═══ detached session watchdog ═══"
if grep -q '^_spawn_detached() {$' bin/lib/session-cleanup.sh \
  && grep -q 'command -v setsid' bin/lib/session-cleanup.sh \
  && grep -q 'os\.setsid()' bin/lib/session-cleanup.sh \
  && grep -q 'POSIX qw(setsid)' bin/lib/session-cleanup.sh \
  && grep -q '_spawn_detached ' bin/lib/session-cleanup.sh \
  && grep -q 'sleep 0.5' bin/lib/session-cleanup.sh \
  && grep -q 'attempt < 20' bin/lib/session-cleanup.sh \
  && grep -q 'sleep 0.25' bin/lib/session-cleanup.sh; then
  ok "session watchdog is detached (portable fallback ladder) and polls quickly"
else
  fail "session watchdog missing portable detach ladder or fast poll"
fi

echo ""
echo "═══ Docker wrapper bypass check (Vuln 2) ═══"
# Closes the bypass where /usr/bin/docker remained the real binary while the
# wrapper sat at /usr/local/bin/docker. Mirrors the existing git-wrapper pattern.

if grep -qE 'mv /usr/bin/docker[[:space:]]+/usr/libexec/docker-real/docker' Dockerfile; then
  ok "Dockerfile relocates real /usr/bin/docker to /usr/libexec/docker-real/docker"
else
  fail "Dockerfile does not relocate /usr/bin/docker — wrapper bypass via direct /usr/bin/docker call"
fi

if grep -qE 'COPY scripts/docker-wrapper\.sh[[:space:]]+/usr/bin/docker' Dockerfile; then
  ok "Dockerfile installs docker wrapper at /usr/bin/docker"
else
  fail "Dockerfile does not install wrapper at /usr/bin/docker — PATH-shadow only"
fi

if grep -qE 'exec[[:space:]]+/usr/libexec/docker-real/docker' scripts/docker-wrapper.sh; then
  ok "wrapper invokes real docker at /usr/libexec/docker-real/docker"
else
  fail "wrapper does not invoke /usr/libexec/docker-real/docker"
fi

if grep -qE 'exec[[:space:]]+/usr/bin/docker' scripts/docker-wrapper.sh; then
  fail "wrapper still invokes /usr/bin/docker — would recurse into itself"
else
  ok "wrapper no longer invokes /usr/bin/docker"
fi

echo ""
echo "═══ Docker wrapper behavioral check ═══"
# Run the wrapper with the real-docker path rewritten to a mock so we can
# observe what gets exec'd without needing a built container.
WRAP_TMP=$(mktemp -d)
trap 'rm -rf "$WRAP_TMP"' EXIT
cat > "$WRAP_TMP/mock-docker" <<'MOCK'
#!/bin/bash
echo "REAL_DOCKER:$*"
MOCK
chmod +x "$WRAP_TMP/mock-docker"
sed "s|/usr/libexec/docker-real/docker|$WRAP_TMP/mock-docker|g" scripts/docker-wrapper.sh > "$WRAP_TMP/wrapper.sh"
chmod +x "$WRAP_TMP/wrapper.sh"

output=$(bash "$WRAP_TMP/wrapper.sh" ps 2>&1 || true)
if [[ "$output" == "REAL_DOCKER:ps" ]]; then
  ok "wrapper passes 'ps' through to real docker"
else
  fail "wrapper 'ps' got: $output"
fi

output=$(bash "$WRAP_TMP/wrapper.sh" run alpine 2>&1 || true)
if [[ "$output" == *"blocked"* ]]; then
  ok "wrapper blocks 'run'"
else
  fail "wrapper 'run' got: $output"
fi

output=$(bash "$WRAP_TMP/wrapper.sh" build . 2>&1 || true)
if [[ "$output" == *"blocked"* ]]; then
  ok "wrapper blocks 'build'"
else
  fail "wrapper 'build' got: $output"
fi

output=$(bash "$WRAP_TMP/wrapper.sh" cp foo bar 2>&1 || true)
if [[ "$output" == *"blocked"* ]]; then
  ok "wrapper blocks 'cp'"
else
  fail "wrapper 'cp' got: $output"
fi

output=$(bash "$WRAP_TMP/wrapper.sh" --version 2>&1 || true)
if [[ "$output" == "REAL_DOCKER:--version" ]]; then
  ok "wrapper passes '--version' to real docker"
else
  fail "wrapper '--version' got: $output"
fi

echo
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
