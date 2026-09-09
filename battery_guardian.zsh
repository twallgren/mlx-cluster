#!/bin/zsh
#
# battery_guardian.zsh — kill AI processing on THIS node if its battery
# drops to or below a threshold
#
# Runs locally on a single cluster node — no SSH, no dependency on any
# other machine (including the admin client) being up or reachable. Meant
# to run continuously via launchd (see install_battery_guardian.zsh),
# surviving reboots and not caring whether anything else in the cluster
# is alive.
#
# Doesn't require "discharging" state to trigger — a node can show
# "charging" while still net-losing charge under heavy sustained compute
# load if the charger can't keep up (this is what happened to ai-1), so
# raw percentage is checked regardless of charge state.
#
# Usage:
#   battery_guardian.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
THRESHOLD=10
INTERVAL=30
ONCE=0
LOG_FILE="$HOME/battery_guardian.log"

usage() {
  cat <<'EOF'
battery_guardian.zsh [options]

Runs locally on ONE node — checks only this machine's battery, kills only
this machine's mlx.launch/mlx_lm.server processes. Deploy to every node
you want protected (see install_battery_guardian.zsh).

Options:
  -t, --threshold PCT                 Kill local processing if battery is <= this percent
                                      (default: 10). Checked regardless of
                                      charging/discharging state.
  -i, --interval SEC                  Poll interval in seconds (default: 30)
  --log FILE                          Event log path (default: ~/battery_guardian.log)
  --once                              Check once and exit (0 if above threshold, 1 if
                                      triggered) — for testing.
  -h, --help                          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--threshold) THRESHOLD="$2"; shift 2 ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

notify() {
  osascript -e "display notification \"$1\" with title \"Battery Guardian ($(hostname -s))\"" 2>/dev/null
}

read_battery_pct() {
  pmset -g batt | sed -n 2p | sed -E 's/.*[[:space:]]([0-9]+)%;.*/\1/'
}

kill_local_processing() {
  log "TRIGGERED — killing local mlx.launch/mlx_lm.server"
  pkill -f 'mlx_lm.server' >> "$LOG_FILE" 2>&1
  pkill -f 'mlx.launch' >> "$LOG_FILE" 2>&1
}

check_once() {
  local pct=""
  pct=$(read_battery_pct)
  if [[ -z "$pct" ]]; then
    log "WARNING: could not read battery"
    return 0
  fi
  if (( pct <= THRESHOLD )); then
    log "ALERT: battery at ${pct}% (threshold: ${THRESHOLD}%)"
    return 1
  fi
  return 0
}

if (( ONCE )); then
  if check_once; then
    echo "Battery above ${THRESHOLD}%."
    exit 0
  else
    kill_local_processing
    notify "Battery threshold hit — AI processing stopped on $(hostname -s)."
    exit 1
  fi
fi

log "battery_guardian started on $(hostname -s) — threshold=${THRESHOLD}% interval=${INTERVAL}s"
ALREADY_TRIGGERED=0
while true; do
  if check_once; then
    ALREADY_TRIGGERED=0
  else
    if (( ! ALREADY_TRIGGERED )); then
      kill_local_processing
      notify "Battery threshold hit — AI processing stopped on $(hostname -s)."
      ALREADY_TRIGGERED=1
    fi
  fi
  sleep "$INTERVAL"
done
