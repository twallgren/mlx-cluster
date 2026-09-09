#!/bin/zsh
#
# monitor_nodes.zsh — battery, CPU load, GPU load, and thermal state across
# the cluster nodes, refreshed in place
#
# CPU load/usage and battery are read without sudo. GPU load and exact
# temperatures need `powermetrics`, which macOS requires root for — this
# script tries `sudo -n` (fails instantly if no passwordless sudo is set
# up, never hangs waiting for a password) and shows "n/a" for those columns
# if unavailable, rather than blocking on a prompt.
#
# To get GPU/temperature data without a password prompt on every refresh,
# add a scoped NOPASSWD rule on each node (visudo, or a file under
# /etc/sudoers.d/): `your-username ALL=(ALL) NOPASSWD: /usr/bin/powermetrics`
#
# Usage:
#   monitor_nodes.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
HOSTS="ai-1,ai-2,ai-3"
SSH_USER="$USER"
INTERVAL=5
ONCE=0

usage() {
  cat <<'EOF'
monitor_nodes.zsh [options]

Options:
  -H, --hosts LIST                    Comma-separated hostnames (default: ai-1,ai-2,ai-3)
                                      Bare Tailscale names by default — works regardless of
                                      which network the client is on.
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  -i, --interval SEC                  Refresh interval in seconds (default: 5)
  --once                              Print one snapshot and exit (no refresh loop)
  -h, --help                          Show this help.

GPU load / temperature need passwordless sudo for `powermetrics` on each
node (see script header) — shown as "n/a" otherwise. Everything else
(battery, CPU load) works with no special setup.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

HOST_LIST=("${(@s/,/)HOSTS}")
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# One round-trip per node: battery, CPU load/usage, and a best-effort
# powermetrics sample (non-interactive sudo; instant no-op if unavailable).
REMOTE_CMD='
batt=$(pmset -g batt | sed -n 2p | sed -E "s/.*[[:space:]]([0-9]+%);[[:space:]]*([a-zA-Z ]+);.*/\1 \2/")
load=$(sysctl -n vm.loadavg | tr -d "{}")
cpu=$(top -l 1 -n 0 | grep "CPU usage" | sed -E "s/CPU usage: //")
pm=$(sudo -n powermetrics -n 1 -i 200 --samplers gpu_power,smc 2>/dev/null)
if [[ -n "$pm" ]]; then
  gpu=$(echo "$pm" | awk "/GPU active residency/{print \$4; exit}")
  temp=$(echo "$pm" | awk "/CPU die temperature/{print \$4\" \"\$5; exit}")
else
  gpu="n/a"
  temp="n/a"
fi
echo "BATT|$batt|LOAD|$load|CPU|$cpu|GPU|$gpu|TEMP|$temp"
'

render() {
  local -A results
  for host in "${HOST_LIST[@]}"; do
    results[$host]=$(ssh ${=SSH_OPTS} "$SSH_USER@$host" "$REMOTE_CMD" 2>/dev/null)
  done

  printf "%-8s %-14s %-20s %-28s %-10s %s\n" "NODE" "BATTERY" "LOAD (1/5/15m)" "CPU (user/sys/idle)" "GPU" "TEMP"
  for host in "${HOST_LIST[@]}"; do
    local line="${results[$host]}"
    if [[ -z "$line" ]]; then
      printf "%-8s %s\n" "$host" "unreachable"
      continue
    fi
    local batt=$(echo "$line" | sed -E 's/.*BATT\|([^|]*)\|LOAD.*/\1/')
    local load=$(echo "$line" | sed -E 's/.*LOAD\|([^|]*)\|CPU.*/\1/')
    local cpu=$(echo "$line" | sed -E 's/.*CPU\|([^|]*)\|GPU.*/\1/')
    local gpu=$(echo "$line" | sed -E 's/.*GPU\|([^|]*)\|TEMP.*/\1/')
    local temp=$(echo "$line" | sed -E 's/.*TEMP\|(.*)$/\1/')
    printf "%-8s %-14s %-20s %-28s %-10s %s\n" "$host" "$batt" "$load" "$cpu" "$gpu" "$temp"
  done
}

if (( ONCE )); then
  render
  exit 0
fi

# Redraw in place rather than clearing the screen.
FIRST=1
while true; do
  OUT=$(render)
  LINES=$(echo "$OUT" | wc -l | tr -d ' ')
  if (( ! FIRST )); then
    printf "\033[%dA" "$PREV_LINES"
  fi
  echo "$OUT" | while IFS= read -r line; do printf "\033[2K%s\n" "$line"; done
  PREV_LINES=$LINES
  FIRST=0
  sleep "$INTERVAL"
done
