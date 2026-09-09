#!/bin/zsh
#
# reconfigure_thunderbolt_ring.zsh — restore the MLX Thunderbolt ring after a reboot
#
# macOS discards the point-to-point Thunderbolt IP configuration at reboot and
# may renumber the en* interfaces. This script asks mlx.distributed_config to
# rediscover the current topology, applies the per-node commands it prints via
# the cluster's command-specific NOPASSWD sudo rules, then verifies the exact
# MLX point-to-point traffic used by pipeline parallelism.
#
# Run from an admin/client machine that can SSH to the controller (normally
# via its Tailscale name). The controller itself must be able to SSH to the
# .local names in --hosts.

set -o pipefail
emulate -L zsh

CONTROLLER="ai-1"
HOSTS="ai-1.local,ai-2.local,ai-3.local"
SSH_USER="$USER"
VENV_PATH="~/mlx-env"
HOSTFILE="cluster.json"
VERIFY_SCRIPT="~/ring_sendrecv_test.py"
VERIFY=1
DRY_RUN=0

usage() {
  cat <<'EOF'
reconfigure_thunderbolt_ring.zsh [options]

Rediscovers and applies the MLX Thunderbolt point-to-point configuration
after a reboot, then verifies distributed point-to-point send/receive.

Options:
  --controller HOST                   Controller reachable from this machine (default: ai-1)
  -H, --hosts LIST                    Comma-separated controller-visible hostnames (default:
                                      ai-1.local,ai-2.local,ai-3.local)
  -u, --user NAME                     SSH username on every node (default: $USER)
  --venv-path PATH                    MLX virtualenv path on every node (default: ~/mlx-env)
  --hostfile PATH                     Hostfile path relative to the controller's home unless
                                      absolute (default: cluster.json)
  --verify-script PATH                Ring test path on the controller (default:
                                      ~/ring_sendrecv_test.py)
  --no-verify                         Configure only; do not run the MLX ring test
  --dry-run                           Print planned operations; make no changes
  -h, --help                          Show this help

The script expects command-specific passwordless sudo for /sbin/ifconfig and
/sbin/route. It uses sudo -n, so it fails safely rather than prompting.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --controller) CONTROLLER="$2"; shift 2 ;;
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --venv-path) VENV_PATH="$2"; shift 2 ;;
    --hostfile) HOSTFILE="$2"; shift 2 ;;
    --verify-script) VERIFY_SCRIPT="$2"; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "ERROR: unknown option: $1"; usage >&2; exit 1 ;;
  esac
done

HOST_LIST=("${(@s/,/)HOSTS}")
if (( ${#HOST_LIST} < 2 )) || [[ -z "$HOST_LIST[1]" ]]; then
  print -u2 "ERROR: --hosts must contain at least two comma-separated names."
  exit 1
fi

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
REMOTE_VENV="${VENV_PATH}/bin"
CONFIG_CMD="cd ~ && yes '' | ${REMOTE_VENV}/mlx.distributed_config --hosts ${HOSTS} --over thunderbolt --auto-setup --backend ring --output-hostfile ${HOSTFILE} --verbose"

if (( DRY_RUN )); then
  print "[dry-run] SSH to $SSH_USER@$CONTROLLER and run:"
  print "  $CONFIG_CMD"
  for host in "${HOST_LIST[@]}"; do
    print "[dry-run] extract $host's sudo ifconfig/route block and run it from $CONTROLLER"
  done
  (( VERIFY )) && print "[dry-run] run ${VERIFY_SCRIPT} through mlx.launch on $CONTROLLER"
  exit 0
fi

OUTPUT_FILE=$(mktemp -t mlx-thunderbolt-config.XXXXXX) || exit 1
trap 'rm -f "$OUTPUT_FILE"' EXIT

print "== Discovering current Thunderbolt topology from $CONTROLLER =="
if ! ssh ${SSH_OPTS} "$SSH_USER@$CONTROLLER" "$CONFIG_CMD" >"$OUTPUT_FILE" 2>&1; then
  cat "$OUTPUT_FILE" >&2
  print -u2 "ERROR: mlx.distributed_config failed; no node configuration was applied."
  exit 1
fi
cat "$OUTPUT_FILE"

# The tool's generic sudo probe does not recognize this cluster's
# command-specific NOPASSWD rules. Extract only its setup commands and invoke
# their absolute /sbin paths with sudo -n, which does match the allowlist.
strip_ansi() {
  sed $'s/\033\\[[0-9;]*[[:alpha:]]//g' "$1"
}

extract_block() {
  local host="$1"
  strip_ansi "$OUTPUT_FILE" | awk -v host="$host" '
    $0 == "Setup for " host { in_block = 1; found = 1; next }
    in_block && /^Setup for / { exit }
    in_block && /^sudo (ifconfig|route) / { print }
    END { if (!found) exit 2 }
  '
}

for host in "${HOST_LIST[@]}"; do
  block=$(extract_block "$host")
  block_status=$?

  if (( block_status == 2 )); then
    print "No manual setup block for $host. MLX may have applied it directly; leaving it unchanged."
    continue
  elif (( block_status != 0 )) || [[ -z "$block" ]]; then
    print -u2 "ERROR: no usable setup commands found for $host. Refusing to guess an interface mapping."
    exit 1
  fi

  safe_block=$(print -r -- "$block" | sed -E \
    -e 's/^sudo ifconfig /sudo -n \/sbin\/ifconfig /' \
    -e 's/^sudo route /sudo -n \/sbin\/route /')

  print "== Applying newly detected configuration on $host =="
  if ! print -r -- "$safe_block" | ssh ${SSH_OPTS} "$SSH_USER@$CONTROLLER" \
      "ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new $SSH_USER@$host 'zsh -s'"; then
    print -u2 "ERROR: configuration failed on $host; stopping before configuring later nodes."
    exit 1
  fi
done

if (( VERIFY )); then
  print "== Verifying MLX point-to-point ring traffic =="
  VERIFY_CMD="cd ~ && ${REMOTE_VENV}/mlx.launch --backend ring --hostfile ${HOSTFILE} -- ${REMOTE_VENV}/python ${VERIFY_SCRIPT}"
  ssh -tt ${SSH_OPTS} "$SSH_USER@$CONTROLLER" "$VERIFY_CMD"
else
  print "Configured. Verification skipped (--no-verify)."
fi
