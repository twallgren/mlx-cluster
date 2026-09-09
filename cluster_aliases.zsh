#!/bin/zsh
#
# cluster_aliases.zsh — interactive shell conveniences for the cluster
#
# Source this from your ~/.zshrc (or a helpers file it sources):
#
#   source /path/to/this/repo/cluster_aliases.zsh
#
# Everything here is a thin wrapper over the scripts in this folder; nothing
# here implements cluster logic of its own, so a script stays usable on its
# own and these stay usable without memorising paths.
#
# Configure by exporting any of these BEFORE sourcing (or at any time — they
# are read at call time, not at source time):
#
#   MLX_CLUSTER_HOSTS       Comma-separated node hostnames  (default: ai-1,ai-2,ai-3)
#   MLX_CLUSTER_USER        SSH username on the nodes       (default: $USER)
#   MLX_CLUSTER_CONTROLLER  Node that runs the server       (default: first of HOSTS)
#   MLX_CLUSTER_PORT        Server port on the controller   (default: 18080)
#   MLX_CLUSTER_LOCAL_PORT  Local port for ai_portforward   (default: 8088)

# Absolute path to this repo, resolved when sourced so the functions work
# from any working directory.
export MLX_CLUSTER_DIR="${MLX_CLUSTER_DIR:-${0:A:h}}"

: "${MLX_CLUSTER_HOSTS:=ai-1,ai-2,ai-3}"
: "${MLX_CLUSTER_USER:=$USER}"
: "${MLX_CLUSTER_PORT:=18080}"
: "${MLX_CLUSTER_LOCAL_PORT:=8088}"

# First host in the list, unless overridden.
_ai_controller() {
  if [[ -n "$MLX_CLUSTER_CONTROLLER" ]]; then
    echo "$MLX_CLUSTER_CONTROLLER"
  else
    echo "${${(@s/,/)MLX_CLUSTER_HOSTS}[1]}"
  fi
}

_ai_common_args() {
  echo "-H ${MLX_CLUSTER_HOSTS} -u ${MLX_CLUSTER_USER}"
}

# ---------- the scripts, on your PATH by name ----------

ai_switch_model()   { "$MLX_CLUSTER_DIR/switch_model.zsh"                ${=$(_ai_common_args)} "$@"; }
ai_monitor_nodes()  { "$MLX_CLUSTER_DIR/monitor_nodes.zsh"               ${=$(_ai_common_args)} "$@"; }
ai_run_on_all()     { "$MLX_CLUSTER_DIR/run_on_all.zsh"                  ${=$(_ai_common_args)} "$@"; }
ai_reboot_all()     { "$MLX_CLUSTER_DIR/reboot_cluster.zsh"              ${=$(_ai_common_args)} "$@"; }
ai_reconfigure()    { "$MLX_CLUSTER_DIR/reconfigure_thunderbolt_ring.zsh" ${=$(_ai_common_args)} "$@"; }
ai_test_models()    { "$MLX_CLUSTER_DIR/test_all_models.zsh"             ${=$(_ai_common_args)} "$@"; }

# ---------- conveniences with no script behind them ----------

# ai_ssh [n|hostname] — SSH to a node by position (1-based) or by name.
ai_ssh() {
  local target="$1"
  local -a hosts
  hosts=("${(@s/,/)MLX_CLUSTER_HOSTS}")
  if [[ -z "$target" ]]; then
    echo "Usage: ai_ssh <node-number|hostname>" >&2
    echo "Nodes: ${hosts[*]}" >&2
    return 1
  fi
  if [[ "$target" == <-> ]]; then
    if (( target < 1 || target > ${#hosts[@]} )); then
      echo "Error: node must be between 1 and ${#hosts[@]} (${hosts[*]})" >&2
      return 1
    fi
    target="${hosts[$target]}"
  fi
  ssh "${MLX_CLUSTER_USER}@${target}"
}

# ai_portforward — tunnel the controller's loopback-bound server to this machine.
# The server deliberately binds 127.0.0.1 on the controller and is never
# exposed on the network; this is the intended way to reach it.
ai_portforward() {
  local controller
  controller="$(_ai_controller)"
  echo "Forwarding localhost:${MLX_CLUSTER_LOCAL_PORT} -> ${controller}:${MLX_CLUSTER_PORT} (Ctrl-C to stop)"
  ssh -N -L "${MLX_CLUSTER_LOCAL_PORT}:127.0.0.1:${MLX_CLUSTER_PORT}" "${MLX_CLUSTER_USER}@${controller}"
}

# ai_wait_for_nodes — block until every node answers SSH.
ai_wait_for_nodes() {
  local host
  for host in "${(@s/,/)MLX_CLUSTER_HOSTS}"; do
    while ! ssh -q -o ConnectTimeout=5 "${MLX_CLUSTER_USER}@${host}" exit 2>/dev/null; do
      echo "Waiting for ${host}..."
      sleep 5
    done
    echo "${host} is up."
  done
}

# ai_restart_tailscale — Tailscale's macOS app occasionally stops advertising a
# node after a reboot; quitting and reopening it is faster than debugging why.
ai_restart_tailscale() {
  local host
  for host in "${(@s/,/)MLX_CLUSTER_HOSTS}"; do
    echo "Restarting Tailscale on ${host}..."
    ssh -t "${MLX_CLUSTER_USER}@${host}" \
      'osascript -e '\''tell application "Tailscale" to quit'\''; sleep 3; open -a Tailscale'
  done
}

# ai_help — what this file provides.
ai_help() {
  cat <<EOF
MLX cluster shell helpers (from \$MLX_CLUSTER_DIR = $MLX_CLUSTER_DIR)

  ai_switch_model <alias>   Launch a model across the cluster (--list, --status, --stop)
  ai_monitor_nodes          Battery, CPU and thermal status for every node
  ai_test_models            Walk the registry, verify and benchmark each model
  ai_run_on_all -- <cmd>    Run one command on every node
  ai_reboot_all             Reboot every node, wait for SSH, re-establish the ring
  ai_reconfigure            Re-establish the Thunderbolt ring (run after any reboot)

  ai_ssh <n|host>           SSH to a node by position or name
  ai_portforward            Tunnel the controller's server to localhost:${MLX_CLUSTER_LOCAL_PORT}
  ai_wait_for_nodes         Block until every node answers SSH
  ai_restart_tailscale      Quit and reopen Tailscale on every node

Current cluster: ${MLX_CLUSTER_HOSTS} as ${MLX_CLUSTER_USER}, controller $(_ai_controller), port ${MLX_CLUSTER_PORT}
Every wrapper passes -H/-u through, and forwards any extra arguments to the
underlying script, so \`ai_switch_model --help\` works.
EOF
}
