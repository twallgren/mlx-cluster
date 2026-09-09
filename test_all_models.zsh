#!/bin/zsh
#
# test_all_models.zsh — switch through every known model alias one at a
# time, confirm each one comes up and answers correctly, and report a
# rough throughput/memory summary for each.
#
# Composes switch_model.zsh rather than re-implementing launch/download/
# health-check logic: this script's job is only to iterate the registry,
# add a throughput-measuring request, and collect results into one table.
#
# Usage:
#   test_all_models.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
SCRIPT_DIR="${0:A:h}"
SWITCH="$SCRIPT_DIR/switch_model.zsh"
REBOOT_CLUSTER="$SCRIPT_DIR/reboot_cluster.zsh"
HOSTS="ai-1,ai-2,ai-3"
SSH_USER="$USER"
CONTROLLER="ai-1"
PORT=18080
WAIT_SECS=300
ONLY=""
SKIP=""
PROMPT="Count from 1 to 40, one number per line, nothing else."
MAX_TOKENS=200
OUT_FILE=""
LEAVE_RUNNING=0
BOTH_MODES=0
NO_RECOVER=0
REBOOT_WAIT_SECS=240
CURL_MAX_TIME=120
RECOVERIES=0

usage() {
  cat <<'EOF'
test_all_models.zsh [options]

Switches through every model alias known to switch_model.zsh (one at a
time), waits for each to come up, sends a longer completion request to
measure rough throughput, and reports per-node memory from
switch_model.zsh --status. Prints a final summary table; each model's own
launch failure is recorded and does NOT stop the run.

Options:
  --only LIST                         Comma-separated aliases to test (default: all known
                                      aliases, from `switch_model.zsh --list`)
  --skip LIST                         Comma-separated aliases to exclude
  -H, --hosts LIST                    Comma-separated hostnames (default: ai-1,ai-2,ai-3)
  -u, --user NAME                     SSH username (default: $USER)
  --port PORT                         Server port (default: 18080)
  --wait SECS                         Max seconds to wait for each model to come up before
                                      marking it FAILED (default: 300 -- the largest models
                                      take several minutes)
  --prompt TEXT                       Throughput-test prompt (default: a count-to-40
                                      request, since a deterministic-length answer gives a
                                      stable tokens/sec estimate)
  --max-tokens N                      Max tokens for the throughput-test request (default:
                                      200)
  --out FILE                          Also write the summary table to this file (default:
                                      stdout only)
  --leave-running                     Don't stop the server after the last model (default:
                                      stop at the end, leaving the cluster idle)
  --both-modes                        For every alias registered as pipeline or tensor, test
                                      it in BOTH modes (forcing the non-default one via
                                      switch_model.zsh --mode) so tok/s is directly
                                      comparable. Aliases registered as standalone are
                                      unaffected -- there's no pipeline/tensor equivalent to
                                      compare.
  --no-recover                        Don't reboot on a detected hang (see below) -- just
                                      record the failure and move on. Use this if the
                                      cluster is also doing something else during the run.
  --reboot-wait SECS                  Max seconds to wait for a node to come back after a
                                      recovery reboot (default: 240)
  -h, --help                          Show this help

A hung mlx_lm.server, once killed, can leave wired GPU memory stuck until
the machine reboots (see "Operating notes" in README.md). A launch that never
comes up within --wait, or a throughput-test request that times out, is treated as
a hang: unless --no-recover, this reboots every node, waits for SSH to
come back, re-runs reconfigure_thunderbolt_ring.zsh (a reboot renumbers
the Thunderbolt interfaces), and retries that one task once before giving
up on it. Recoveries triggered are counted in the final summary.

Requires jq (already installed on the client and all three nodes).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --skip) SKIP="$2"; shift 2 ;;
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --leave-running) LEAVE_RUNNING=1; shift ;;
    --both-modes) BOTH_MODES=1; shift ;;
    --no-recover) NO_RECOVER=1; shift ;;
    --reboot-wait) REBOOT_WAIT_SECS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# (recovery reboots + re-rings via reboot_cluster.zsh, checked below)

if [[ ! -x "$SWITCH" ]]; then
  echo "Expected switch_model.zsh next to this script at: $SWITCH" >&2
  exit 1
fi
if (( ! NO_RECOVER )) && [[ ! -x "$REBOOT_CLUSTER" ]]; then
  echo "Expected reboot_cluster.zsh next to this script at: $REBOOT_CLUSTER (or pass --no-recover)" >&2
  exit 1
fi
if ! command -v jq >/dev/null; then
  echo "jq is required (found on client and all nodes as of this writing) but not on PATH here." >&2
  exit 1
fi

SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

# A hung mlx_lm.server, once killed (which switch_model.zsh does when
# moving to the next task), can leave wired GPU memory stuck until the node
# reboots -- see "Operating notes" in README.md. reboot_cluster.zsh does the
# whole recovery: reboot every node, wait for SSH, and re-run the ring
# reconfiguration that a reboot invalidates. Returns non-zero if any node
# does not come back or the ring fails to verify.
recover_cluster() {
  echo ">>> Hang detected -- rebooting all nodes to clear stuck wired memory <<<"
  RECOVERIES=$((RECOVERIES + 1))
  "$REBOOT_CLUSTER" -H "$HOSTS" -u "$SSH_USER" --wait "$REBOOT_WAIT_SECS"
}

# Registry aliases come from switch_model.zsh itself (single source of
# truth) -- header/footer lines are skipped by requiring the first column
# to be non-blank and the line to start with two leading spaces.
ALL_ALIASES=()
typeset -A ALIAS_MODE
while IFS= read -r line; do
  [[ "$line" == "  "[^\ ]* ]] || continue
  alias_name=$(echo "$line" | awk '{print $1}')
  ALL_ALIASES+=("$alias_name")
  ALIAS_MODE[$alias_name]=$(echo "$line" | awk '{print $3}')
done < <("$SWITCH" --list)

if [[ -n "$ONLY" ]]; then
  ALIASES=("${(@s/,/)ONLY}")
else
  ALIASES=("${ALL_ALIASES[@]}")
fi
if [[ -n "$SKIP" ]]; then
  SKIP_LIST=("${(@s/,/)SKIP}")
  FILTERED=()
  for a in "${ALIASES[@]}"; do
    if [[ ! " ${SKIP_LIST[*]} " == *" $a "* ]]; then
      FILTERED+=("$a")
    fi
  done
  ALIASES=("${FILTERED[@]}")
fi

if (( ${#ALIASES[@]} == 0 )); then
  echo "No aliases to test (check --only/--skip against: ${ALL_ALIASES[*]})" >&2
  exit 1
fi

# Each task is "alias:mode". Normally one task per alias, in its registered
# mode. With --both-modes, an alias registered as pipeline or tensor gets
# two tasks (one per mode, the non-default one forced via switch_model.zsh
# --mode) so tok/s is directly comparable; standalone aliases have no
# pipeline/tensor equivalent and are left as a single task.
TASKS=()
for a in "${ALIASES[@]}"; do
  reg_mode="${ALIAS_MODE[$a]:-}"
  if (( BOTH_MODES )) && [[ "$reg_mode" == "pipeline" || "$reg_mode" == "tensor" ]]; then
    # Braces are required here: zsh applies history-style modifiers
    # (e.g. ":t" for tail) to a *bare* $name followed by ":letter", so
    # unbraced "$a:tensor" silently becomes "${a:t}ensor" instead of the
    # literal string "$a:tensor".
    TASKS+=("${a}:pipeline" "${a}:tensor")
  else
    TASKS+=("${a}:${reg_mode}")
  fi
done

echo "Testing ${#TASKS[@]} run(s) across ${#ALIASES[@]} model(s): ${ALIASES[*]}"
echo ""

# Rows collected as pipe-delimited strings for the final summary table.
RESULTS=()

# A model architecture that simply never implemented a mode (e.g. Qwen2's
# shard() but no pipeline()) fails deterministically on the first generate
# call, in a background thread that never signals the HTTP layer -- so the
# request hangs exactly like a real memory-leak hang would, but a reboot
# will never fix it and retrying wastes a full reboot cycle. Check the
# model's own log for that specific, known error text before concluding
# "hang".
check_unsupported_mode() {
  local node="$1" repo="$2" log_name
  log_name="switch_$(echo "$repo" | tr '/' '_').log"
  ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$SSH_USER@$node" \
    "grep -oE 'does not support (pipelining|tensor parallelism|any sharding)' ~/$log_name 2>/dev/null | head -1"
}

# Runs one (alias, forced_mode) task. Sets TASK_ROW to the pipe-delimited
# summary row and returns 0 (OK), 1 (a real failure -- don't bother
# retrying), or 2 (looks like a hang: launch never came up, or the
# throughput request timed out).
run_task() {
  local alias="$1" forced_mode="$2"
  local -a MODE_ARGS
  [[ -n "$forced_mode" ]] && MODE_ARGS=(--mode "$forced_mode")

  local switch_out switch_status repo mode node
  switch_out=$("$SWITCH" "$alias" "${MODE_ARGS[@]}" -H "$HOSTS" -u "$SSH_USER" --port "$PORT" --wait "$WAIT_SECS" --no-test 2>&1)
  switch_status=$?
  echo "$switch_out"

  repo=$(echo "$switch_out" | grep -oE '^Model:  .*' | sed 's/^Model:  //')
  mode=$(echo "$switch_out" | grep -oE '^Mode:   .*' | sed 's/^Mode:   //')
  node=$(echo "$switch_out" | grep -oE '^Node:   .*' | sed 's/^Node:   //')
  [[ -z "$node" ]] && node="$CONTROLLER"

  if (( switch_status != 0 )); then
    if [[ "$switch_out" == *"TIMEOUT after"* ]]; then
      TASK_ROW="$alias|${repo:-?}|${mode:-?}|FAILED|-|-|never came up -- possible hang, see log above"
      return 2
    fi
    TASK_ROW="$alias|${repo:-?}|${mode:-?}|FAILED|-|-|see log above"
    return 1
  fi

  echo "Sending throughput-test request to $node..."
  local req_json timing elapsed resp completion_tokens content note curl_exit
  req_json=$(jq -nc --arg p "$PROMPT" --argjson mt "$MAX_TOKENS" \
    '{messages:[{role:"user",content:$p}],max_tokens:$mt}')
  timing=$(ssh ${=SSH_OPTS} "$SSH_USER@$node" "
    start=\$(date +%s.%N)
    resp=\$(curl -s --max-time $CURL_MAX_TIME -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d '$req_json')
    curl_exit=\$?
    end=\$(date +%s.%N)
    echo -E \"ELAPSED:\$(echo \"\$end - \$start\" | bc)\"
    echo -E \"CURLEXIT:\$curl_exit\"
    echo -E \"RESP:\$resp\"
  ")
  elapsed=$(echo -E "$timing" | grep '^ELAPSED:' | sed 's/^ELAPSED://')
  curl_exit=$(echo -E "$timing" | grep '^CURLEXIT:' | sed 's/^CURLEXIT://')
  resp=$(echo -E "$timing" | grep '^RESP:' | sed 's/^RESP://')

  # curl exit 28 = --max-time hit: the request itself hung, not just a
  # slow-but-completing response.
  if [[ "$curl_exit" == "28" ]]; then
    local unsupported_reason
    unsupported_reason=$(check_unsupported_mode "$node" "$repo")
    if [[ -n "$unsupported_reason" ]]; then
      echo "Not a hang -- the model's log shows: $unsupported_reason"
      TASK_ROW="$alias|${repo:-?}|${mode:-?}|NOT_SUPPORTED|-|-|$unsupported_reason"
      return 1
    fi
    echo "Throughput request timed out after ${CURL_MAX_TIME}s."
    TASK_ROW="$alias|${repo:-?}|${mode:-?}|FAILED|-|-|request timed out -- possible hang"
    return 2
  fi

  completion_tokens=$(echo -E "$resp" | jq -r '.usage.completion_tokens // empty' 2>/dev/null)
  content=$(echo -E "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

  note=""
  if [[ -z "$content" ]]; then
    # Reasoning models can spend the whole token budget on .reasoning,
    # leaving .content null -- that's a slow response, not a broken one.
    content=$(echo -E "$resp" | jq -r '.choices[0].message.reasoning // empty' 2>/dev/null)
    [[ -n "$content" ]] && note="reasoning-only response; raise --max-tokens to see a final answer"
  fi

  if [[ -z "$content" ]]; then
    local unsupported_reason
    unsupported_reason=$(check_unsupported_mode "$node" "$repo")
    if [[ -n "$unsupported_reason" ]]; then
      echo "Not a broken response -- the model's log shows: $unsupported_reason"
      TASK_ROW="$alias|${repo:-?}|${mode:-?}|NOT_SUPPORTED|-|-|$unsupported_reason"
      return 1
    fi
    echo "No valid completion in response:"
    echo -E "$resp"
    TASK_ROW="$alias|${repo:-?}|${mode:-?}|BAD_RESPONSE|-|-|empty/malformed completion"
    return 1
  fi

  if [[ -z "$completion_tokens" || "$completion_tokens" == "null" ]]; then
    # Server didn't report usage -- fall back to a word-count estimate.
    completion_tokens=$(echo "$content" | wc -w | tr -d ' ')
  fi

  local toks_per_sec="n/a"
  if [[ -n "$elapsed" ]] && (( $(echo "$elapsed > 0" | bc -l 2>/dev/null || echo 0) )); then
    toks_per_sec=$(echo "scale=1; $completion_tokens / $elapsed" | bc)
  fi

  local status_line mem_summary
  status_line=$("$SWITCH" --status -H "$HOSTS" -u "$SSH_USER" 2>&1)
  mem_summary=$(echo "$status_line" | grep -oE 'mem: [^ ]+' | sed 's/mem: //' | paste -sd '/' -)

  echo "Response (${completion_tokens} tokens in ${elapsed}s = ${toks_per_sec} tok/s):"
  echo "  $content" | head -3
  echo "Per-node memory: $mem_summary"

  TASK_ROW="$alias|${repo:-?}|${mode:-?}|OK|${toks_per_sec}|${mem_summary}|$note"
  return 0
}

for task in "${TASKS[@]}"; do
  alias="${task%%:*}"
  forced_mode="${task#*:}"

  echo "================================================================"
  echo "== $alias${forced_mode:+ ($forced_mode)}"
  echo "================================================================"

  run_task "$alias" "$forced_mode"
  task_status=$?

  if (( task_status == 2 )) && (( ! NO_RECOVER )); then
    if recover_cluster; then
      echo "Recovery looks good -- retrying $alias${forced_mode:+ ($forced_mode)}..."
      run_task "$alias" "$forced_mode"
      task_status=$?
    else
      echo "Recovery itself failed -- giving up on this task without a retry." >&2
    fi
  fi

  RESULTS+=("$TASK_ROW")
  echo ""
done

if (( ! LEAVE_RUNNING )); then
  echo "Stopping cluster (final cleanup)..."
  "$SWITCH" --stop -H "$HOSTS" -u "$SSH_USER"
  echo ""
fi

SUMMARY="$(
  printf "%-18s %-52s %-11s %-9s %-9s %-24s %s\n" "ALIAS" "REPO" "MODE" "STATUS" "TOK/S" "MEMORY (per node)" "NOTE"
  for row in "${RESULTS[@]}"; do
    IFS='|' read -r a r m s t mem note <<< "$row"
    printf "%-18s %-52s %-11s %-9s %-9s %-24s %s\n" "$a" "$r" "$m" "$s" "$t" "$mem" "$note"
  done
)"

echo "================================================================"
echo "SUMMARY"
echo "================================================================"
echo "$SUMMARY"
if (( RECOVERIES > 0 )); then
  echo ""
  echo "Hang recovery (reboot + reconfigure) triggered $RECOVERIES time(s) during this run."
fi

if [[ -n "$OUT_FILE" ]]; then
  echo "$SUMMARY" > "$OUT_FILE"
  echo ""
  echo "Also written to: $OUT_FILE"
fi
