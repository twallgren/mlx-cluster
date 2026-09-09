#!/bin/zsh
#
# run_on_all.zsh — run one command on every node, in sequence
#
# The workhorse behind most ad hoc cluster chores: checking a version,
# tailing a log, clearing a directory, restarting an app. Sequential rather
# than parallel on purpose, so the output stays attributable to a node and a
# command that prompts for sudo still works.
#
# Usage:
#   run_on_all.zsh [options] -- <command>
#   run_on_all.zsh [options] <command>
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
HOSTS="ai-1,ai-2,ai-3"
SSH_USER="$USER"
TTY_FLAG="-t"
CONTINUE_ON_ERROR=0
QUIET=0
DRY_RUN=0

usage() {
  cat <<'EOF'
run_on_all.zsh [options] -- <command>

Runs <command> on every node over SSH, one node at a time, and reports a
per-node exit status at the end. Everything after `--` is passed to the
remote shell verbatim, so quote it the way you would for `ssh`.

Options:
  -H, --hosts LIST                    Comma-separated hostnames (default: ai-1,ai-2,ai-3)
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  --no-tty                            Do not allocate a TTY. Use for commands whose output
                                      you want to pipe or capture; the default allocates one
                                      so interactive sudo prompts work.
  -k, --keep-going                    Keep going after a node fails (default: stop at the
                                      first failure).
  -q, --quiet                         Suppress the per-node banner; print only command
                                      output.
  --dry-run                           Print what would run on each node and exit.
  -h, --help                          Show this help.

Examples:
  run_on_all.zsh -- 'sw_vers -productVersion'
  run_on_all.zsh --no-tty -- '~/mlx-env/bin/python -c "import mlx; print(mlx.__version__)"'
  run_on_all.zsh -k -- 'pkill -f mlx_lm.server'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --no-tty) TTY_FLAG=""; shift ;;
    -k|--keep-going) CONTINUE_ON_ERROR=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) break ;;
  esac
done

REMOTE_CMD="$*"
if [[ -z "$REMOTE_CMD" ]]; then
  echo "ERROR: no command given." >&2
  usage >&2
  exit 1
fi

HOST_LIST=("${(@s/,/)HOSTS}")
typeset -A STATUS
FAILED=0

for host in "${HOST_LIST[@]}"; do
  (( QUIET )) || echo "== $host: $REMOTE_CMD"
  if (( DRY_RUN )); then
    echo "[dry-run] ssh ${TTY_FLAG} $SSH_USER@$host \"$REMOTE_CMD\""
    STATUS[$host]=0
    continue
  fi
  ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new ${=TTY_FLAG} "$SSH_USER@$host" "$REMOTE_CMD"
  rc=$?
  STATUS[$host]=$rc
  if (( rc != 0 )); then
    FAILED=1
    echo "ERROR: $host exited $rc" >&2
    (( CONTINUE_ON_ERROR )) || break
  fi
done

if (( ! QUIET )); then
  echo
  echo "Exit status by node:"
  for host in "${HOST_LIST[@]}"; do
    printf "  %-12s %s\n" "$host" "${STATUS[$host]:-not reached}"
  done
fi

exit $FAILED
