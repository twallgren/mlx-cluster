#!/bin/zsh
#
# deploy_mlx_patch.zsh — push a local, hand-patched mlx/mlx-lm source file
# out to the cluster nodes' installed venv (site-packages), since `mlx`
# core is a plain pip wheel there (not an editable git install) and picks
# up changes only by directly overwriting the installed .py file.
#
# Locates the destination path on each node by asking that node's own
# Python which file it actually imports (`python -c "import <module>;
# print(<module>.__file__)"`), rather than hardcoding a python3.NN version
# path, so a future Python upgrade on a node doesn't silently break this.
#
# Usage:
#   deploy_mlx_patch.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
HOSTS="ai-1,ai-2,ai-3"
SSH_USER="$USER"
SRC_FILE="$HOME/Documents/code/mlx/python/mlx/nn/layers/distributed.py"
MODULE="mlx.nn.layers.distributed"
VENV_PATH="mlx-env"
DRY_RUN=0
NO_BACKUP=0

usage() {
  cat <<'EOF'
deploy_mlx_patch.zsh [options]

Copies a local source file to the matching installed-package path on each
cluster node and verifies it still imports cleanly. Defaults to the
uneven-tensor-parallel-sharding patch to mlx.nn.layers.distributed.

Options:
  -H, --hosts LIST                    Comma-separated hostnames (default: ai-1,ai-2,ai-3)
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  -f, --file PATH                     Local file to deploy (default:
                                      ~/Documents/code/mlx/python/mlx/nn/layers/distributed.py)
  -m, --module NAME                   Python module path used to locate the destination on
                                      each node, e.g. mlx.nn.layers.distributed (default:
                                      mlx.nn.layers.distributed)
  --venv NAME                         Venv directory name under the remote home dir
                                      (default: mlx-env)
  --no-backup                         Skip timestamped backup of the file being replaced
  --dry-run                           Show what would happen; make no changes
  -h, --help                          Show this help

What it does per node:
  1. Resolves the destination path via the node's own Python
     (import <module>; print(<module>.__file__)) so it always matches
     that node's actual Python version and install layout.
  2. Backs up the existing file to <dest>.bak.<timestamp> (unless
     --no-backup).
  3. Copies the local file over via scp.
  4. Re-imports the module on the node to confirm it's still valid
     Python and importable before moving on to the next node.

This only replaces the file — it does NOT restart any running
mlx_lm.server process. A long-running server has already loaded the old
module into memory; restart it manually (see monitor_nodes.zsh /
switch_model.zsh) to pick up the change.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    -f|--file) SRC_FILE="$2"; shift 2 ;;
    -m|--module) MODULE="$2"; shift 2 ;;
    --venv) VENV_PATH="$2"; shift 2 ;;
    --no-backup) NO_BACKUP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ! -f "$SRC_FILE" ]]; then
  echo "Local file not found: $SRC_FILE" >&2
  exit 1
fi

if ! python3 -m py_compile "$SRC_FILE" 2>/tmp/deploy_mlx_patch_compile_err; then
  echo "Local file fails to compile as Python -- not deploying:" >&2
  cat /tmp/deploy_mlx_patch_compile_err >&2
  rm -f /tmp/deploy_mlx_patch_compile_err
  exit 1
fi
rm -f /tmp/deploy_mlx_patch_compile_err

HOST_LIST=("${(@s/,/)HOSTS}")
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
PY="\$HOME/$VENV_PATH/bin/python"
STAMP=$(date +%Y%m%d%H%M%S)

echo "Deploying $SRC_FILE"
echo "  module:  $MODULE"
echo "  hosts:   ${HOST_LIST[*]}"
echo ""

FAILED=()
for host in "${HOST_LIST[@]}"; do
  echo "== $host =="

  DEST=$(ssh ${=SSH_OPTS} "$SSH_USER@$host" \
    "$PY -c \"import $MODULE as m; print(m.__file__)\"" 2>/tmp/deploy_mlx_patch_resolve_err)
  if [[ -z "$DEST" ]]; then
    echo "  FAILED to resolve destination path:" >&2
    cat /tmp/deploy_mlx_patch_resolve_err >&2
    FAILED+=("$host")
    continue
  fi
  echo "  destination: $DEST"

  if (( DRY_RUN )); then
    echo "  [dry-run] would back up to ${DEST}.bak.$STAMP and copy $SRC_FILE over it"
    continue
  fi

  if (( ! NO_BACKUP )); then
    if ! ssh ${=SSH_OPTS} "$SSH_USER@$host" "cp '$DEST' '${DEST}.bak.$STAMP'"; then
      echo "  FAILED to create backup -- skipping this host" >&2
      FAILED+=("$host")
      continue
    fi
    echo "  backed up existing file to ${DEST}.bak.$STAMP"
  fi

  # scp to a temp path in the same directory, then rename into place --
  # `mv` within one filesystem is atomic, so a dropped connection mid-
  # transfer leaves the temp file corrupted, never the real destination
  # (a direct `scp` straight to $DEST would risk leaving a truncated file
  # at the real path if the transfer were interrupted).
  TMP_DEST="${DEST}.tmp.$STAMP"
  if ! scp ${=SSH_OPTS} "$SRC_FILE" "$SSH_USER@$host:$TMP_DEST" >/dev/null; then
    echo "  FAILED to copy file" >&2
    ssh ${=SSH_OPTS} "$SSH_USER@$host" "rm -f '$TMP_DEST'" 2>/dev/null
    FAILED+=("$host")
    continue
  fi
  if ! ssh ${=SSH_OPTS} "$SSH_USER@$host" "mv '$TMP_DEST' '$DEST'"; then
    echo "  FAILED to move new file into place" >&2
    ssh ${=SSH_OPTS} "$SSH_USER@$host" "rm -f '$TMP_DEST'" 2>/dev/null
    FAILED+=("$host")
    continue
  fi

  if ! ssh ${=SSH_OPTS} "$SSH_USER@$host" "$PY -c \"import $MODULE\"" 2>/tmp/deploy_mlx_patch_verify_err; then
    echo "  FAILED post-copy import check -- restoring backup" >&2
    cat /tmp/deploy_mlx_patch_verify_err >&2
    if (( ! NO_BACKUP )); then
      ssh ${=SSH_OPTS} "$SSH_USER@$host" "cp '${DEST}.bak.$STAMP' '$DEST'"
      echo "  restored previous version" >&2
    fi
    FAILED+=("$host")
    continue
  fi

  echo "  OK -- copied and re-imports cleanly"
done
rm -f /tmp/deploy_mlx_patch_resolve_err /tmp/deploy_mlx_patch_verify_err

echo ""
if (( ${#FAILED[@]} > 0 )); then
  echo "Failed on: ${FAILED[*]}" >&2
  exit 1
fi

if (( ! DRY_RUN )); then
  echo "Deployed to all hosts. Restart any running mlx_lm.server on these"
  echo "nodes to pick up the change (a running server has the old module"
  echo "already loaded in memory)."
fi
