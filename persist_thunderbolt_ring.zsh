#!/bin/zsh
# persist_thunderbolt_ring.zsh
#
# Makes the Thunderbolt ring survive reboots and cable moves. It records, for
# every node, the MAC of each of its Thunderbolt ports (via tb_port_map.zsh)
# and the address each node uses on each link (from the live ring set up by
# reconfigure_thunderbolt_ring.zsh, each link's peer identified by MAC through
# ARP). It then installs a root LaunchDaemon on every node running
# ring_boot_apply.zsh, which at boot and every --interval seconds finds which
# peer is on each port (tb_peer_mac.zsh, over IPv6 link-local) and puts that
# link's address on it. Interface renumbering and cables moved between ports
# are therefore handled with no re-run. A port with an unknown peer gets no
# ring address and a warning in /var/log/mlx-ring.log.
#
# (macOS 27 refuses `networksetup -createnetworkservice` for these ports even
# from the desktop session, so persistent network services are not an option.)
#
# (Thunderbolt Domain UUIDs were tried first and rejected: they change at
# every boot. The port MACs have stayed fixed across reboots and updates.)
#
# Re-run only when the topology changes (nodes added or removed) or a Mac's
# Thunderbolt MACs change (e.g. after a reinstall): use --reconfigure, which stops the daemons, runs
# the MLX discovery again, then reinstalls with the new plan.
#
# Needs every node up, and an admin password on each node (ssh -t lets you
# type it in your own terminal).

set -o pipefail
emulate -L zsh

HOSTS="ai-1,ai-2,ai-3"
SSH_USER="$USER"
PREFIX="192.168.0."
NETMASK="255.255.255.252"
INTERVAL=30
LABEL="com.taylorwallgren.mlxring"
RECONFIGURE=0
UNINSTALL=0
DRY_RUN=0
SCRIPT_DIR="${0:A:h}"

usage() {
  cat <<'EOF'
persist_thunderbolt_ring.zsh [options]

Records each node's Thunderbolt port MACs and the live ring addresses, then
installs a LaunchDaemon on every node that assigns addresses by which peer is
on each port. Survives reboots, interface renumbering and cables moved between
ports. All nodes must be up.

Options:
  -H, --hosts LIST     Comma-separated node names (default: ai-1,ai-2,ai-3)
  -u, --user NAME      SSH username on every node (default: $USER)
  --reconfigure        Stop the daemons, run reconfigure_thunderbolt_ring.zsh
                       (same --hosts/--user) to rediscover the ring, then
                       install with the new plan. Only needed when nodes are
                       added/removed or a node's Thunderbolt MACs change.
  --prefix PREFIX      Address prefix that marks ring addresses (default: 192.168.0.)
  --netmask MASK       Netmask for each link (default: 255.255.255.252)
  --interval SECS      Re-check interval in the daemon (default: 30)
  --label LABEL        LaunchDaemon label (default: com.taylorwallgren.mlxring)
  --uninstall          Remove the daemon and its files from each node
  --dry-run            Collect and print the per-node config; change nothing
  -h, --help           Show this help

Each node asks for an admin password (sudo); --reconfigure asks twice.
Node-side pieces: tb_port_map.zsh, tb_peer_mac.zsh, ring_boot_apply.zsh
(see their --help).
Daemon log: /var/log/mlx-ring.log on each node.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --netmask) NETMASK="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "ERROR: unknown option: $1"; usage >&2; exit 1 ;;
  esac
done

HOST_LIST=("${(@s/,/)HOSTS}")
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
APPLY_SRC="$SCRIPT_DIR/ring_boot_apply.zsh"
MAP_SRC="$SCRIPT_DIR/tb_port_map.zsh"
PEER_SRC="$SCRIPT_DIR/tb_peer_mac.zsh"
APPLY_DST="/usr/local/libexec/mlx-ring-apply.zsh"
MAP_DST="/usr/local/libexec/mlx-tb-port-map.zsh"
PEER_DST="/usr/local/libexec/mlx-tb-peer-mac.zsh"
CONF_DST="/usr/local/etc/mlx-ring.conf"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

die() { print -u2 "ERROR: $*"; exit 1; }
node_ssh() { local h="$1"; shift; ssh ${SSH_OPTS} -o BatchMode=yes "$SSH_USER@$h" "$@"; }

# "iface ip" for ring addresses on active links of a node.
live_ring_addrs() {
  node_ssh "$1" ifconfig | awk -v p="$PREFIX" '
    function flush() { if (i ~ /^en/ && ip != "" && st == "active") print i, ip }
    /^[a-z0-9]+:/ { flush(); i = $1; sub(/:$/, "", i); ip = ""; st = "" }
    $1 == "inet" && index($2, p) == 1 { ip = $2 }
    $1 == "status:" { st = $2 }
    END { flush() }'
}

# 36:1a:b:e:d5:40 -> 36:1a:0b:0e:d5:40
norm_mac() {
  local x; local -a out
  for x in ${(s.:.)1}; do out+=($(printf '%02x' $(( 16#$x )))); done
  print -r -- "${(j.:.)out}"
}

# MAC answering for IP $3 on node $1's interface $2 (the live ring is up, so
# ARP works).
arp_mac() {
  node_ssh "$1" "ping -c1 -t2 $3 >/dev/null 2>&1; arp -n $3" </dev/null \
    | awk -v i="$2" 'index($0, " on " i " ") && $4 ~ /:/ {print $4; exit}'
}

# The other end of a /30 link: .1<->.2, .5<->.6 ...
peer_of() {
  local octet="${1##*.}" base="${1%.*}"
  case $(( octet % 4 )) in
    1) print "$base.$(( octet + 1 ))" ;;
    2) print "$base.$(( octet - 1 ))" ;;
  esac
}

plist_text() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$APPLY_DST</string>
    <string>--conf</string><string>$CONF_DST</string>
    <string>--port-map</string><string>$MAP_DST</string>
    <string>--peer-mac</string><string>$PEER_DST</string>
    <string>--netmask</string><string>$NETMASK</string>
    <string>--interval</string><string>$INTERVAL</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/mlx-ring.log</string>
  <key>StandardErrorPath</key><string>/var/log/mlx-ring.log</string>
</dict>
</plist>
EOF
}

install_script() {
  cat <<EOF
set -e
T="\$1"
mkdir -p /usr/local/libexec /usr/local/etc
launchctl bootout system/$LABEL 2>/dev/null || true
install -m 755 -o root -g wheel "\$T/apply.zsh" $APPLY_DST
install -m 755 -o root -g wheel "\$T/map.zsh" $MAP_DST
install -m 755 -o root -g wheel "\$T/peer.zsh" $PEER_DST
install -m 644 -o root -g wheel "\$T/mlx-ring.conf" $CONF_DST
install -m 644 -o root -g wheel "\$T/daemon.plist" $PLIST_DST
echo "plan:"
zsh $APPLY_DST --conf $CONF_DST --port-map $MAP_DST --peer-mac $PEER_DST --plan | grep -v '^would run: route' || true
launchctl bootstrap system $PLIST_DST
echo "installed $LABEL"
EOF
}

uninstall_cmd="launchctl bootout system/$LABEL 2>/dev/null; rm -f $PLIST_DST $APPLY_DST $MAP_DST $PEER_DST $CONF_DST; echo removed $LABEL"
stop_cmd="launchctl bootout system/$LABEL 2>/dev/null; echo stopped $LABEL"

# --- uninstall ---------------------------------------------------------------
if (( UNINSTALL )); then
  for host in "${HOST_LIST[@]}"; do
    print "== $host: uninstall =="
    if (( DRY_RUN )); then print "    sudo sh -c '$uninstall_cmd'"; continue; fi
    ssh -t ${SSH_OPTS} "$SSH_USER@$host" "sudo sh -c '$uninstall_cmd'" || die "failed on $host"
  done
  exit 0
fi

# --- optional rediscovery ----------------------------------------------------
if (( RECONFIGURE )); then
  if (( DRY_RUN )); then
    print "[dry-run] stop $LABEL on ${HOST_LIST[*]}, then run reconfigure_thunderbolt_ring.zsh -u $SSH_USER -H $HOSTS"
  else
    for host in "${HOST_LIST[@]}"; do
      print "== $host: stopping daemon so it does not undo the rediscovery =="
      ssh -t ${SSH_OPTS} "$SSH_USER@$host" "sudo sh -c '$stop_cmd'" || die "failed on $host"
    done
    print "== Rediscovering ring =="
    "$SCRIPT_DIR/reconfigure_thunderbolt_ring.zsh" -u "$SSH_USER" -H "$HOSTS" || exit 1
  fi
fi

# --- collect -----------------------------------------------------------------
typeset -A MACS IP_OWNER MAC_HOST
for host in "${HOST_LIST[@]}"; do
  map=$(node_ssh "$host" 'zsh -s' < "$MAP_SRC") || die "cannot read Thunderbolt ports on $host (is it up?)"
  [[ -n "$map" ]] || die "no Thunderbolt ports found on $host"
  while read -r iface sock own cabled; do
    [[ "$own" == - ]] && die "$host $iface has no MAC"
    own=$(norm_mac "$own")
    [[ -n "${MAC_HOST[$own]}" ]] && die "MAC $own is on both ${MAC_HOST[$own]} and $host"
    MACS[$host]+="${MACS[$host]:+ }$own"
    MAC_HOST[$own]="$host"
  done <<< "$map"
done

typeset -A LINK
for host in "${HOST_LIST[@]}"; do
  live=$(live_ring_addrs "$host") || die "cannot read addresses on $host"
  [[ -n "$live" ]] || die "$host has no live ring addresses; run with --reconfigure"
  while read -r iface ip; do
    peer_mac=$(arp_mac "$host" "$iface" "$(peer_of "$ip")")
    [[ -n "$peer_mac" ]] && peer_mac=$(norm_mac "$peer_mac")
    peer_host="${MAC_HOST[$peer_mac]}"
    [[ -n "$peer_host" ]] || die "$host $iface ($ip) has no identifiable peer (peer MAC: ${peer_mac:--})"
    [[ -n "${IP_OWNER[$ip]}" ]] && die "$ip is live on both ${IP_OWNER[$ip]} and $host/$iface"
    IP_OWNER[$ip]="$host/$iface"
    pair=("$host" "$peer_host")
    key="${(j: :)${(@o)pair}}"
    LINK[$key]+="${LINK[$key]:+ }$host=$ip"
  done <<< "$live"
done

# Every link must have both ends, on matching /30 addresses.
LINK_LINES=()
for key in "${(@ok)LINK}"; do
  ends=(${=LINK[$key]})
  (( ${#ends} == 2 )) || die "link $key has ${#ends} live end(s): ${ends[*]}"
  h1="${ends[1]%%=*}" ip1="${ends[1]#*=}" h2="${ends[2]%%=*}" ip2="${ends[2]#*=}"
  [[ "$(peer_of "$ip1")" == "$ip2" ]] || die "link $key: $ip1 and $ip2 are not the two ends of one /30"
  LINK_LINES+=("link $h1 $ip1 $h2 $ip2")
done
(( ${#LINK_LINES} >= ${#HOST_LIST} )) || print -u2 "WARN: only ${#LINK_LINES} link(s) for ${#HOST_LIST} nodes; the ring is not closed"

conf_for() {
  local self="$1" h
  print "# written by persist_thunderbolt_ring.zsh on $(date '+%F %T')"
  print "self $self"
  print "prefix $PREFIX"
  for h in "${HOST_LIST[@]}"; do print "node $h ${MACS[$h]}"; done
  print -l -- "${LINK_LINES[@]}"
}

# --- install -----------------------------------------------------------------
for host in "${HOST_LIST[@]}"; do
  print "== $host =="
  if (( DRY_RUN )); then
    conf_for "$host" | sed 's/^/    /'
    continue
  fi
  tmp="/tmp/mlx-ring-install.$$"
  node_ssh "$host" "mkdir -p $tmp" || exit 1
  node_ssh "$host" "cat > $tmp/apply.zsh" < "$APPLY_SRC" || exit 1
  node_ssh "$host" "cat > $tmp/map.zsh" < "$MAP_SRC" || exit 1
  node_ssh "$host" "cat > $tmp/peer.zsh" < "$PEER_SRC" || exit 1
  conf_for "$host" | node_ssh "$host" "cat > $tmp/mlx-ring.conf" || exit 1
  plist_text | node_ssh "$host" "cat > $tmp/daemon.plist" || exit 1
  install_script | node_ssh "$host" "cat > $tmp/install.zsh" || exit 1
  ssh -t ${SSH_OPTS} "$SSH_USER@$host" "sudo zsh $tmp/install.zsh $tmp; rc=\$?; rm -rf $tmp; exit \$rc" \
    || die "failed on $host; stopping."
done

(( DRY_RUN )) || print "Done. Reboot a node, then run the ring test to confirm."
