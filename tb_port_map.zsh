#!/bin/zsh
# tb_port_map.zsh
#
# Runs ON a node (no root needed). Prints one line per Thunderbolt IP port:
#
#   <iface> <socket> <own-mac> <cabled: yes|no>
#
# The port list and the cabled flag come from the IORegistry (an
# IOThunderboltXDomainLink under the port's controller means another Mac is on
# the cable), so they do not depend on interface numbering. The MAC is the
# port's own, from ifconfig; these have stayed fixed across reboots and macOS
# updates, unlike the Thunderbolt Domain UUIDs, which change at every boot.
#
# Used by ring_boot_apply.zsh and persist_thunderbolt_ring.zsh. To learn which
# Mac is on the other end, see tb_peer_mac.zsh.

emulate -L zsh

usage() {
  cat <<'EOF'
tb_port_map.zsh [-h]

Prints "<iface> <socket> <own-mac> <yes|no>" for each Thunderbolt IP port on
this Mac (yes = another Mac is on the cable). Read-only.
EOF
}

case "$1" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) print -u2 "ERROR: unknown option: $1"; usage >&2; exit 1 ;;
esac

# LC_ALL=C: ioreg output can hold bytes that are not valid UTF-8, which awk
# rejects under a UTF-8 locale (forwarded by ssh from the user's terminal).
ioreg -l -w0 | LC_ALL=C awk '
  function flush() {
    if (in_ctl && iface != "") print iface, (sock == "" ? "-" : sock), (link ? "yes" : "no")
  }
  function val(line) { sub(/^[^=]*= *"?/, "", line); sub(/"$/, "", line); return line }
  /\+-o / && /<class IOThunderboltController/ {
    flush(); in_ctl = 1; iface = sock = ""; link = 0; next
  }
  !in_ctl { next }
  /\+-o / && /<class IOThunderboltXDomainLink/ { link = 1; next }
  /"BSD Name" = "en[0-9]+"/ { if (iface == "") iface = val($0); next }
  /"Socket ID" = / { if (sock == "") sock = val($0); next }
  END { flush() }
' | while read -r iface sock cabled; do
  mac=$(ifconfig "$iface" 2>/dev/null | awk '$1 == "ether" {print $2; exit}')
  print -r -- "$iface $sock ${mac:--} $cabled"
done
