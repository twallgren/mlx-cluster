#!/bin/zsh
# tb_peer_mac.zsh
#
# Runs ON a node. Prints the MAC of the Mac on the other end of one
# Thunderbolt port, without needing any IPv4 ring address: it gives the port
# its own EUI-64 IPv6 link-local address (macOS leaves IPv6 off on these
# ports), pings the all-nodes address on that port, and looks up the replying
# address in the neighbour table. The peer must also have its link-local
# address up, which its own ring daemon does at boot.
#
# Changes the interface (adds an IPv6 address), so it needs root, or the
# cluster's passwordless sudo rule for /sbin/ifconfig.

emulate -L zsh

COUNT=2

usage() {
  cat <<'EOF'
tb_peer_mac.zsh [options] IFACE

Prints the MAC of the peer on Thunderbolt port IFACE, found over IPv6
link-local. Exits 1 if no peer answers. Adds this port's own link-local
address if missing (root or sudo -n /sbin/ifconfig).

Options:
  -c, --count N   Pings to send to the all-nodes address (default: 2)
  -h, --help      Show this help
EOF
}

IFACE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--count) COUNT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) print -u2 "ERROR: unknown option: $1"; usage >&2; exit 1 ;;
    *) IFACE="$1"; shift ;;
  esac
done
[[ -n "$IFACE" ]] || { usage >&2; exit 1; }

IFCONFIG=(/sbin/ifconfig)
(( EUID == 0 )) || IFCONFIG=(sudo -n /sbin/ifconfig)

# 36:1a:b:e:d5:40 -> 36:1a:0b:0e:d5:40
norm_mac() {
  local x; local -a out
  for x in ${(s.:.)1}; do out+=($(printf '%02x' $(( 16#$x )))); done
  print -r -- "${(j.:.)out}"
}

# fe80::<EUI-64> from a MAC: flip the universal/local bit, insert ff:fe.
eui64_ll() {
  local -a o=(${(s.:.)1})
  local first=$(( 16#${o[1]} ^ 2 ))
  printf 'fe80::%x:%x:%x:%x\n' $(( first << 8 | 16#${o[2]} )) $(( 16#${o[3]} << 8 | 0xff )) \
    $(( 0xfe << 8 | 16#${o[4]} )) $(( 16#${o[5]} << 8 | 16#${o[6]} ))
}

own=$(ifconfig "$IFACE" 2>/dev/null | awk '$1 == "ether" {print $2; exit}')
[[ -n "$own" ]] || { print -u2 "ERROR: no such interface: $IFACE"; exit 1; }
own=$(norm_mac "$own")

if ! ifconfig "$IFACE" | grep -q 'inet6 fe80:'; then
  "${IFCONFIG[@]}" "$IFACE" inet6 "$(eui64_ll "$own")%$IFACE" prefixlen 64 alias || exit 1
  sleep 1
fi
# An address can be present while IPv6 is still marked disabled on the port
# (ping6 then says "Network is down"); clearing the flag is harmless if unset.
if ndp -i "$IFACE" 2>/dev/null | grep -q IFDISABLED; then
  "${IFCONFIG[@]}" "$IFACE" inet6 -ifdisabled || exit 1
fi

# Addresses that answered, other than our own.
mine=(${(f)"$(ifconfig "$IFACE" | awk '$1 == "inet6" {sub(/%.*/, "", $2); print $2}')"})
for addr in ${(u)${(f)"$(ping6 -c "$COUNT" -i 0.5 "ff02::1%$IFACE" 2>/dev/null \
    | awk '/bytes from/ {a = $4; sub(/%.*/, "", a); sub(/,$/, "", a); print a}')"}}; do
  (( ${mine[(Ie)$addr]} )) && continue
  mac=$(ndp -n "$addr%$IFACE" 2>/dev/null | awk 'NR > 1 {print $2; exit}')
  [[ -n "$mac" && "$mac" != "(incomplete)" ]] || continue
  mac=$(norm_mac "$mac")
  [[ "$mac" == "$own" ]] && continue
  print -r -- "$mac"
  exit 0
done
exit 1
