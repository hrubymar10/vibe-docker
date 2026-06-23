#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
LOG="$TMP_ROOT/vibe-docker.log"
mkdir -p "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/vibe-docker" <<'EOF'
#!/bin/bash
printf '%q ' "$@" >> "$VIBE_DOCKER_WRAPPER_LOG"
printf '\n' >> "$VIBE_DOCKER_WRAPPER_LOG"
echo wrapped-ok
EOF
chmod +x "$TMP_ROOT/bin/vibe-docker"

# Replace sibling vibe-docker temporarily so the wrapper resolves it via SCRIPT_DIR.
ORIG="$ROOT/bin/vibe-docker"
BAK="$TMP_ROOT/vibe-docker.bak"
cp "$ORIG" "$BAK"
cp "$TMP_ROOT/bin/vibe-docker" "$ORIG"
trap 'cp "$BAK" "$ORIG"; rm -rf "$TMP_ROOT"' EXIT

echo
echo "═══ vscode wrapper forwarding ═══"
VIBE_DOCKER_WRAPPER_LOG="$LOG" "$ROOT/bin/vibe-docker-vscode-wrapper" --append-system-prompt hello world > "$TMP_ROOT/out.txt"

if grep -Eq '^--append-system-prompt hello world $' "$LOG"; then
  ok "vscode wrapper forwards argv unchanged"
else
  fail "vscode wrapper argv mismatch"
fi

if grep -q '^wrapped-ok$' "$TMP_ROOT/out.txt"; then
  ok "vscode wrapper returns delegated stdout"
else
  fail "vscode wrapper stdout mismatch"
fi

echo
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
