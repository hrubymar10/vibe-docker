#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

HOST_HOME="$TMP_ROOT/home/tester"
VIBE_DIR="$HOST_HOME/.vibe"
GOPATH_DIR="$HOST_HOME/go"
mkdir -p "$VIBE_DIR" "$GOPATH_DIR/pkg"

OUT="$TMP_ROOT/compose-config.yml"

echo
echo "═══ docker compose config smoke test ═══"
HOST_UID=1000 \
HOST_USER=tester \
HOST_HOME="$HOST_HOME" \
GO_VERSION=go1.26.0 \
GOPATH="$GOPATH_DIR" \
VIBE_HOME_HOST="$VIBE_DIR" \
ALLOWED_BIND_MOUNTS="$VIBE_DIR,$GOPATH_DIR/pkg" \
DOCKER_MEMORY_LIMIT=0 \
GITHUB_TOKEN=dummy \
GIT_USER_NAME='' \
GIT_USER_EMAIL='' \
GOPRIVATE='' \
GONOSUMDB='' \
docker compose -f docker-compose.yml config > "$OUT"

if grep -q '^  vibe:$' "$OUT" && grep -q '^  filter-proxy:$' "$OUT" && grep -q '^  socket-proxy:$' "$OUT"; then
  ok "compose includes expected services"
else
  fail "compose missing expected services"
fi

if grep -q 'target: /usr/local/bin/vibe-notifier' "$OUT"; then
  ok "compose mounts notifier hook"
else
  fail "compose missing notifier hook mount"
fi

if grep -q "source: $VIBE_DIR" "$OUT" && grep -q "target: $VIBE_DIR" "$OUT"; then
  ok "compose mounts VIBE_HOME"
else
  fail "compose missing VIBE_HOME mount"
fi

if grep -q 'MISTRAL_API_KEY:' "$OUT"; then
  ok "compose passes MISTRAL_API_KEY"
else
  fail "compose missing MISTRAL_API_KEY passthrough"
fi

if grep -q 'container_name: vibe-docker' "$OUT"; then
  ok "compose keeps expected container name"
else
  fail "compose missing vibe-docker container name"
fi

echo
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
