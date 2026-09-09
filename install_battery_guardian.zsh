#!/bin/zsh
#
# install_battery_guardian.zsh — deploy battery_guardian.zsh to cluster
# nodes as a launchd agent
#
# Run from the client — this is a one-time (or re-run-to-update) setup
# step, NOT something that needs to stay running. Once installed, each
# node's guardian runs independently via launchd: starts at login
# (RunAtLoad), restarts if it crashes (KeepAlive), and has no dependency
# on the client or any other node being up. Pairs with Automatic Login
# (see 00_manual_checklist.md step 3) so it's running again immediately after any
# reboot, unattended.
#
# Usage:
#   install_battery_guardian.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

SCRIPT_DIR="${0:A:h}"

# ---------- defaults ----------
HOSTS="ai-1,ai-2,ai-3"
SSH_USER="$USER"
THRESHOLD=10
INTERVAL=30

usage() {
  cat <<'EOF'
install_battery_guardian.zsh [options]

Options:
  -H, --hosts LIST                    Comma-separated hostnames (default: ai-1,ai-2,ai-3)
  -u, --user NAME                     SSH username, same on all nodes (default: $USER)
  -t, --threshold PCT                 Passed through to battery_guardian.zsh (default: 10)
  -i, --interval SEC                  Passed through to battery_guardian.zsh (default: 30)
  -h, --help                          Show this help.

Re-run any time to update the deployed script/config on all nodes — it's
idempotent (unloads and reloads the launchd agent each time).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hosts) HOSTS="$2"; shift 2 ;;
    -u|--user) SSH_USER="$2"; shift 2 ;;
    -t|--threshold) THRESHOLD="$2"; shift 2 ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Built from SSH_USER (the remote account), not the local $USER -- those
# can differ if --user is passed, and this label identifies the launchd
# agent on the REMOTE machine.
LABEL="com.${SSH_USER}.battery-guardian"

HOST_LIST=("${(@s/,/)HOSTS}")
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

for host in "${HOST_LIST[@]}"; do
  echo "\n== $host =="

  scp ${=SSH_OPTS} -q "$SCRIPT_DIR/battery_guardian.zsh" "$SSH_USER@$host:~/battery_guardian.zsh"
  ssh ${=SSH_OPTS} "$SSH_USER@$host" "chmod +x ~/battery_guardian.zsh"

  # launchd's environment for agents does NOT include $HOME or other
  # inherited shell variables — every path must be absolute and resolved
  # here, not left for the remote shell to expand.
  REMOTE_HOME=$(ssh ${=SSH_OPTS} "$SSH_USER@$host" 'echo $HOME')

  PLIST=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${REMOTE_HOME}/battery_guardian.zsh</string>
    <string>--threshold</string>
    <string>${THRESHOLD}</string>
    <string>--interval</string>
    <string>${INTERVAL}</string>
    <string>--log</string>
    <string>${REMOTE_HOME}/battery_guardian.log</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${REMOTE_HOME}/battery_guardian.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${REMOTE_HOME}/battery_guardian.stderr.log</string>
</dict>
</plist>
EOF
)

  ssh ${=SSH_OPTS} "$SSH_USER@$host" "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/${LABEL}.plist" <<< "$PLIST"

  # Idempotent (re)load: bootout is a no-op (with a harmless stderr
  # message) if it wasn't loaded yet.
  ssh ${=SSH_OPTS} "$SSH_USER@$host" "launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/${LABEL}.plist 2>/dev/null; launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/${LABEL}.plist"
  ssh ${=SSH_OPTS} "$SSH_USER@$host" "launchctl print gui/\$(id -u)/${LABEL} 2>&1 | grep -E 'state|pid' | head -2"
done

echo "\nInstalled. Verify on any node with:"
echo "  ssh $SSH_USER@ai-1 'tail -5 ~/battery_guardian.log'"
echo "To remove from a node:"
echo "  ssh $SSH_USER@ai-1 \"launchctl bootout gui/\\\$(id -u) ~/Library/LaunchAgents/${LABEL}.plist\""
