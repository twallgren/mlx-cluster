#!/bin/zsh
#
# reboot_cluster.zsh — reboot every node, wait for SSH, re-establish the ring
#
# A reboot is the only reliable way to release GPU-wired memory that a hung
# mlx_lm.server left behind (killing the process does not; see "Operating
# notes" in README.md). It is also the operation that invalidates the
# Thunderbolt interface mapping, so the two always belong together: reboot,
# wait, re-ring. Doing the first without the third leaves a cluster that
# initialises and passes collectives while point-to-point send/recv hangs.
#
# Usage:
#   reboot_cluster.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

SCRIPT_DIR="${0:A:h}"

# ---------- defaults ----------
HOSTS="ai-1,ai-2,ai-3"
SSH_USER="$USER"
WAIT_SECS=300
SKIP_RING=0
DRY_RUN=0

usage() {
  cat <<'EOF'
reboot_cluster.zsh [options]

Reboots every node, waits for each to answer SSH again, then re-runs
reconfigure_thunderbolt_ring.zsh because a reboot renumbers the Thunderbolt
interfaces. Exits non-zero if a node does not come back in time or the ring
fails to verify.

Requires a passwordless sudo rule for /sbin/reboot on each node. Nothing
here creates it — see "Passwordless sudo" in README.md.

Options:
  -H, --hosts LIST                    Comma-separated hostnames (default: ai-1,ai-2,ai-3)
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  --wait SECS                         How long to wait per node for SSH to come back
                                      (default: 300).
  --skip-ring                         Reboot and wait, but do not reconfigure the
                                      Thunderbolt ring afterwards. Only useful if you are
                                      about to reconfigure it yourself.
  --dry-run                           Print what would happen; reboot nothing.
  -h, --help                          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    --skip-ring) SKIP_RING=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

RECONFIGURE="$SCRIPT_DIR/reconfigure_thunderbolt_ring.zsh"
if (( ! SKIP_RING )) && [[ ! -x "$RECONFIGURE" ]]; then
  echo "ERROR: $RECONFIGURE not found or not executable." >&2
  exit 1
fi

HOST_LIST=("${(@s/,/)HOSTS}")
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

if (( DRY_RUN )); then
  for host in "${HOST_LIST[@]}"; do
    echo "[dry-run] ssh $SSH_USER@$host 'sudo -n reboot'"
  done
  echo "[dry-run] wait up to ${WAIT_SECS}s per node for SSH"
  (( SKIP_RING )) || echo "[dry-run] $RECONFIGURE -H $HOSTS -u $SSH_USER"
  exit 0
fi

echo "Rebooting ${#HOST_LIST[@]} node(s)..."
for host in "${HOST_LIST[@]}"; do
  # A reboot severs the connection mid-command, so a non-zero exit here is
  # expected and not a failure.
  ssh ${=SSH_OPTS} "$SSH_USER@$host" "sudo -n reboot" 2>&1
  echo "  $host: reboot issued"
done

echo "Waiting up to ${WAIT_SECS}s per node for SSH to come back..."
sleep 10
for host in "${HOST_LIST[@]}"; do
  deadline=$(( $(date +%s) + WAIT_SECS ))
  until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$SSH_USER@$host" "exit" 2>/dev/null; do
    if (( $(date +%s) > deadline )); then
      echo "ERROR: $host did not come back within ${WAIT_SECS}s" >&2
      exit 1
    fi
    sleep 5
  done
  echo "  $host is back up."
done

if (( SKIP_RING )); then
  echo
  echo "Skipping ring reconfiguration (--skip-ring)."
  echo "Run reconfigure_thunderbolt_ring.zsh before launching a model, or"
  echo "point-to-point send/recv will hang while collectives still pass."
  exit 0
fi

echo "Reconfiguring the Thunderbolt ring..."
exec "$RECONFIGURE" -H "$HOSTS" -u "$SSH_USER"
