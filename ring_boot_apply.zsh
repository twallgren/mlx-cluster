#!/bin/zsh
# ring_boot_apply.zsh
#
# Runs ON a cluster node (as root, from a LaunchDaemon installed by
# persist_thunderbolt_ring.zsh). Reads a config of "iface ip" lines and keeps
# those Thunderbolt ring addresses applied: at boot, and again whenever one
# goes missing (interface appears late, accessory approved later, cable moved
# back). Does the same work as the ifconfig/route lines that
# mlx.distributed_config prints.
#
# Config format (one per line, '#' comments allowed):
#   en1 192.168.0.1

emulate -L zsh

CONF="/usr/local/etc/mlx-ring.conf"
NETMASK="255.255.255.252"
INTERVAL=30
ONCE=0

usage() {
  cat <<'EOF'
ring_boot_apply.zsh [options]

Applies the Thunderbolt ring addresses listed in the config file, then keeps
re-checking them. Must run as root.

Options:
  --conf PATH       Config file of "iface ip" lines (default: /usr/local/etc/mlx-ring.conf)
  --netmask MASK    Netmask for each link (default: 255.255.255.252)
  --interval SECS   Seconds between re-checks (default: 30)
  --once            Apply once and exit instead of looping
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf) CONF="$2"; shift 2 ;;
    --netmask) NETMASK="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "ERROR: unknown option: $1"; usage >&2; exit 1 ;;
  esac
done

log() { print -r -- "$(date '+%F %T') $*"; }

# The other end of a /30 link: .1<->.2, .5<->.6, .9<->.10 ...
peer_of() {
  local ip="$1" octet="${1##*.}" base="${1%.*}"
  case $(( octet % 4 )) in
    1) print "$base.$(( octet + 1 ))" ;;
    2) print "$base.$(( octet - 1 ))" ;;
  esac
}

apply_all() {
  local iface ip peer
  # A merged Thunderbolt bridge loops on a ring.
  if ifconfig bridge0 2>/dev/null | grep -q '<UP'; then
    ifconfig bridge0 down && log "bridge0 down"
  fi
  while read -r iface ip; do
    [[ -z "$iface" || "$iface" == \#* ]] && continue
    if ! ifconfig "$iface" >/dev/null 2>&1; then
      log "waiting: $iface does not exist yet"
      continue
    fi
    if ! ifconfig "$iface" | grep -q "inet $ip "; then
      ifconfig "$iface" inet "$ip" netmask "$NETMASK" && log "set $iface = $ip"
    fi
    peer=$(peer_of "$ip")
    if [[ -n "$peer" ]] && ! route -n get "$peer" 2>/dev/null | grep -q "interface: $iface\$"; then
      route -n change "$peer" -interface "$iface" >/dev/null 2>&1 \
        || route -n add "$peer" -interface "$iface" >/dev/null 2>&1
      log "route $peer via $iface"
    fi
  done < "$CONF"
}

if [[ ! -r "$CONF" ]]; then
  print -u2 "ERROR: cannot read $CONF"
  exit 1
fi

while true; do
  apply_all
  (( ONCE )) && break
  sleep "$INTERVAL"
done
