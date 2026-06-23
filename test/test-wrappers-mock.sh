#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN" "$TMP_ROOT/home" "$TMP_ROOT/work/project"
LOG="$TMP_ROOT/docker.log"
: > "$LOG"

cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
LOG_FILE="${FAKE_DOCKER_LOG:?}"
printf '%q ' "$@" >> "$LOG_FILE"
printf '\n' >> "$LOG_FILE"

case "${1:-}" in
  info)
    exit 0
    ;;
  inspect)
    format=""
    target=""
    args=("$@")
    for ((i=0; i<$#; i++)); do
      if [[ "${args[$i]}" == "--format" && $((i+1)) -lt $# ]]; then
        format="${args[$((i+1))]}"
      fi
    done
    for ((i=1; i<$#; i++)); do
      arg="${args[$i]}"
      if [[ "$arg" != "--format" && "$arg" != "$format" && "${args[$((i-1))]}" != "--format" ]]; then
        target="$arg"
        break
      fi
    done
    case "$format" in
      *'.Mounts'*)
        echo "${FAKE_DOCKER_MOUNT:?} "
        exit 0
        ;;
      *'{{.Name}}'*|*'.State.StartedAt'*)
        echo "Name: /$target  Status: running  Started: 2026-01-01T00:00:00Z"
        exit 0
        ;;
      *'.State.Status'*)
        case "$target" in
          vibe-docker|vibe-socket-proxy|vibe-filter-proxy)
            echo running
            exit 0
            ;;
          *)
            exit 1
            ;;
        esac
        ;;
    esac
    exit 1
    ;;
  exec)
    if [[ "$*" == *'printenv CONTAINER_SHELL'* ]]; then
      echo /bin/zsh
      exit 0
    fi
    if [[ "$*" == *' vibe-session '* || "$*" == *' vibe-session' ]]; then
      echo vibe-mock-0.0.0
      exit 0
    fi
    exit 0
    ;;
  *)
    echo "unexpected docker call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/docker"

echo
echo "═══ mocked vibe-docker wrapper ═══"
(
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export FAKE_DOCKER_MOUNT="$TMP_ROOT/work"
  export VIBE_DOCKER_USER=tester
  cd "$TMP_ROOT/work/project"
  "$ROOT/bin/vibe-docker" --version > "$TMP_ROOT/vibe-docker.out"
)

if grep -Eq 'exec -i .*VIBE_SESSION_ID=.* -u tester -w .*/work/project vibe-docker vibe-session --yolo --version' "$LOG"; then
  ok "vibe-docker forwards args, --yolo, and session env"
else
  fail "vibe-docker did not emit expected docker exec call with --yolo"
fi

if grep -Eq 'exec vibe-docker sh -c .*vibe-session-.*\.pid' "$LOG"; then
  ok "vibe-docker performs cleanup exec"
else
  fail "vibe-docker missing cleanup exec"
fi

if grep -q '^vibe-mock-0.0.0$' "$TMP_ROOT/vibe-docker.out"; then
  ok "vibe-docker returns docker exec stdout"
else
  fail "vibe-docker stdout mismatch"
fi

echo
echo "═══ mocked vibe-docker-ctrl status ═══"
(
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_DOCKER_LOG="$LOG"
  export FAKE_DOCKER_MOUNT="$TMP_ROOT/work"
  export HOME="$TMP_ROOT/home"
  "$ROOT/bin/vibe-docker-ctrl" status > "$TMP_ROOT/status.out"
)

if grep -q '=== Socket Proxy ===' "$TMP_ROOT/status.out" \
  && grep -q '=== Filter Proxy ===' "$TMP_ROOT/status.out" \
  && grep -q '=== Container ===' "$TMP_ROOT/status.out" \
  && grep -q '=== Beeper ===' "$TMP_ROOT/status.out"; then
  ok "status prints expected sections"
else
  fail "status output missing sections"
fi

if grep -q 'Name: /vibe-docker  Status: running' "$TMP_ROOT/status.out" \
  && grep -q 'Name: /vibe-filter-proxy  Status: running' "$TMP_ROOT/status.out"; then
  ok "status reports running containers"
else
  fail "status output missing running container details"
fi

echo
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
