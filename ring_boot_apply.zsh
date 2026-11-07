#!/bin/zsh
# ring_boot_apply.zsh
#
# Runs ON a cluster node, as root, from the LaunchDaemon installed by
# persist_thunderbolt_ring.zsh. Keeps this node's Thunderbolt ring addresses
# correct by identifying WHICH PEER is on each port, not by interface name:
# tb_port_map.zsh lists the cabled ports, tb_peer_mac.zsh finds the MAC of the
# Mac on each one over IPv6 link-local, the config maps MACs to hosts, and each
# link (pair of hosts) has fixed addresses. So a renumbered interface or a
# cable moved to another port still gets the right address. A port whose peer
# MAC is not in the config gets no ring address (fails loudly in the log
# instead of silently mis-mapping). A cabled port whose peer does not answer
# yet (it is still booting) is left as it is until it does.
#
# Config (written by persist_thunderbolt_ring.zsh), one directive per line:
#   self   ai-1
#   prefix 192.168.0.
#   node   ai-2 <mac> [<mac> ...]       # every Thunderbolt port MAC of ai-2
#   link   ai-1 192.168.0.1 ai-2 192.168.0.2

emulate -L zsh

CONF="/usr/local/etc/mlx-ring.conf"
PORT_MAP="/usr/local/libexec/mlx-tb-port-map.zsh"
PEER_MAC="/usr/local/libexec/mlx-tb-peer-mac.zsh"
NETMASK="255.255.255.252"
INTERVAL=30
ONCE=0

usage() {
  cat <<'EOF'
ring_boot_apply.zsh [options]

Assigns Thunderbolt ring addresses by peer identity (the peer port's MAC),
then keeps re-checking. Removes ring addresses from ports where they don't belong. Must
run as root to change anything.

Options:
  --conf PATH       Config file (default: /usr/local/etc/mlx-ring.conf)
  --port-map PATH   tb_port_map.zsh to use (default: /usr/local/libexec/mlx-tb-port-map.zsh)
  --peer-mac PATH   tb_peer_mac.zsh to use (default: /usr/local/libexec/mlx-tb-peer-mac.zsh)
  --netmask MASK    Netmask for each link (default: 255.255.255.252)
  --interval SECS   Seconds between re-checks (default: 30)
  --once            Run one pass and exit
  --plan            Print what it would do for the current cabling. Changes no
                    IPv4 address or route; peer discovery still turns on IPv6
                    link-local on cabled ports
  -h, --help        Show this help
EOF
}

PLAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf) CONF="$2"; shift 2 ;;
    --port-map) PORT_MAP="$2"; shift 2 ;;
    --peer-mac) PEER_MAC="$2"; shift 2 ;;
    --netmask) NETMASK="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --plan) PLAN=1; ONCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "ERROR: unknown option: $1"; usage >&2; exit 1 ;;
  esac
done

log() { print -r -- "$(date '+%F %T') $*"; }

# Log a message only when it differs from the last one logged under that key,
# so a steady state does not fill the log every 30 seconds.
typeset -A LAST
note() {
  local key="$1"; shift
  [[ "${LAST[$key]}" == "$*" ]] && return
  LAST[$key]="$*"
  log "$*"
}

run() {
  if (( PLAN )); then print "would run: $*"; else "$@"; fi
}

read_conf() {
  SELF="" PREFIX=""
  typeset -gA MAC_HOST
  typeset -ga LINKS
  MAC_HOST=() LINKS=()
  local line kw host u
  while read -r line; do
    set -- ${=line}
    kw="$1"
    case "$kw" in
      self) SELF="$2" ;;
      prefix) PREFIX="$2" ;;
      node) host="$2"; shift 2; for u in "$@"; do MAC_HOST[${u:l}]="$host"; done ;;
      link) LINKS+=("$2 $3 $4 $5") ;;
    esac
  done < <(sed -E 's/#.*//; /^[[:space:]]*$/d' "$CONF")
  [[ -n "$SELF" && -n "$PREFIX" ]]
}

# "<my ip> <peer ip>" for the link between SELF and $1, if one exists.
link_addrs() {
  local peer="$1" l
  for l in "${LINKS[@]}"; do
    set -- ${=l}
    if [[ "$1" == "$SELF" && "$3" == "$peer" ]]; then print "$2 $4"; return; fi
    if [[ "$3" == "$SELF" && "$1" == "$peer" ]]; then print "$4 $2"; return; fi
  done
}

ring_addrs_on() {
  ifconfig "$1" 2>/dev/null | awk -v p="$PREFIX" '$1 == "inet" && index($2, p) == 1 {print $2}'
}

pass() {
  local iface sock own cabled peer peerhost want mine peerip cur
  if ifconfig bridge0 2>/dev/null | grep -q '<UP'; then
    run ifconfig bridge0 down && note bridge "bridge0 down"
  fi
  while read -r iface sock own cabled; do
    want="" peerip="" peerhost=""
    if [[ "$cabled" == yes ]]; then
      if ! peer=$(zsh "$PEER_MAC" "$iface" </dev/null); then
        # Peer still booting or its daemon not running: change nothing yet.
        note "$iface" "$iface: cabled, peer not answering on IPv6 link-local yet; leaving it as is"
        continue
      fi
      peerhost="${MAC_HOST[$peer]}"
      if [[ -z "$peerhost" ]]; then
        note "$iface" "WARN $iface: peer MAC $peer is not in $CONF; leaving it unaddressed (re-run persist_thunderbolt_ring.zsh)"
      else
        set -- ${=$(link_addrs "$peerhost")}
        if [[ -z "$1" ]]; then
          note "$iface" "WARN $iface: cabled to $peerhost but no link $SELF-$peerhost in $CONF"
        else
          want="$1" peerip="$2"
        fi
      fi
    fi

    for cur in ${(f)"$(ring_addrs_on "$iface")"}; do
      if [[ "$cur" != "$want" ]]; then
        run ifconfig "$iface" inet "$cur" delete && { (( PLAN )) || log "removed $cur from $iface (does not belong there)"; }
      fi
    done

    if [[ -n "$want" ]]; then
      if ! ring_addrs_on "$iface" | grep -qx "$want"; then
        run ifconfig "$iface" inet "$want" netmask "$NETMASK" && { (( PLAN )) || log "set $iface = $want (link to $peerhost)"; }
      fi
      if (( PLAN )) || ! route -n get "$peerip" 2>/dev/null | grep -q "interface: $iface\$"; then
        run route -n change "$peerip" -interface "$iface" >/dev/null 2>&1 \
          || run route -n add "$peerip" -interface "$iface" >/dev/null 2>&1
        (( PLAN )) || log "route $peerip via $iface"
      fi
      note "$iface" "$iface -> $peerhost ok ($want)"
    elif [[ "$cabled" != yes ]]; then
      note "$iface" "$iface: no cable"
    fi
  done < <(zsh "$PORT_MAP")
}

if [[ ! -r "$CONF" ]]; then print -u2 "ERROR: cannot read $CONF"; exit 1; fi
for f in "$PORT_MAP" "$PEER_MAC"; do
  [[ -r "$f" ]] || { print -u2 "ERROR: cannot read $f"; exit 1; }
done

while true; do
  if read_conf; then
    pass
  else
    note conf "ERROR: $CONF needs 'self' and 'prefix' lines"
  fi
  (( ONCE )) && break
  sleep "$INTERVAL"
done
