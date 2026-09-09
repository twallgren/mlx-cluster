#!/bin/zsh
#
# tb_link_addrs.zsh — find the real direct-link Thunderbolt IP between
# two cluster nodes, and optionally build/run an rsync command with it
#
# Thunderbolt interface names (en1/en2/en3) and their addresses get
# reassigned across reboots, and a node's OWN advertised address in
# cluster.json is only guaranteed reachable from its RING NEIGHBORS, not
# from every other node — using the wrong address for a direct transfer
# either times out outright, or (worse) silently resolves via Tailscale/
# .local and crawls at ~1/2000th of Thunderbolt speed with no error, just
# looking like "slow progress". This script derives the correct address
# by reading actual `ifconfig` output on both nodes and matching by
# subnet (each /30 point-to-point link's two endpoints share one), rather
# than trusting any cached/previous mapping.
#
# Usage:
#   tb_link_addrs.zsh --from ai-1 --to ai-3
#   tb_link_addrs.zsh --from ai-1 --to ai-3 --rsync /local/path/ /remote/path/
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
FROM=""
TO=""
SSH_USER="$USER"
RSYNC_SRC=""
RSYNC_DST=""
VERIFY=1

usage() {
  cat <<'EOF'
tb_link_addrs.zsh --from HOST --to HOST [options]

Options:
  --from HOST                         Node you're operating from (e.g. ai-1) — required.
  --to HOST                           Node you want the direct-link address for — required.
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  --rsync SRC DST                     If given, run `rsync -a --progress` from SRC (a path
                                      on --from) to DST (a path on --to) using the
                                      discovered address, instead of just printing it.
  --no-verify                         Skip the TCP reachability check before printing/using
                                      the address (verification is on by default).
  -h, --help                          Show this help.

Prints the direct point-to-point Thunderbolt IP for --to, as reachable
from --from, to stdout (so it's easy to capture: `addr=$(tb_link_addrs.zsh ...)`).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --rsync) RSYNC_SRC="$2"; RSYNC_DST="$3"; shift 3 ;;
    --no-verify) VERIFY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$FROM" || -z "$TO" ]]; then
  echo "ERROR: --from and --to are required" >&2
  usage
  exit 1
fi

SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

# Pull inet+netmask for every Thunderbolt-range interface (en1..en4, covers
# every mapping seen on this cluster so far) on both nodes.
gather() {
  local host="$1"
  ssh ${=SSH_OPTS} "$SSH_USER@$host" \
    "for i in en1 en2 en3 en4; do ifconfig \$i 2>/dev/null | awk -v i=\$i '/inet /{print i, \$2, \$4}'; done"
}

FROM_IFACES=$(gather "$FROM")
TO_IFACES=$(gather "$TO")

if [[ -z "$FROM_IFACES" || -z "$TO_IFACES" ]]; then
  echo "ERROR: could not read Thunderbolt interface info from $FROM and/or $TO" >&2
  exit 1
fi

# Compute the /30 network base for an "a.b.c.d" address (last octet & ~3).
net_base() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<< "$ip"
  echo "$a.$b.$c.$(( d & ~3 ))"
}

MATCH_IP=""
while read -r _ from_ip _; do
  [[ -z "$from_ip" ]] && continue
  from_net=$(net_base "$from_ip")
  while read -r _ to_ip _; do
    [[ -z "$to_ip" ]] && continue
    to_net=$(net_base "$to_ip")
    if [[ "$from_net" == "$to_net" ]]; then
      MATCH_IP="$to_ip"
      break 2
    fi
  done <<< "$TO_IFACES"
done <<< "$FROM_IFACES"

if [[ -z "$MATCH_IP" ]]; then
  echo "ERROR: no matching /30 subnet found between $FROM and $TO — no direct Thunderbolt link, or interfaces are down. Raw data:" >&2
  echo "-- $FROM --" >&2; echo "$FROM_IFACES" >&2
  echo "-- $TO --" >&2; echo "$TO_IFACES" >&2
  exit 1
fi

if (( VERIFY )); then
  if ! ssh ${=SSH_OPTS} "$SSH_USER@$FROM" "nc -zw3 $MATCH_IP 22" 2>/dev/null; then
    echo "ERROR: found candidate address $MATCH_IP but it's not reachable (nc -z failed) from $FROM. Stale interface state? Re-run mlx.distributed_config --auto-setup." >&2
    exit 1
  fi
fi

if [[ -n "$RSYNC_SRC" ]]; then
  # SRC/DST are single-quoted in the remote command below (so spaces are
  # safe), which means a leading ~ would NOT be shell-expanded — resolve it
  # to an absolute path here instead, against each host's real $HOME.
  if [[ "$RSYNC_SRC" == "~/"* || "$RSYNC_SRC" == "~" ]]; then
    from_home=$(ssh ${=SSH_OPTS} "$SSH_USER@$FROM" 'echo $HOME')
    RSYNC_SRC="${from_home}${RSYNC_SRC#\~}"
  fi
  if [[ "$RSYNC_DST" == "~/"* || "$RSYNC_DST" == "~" ]]; then
    to_home=$(ssh ${=SSH_OPTS} "$SSH_USER@$TO" 'echo $HOME')
    RSYNC_DST="${to_home}${RSYNC_DST#\~}"
  fi
  echo "-- rsync $FROM:$RSYNC_SRC -> $TO ($MATCH_IP):$RSYNC_DST --" >&2
  ssh ${=SSH_OPTS} "$SSH_USER@$FROM" \
    "rsync -a --progress -e 'ssh -o StrictHostKeyChecking=accept-new' '$RSYNC_SRC' '$SSH_USER@$MATCH_IP:$RSYNC_DST'"
else
  echo "$MATCH_IP"
fi
