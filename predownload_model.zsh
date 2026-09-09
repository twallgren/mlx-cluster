#!/bin/zsh
#
# predownload_model.zsh — download one model's snapshot on a single node,
# ready to distribute to the rest of the cluster afterward
#
# Downloads happen at MODEL-LOAD time, not sharding time, so downloading
# independently on all three nodes at once just splits one home internet
# connection three ways for no reason. This downloads ONCE on one node
# (default: ai-1) via a plain Python script (not through mlx.launch, which
# needs a healthy ring already) and launches it detached, since large
# models take a while.
#
# Once this finishes, distribute the model directory to the other nodes
# over the fast Thunderbolt link rather than re-downloading:
#   tb_link_addrs.zsh --from ai-1 --to ai-2 --rsync \
#     ~/.cache/huggingface/hub/models--ORG--NAME/ ~/.cache/huggingface/hub/models--ORG--NAME/
# (repeat --to for each other node; the two transfers can run in parallel
# since they're separate physical links)
#
# Usage:
#   predownload_model.zsh <repo-id> [options]
#   predownload_model.zsh mlx-community/GLM-4.5-Air-4bit
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

SCRIPT_DIR="${0:A:h}"

# ---------- defaults ----------
NODE="ai-1"
SSH_USER="$USER"
WAIT=1
WAIT_SECS=14400   # 4h ceiling for --wait on a very large model; override for bigger ones
REMOTE_SCRIPT_PATH='$HOME/predownload_model.py'

usage() {
  cat <<'EOF'
predownload_model.zsh <repo-id> [options]

Positional argument is a Hugging Face repo id, e.g.
mlx-community/GLM-4.5-Air-4bit.

Options:
  --node HOST                         Node to download on (default: ai-1)
  -u, --user NAME                     SSH username (default: $USER)
  --wait / --no-wait                  Block and tail progress until done, or return
                                      immediately after launching (default: --wait)
  --wait-secs N                       Max seconds to wait with --wait before giving up
                                      (still runs in the background on the node; default:
                                      14400 = 4h)
  -h, --help                          Show this help

Checks whether the model already looks fully downloaded before starting
(same check switch_model.zsh uses), so re-running this is a cheap no-op
once a download has completed.
EOF
}

REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --wait) WAIT=1; shift ;;
    --no-wait) WAIT=0; shift ;;
    --wait-secs) WAIT_SECS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      if [[ -z "$REPO" ]]; then
        REPO="$1"
      else
        echo "Unexpected extra argument: $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "ERROR: a Hugging Face repo id is required, e.g. mlx-community/GLM-4.5-Air-4bit" >&2
  usage
  exit 1
fi

SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
CACHE_DIR="~/.cache/huggingface/hub/models--${REPO//\//--}"
LOG_NAME="predownload_$(echo "$REPO" | tr '/' '_').log"

present=$(ssh ${=SSH_OPTS} "$SSH_USER@$NODE" "
  if find $CACHE_DIR -name '*.incomplete' 2>/dev/null | grep -q .; then echo incomplete; exit; fi
  if [[ -d $CACHE_DIR/snapshots ]] && find $CACHE_DIR/snapshots -name '*.safetensors' 2>/dev/null | grep -q .; then echo ready; exit; fi
  echo missing
")

if [[ "$present" == "ready" ]]; then
  echo "$REPO already fully downloaded on $NODE ($CACHE_DIR). Nothing to do."
  exit 0
fi
echo "Status on $NODE: $present. Starting download (snapshot_download resumes an incomplete one)..."

scp ${=SSH_OPTS} "$SCRIPT_DIR/node-scripts/predownload_model.py" "$SSH_USER@$NODE:predownload_model.py" >/dev/null

ssh ${=SSH_OPTS} "$SSH_USER@$NODE" \
  "cd ~ && nohup ~/mlx-env/bin/python $REMOTE_SCRIPT_PATH '$REPO' > ~/$LOG_NAME 2>&1 < /dev/null & disown; echo issued"

echo "Download launched on $NODE. Log: ~/$LOG_NAME"

if (( ! WAIT )); then
  echo "Not waiting (--no-wait) -- check progress with:"
  echo "  ssh $SSH_USER@$NODE 'tail -20 ~/$LOG_NAME'"
  exit 0
fi

echo -n "Waiting for completion (up to ${WAIT_SECS}s)"
elapsed=0
result=""
while (( elapsed < WAIT_SECS )); do
  sleep 10
  elapsed=$((elapsed + 10))
  echo -n "."
  result=$(ssh ${=SSH_OPTS} "$SSH_USER@$NODE" "grep -E 'DONE:|Traceback|Error' ~/$LOG_NAME 2>/dev/null | tail -1")
  [[ -n "$result" ]] && break
done
echo

if [[ -z "$result" ]]; then
  echo "TIMEOUT after ${WAIT_SECS}s -- still running in the background on $NODE. Check:"
  echo "  ssh $SSH_USER@$NODE 'tail -20 ~/$LOG_NAME'"
  exit 1
fi

if [[ "$result" != DONE:* ]]; then
  echo "FAILED: $result" >&2
  echo "Full log: ssh $SSH_USER@$NODE 'cat ~/$LOG_NAME'" >&2
  exit 1
fi

echo "$result"
echo ""
echo "Next: distribute to the other nodes over Thunderbolt, e.g."
echo "  tb_link_addrs.zsh --from $NODE --to ai-2 --rsync $CACHE_DIR/ $CACHE_DIR/"
