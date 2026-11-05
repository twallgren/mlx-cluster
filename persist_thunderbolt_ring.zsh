#!/bin/zsh
# persist_thunderbolt_ring.zsh
#
# Makes the Thunderbolt ring addresses survive a reboot. The ring script
# (reconfigure_thunderbolt_ring.zsh) sets addresses with ifconfig, which macOS
# forgets at the next boot. This script reads each node's current ring
# addresses, stores them in /usr/local/etc/mlx-ring.conf, and installs a root
# LaunchDaemon that runs ring_boot_apply.zsh to re-apply them at boot and
# whenever one goes missing.
#
# (macOS 27 refuses `networksetup -createnetworkservice` here even from the
# desktop session, so persistent network services are not an option.)
#
# Re-runnable: after moving cables, run with --reconfigure; it rediscovers the
# cabling, applies it live and overwrites the stored config.
#
# Needs an admin password on each node; ssh -t lets you type it in your own
# terminal.

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

Stores each node's current Thunderbolt ring addresses and installs a
LaunchDaemon that re-applies them at boot (and every --interval seconds if
they go missing). Re-run with --reconfigure after moving cables.

Options:
  -H, --hosts LIST     Comma-separated node names (default: ai-1,ai-2,ai-3)
  -u, --user NAME      SSH username on every node (default: $USER)
  --reconfigure        First run reconfigure_thunderbolt_ring.zsh (same
                       --hosts/--user) so the live addresses match the
                       current cabling; use this after moving cables
  --prefix PREFIX      Address prefix that marks ring addresses
                       (default: 192.168.0.)
  --netmask MASK       Netmask for each link (default: 255.255.255.252)
  --interval SECS      Re-check interval in the daemon (default: 30)
  --label LABEL        LaunchDaemon label (default: com.taylorwallgren.mlxring)
  --uninstall          Remove the daemon, script and config from each node
  --dry-run            Print what would run on each node; change nothing
  -h, --help           Show this help

Each node asks for an admin password (sudo) once. The node-side logic lives
in ring_boot_apply.zsh (see its --help). Daemon log: /var/log/mlx-ring.log
on each node.
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
APPLY_DST="/usr/local/libexec/mlx-ring-apply.zsh"
CONF_DST="/usr/local/etc/mlx-ring.conf"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

# Prints "iface ip" lines for ring addresses live on a node, only for links
# that are active (a stale address left on an unplugged port is skipped).
live_ring_addrs() {
  local host="$1"
  ssh ${SSH_OPTS} -o BatchMode=yes "$SSH_USER@$host" ifconfig | awk -v p="$PREFIX" '
    function flush() { if (i ~ /^en/ && ip != "" && st == "active") print i, ip }
    /^[a-z0-9]+:/ { flush(); i = $1; sub(/:$/, "", i); ip = ""; st = "" }
    $1 == "inet" && index($2, p) == 1 { ip = $2 }
    $1 == "status:" { st = $2 }
    END { flush() }'
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

# Script run as root on a node. $1 = temp dir holding apply, conf, plist.
install_script() {
  cat <<EOF
set -e
T="\$1"
mkdir -p /usr/local/libexec /usr/local/etc
launchctl bootout system/$LABEL 2>/dev/null || true
install -m 755 -o root -g wheel "\$T/apply.zsh" $APPLY_DST
install -m 644 -o root -g wheel "\$T/mlx-ring.conf" $CONF_DST
install -m 644 -o root -g wheel "\$T/daemon.plist" $PLIST_DST
launchctl bootstrap system $PLIST_DST
echo "installed $LABEL; config:"
cat $CONF_DST
EOF
}

uninstall_script() {
  cat <<EOF
launchctl bootout system/$LABEL 2>/dev/null || true
rm -f $PLIST_DST $APPLY_DST $CONF_DST
echo "removed $LABEL"
EOF
}

if (( RECONFIGURE && ! UNINSTALL )); then
  if (( DRY_RUN )); then
    print "[dry-run] run $SCRIPT_DIR/reconfigure_thunderbolt_ring.zsh -u $SSH_USER -H $HOSTS"
  else
    print "== Rediscovering ring for current cabling =="
    "$SCRIPT_DIR/reconfigure_thunderbolt_ring.zsh" -u "$SSH_USER" -H "$HOSTS" || exit 1
  fi
fi

for host in "${HOST_LIST[@]}"; do
  if (( UNINSTALL )); then
    print "== $host: uninstall =="
    if (( DRY_RUN )); then
      uninstall_script | sed 's/^/    /'
    else
      ssh -t ${SSH_OPTS} "$SSH_USER@$host" "sudo zsh -c '$(uninstall_script | tr '\n' ';')'" \
        || { print -u2 "ERROR: failed on $host; stopping."; exit 1; }
    fi
    continue
  fi

  pairs=("${(@f)$(live_ring_addrs "$host")}")
  pairs=("${(@)pairs:#}")
  if (( ${#pairs} == 0 )); then
    print -u2 "ERROR: $host has no live ${PREFIX}x ring addresses. Run with --reconfigure first."
    exit 1
  fi

  print "== $host =="
  print -l -- "${pairs[@]}" | sed 's/^/    /'
  if (( DRY_RUN )); then
    print "[dry-run] would install $APPLY_DST, $CONF_DST and $PLIST_DST, then launchctl bootstrap"
    continue
  fi

  tmp="/tmp/mlx-ring-install.$$"
  ssh ${SSH_OPTS} "$SSH_USER@$host" "mkdir -p $tmp" || exit 1
  ssh ${SSH_OPTS} "$SSH_USER@$host" "cat > $tmp/apply.zsh" < "$APPLY_SRC" || exit 1
  print -l -- "${pairs[@]}" | ssh ${SSH_OPTS} "$SSH_USER@$host" "cat > $tmp/mlx-ring.conf" || exit 1
  plist_text | ssh ${SSH_OPTS} "$SSH_USER@$host" "cat > $tmp/daemon.plist" || exit 1
  install_script | ssh ${SSH_OPTS} "$SSH_USER@$host" "cat > $tmp/install.zsh" || exit 1
  ssh -t ${SSH_OPTS} "$SSH_USER@$host" "sudo zsh $tmp/install.zsh $tmp; rc=\$?; rm -rf $tmp; exit \$rc" \
    || { print -u2 "ERROR: failed on $host; stopping."; exit 1; }
done

(( DRY_RUN || UNINSTALL )) || print "Done. Reboot a node and run the ring test to confirm the addresses persist."
