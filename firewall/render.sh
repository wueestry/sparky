#!/usr/bin/env bash
# Render ruleset.nft.in into a loadable nftables file.
#
#   render.sh [output-file]        # default: build/ruleset.nft
#
# Settings come from ./.env (KEY=value lines, read by the same rule as the other
# stacks: never executed) or the environment, which wins: LAN_CIDR, NTP_SERVERS
# (optional, comma-separated IPv4 addresses), MODE (enforce|audit). Every value is validated before it is put into a file that
# is loaded as root.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

if [[ -f .env ]]; then
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ "$_line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    _key=${BASH_REMATCH[2]}; _value=${BASH_REMATCH[3]}
    if [[ "$_value" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ || "$_value" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      _value=${BASH_REMATCH[1]}
    else
      _value=${_value%%#*}; _value=${_value%"${_value##*[![:space:]]}"}
    fi
    [[ -n "${!_key+set}" ]] || export "$_key=$_value"
  done < .env
fi

out=${1:-build/ruleset.nft}
mkdir -p "$(dirname "$out")"

LAN_CIDR=${LAN_CIDR:-192.168.1.0/24} NTP_SERVERS=${NTP_SERVERS:-} MODE=${MODE:-enforce} \
python3 - "$out" <<'PY'
import ipaddress, os, re, sys

def die(msg):
    sys.exit("render: " + msg)

lan, servers, mode = os.environ["LAN_CIDR"], os.environ["NTP_SERVERS"], os.environ["MODE"]
try:
    net = ipaddress.ip_network(lan, strict=False)   # 192.168.1.1/24 (a host address) means 192.168.1.0/24
except ValueError as e:
    die(f"LAN_CIDR {lan!r}: {e}")
if str(net) != lan:
    print(f"render: LAN_CIDR {lan} normalised to the network {net}", file=sys.stderr)
if net.version != 4:
    die("LAN_CIDR must be IPv4 (IPv6 is blocked by design)")
if net.prefixlen < 8:
    die(f"LAN_CIDR {lan} is wider than a /8: that is not a local network")
ntp = []
for s in filter(None, (x.strip() for x in servers.split(","))):
    try:
        a = ipaddress.ip_address(s)
    except ValueError:
        die(f"NTP_SERVERS: {s!r} is not an IP address (nftables cannot match hostnames)")
    if a.version != 4:
        die(f"NTP_SERVERS: {s} must be IPv4 (IPv6 is blocked by design)")
    ntp.append(str(a))
ntp_rule = ("        ip daddr { %s } udp dport 123 accept                      # NTP, to these servers only\n" % ", ".join(ntp)) if ntp else ""
if mode not in ("audit", "enforce"):
    die(f"MODE must be audit or enforce, not {mode!r}")

if mode == "enforce":
    final_in = (
        '        limit rate 6/minute log prefix "sparky-fw in: " level warn\n'
        '        counter drop'
    )
    final_out = (
        '        limit rate 6/minute log prefix "sparky-fw out: " level warn\n'
        '        meta l4proto tcp counter reject with tcp reset\n'
        '        counter reject with icmpx type admin-prohibited'
    )
else:
    final_in = (
        '        limit rate 30/minute burst 20 packets log prefix "sparky-fw AUDIT in: " level warn\n'
        '        counter accept'
    )
    final_out = (
        '        limit rate 30/minute burst 20 packets log prefix "sparky-fw AUDIT out: " level warn flags skuid\n'
        '        counter accept'
    )

text = open("ruleset.nft.in").read()
for key, val in {"@LAN_CIDR@": str(net), "@NTP_RULE@": ntp_rule, "@MODE@": mode,
                 "@FINAL_IN@": final_in, "@FINAL_OUT@": final_out}.items():
    if key not in text:
        die(f"template has no {key}")
    text = text.replace(key, val)
left = re.findall(r"@[A-Z_]+@", text)
if left:
    die(f"unsubstituted placeholders: {sorted(set(left))}")
open(sys.argv[1], "w").write(text)
print(f"render: wrote {sys.argv[1]} (mode={mode}, lan={net}, ntp={",".join(ntp) or "LAN only"})")
PY
