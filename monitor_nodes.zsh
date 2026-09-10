#!/bin/zsh
#
# monitor_nodes.zsh — battery, CPU load, GPU load, and thermal state across
# the cluster nodes, refreshed in place
#
# CPU load/usage and battery are read without sudo. GPU residency and
# thermal pressure need `powermetrics`, which macOS requires root for — this
# script tries `sudo -n` (fails instantly if no passwordless sudo is set up,
# never hangs waiting for a password) rather than blocking on a prompt.
#
# THERMAL is a pressure level (Nominal/Fair/Serious/Critical), not a
# temperature: Apple silicon's powermetrics reports no die temperature. The
# pressure level is the more useful signal regardless, since it is what
# actually predicts throttling.
#
# "no-sudo" in those columns means the NOPASSWD rule below is missing;
# "n/a" means powermetrics ran but its output could not be parsed.
#
# To get GPU/thermal data without a password prompt on every refresh,
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

GPU residency and thermal pressure need passwordless sudo for
`powermetrics` on each node (see script header): "no-sudo" in those columns
means that rule is missing, "n/a" means powermetrics ran but could not be
parsed. THERMAL is a pressure level, not a temperature — Apple silicon
reports no die temperature. Battery and CPU load need no special setup.
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
# gpu_power + thermal. NOT "smc": that sampler does not exist on Apple
# silicon, and naming it makes powermetrics exit 64 without sampling
# anything at all, taking the GPU reading down with it.
#
# stderr is folded in so a sudo refusal can be told apart from a parse
# failure. Do not probe with `sudo -n true` instead: the NOPASSWD rule is
# scoped to powermetrics, so `true` is refused even when powermetrics is
# allowed, and every node reports a permission problem it does not have.
pm=$(sudo -n powermetrics -n 1 -i 200 --samplers gpu_power,thermal 2>&1)
if echo "$pm" | grep -q "password is required\|^sudo:"; then
  # Distinguished from "n/a" on purpose: this one you can fix.
  gpu="no-sudo"
  therm="no-sudo"
else
  # The field is "GPU HW active residency", not "GPU active residency", and
  # the percentage is the 5th field because "HW" shifts everything right.
  gpu=$(echo "$pm" | awk "/GPU HW active residency/{print \$5; exit}")
  # Apple silicon reports no die temperature here at all -- the thermal
  # sampler gives a pressure level (Nominal/Fair/Serious/Critical) instead,
  # which is the actual throttling signal you want anyway.
  therm=$(echo "$pm" | awk "/Current pressure level/{print \$4; exit}")
  [[ -z "$gpu" ]] && gpu="n/a"
  [[ -z "$therm" ]] && therm="n/a"
fi
echo "BATT|$batt|LOAD|$load|CPU|$cpu|GPU|$gpu|THERM|$therm"
'

render() {
  local -A results
  for host in "${HOST_LIST[@]}"; do
    results[$host]=$(ssh ${=SSH_OPTS} "$SSH_USER@$host" "$REMOTE_CMD" 2>/dev/null)
  done

  printf "%-8s %-14s %-20s %-36s %-10s %s\n" "NODE" "BATTERY" "LOAD (1/5/15m)" "CPU (user/sys/idle)" "GPU" "THERMAL"
  for host in "${HOST_LIST[@]}"; do
    local line="${results[$host]}"
    if [[ -z "$line" ]]; then
      printf "%-8s %s\n" "$host" "unreachable"
      continue
    fi
    local batt=$(echo "$line" | sed -E 's/.*BATT\|([^|]*)\|LOAD.*/\1/')
    local load=$(echo "$line" | sed -E 's/.*LOAD\|([^|]*)\|CPU.*/\1/')
    local cpu=$(echo "$line" | sed -E 's/.*CPU\|([^|]*)\|GPU.*/\1/')
    local gpu=$(echo "$line" | sed -E 's/.*GPU\|([^|]*)\|THERM.*/\1/')
    local therm=$(echo "$line" | sed -E 's/.*THERM\|(.*)$/\1/')
    printf "%-8s %-14s %-20s %-36s %-10s %s\n" "$host" "$batt" "$load" "$cpu" "$gpu" "$therm"
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
