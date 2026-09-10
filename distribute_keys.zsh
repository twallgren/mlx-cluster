#!/bin/zsh
#
# distribute_keys.zsh — set up passwordless SSH for the cluster
#
# Two phases, both run from the client machine:
#   A. client -> every node (so main.zsh/configure_node.zsh can run without
#      password prompts).
#   B. controller node (ai-1) -> every worker node (required because
#      mlx.launch runs ON ai-1 and SSHes into ai-2/ai-3 itself — see the
#      guide's "Required conditions" section).
#
# Idempotent: ssh-copy-id skips keys already present; key generation on the
# controller is skipped if a key already exists there.
#
# Usage:
#   distribute_keys.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
HOSTS="ai-1.local,ai-2.local,ai-3.local"
SSH_USER="$USER"
CLIENT_KEY="$HOME/.ssh/id_ed25519.pub"
CONTROLLER=""          # empty = first host in HOSTS
PHASE_A=1
PHASE_B=1
DRY_RUN=0

usage() {
  cat <<'EOF'
distribute_keys.zsh [options]

Options:
  -H, --hosts LIST                    Comma-separated hostnames (default:
                                      ai-1.local,ai-2.local,ai-3.local) First host is the
                                      controller unless --controller is given.
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  -k, --client-key PATH               Client's public key to install on all nodes (default:
                                      ~/.ssh/id_ed25519.pub). Generated with ssh-keygen if
                                      missing.
  --controller HOST                   Which host is the MLX controller (default: first in
                                      --hosts)
  --client-only                       Only do phase A (client -> nodes)
  --controller-only                   Only do phase B (controller -> workers)
  --dry-run                           Print what would happen; make no changes.
  -h, --help                          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    -k|--client-key) CLIENT_KEY="$2"; shift 2 ;;
    --controller) CONTROLLER="$2"; shift 2 ;;
    --client-only) PHASE_B=0; shift ;;
    --controller-only) PHASE_A=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

run() {
  if (( DRY_RUN )); then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

# accept-new: auto-trust a host's SSH fingerprint on first contact (still
# rejects a CHANGED fingerprint, so it's not disabling verification, just
# the interactive first-contact prompt that breaks non-interactive scripts —
# this bit us testing ai-1 -> ai-2/ai-3, which had never connected before).
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

HOST_LIST=("${(@s/,/)HOSTS}")
[[ -z "$CONTROLLER" ]] && CONTROLLER="${HOST_LIST[1]}"
WORKERS=("${(@)HOST_LIST:#$CONTROLLER}")

echo "Controller: $CONTROLLER"
echo "Workers:    ${WORKERS[*]}"

# ---------- Phase A: client -> every node ----------
if (( PHASE_A )); then
  echo "\n== Phase A: client -> all nodes =="

  CLIENT_PRIVATE_KEY="${CLIENT_KEY%.pub}"
  if [[ ! -f "$CLIENT_KEY" ]]; then
    echo "No client key at $CLIENT_KEY — generating one..."
    run "ssh-keygen -t ed25519 -C 'ai-cluster-admin' -f $CLIENT_PRIVATE_KEY -N ''"
  fi

  for host in "${HOST_LIST[@]}"; do
    echo "-- ssh-copy-id -> $SSH_USER@$host"
    run "ssh-copy-id -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -i $CLIENT_KEY $SSH_USER@$host"
  done
fi

# ---------- Phase B: controller -> workers ----------
if (( PHASE_B )); then
  echo "\n== Phase B: $CONTROLLER -> workers (required by mlx.launch) =="

  if (( DRY_RUN )); then
    echo "[dry-run] check/generate ed25519 key on $CONTROLLER"
    CONTROLLER_PUBKEY="[dry-run: controller pubkey]"
  else
    CONTROLLER_KEY_CHECK="test -f ~/.ssh/id_ed25519 && echo present || echo missing"
    STATE=$(ssh ${=SSH_OPTS} "$SSH_USER@$CONTROLLER" "$CONTROLLER_KEY_CHECK" 2>/dev/null)

    if [[ "$STATE" == "missing" ]]; then
      echo "No key on $CONTROLLER — generating one there..."
      ssh ${=SSH_OPTS} "$SSH_USER@$CONTROLLER" "ssh-keygen -t ed25519 -C 'mlx-controller' -f ~/.ssh/id_ed25519 -N ''"
    else
      echo "$CONTROLLER already has an ed25519 key."
    fi

    CONTROLLER_PUBKEY=$(ssh ${=SSH_OPTS} "$SSH_USER@$CONTROLLER" "cat ~/.ssh/id_ed25519.pub")
  fi

  # Controller needs its own key in its own authorized_keys too — MLX
  # tooling (mlx.distributed_config, mlx.launch) treats the controller as
  # just another host in the list and SSHes to it, including to itself.
  INSTALL_TARGETS=("$CONTROLLER" "${WORKERS[@]}")

  for target in "${INSTALL_TARGETS[@]}"; do
    echo "-- installing $CONTROLLER's key on $target"
    if (( DRY_RUN )); then
      echo "[dry-run] ssh $SSH_OPTS $SSH_USER@$target \"mkdir -p ~/.ssh && ... >> ~/.ssh/authorized_keys\""
      continue
    fi
    if ! ssh ${=SSH_OPTS} "$SSH_USER@$target" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$CONTROLLER_PUBKEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$CONTROLLER_PUBKEY' >> ~/.ssh/authorized_keys"; then
      echo "WARNING: failed to install $CONTROLLER's key on $target (see error above)" >&2
    fi
  done

  echo "\n-- verifying $CONTROLLER can reach itself and each worker without a password --"
  for worker in "$CONTROLLER" "${WORKERS[@]}"; do
    if (( DRY_RUN )); then
      echo "[dry-run] ssh $CONTROLLER -> $worker check"
      continue
    fi
    # accept-new here covers ai-1's OWN first contact with each worker,
    # which is separate from the client's known_hosts entries above.
    if ssh ${=SSH_OPTS} "$SSH_USER@$CONTROLLER" "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $SSH_USER@$worker exit" 2>/dev/null; then
      echo "$CONTROLLER -> $worker: OK"
    else
      echo "$CONTROLLER -> $worker: FAILED (re-run with PHASE_B debug: ssh $CONTROLLER then 'ssh -v $worker' to see the real error)" >&2
    fi
  done
fi

echo "\nDone."
