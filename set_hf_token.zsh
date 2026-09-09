#!/bin/zsh
#
# set_hf_token.zsh — push a Hugging Face access token to every cluster node
#
# Writes to ~/.cache/huggingface/token on each node — the standard location
# huggingface_hub (and therefore mlx_lm/mlx.distributed_config) reads
# automatically, without needing HF_TOKEN set in every process's env. Avoids
# the "unauthenticated requests" rate limit that slows down model downloads.
#
# The token is never printed, logged, or typed into a chat by an assistant —
# it's read from your own shell (export HF_TOKEN=hf_xxx before running this,
# typed directly into your own terminal) or prompted for locally with hidden
# input if not already set.
#
# Get a token at https://huggingface.co/settings/tokens (read access is enough).
#
# Usage:
#   export HF_TOKEN=hf_xxx   # optional — prompted for if not set
#   set_hf_token.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
HOSTS="ai-1.local,ai-2.local,ai-3.local"
SSH_USER="$USER"
DRY_RUN=0

usage() {
  cat <<'EOF'
set_hf_token.zsh [options]

Reads the token from $HF_TOKEN if already exported in your shell, otherwise
prompts locally (hidden input). Never echoes or logs the token value.

Options:
  -H, --hosts LIST                    Comma-separated hostnames (default:
                                      ai-1.local,ai-2.local,ai-3.local)
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  --dry-run                           Print what would happen; make no changes; no token
                                      needed.
  -h, --help                          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

HOST_LIST=("${(@s/,/)HOSTS}")
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

if (( DRY_RUN )); then
  for host in "${HOST_LIST[@]}"; do
    echo "[dry-run] ssh $SSH_OPTS $SSH_USER@$host \"mkdir -p ~/.cache/huggingface && write token to ~/.cache/huggingface/token (chmod 600)\""
  done
  exit 0
fi

if [[ -z "$HF_TOKEN" ]]; then
  echo -n "Enter your Hugging Face token (hidden, from https://huggingface.co/settings/tokens): "
  read -s HF_TOKEN
  echo
fi

if [[ -z "$HF_TOKEN" ]]; then
  echo "ERROR: no token provided" >&2
  exit 1
fi

for host in "${HOST_LIST[@]}"; do
  echo "-- writing token to $host"
  if ssh ${=SSH_OPTS} "$SSH_USER@$host" "mkdir -p ~/.cache/huggingface && chmod 700 ~/.cache/huggingface && cat > ~/.cache/huggingface/token && chmod 600 ~/.cache/huggingface/token" <<< "$HF_TOKEN"; then
    echo "   OK"
  else
    echo "   WARNING: failed to write token to $host" >&2
  fi
done

unset HF_TOKEN
echo "\nDone. Verify on one node with:"
echo "  ssh $SSH_USER@ai-1.local '~/mlx-env/bin/python -c \"from huggingface_hub import whoami; print(whoami())\"'"
