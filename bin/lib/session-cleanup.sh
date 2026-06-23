# shellcheck shell=bash
# Session cleanup for vibe-docker wrappers.
# Source this, then call: start_session_watchdog <container> <session_id> <parent_pid>
# and after docker exec: run_session_cleanup <container> <session_id>
#
# The watchdog monitors the parent PID. When it dies (terminal closed, host
# wrapper killed), the watchdog keeps retrying cleanup briefly so it can catch
# the session pidfile even when docker exec is still starting up.

_session_pidfile() {
  printf '/tmp/vibe-session-%s.pid' "$1"
}

# Spawn a backgrounded process in a new session, detached from the parent's
# controlling tty so it survives terminal close. macOS does not ship setsid(1),
# so fall back through python3 → perl → nohup. Stdio goes to /dev/null.
#
# Usage: _spawn_detached <bash_script> [args...]
# Inside <bash_script>, positional args start at $1 (with $0 being "sh").
_spawn_detached() {
  local script="$1"; shift
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$script" sh "$@" >/dev/null 2>&1 </dev/null &
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp("bash", ["bash", "-c", sys.argv[1], "sh"] + sys.argv[2:])
' "$script" "$@" >/dev/null 2>&1 </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
use POSIX qw(setsid);
eval { setsid(); };
exec("bash", "-c", $ARGV[0], "sh", @ARGV[1..$#ARGV]);
' "$script" "$@" >/dev/null 2>&1 </dev/null &
  else
    nohup bash -c "$script" sh "$@" >/dev/null 2>&1 </dev/null &
  fi
}

start_session_watchdog() {
  local container="$1" session_id="$2" parent_pid="$3" pidfile
  pidfile=$(_session_pidfile "$session_id")
  _spawn_detached '
    parent_pid="$1"
    container="$2"
    pidfile="$3"
    while kill -0 "$parent_pid" 2>/dev/null; do sleep 0.5; done
    for ((attempt = 0; attempt < 20; attempt++)); do
      if docker exec "$container" sh -c '"'"'
        f="$1"
        [ -f "$f" ] || exit 1
        pid=$(cat "$f")
        kill -HUP "$pid" 2>/dev/null
        rm -f "$f"
      '"'"' sh "$pidfile" 2>/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
  ' "$parent_pid" "$container" "$pidfile"
}

run_session_cleanup() {
  _do_session_cleanup "$@" || true
}

_do_session_cleanup() {
  local container="$1" session_id="$2" pidfile
  pidfile=$(_session_pidfile "$session_id")
  docker exec "$container" sh -c '
    f="$1"
    [ -f "$f" ] || exit 1
    pid=$(cat "$f")
    kill -HUP "$pid" 2>/dev/null
    rm -f "$f"
  ' sh "$pidfile" 2>/dev/null
}
