#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexUsageMonitor"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${CODEX_USAGE_APP_BUNDLE:-$ROOT_DIR/dist/$APP_NAME.app}"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
DURATION_SECONDS="${1:-180}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-5}"
CHILD_START_TIMEOUT_SECONDS="${CHILD_START_TIMEOUT_SECONDS:-20}"
MAX_RSS_GROWTH_KIB="${MAX_RSS_GROWTH_KIB:-131072}"
MAX_RSS_PEAK_KIB="${MAX_RSS_PEAK_KIB:-524288}"
MAX_FD_GROWTH="${MAX_FD_GROWTH:-16}"
MAX_FD_PEAK="${MAX_FD_PEAK:-256}"
REPORT="${CODEX_USAGE_RESOURCE_REPORT:-$ROOT_DIR/work/resource-check.csv}"
APP_PID=""
CHILD_PID=""
OBSERVED_CHILD_PIDS=""

pid_is_test_app() {
  local pid="$1"
  local command
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == "$APP_BINARY" ]]
}

pid_is_app_server() {
  local pid="$1"
  local command
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" =~ codex[[:space:]]app-server[[:space:]]--stdio$ ]]
}

find_app_pids() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if pid_is_test_app "$pid"; then
      echo "$pid"
    fi
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)
}

wait_for_test_app_exit() {
  local pid="$1"
  local attempt
  for attempt in {1..80}; do
    pid_is_test_app "$pid" || return 0
    sleep 0.1
  done
  return 1
}

stop_test_app_pid() {
  local pid="$1"
  pid_is_test_app "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  if wait_for_test_app_exit "$pid"; then
    return 0
  fi
  if pid_is_test_app "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait_for_test_app_exit "$pid"
}

stop_existing_test_apps() {
  local pid pids
  pids="$(find_app_pids)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    stop_test_app_pid "$pid" || {
      echo "Unable to stop pre-existing test app PID $pid." >&2
      return 1
    }
  done <<<"$pids"
}

capture_single_new_app_pid() {
  local attempt count pid pids
  for attempt in {1..100}; do
    pids="$(find_app_pids)"
    count="$(printf '%s\n' "$pids" | awk 'NF { count += 1 } END { print count + 0 }')"
    if (( count == 1 )); then
      pid="$(printf '%s\n' "$pids" | awk 'NF { print; exit }')"
      echo "$pid"
      return 0
    fi
    if (( count > 1 )); then
      echo "Expected one new test instance, found $count." >&2
      return 1
    fi
    sleep 0.1
  done
  return 1
}

app_server_child_pids() {
  ps -axo pid=,ppid=,command= |
    awk -v parent="$APP_PID" '
      $2 == parent && $0 ~ /codex app-server --stdio$/ { print $1 }
    '
}

remember_child_pids() {
  local pid
  for pid in "$@"; do
    [[ -n "$pid" ]] || continue
    case " $OBSERVED_CHILD_PIDS " in
      *" $pid "*) ;;
      *) OBSERVED_CHILD_PIDS="${OBSERVED_CHILD_PIDS:+$OBSERVED_CHILD_PIDS }$pid" ;;
    esac
  done
}

wait_for_initial_child() {
  local deadline child_count child_pids
  deadline=$((SECONDS + CHILD_START_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    pid_is_test_app "$APP_PID" || return 1
    child_pids="$(app_server_child_pids)"
    child_count="$(printf '%s\n' "$child_pids" | awk 'NF { count += 1 } END { print count + 0 }')"
    if (( child_count > 1 )); then
      remember_child_pids $child_pids
      echo "Observed $child_count app-server children during startup." >&2
      return 1
    fi
    if (( child_count == 1 )); then
      CHILD_PID="$(printf '%s\n' "$child_pids" | awk 'NF { print; exit }')"
      remember_child_pids "$CHILD_PID"
      return 0
    fi
    sleep 0.1
  done
  echo "No app-server child appeared within $CHILD_START_TIMEOUT_SECONDS seconds." >&2
  return 1
}

wait_for_observed_children_exit() {
  local attempt pid still_running
  for attempt in {1..50}; do
    still_running=0
    for pid in $OBSERVED_CHILD_PIDS; do
      if pid_is_app_server "$pid"; then
        still_running=1
        break
      fi
    done
    (( still_running == 0 )) && return 0
    sleep 0.1
  done
  return 1
}

force_cleanup() {
  local pid pids
  if [[ -n "$APP_PID" ]] && pid_is_test_app "$APP_PID"; then
    stop_test_app_pid "$APP_PID" || true
  fi
  pids="$(find_app_pids)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    stop_test_app_pid "$pid" || true
  done <<<"$pids"
  for pid in $OBSERVED_CHILD_PIDS; do
    if pid_is_app_server "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in {1..20}; do
        pid_is_app_server "$pid" || break
        sleep 0.1
      done
      if pid_is_app_server "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
  done
}
trap force_cleanup EXIT INT TERM

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 2
fi
if ! [[ "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || (( DURATION_SECONDS < 1 )); then
  echo "Duration must be a positive number of seconds." >&2
  exit 2
fi
for numeric_value in \
  "$SAMPLE_SECONDS" \
  "$CHILD_START_TIMEOUT_SECONDS" \
  "$MAX_RSS_GROWTH_KIB" \
  "$MAX_RSS_PEAK_KIB" \
  "$MAX_FD_GROWTH" \
  "$MAX_FD_PEAK"; do
  if ! [[ "$numeric_value" =~ ^[0-9]+$ ]]; then
    echo "Sampling intervals and thresholds must be non-negative integers." >&2
    exit 2
  fi
done
if (( SAMPLE_SECONDS < 1 || CHILD_START_TIMEOUT_SECONDS < 1 )); then
  echo "Sampling interval and child startup timeout must be positive." >&2
  exit 2
fi

mkdir -p "$(dirname "$REPORT")"
stop_existing_test_apps
if [[ -n "$(find_app_pids)" ]]; then
  echo "A matching test app is still running before launch." >&2
  exit 1
fi
/usr/bin/open -n "$APP_BUNDLE"
APP_PID="$(capture_single_new_app_pid || true)"
if [[ -z "$APP_PID" ]]; then
  echo "Exactly one new app did not launch from the expected bundle." >&2
  exit 1
fi
if ! wait_for_initial_child; then
  exit 1
fi

echo "timestamp,pid,cpu_percent,rss_kib,open_fds,app_server_child_pid" >"$REPORT"
deadline=$((SECONDS + DURATION_SECONDS))
first_rss=""
last_rss=""
peak_rss=0
first_fds=""
last_fds=""
peak_fds=0
while (( SECONDS < deadline )); do
  pid_is_test_app "$APP_PID" || {
    echo "The app exited during the resource check." >&2
    exit 1
  }

  read -r cpu rss < <(ps -p "$APP_PID" -o %cpu=,rss=)
  rss="${rss//[[:space:]]/}"
  fds="$(lsof -p "$APP_PID" 2>/dev/null | wc -l | tr -d ' ')"
  child_pids="$(app_server_child_pids)"
  child_count="$(printf '%s\n' "$child_pids" | awk 'NF { count += 1 } END { print count + 0 }')"
  remember_child_pids $child_pids
  if (( child_count != 1 )); then
    echo "Expected exactly 1 app-server child, observed $child_count." >&2
    exit 1
  fi
  current_child_pid="$(printf '%s\n' "$child_pids" | awk 'NF { print; exit }')"
  if [[ "$current_child_pid" != "$CHILD_PID" ]]; then
    echo "app-server PID changed from $CHILD_PID to $current_child_pid." >&2
    exit 1
  fi

  [[ -n "$first_rss" ]] || first_rss="$rss"
  [[ -n "$first_fds" ]] || first_fds="$fds"
  last_rss="$rss"
  last_fds="$fds"
  (( rss > peak_rss )) && peak_rss="$rss"
  (( fds > peak_fds )) && peak_fds="$fds"
  printf '%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP_PID" "$cpu" "$rss" "$fds" "$CHILD_PID" \
    >>"$REPORT"
  sleep "$SAMPLE_SECONDS"
done

rss_growth=$((last_rss - first_rss))
fd_growth=$((last_fds - first_fds))
echo "RSS KiB: first=$first_rss last=$last_rss peak=$peak_rss growth=$rss_growth"
echo "Open FDs: first=$first_fds last=$last_fds peak=$peak_fds growth=$fd_growth"

if ! stop_test_app_pid "$APP_PID"; then
  echo "FAIL: app PID $APP_PID did not exit within the bounded shutdown wait." >&2
  exit 1
fi
if ! wait_for_observed_children_exit; then
  echo "FAIL: an observed app-server child survived after the app exited." >&2
  exit 1
fi
APP_PID=""
CHILD_PID=""

if (( rss_growth > MAX_RSS_GROWTH_KIB )); then
  echo "FAIL: RSS growth $rss_growth KiB exceeds $MAX_RSS_GROWTH_KIB KiB." >&2
  exit 1
fi
if (( peak_rss > MAX_RSS_PEAK_KIB )); then
  echo "FAIL: peak RSS $peak_rss KiB exceeds $MAX_RSS_PEAK_KIB KiB." >&2
  exit 1
fi
if (( fd_growth > MAX_FD_GROWTH )); then
  echo "FAIL: file descriptor growth $fd_growth exceeds $MAX_FD_GROWTH." >&2
  exit 1
fi
if (( peak_fds > MAX_FD_PEAK )); then
  echo "FAIL: peak file descriptors $peak_fds exceeds $MAX_FD_PEAK." >&2
  exit 1
fi

echo "PASS: one stable app-server child, bounded RSS/FD usage, and no orphan after shutdown. Report: $REPORT"
