#!/bin/zsh
#
# main.zsh — orchestrate cluster bring-up from the client machine
#
# Runs, in order:
#   1. distribute_keys.zsh   (client -> nodes, controller -> workers)
#   2. configure_node.zsh    (pushed to and run on each node over SSH)
#
# Prerequisite: SSH (Remote Login) already enabled on all nodes and
# reachable by hostname — see 00_manual_checklist.md.
#
# Usage:
#   main.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

SCRIPT_DIR="${0:A:h}"

# ---------- defaults ----------
HOSTS="ai-1.local,ai-2.local,ai-3.local"
SSH_USER="$USER"
PYTHON_VERSION="3.12"
VENV_PATH="\$HOME/mlx-env"
MLX_LM_VERSION=""
SKIP_KEYS=0
SKIP_CONFIGURE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
main.zsh [options]

Options:
  -H, --hosts LIST                    Comma-separated hostnames (default:
                                      ai-1.local,ai-2.local,ai-3.local)
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  --python-version VER                Homebrew python formula version (default: 3.12)
  --venv-path PATH                    Venv path, same on every node (default: ~/mlx-env)
  --mlx-lm-version VER                Pin mlx-lm to an exact version (default: latest)
  --skip-keys                         Skip the SSH key distribution phase
  --skip-configure                    Skip the per-node environment setup phase
  --dry-run                           Print what would happen; make no changes.
  -h, --help                          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --python-version) PYTHON_VERSION="$2"; shift 2 ;;
    --venv-path) VENV_PATH="$2"; shift 2 ;;
    --mlx-lm-version) MLX_LM_VERSION="$2"; shift 2 ;;
    --skip-keys) SKIP_KEYS=1; shift ;;
    --skip-configure) SKIP_CONFIGURE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

DRY_FLAG=""
(( DRY_RUN )) && DRY_FLAG="--dry-run"

HOST_LIST=("${(@s/,/)HOSTS}")

# ---------- Phase 1: SSH key distribution ----------
if (( ! SKIP_KEYS )); then
  echo "\n########## Phase 1: SSH key distribution ##########"
  "$SCRIPT_DIR/distribute_keys.zsh" --hosts "$HOSTS" --user "$SSH_USER" $DRY_FLAG
else
  echo "Skipping key distribution (--skip-keys)."
fi

# ---------- Phase 2: per-node environment setup ----------
if (( ! SKIP_CONFIGURE )); then
  echo "\n########## Phase 2: per-node environment setup ##########"
  for host in "${HOST_LIST[@]}"; do
    echo "\n== $host =="
    if (( DRY_RUN )); then
      echo "[dry-run] scp configure_node.zsh -> $SSH_USER@$host:/tmp/"
      echo "[dry-run] ssh $SSH_USER@$host run configure_node.zsh --python-version $PYTHON_VERSION --venv-path $VENV_PATH ${MLX_LM_VERSION:+--mlx-lm-version $MLX_LM_VERSION} --dry-run"
      continue
    fi
    scp -o ConnectTimeout=8 -q "$SCRIPT_DIR/configure_node.zsh" "$SSH_USER@$host:/tmp/configure_node.zsh"
    ssh -o ConnectTimeout=8 -t "$SSH_USER@$host" \
      "zsh /tmp/configure_node.zsh --python-version $PYTHON_VERSION --venv-path $VENV_PATH${MLX_LM_VERSION:+ --mlx-lm-version $MLX_LM_VERSION} && rm -f /tmp/configure_node.zsh"
  done
else
  echo "Skipping per-node configuration (--skip-configure)."
fi

cat <<'EOF'

Cluster bring-up finished.

Next, in order:

  1. At each node, in person: System Settings -> Privacy & Security ->
     Local Network -> enable your venv's Python. macOS silently blocks
     same-subnet connections from non-Apple-signed binaries, and the
     prompt cannot appear over SSH. Skipping this produces a generic
     connection failure later while ping and nc both report success,
     because those are Apple-signed and exempt.

  2. Install Tailscale on each node (interactive login, not scriptable).

  3. Cable the nodes into a physical Thunderbolt ring, then from the
     controller run:

       mlx.distributed_config --hosts <node>,<node>,<node> \
         --over thunderbolt --auto-setup --backend ring \
         --output-hostfile cluster.json

     This disables macOS's merged Thunderbolt Bridge and configures an
     isolated point-to-point link per cable. Do NOT assign static IPs to
     the Thunderbolt Bridge service instead: on a closed ring that is a
     bridging loop, since the bridge has no spanning-tree.

     Without passwordless sudo it prints the ifconfig/route commands per
     node rather than applying them; run each block yourself over
     `ssh -t`. Re-run this after EVERY reboot -- macOS renumbers the
     Thunderbolt interfaces, so a saved mapping goes stale silently.

  4. Verify, then start a model with switch_model.zsh.
EOF
