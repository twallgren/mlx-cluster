#!/bin/zsh
#
# switch_model.zsh — stop whatever's running on the cluster and launch a
# different model, from the client machine
#
# Knows which launch mode (pipeline vs tensor-parallel) each known model
# needs, since that's model-specific and easy to get wrong: pipeline mode
# needs the explicit --pipeline flag or mlx-lm silently tries
# tensor-parallel and hits the divisibility wall; tensor-parallel mode
# must NOT pass --pipeline or it'll use a strategy the model may not
# support well. Each entry in the registry below was determined by testing
# the model on a real 3-node cluster; see "Choosing a model" in README.md for
# the rules that decide which mode a given architecture can use.
#
# Usage:
#   switch_model.zsh <alias-or-repo> [options]
#   switch_model.zsh --list
#   switch_model.zsh --status
#   switch_model.zsh --stop
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
HOSTS="ai-1,ai-2,ai-3"
SSH_USER="$USER"
CONTROLLER="ai-1"
MODE=""          # "" = look up from registry; or explicit "pipeline"/"tensor"/"standalone"
REPO=""          # explicit repo override
NODE=""          # explicit --node override for standalone mode
PORT=18080   # not 8080 -- too easy to collide with other local dev services
LOG_DIR_REMOTE='$HOME'
ACTION="switch"   # switch | list | status | stop
DRY_RUN=0
TEST_AFTER=1
WAIT_SECS=60
MAX_TOKENS=8192   # mlx_lm.server's own default is 512 -- far too low for
                  # agentic coding (long completions, multi-step edits), so
                  # this script defaults much higher. Still overridable.
CHAT_TEMPLATE_ARGS=""   # raw escape hatch, e.g. '{"enable_thinking":false}'
THINKING=""              # "on"/"off" -- convenience for the enable_thinking
                         # convention shared by Qwen3 and GLM 4.x/4.5/4.6
                         # chat templates (not a universal spec, but it
                         # covers every model in our candidate list)
PROMPT_CACHE_SIZE=5   # mlx_lm.server's own default is 10 -- lowered here since
                       # memory is tight on this cluster (e.g. GLM-4.6 leaves
                       # only ~13GB/node of headroom for cached KV entries)
PROMPT_CACHE_BYTES_DEFAULT=8589934592   # 8GiB -- the GLOBAL FALLBACK, used when
                                  # neither an explicit --prompt-cache-bytes nor
                                  # the resolved alias's own registry value is
                                  # set. mlx_lm.server's own default is
                                  # effectively unbounded (1<<63), which lets the
                                  # combined active+stored KV cache grow without
                                  # limit; this is what let wired/GPU memory grow
                                  # unbounded and (per upstream reports) leave
                                  # leaked wired memory behind after a GPU hang +
                                  # kill, recoverable only by rebooting the node.
                                  # This caps the STORED cache of idle/past
                                  # conversations (LRU-evicted first) -- it does
                                  # NOT truncate a single live generation's own
                                  # context, so the only user-visible cost of a
                                  # tight cap is a cache-miss (re-processing an
                                  # old conversation's prompt) rather than any
                                  # correctness loss.
PROMPT_CACHE_BYTES=""   # set from --prompt-cache-bytes on the command line only;
                          # empty means "use the alias's registry value, or the
                          # global fallback above, whichever applies" -- see the
                          # precedence resolution right before launch.
PREFILL_STEP_SIZE=""
TEMP=""
TOP_P=""
TOP_K=""
MIN_P=""

usage() {
  cat <<'EOF'
switch_model.zsh <alias-or-repo> [options]
switch_model.zsh --list
switch_model.zsh --status
switch_model.zsh --stop

Positional argument is a known alias (see --list) or a raw HF repo id
(e.g. mlx-community/Some-Model-4bit) — for a raw repo id not in the
registry, pass --mode explicitly.

Options:
  --mode {pipeline,tensor,standalone}
                                      Override/required for a repo not in the registry.
                                      "standalone" runs mlx_lm.server directly on one node
                                      (no mlx.launch/ring) -- for a model whose architecture
                                      has no .pipeline()/.shard() support and so fits on
                                      (and only needs) one node.
  --repo REPO                         Override the registry's repo id (rare).
  --node HOST                         Which host to run a standalone model on, or to check
                                      for the download on (default: ai-1). Ignored for
                                      pipeline/tensor modes, which always run from ai-1
                                      across the whole ring.
  -H, --hosts LIST                    Comma-separated hostnames (default: ai-1,ai-2,ai-3)
  -u, --user NAME                     SSH username (default: $USER)
  --port PORT                         Server port (default: 18080 -- deliberately not 8080,
                                      which collides easily with other local dev services)
  --max-tokens N                      Default max completion tokens the server will generate
                                      per request when the client doesn't specify one
                                      (default: 8192 -- mlx_lm.server's own default is 512,
                                      too low for agentic coding).
  --thinking {on,off}                 Convenience for the enable_thinking convention shared
                                      by Qwen3 and GLM 4.x/4.5/4.6 chat templates -- "off"
                                      skips a reasoning model's hidden thinking tokens
                                      (default: unset -- model's own chat template default
                                      applies). Mutually exclusive with
                                      --chat-template-args.
  --chat-template-args JSON           Raw escape hatch, passed to mlx_lm.server as-is
                                      (default: unset). Mutually exclusive with --thinking.
  --prompt-cache-size N               Max number of distinct KV caches to hold in the prompt
                                      cache (default: 5 -- mlx_lm.server's own default is
                                      10, lowered here since memory is tight on this
                                      cluster).
  --prompt-cache-bytes N              Max combined bytes of the active generation's KV cache
                                      plus the stored cache of other, idle conversations.
                                      Default is now per-model: each known alias may carry
                                      its own cap in the registry (see --list); an alias
                                      with no registry value, or a raw repo id, falls back
                                      to the global default of 8589934592 = 8GiB. An
                                      explicit value here always overrides both.
                                      mlx_lm.server's own default is effectively unbounded,
                                      which is what let wired memory grow without limit in
                                      past hangs; a tight cap only costs a slower cache-miss
                                      on an old idle conversation, not correctness or a live
                                      generation's own context). Pass 0 to remove the cap
                                      entirely (works as a CLI override or as an alias's
                                      registry value).
  --prefill-step-size N               Step size for prompt prefill processing (default:
                                      unset -- mlx_lm.server's own default: 2048).
  --temp T                            Default sampling temperature (default: unset --
                                      mlx_lm.server's own default: 0.0).
  --top-p P                           Default nucleus sampling top-p (default: unset --
                                      mlx_lm.server's own default: 1.0).
  --top-k K                           Default top-k sampling (default: unset --
                                      mlx_lm.server's own default: 0).
  --min-p P                           Default min-p sampling (default: unset --
                                      mlx_lm.server's own default: 0.0).
  --dry-run                           Resolve the alias/repo, mode, node, and all flags,
                                      print the exact command(s) that would run, and exit --
                                      no SSH calls at all (no stop, no download check, no
                                      launch, no test request).
  --no-test                           Don't send a verification request after launch.
  --wait SECS                         Max seconds to wait for the server to come up before
                                      giving up (default: 60).
  -h, --help                          Show this help.

Actions (in place of a model argument):
  --list                              List known model aliases and their launch mode.
  --status                            Show what's currently running, if anything.
  --stop                              Stop whatever's running, launch nothing new.
EOF
}

# ---------- model registry (edit this for your own cluster) ----------
#
# This table is site-specific data, not library code: it records which models
# have actually been downloaded and verified here, and how each one has to be
# launched. Add your own entries as you verify models; the rules that decide
# which mode an architecture can use are in "Choosing a model" in README.md.
#
# Format: "repo:mode:host:cache_bytes" -- always four colon-separated fields,
# with an empty string for the ones that do not apply.
#
#   repo        Hugging Face repo id.
#   mode        pipeline | tensor | standalone.
#   host        standalone only -- which node holds the download and runs the
#               server. Empty means the controller. --node overrides it.
#   cache_bytes This model's own --prompt-cache-bytes default. Empty falls
#               back to PROMPT_CACHE_BYTES_DEFAULT; 0 means "no cap" for this
#               model. --prompt-cache-bytes overrides it.
#
# The cache_bytes column is derived per model from its measured worst-node
# memory footprint: half of (installed RAM - that footprint - 4GiB for macOS),
# rounded down to a clean bucket, leaving the other half as slack for
# fragmentation and transient spikes. The values below were measured on 64GB
# nodes -- re-derive them for different hardware, or if a model's memory
# profile changes. llama3.3-70b has never been run here, so it has no
# measurement and falls back to the global default.

# Canonical alias order, used by --list. Keep in step with resolve_alias.
KNOWN_ALIASES=(
  qwen3-235b qwen3-30b qwen2.5-72b glm4.5-air llama3.3-70b
  llama3.1-8b deepseek-v2-lite glm4.6 qwen3-coder-next
)

resolve_alias() {
  case "$1" in
    qwen3-235b|qwen235b) echo "mlx-community/Qwen3-235B-A22B-Instruct-2507-4bit:pipeline::8589934592" ;;
    qwen3-30b|qwen30b) echo "mlx-community/Qwen3-30B-A3B-4bit:pipeline::17179869184" ;;
    qwen2.5-72b|qwen72b) echo "mlx-community/Qwen2.5-72B-Instruct-4bit:tensor::17179869184" ;;
    glm4.5-air|glm) echo "mlx-community/GLM-4.5-Air-4bit:pipeline::17179869184" ;;
    llama3.3-70b|llama70b) echo "mlx-community/Llama-3.3-70B-Instruct-4bit:pipeline::" ;;
    llama3.1-8b|llama8b) echo "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit:pipeline::17179869184" ;;
    deepseek-v2-lite|dsv2lite) echo "mlx-community/DeepSeek-V2-Lite-Chat-4bit-mlx:pipeline::17179869184" ;;
    glm4.6|glm46) echo "mrtoots/unsloth-GLM-4.6-mlx-3Bit:pipeline::4294967296" ;;
    qwen3-coder-next|qwencodernext) echo "mlx-community/Qwen3-Coder-Next-4bit:standalone:ai-2:8589934592" ;;
    *) echo "" ;;
  esac
}

list_models() {
  echo "Known aliases (repo → launch mode [node] [prompt-cache-bytes]):"
  for a in "${KNOWN_ALIASES[@]}"; do
    entry=$(resolve_alias "$a")
    repo="${entry%%:*}"
    rest="${entry#*:}"
    mode="${rest%%:*}"
    rest="${rest#*:}"
    node="${rest%%:*}"
    cache="${rest#*:}"
    cache_display="${cache:-$PROMPT_CACHE_BYTES_DEFAULT (default)}"
    if [[ "$mode" == "standalone" ]]; then node_display="${node:-$CONTROLLER}"; else node_display="-"; fi
    printf "  %-18s %-52s %-11s %-6s %s\n" "$a" "$repo" "$mode" "$node_display" "$cache_display"
  done
  echo
  echo "Any other HF repo id works too, with an explicit --mode pipeline|tensor|standalone"
  echo "(and --node for a standalone model that lives somewhere other than $CONTROLLER)."
  echo "A raw repo id has no registry entry, so"
  echo "--prompt-cache-bytes falls back to the global default of $PROMPT_CACHE_BYTES_DEFAULT unless overridden."
}

ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --thinking) THINKING="$2"; shift 2 ;;
    --chat-template-args) CHAT_TEMPLATE_ARGS="$2"; shift 2 ;;
    --prompt-cache-size) PROMPT_CACHE_SIZE="$2"; shift 2 ;;
    --prompt-cache-bytes) PROMPT_CACHE_BYTES="$2"; shift 2 ;;
    --prefill-step-size) PREFILL_STEP_SIZE="$2"; shift 2 ;;
    --temp) TEMP="$2"; shift 2 ;;
    --top-p) TOP_P="$2"; shift 2 ;;
    --top-k) TOP_K="$2"; shift 2 ;;
    --min-p) MIN_P="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-test) TEST_AFTER=0; shift ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    --list) ACTION="list"; shift ;;
    --status) ACTION="status"; shift ;;
    --stop) ACTION="stop"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) ARG="$1"; shift ;;
  esac
done

HOST_LIST=("${(@s/,/)HOSTS}")
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

stop_all() {
  echo "Stopping any running server on all nodes..."
  for host in "${HOST_LIST[@]}"; do
    ssh ${=SSH_OPTS} "$SSH_USER@$host" "pkill -f 'mlx_lm.server' 2>/dev/null; pkill -f 'mlx.launch' 2>/dev/null"
  done
  sleep 2
  local still=0
  for host in "${HOST_LIST[@]}"; do
    n=$(ssh ${=SSH_OPTS} "$SSH_USER@$host" "ps aux | grep -E 'mlx.launch|mlx_lm.server' | grep -v grep | wc -l" | tr -d ' ')
    still=$((still + n))
  done
  if (( still > 0 )); then
    echo "WARNING: $still process(es) still present after stop attempt" >&2
  else
    echo "Stopped."
  fi
}

show_status() {
  local any=0
  local line=""
  local model=""
  local mem=""
  for host in "${HOST_LIST[@]}"; do
    line=$(ssh ${=SSH_OPTS} "$SSH_USER@$host" "ps ax -o command | grep -i 'python -m mlx_lm.server' | grep -v grep | grep -v mlx.launch | grep -v 'ssh -tt'" 2>/dev/null)
    if [[ -n "$line" ]]; then
      any=1
      model=$(echo "$line" | grep -oE '\-\-model [^ ]+' | awk '{print $2}')
      mem=$(ssh ${=SSH_OPTS} "$SSH_USER@$host" "PID=\$(ps ax -o pid,command | grep -i 'python -m mlx_lm.server' | grep -v grep | grep -v mlx.launch | grep -v 'ssh -tt' | awk '{print \$1}'); top -pid \$PID -l 1 -stats mem 2>/dev/null | tail -1")
      printf "%-8s running: %-50s mem: %s\n" "$host" "$model" "$mem"
    else
      printf "%-8s idle\n" "$host"
    fi
  done
  (( any == 0 )) && echo "Nothing running on any node."
}

case "$ACTION" in
  list) list_models; exit 0 ;;
  status) show_status; exit 0 ;;
  stop) stop_all; exit 0 ;;
esac

if [[ -z "$ARG" ]]; then
  echo "ERROR: specify a model alias or repo id (or --list/--status/--stop)" >&2
  usage
  exit 1
fi

# Resolve alias, or fall through to treating ARG as a raw repo id. Registry
# entries are always the fixed 4-field "repo:mode:host:cache_bytes" format
# (empty string for whichever fields don't apply to this entry) so parsing
# never has to guess whether a 3rd field is a host or a cache value.
entry=$(resolve_alias "$ARG")
RESOLVED_NODE="$CONTROLLER"
ALIAS_CACHE_BYTES=""
if [[ -n "$entry" ]]; then
  RESOLVED_REPO="${entry%%:*}"
  rest="${entry#*:}"
  RESOLVED_MODE="${rest%%:*}"
  rest="${rest#*:}"
  ALIAS_NODE="${rest%%:*}"
  ALIAS_CACHE_BYTES="${rest#*:}"
  [[ -n "$ALIAS_NODE" ]] && RESOLVED_NODE="$ALIAS_NODE"
else
  RESOLVED_REPO="$ARG"
  RESOLVED_MODE="$MODE"
fi
[[ -n "$REPO" ]] && RESOLVED_REPO="$REPO"
[[ -n "$MODE" ]] && RESOLVED_MODE="$MODE"
[[ -n "$NODE" ]] && RESOLVED_NODE="$NODE"

# Precedence for the prompt-cache-bytes default, strictest first: an explicit
# --prompt-cache-bytes on the command line always wins; otherwise the
# resolved alias's own registry value, if it set one; otherwise the global
# fallback. "0" is a valid value at any of these levels (see the sentinel
# note below).
if [[ -z "$PROMPT_CACHE_BYTES" ]]; then
  if [[ -n "$ALIAS_CACHE_BYTES" ]]; then
    PROMPT_CACHE_BYTES="$ALIAS_CACHE_BYTES"
  else
    PROMPT_CACHE_BYTES="$PROMPT_CACHE_BYTES_DEFAULT"
  fi
fi

if [[ -z "$RESOLVED_MODE" ]]; then
  echo "ERROR: '$ARG' isn't a known alias and no --mode was given. Run --list to see known aliases, or pass --mode pipeline|tensor|standalone explicitly." >&2
  exit 1
fi
if [[ "$RESOLVED_MODE" != "pipeline" && "$RESOLVED_MODE" != "tensor" && "$RESOLVED_MODE" != "standalone" ]]; then
  echo "ERROR: --mode must be 'pipeline', 'tensor', or 'standalone', got '$RESOLVED_MODE'" >&2
  exit 1
fi
# Only standalone mode ever runs anywhere but the controller (ai-1) --
# pipeline/tensor always launch the whole ring from there regardless of
# --node.
[[ "$RESOLVED_MODE" != "standalone" ]] && RESOLVED_NODE="$CONTROLLER"

if [[ -n "$THINKING" && -n "$CHAT_TEMPLATE_ARGS" ]]; then
  echo "ERROR: --thinking and --chat-template-args are mutually exclusive (both set enable_thinking)" >&2
  exit 1
fi
case "$THINKING" in
  "") ;;
  on) CHAT_TEMPLATE_ARGS='{"enable_thinking":true}' ;;
  off) CHAT_TEMPLATE_ARGS='{"enable_thinking":false}' ;;
  *) echo "ERROR: --thinking must be 'on' or 'off', got '$THINKING'" >&2; exit 1 ;;
esac

echo "Model:  $RESOLVED_REPO"
echo "Mode:   $RESOLVED_MODE"
[[ "$RESOLVED_MODE" == "standalone" ]] && echo "Node:   $RESOLVED_NODE"

PIPE_FLAG=""
[[ "$RESOLVED_MODE" == "pipeline" ]] && PIPE_FLAG="--pipeline"
LOG_NAME="switch_$(echo "$RESOLVED_REPO" | tr '/' '_').log"

# Optional sampling/serving flags -- only passed through if the user set them,
# so mlx_lm.server's own defaults apply otherwise.
EXTRA_FLAGS=""
[[ -n "$CHAT_TEMPLATE_ARGS" ]] && EXTRA_FLAGS="$EXTRA_FLAGS --chat-template-args '$CHAT_TEMPLATE_ARGS'"
[[ -n "$PROMPT_CACHE_SIZE" ]] && EXTRA_FLAGS="$EXTRA_FLAGS --prompt-cache-size $PROMPT_CACHE_SIZE"
# "0" is this script's own sentinel for "no cap" (translated to omitting the
# flag entirely) -- mlx_lm.server itself treats a literal 0 as a near-zero
# budget (aggressively evicting the stored cache), not "unbounded", since it
# only skips the cap when the flag is omitted (argparse default None).
[[ -n "$PROMPT_CACHE_BYTES" && "$PROMPT_CACHE_BYTES" != "0" ]] && EXTRA_FLAGS="$EXTRA_FLAGS --prompt-cache-bytes $PROMPT_CACHE_BYTES"
[[ -n "$PREFILL_STEP_SIZE" ]] && EXTRA_FLAGS="$EXTRA_FLAGS --prefill-step-size $PREFILL_STEP_SIZE"
[[ -n "$TEMP" ]] && EXTRA_FLAGS="$EXTRA_FLAGS --temp $TEMP"
[[ -n "$TOP_P" ]] && EXTRA_FLAGS="$EXTRA_FLAGS --top-p $TOP_P"
[[ -n "$TOP_K" ]] && EXTRA_FLAGS="$EXTRA_FLAGS --top-k $TOP_K"
[[ -n "$MIN_P" ]] && EXTRA_FLAGS="$EXTRA_FLAGS --min-p $MIN_P"

if (( DRY_RUN )); then
  echo "DRY RUN -- nothing will be stopped, checked, or launched on the cluster."
  if [[ "$RESOLVED_MODE" == "standalone" ]]; then
    echo "Would run on $RESOLVED_NODE:"
    echo "  ~/mlx-env/bin/python -m mlx_lm.server --model $RESOLVED_REPO --host 127.0.0.1 --port $PORT --max-tokens $MAX_TOKENS$EXTRA_FLAGS"
  else
    echo "Would run on $CONTROLLER (ring: ${HOST_LIST[*]}):"
    echo "  ~/mlx-env/bin/mlx.launch --backend ring --hostfile cluster.json --env MLX_METAL_FAST_SYNCH=1 -- ~/mlx-env/bin/python -m mlx_lm.server --model $RESOLVED_REPO $PIPE_FLAG --host 127.0.0.1 --port $PORT --max-tokens $MAX_TOKENS$EXTRA_FLAGS"
  fi
  exit 0
fi

# Sanity check: model fully present (not just directory-exists — HF's
# snapshot_download creates the directory tree immediately on start, long
# before any weight file is complete, so a bare `ls -d` on the directory
# is not sufficient and would let a still-downloading model through).
CACHE_DIR="~/.cache/huggingface/hub/models--${RESOLVED_REPO//\//--}"
present=$(ssh ${=SSH_OPTS} "$SSH_USER@$RESOLVED_NODE" "
  if [ ! -d $CACHE_DIR ]; then echo missing; exit; fi
  if find $CACHE_DIR -name '*.incomplete' 2>/dev/null | grep -q .; then echo incomplete; exit; fi
  if ! find $CACHE_DIR/snapshots -name '*.safetensors' 2>/dev/null | grep -q .; then echo missing; exit; fi
  echo ready
")
if [[ "$present" != "ready" ]]; then
  echo "ERROR: $RESOLVED_REPO is not fully downloaded on $RESOLVED_NODE (status: $present). Download it first — nothing was stopped or launched." >&2
  exit 1
fi

stop_all

echo "Launching..."
if [[ "$RESOLVED_MODE" == "standalone" ]]; then
  # No mlx.launch/ring at all -- this model has no distributed
  # (.pipeline()/.shard()) support, so it just runs mlx_lm.server directly
  # on one node.
  ssh ${=SSH_OPTS} "$SSH_USER@$RESOLVED_NODE" \
    "cd ~ && nohup ~/mlx-env/bin/python -m mlx_lm.server --model $RESOLVED_REPO --host 127.0.0.1 --port $PORT --max-tokens $MAX_TOKENS$EXTRA_FLAGS > ~/$LOG_NAME 2>&1 < /dev/null & disown; echo issued"
else
  ssh ${=SSH_OPTS} "$SSH_USER@$RESOLVED_NODE" \
    "cd ~ && nohup ~/mlx-env/bin/mlx.launch --backend ring --hostfile cluster.json --env MLX_METAL_FAST_SYNCH=1 -- ~/mlx-env/bin/python -m mlx_lm.server --model $RESOLVED_REPO $PIPE_FLAG --host 127.0.0.1 --port $PORT --max-tokens $MAX_TOKENS$EXTRA_FLAGS > ~/$LOG_NAME 2>&1 < /dev/null & disown; echo issued"
fi

echo -n "Waiting for it to come up"
elapsed=0
while (( elapsed < WAIT_SECS )); do
  sleep 3
  elapsed=$((elapsed + 3))
  echo -n "."
  result=$(ssh ${=SSH_OPTS} "$SSH_USER@$RESOLVED_NODE" "grep -E 'Starting httpd|Traceback|ValueError|Error' ~/$LOG_NAME 2>/dev/null | head -1")
  [[ -n "$result" ]] && break
done
echo

if [[ -z "$result" ]]; then
  echo "TIMEOUT after ${WAIT_SECS}s with no 'Starting httpd' or error — still loading, or something's stuck. Check: ssh $SSH_USER@$RESOLVED_NODE 'tail -40 ~/$LOG_NAME'" >&2
  exit 1
fi
if [[ "$result" != *"Starting httpd"* ]]; then
  echo "FAILED: $result" >&2
  echo "Full log: ssh $SSH_USER@$RESOLVED_NODE 'cat ~/$LOG_NAME'" >&2
  exit 1
fi

echo "Server up."

if (( TEST_AFTER )); then
  echo "Sending a test request..."
  resp=$(ssh ${=SSH_OPTS} "$SSH_USER@$RESOLVED_NODE" "curl -s -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly three words.\"}],\"max_tokens\":20}'")
  echo "$resp"
fi

echo
echo "Tunnel from your laptop: ssh -N -L $PORT:127.0.0.1:$PORT $SSH_USER@$RESOLVED_NODE"
