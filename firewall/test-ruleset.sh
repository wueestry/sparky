#!/usr/bin/env bash
# Tests for the host firewall, in a throwaway user+network namespace: no root, no
# effect on the real network. It renders the real template and drives the real
# sparky-firewall script; only systemd-run, systemctl and tailscale are stubs.
# Needs: nft, ip, python3, unshare with unprivileged user namespaces.
#
#   ./test-ruleset.sh
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

if [[ ${1:-} != --inner ]]; then
  for c in nft ip python3 unshare; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c not found"; exit 0; }
  done
  unshare -Urn true 2>/dev/null || { echo "SKIP: unprivileged user namespaces are not available"; exit 0; }
  exec unshare -Urnm "$0" --inner
fi

tmp=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---------------------------------------------------------------- render
render() { ( cd "$here" && env LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}" TIMESYNC_USER="${TIMESYNC_USER:-0}" MODE="$1" ./render.sh "$2" ) >"$tmp/render.out" 2>&1; }
render enforce "$tmp/enforce.nft"; rc=$?
check "render: enforce renders"                      '(( rc == 0 )) && ! grep -q "@[A-Z_]*@" "$tmp/enforce.nft"'
check "render: mode is recorded in the file"         'grep -qx "# sparky-fw mode: enforce" "$tmp/enforce.nft"'
check "render: enforce rejects, audit accepts"       'render audit "$tmp/audit.nft" && grep -q "reject with tcp reset" "$tmp/enforce.nft" && ! grep -q "reject" "$tmp/audit.nft" && grep -q "AUDIT out" "$tmp/audit.nft"'
check "render: 192.168.1.1/24 is normalised to the network" 'LAN_CIDR=192.168.1.1/24 render enforce "$tmp/n.nft" && grep -q "^define LAN = 192.168.1.0/24" "$tmp/n.nft" && grep -q normalised "$tmp/render.out"'
for bad_env in "LAN_CIDR=0.0.0.0/0" "LAN_CIDR=nonsense" "LAN_CIDR=fd00::/64" "TIMESYNC_USER=a;b" "TIMESYNC_USER=\$(id)"; do
  check "render: refuses $bad_env"                   '( export "$bad_env"; ! render enforce "$tmp/x.nft" )'
done
check "render: refuses a bad MODE"                   '! render bogus "$tmp/x.nft"'
check "nft -c accepts both modes"                    'nft -c -f "$tmp/enforce.nft" && nft -c -f "$tmp/audit.nft"'

# ---------------------------------------------------------------- namespaces
mount -t tmpfs tmpfs /run; mkdir -p /run/netns
ip netns add lan
ip link add h0 type veth peer name l0
ip link set l0 netns lan
ip addr add 192.168.1.10/24 dev h0; ip link set h0 up; ip link set lo up
ip netns exec lan sh -c 'ip addr add 192.168.1.50/24 dev l0; ip link set l0 up; ip link set lo up; ip addr add 203.0.113.5/32 dev lo'
ip route add 203.0.113.5/32 via 192.168.1.50            # "the internet" is an address in the peer namespace
ip -6 addr add fd00::10/64 dev h0 nodad 2>/dev/null; ip netns exec lan ip -6 addr add fd00::50/64 dev l0 nodad 2>/dev/null
for p in 80 22 9999; do python3 -m http.server $p --bind 0.0.0.0 >/dev/null 2>&1 & done
ip netns exec lan python3 -m http.server 443 --bind 0.0.0.0 >/dev/null 2>&1 &
ip netns exec lan python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &
sleep 1

conn()   { python3 - "$@" <<'PY'
import socket,sys
s=socket.socket(); s.settimeout(3); s.connect((sys.argv[1], int(sys.argv[2]))); s.close()
PY
}
inlan()  { ip netns exec lan "$@"; }
marked() { python3 - "$@" <<'PY'
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, int(sys.argv[3],0)); s.settimeout(3); s.connect((sys.argv[1], int(sys.argv[2]))); s.close()
PY
}
export -f conn inlan marked
t() { local n=$1 e=$2; shift 2; local r=1
      timeout 6 bash -c '"$@"' _ "$@" >/dev/null 2>&1 && r=0
      if [[ $r == "$e" ]]; then pass=$((pass + 1)); echo "ok   - $n"; else fail=$((fail + 1)); echo "FAIL - $n (got $r, want $e)"; fi; }
fromlan() { inlan python3 -c "import socket;s=socket.socket();s.settimeout(2);s.connect(('192.168.1.10',$1))"; }
export -f fromlan

echo "--- sanity: nothing filtered yet"
t "lan -> host:9999 reachable"   0 fromlan 9999
t "host -> internet:443 reachable" 0 conn 203.0.113.5 443

# ---------------------------------------------------------------- the ruleset itself
nft -f "$tmp/enforce.nft" || { echo "ENFORCE RULESET FAILED TO LOAD"; exit 1; }
echo "--- enforce ruleset: inbound"
for p in 80 22; do t "lan -> host:$p allowed" 0 fromlan $p; done
t "lan -> host:9999 dropped"        1 fromlan 9999
t "lan ping host allowed"           0 inlan ping -c1 -W2 192.168.1.10
echo "--- enforce ruleset: outbound"
t "host -> lan peer:8080 allowed"   0 conn 192.168.1.50 8080
t "host -> internet:443 rejected"   1 conn 203.0.113.5 443
s=$(date +%s%N); conn 203.0.113.5 443 >/dev/null 2>&1; ms=$(( ($(date +%s%N) - s) / 1000000 ))
check "rejection is fast (${ms}ms, a drop would take the 3s timeout)" '(( ms < 1500 ))'
t "loopback allowed"                0 conn 127.0.0.1 80
t "IPv6 to the peer rejected"       1 ping -6 -c1 -W2 fd00::50
t "::1 allowed"                     0 ping -6 -c1 -W2 ::1
echo "--- identity"
t "socket with tailscaled's bypass mark gets out"      0 marked 203.0.113.5 443 0x80000
t "another mark in the same byte does not"             1 marked 203.0.113.5 443 0x10000
echo "--- egress window (raw set element)"
nft add element inet sparky_fw maint_dst '{ 0.0.0.0/0 timeout 4s }'
t "egress open during the window"   0 conn 203.0.113.5 443
sleep 5
t "closes by itself when the timeout expires" 1 conn 203.0.113.5 443
echo "--- reload is atomic"
nft -f "$tmp/enforce.nft" && t "reload keeps LAN access working" 0 fromlan 80
nft delete table inet sparky_fw

# ---------------------------------------------------------------- the control script
stubs=$tmp/stubs; mkdir -p "$stubs"
for s in systemd-run systemctl tailscale; do
  printf '#!/bin/sh\necho "$0 $*" >> "%s/%s.log"\nexit 0\n' "$tmp" "$s" > "$stubs/$s"; chmod +x "$stubs/$s"
done
export NFT=nft SYSTEMD_RUN=$stubs/systemd-run SYSTEMCTL=$stubs/systemctl TAILSCALE=$stubs/tailscale
export CONF_DIR=$tmp/conf STATE_DIR=$tmp/state LIB_DIR=$tmp/lib SELF=$here/sparky-firewall REVERT_SECONDS=120
fw() { "$here/sparky-firewall" "$@"; }
status_has() { local o; o=$(fw status 2>&1); [[ $o == *"$1"* ]]; }
status_re()  { local o; o=$(fw status 2>&1); grep -qE "$1" <<<"$o"; }
logcount() { grep -c -- "$2" "$tmp/$1.log" 2>/dev/null || echo 0; }

echo "--- script: apply / confirm / revert"
render enforce "$tmp/enforce.nft"; render audit "$tmp/audit.nft"
fw apply "$tmp/enforce.nft" >"$tmp/o" 2>&1; rc=$?
check "enforce is refused until an audit has been reviewed" '(( rc != 0 )) && grep -q "no audit period" "$tmp/o" && ! nft list table inet sparky_fw >/dev/null 2>&1'
fw apply "$tmp/audit.nft" >"$tmp/o" 2>&1; rc=$?
check "audit applies"                                       '(( rc == 0 )) && nft list table inet sparky_fw >/dev/null 2>&1'
t "audit mode lets internet traffic through"                0 conn 203.0.113.5 443
check "apply armed the revert timer (120s)"                 'grep -q -- "--unit=sparky-fw-revert" "$tmp/systemd-run.log" && grep -q -- "--on-active=120s" "$tmp/systemd-run.log"'
check "apply set tailscale --netfilter-mode=off"            'grep -q "set --netfilter-mode=off" "$tmp/tailscale.log"'
check "status shows AUDIT and the armed revert"             'status_has "STATE: AUDIT" && status_has "revert timer: ARMED"'
fw confirm >/dev/null 2>&1
check "confirm cancels the timer and enables the boot unit" 'grep -q "stop sparky-fw-revert.timer" "$tmp/systemctl.log" && grep -q "enable sparky-firewall.service" "$tmp/systemctl.log" && ! status_has "revert timer"'

printf '%s\n' \
  'kernel: sparky-fw AUDIT out: IN= OUT=eth0 SRC=192.168.1.10 DST=140.82.112.3 LEN=60 PROTO=TCP SPT=40000 DPT=443 UID=1000 GID=1000' \
  'kernel: sparky-fw AUDIT out: IN= OUT=eth0 SRC=192.168.1.10 DST=140.82.112.3 LEN=60 PROTO=TCP SPT=40001 DPT=443 UID=1000 GID=1000' \
  'kernel: sparky-fw AUDIT out: IN= OUT=eth0 SRC=192.168.1.10 DST=91.189.91.83 LEN=60 PROTO=TCP SPT=40002 DPT=80 UID=0 GID=0' > "$tmp/audit.log"
AUDIT_LOG_FILE=$tmp/audit.log fw audit-report >"$tmp/o" 2>&1
check "audit-report groups by user and destination"         'grep -qE "^ +2 +[a-z0-9_-]+ +TCP +140.82.112.3:443" "$tmp/o" && grep -qE "^ +1 +root +TCP +91.189.91.83:80" "$tmp/o"'
check "audit-report records the review (unlocks enforce)"   '[[ -f $LIB_DIR/audit-reviewed ]]'

fw apply "$tmp/enforce.nft" >/dev/null 2>&1; rc=$?
check "enforce applies after the audit was reviewed"        '(( rc == 0 ))'
t "enforce blocks the internet"                             1 conn 203.0.113.5 443
check "the previous (audit) ruleset was kept for revert"    '[[ "$(sed -n "s/^# sparky-fw mode: //p" "$CONF_DIR/ruleset.nft.prev")" == audit ]]'
fw apply "$tmp/enforce.nft" >/dev/null 2>&1
check "a second apply before confirming keeps the ORIGINAL previous" '[[ "$(sed -n "s/^# sparky-fw mode: //p" "$CONF_DIR/ruleset.nft.prev")" == audit ]]'
fw revert >/dev/null 2>&1
t "revert restores the previous ruleset (internet open again)" 0 conn 203.0.113.5 443
check "revert installed it as the current ruleset"          '[[ "$(sed -n "s/^# sparky-fw mode: //p" "$CONF_DIR/ruleset.nft")" == audit ]]'
fw apply "$tmp/enforce.nft" >/dev/null 2>&1; fw confirm >/dev/null 2>&1

echo "--- script: DISABLE / ENABLE (the internet is closed by default)"
t "enforcing: internet closed"                              1 conn 203.0.113.5 443
t "enforcing: unlisted LAN port closed"                     1 fromlan 9999
fw disable 1 >"$tmp/o" 2>&1; rc=$?
check "disable succeeds and says so"                        '(( rc == 0 )) && grep -q "DISABLED" "$tmp/o" && ! nft list table inet sparky_fw >/dev/null 2>&1'
t "disabled: internet reachable (image pulls work)"         0 conn 203.0.113.5 443
t "disabled: everything is open, inbound too"               0 fromlan 9999
check "disable armed the re-enable timer (60s)"             'grep -q -- "--unit=sparky-fw-reenable" "$tmp/systemd-run.log" && grep -q -- "--on-active=60s" "$tmp/systemd-run.log"'
check "status says DISABLED and when it re-enables"         'status_re "^STATE: DISABLED.*re-enables in [0-9]+s"'
fw enable >"$tmp/o" 2>&1; rc=$?
check "enable succeeds"                                     '(( rc == 0 )) && nft list table inet sparky_fw >/dev/null 2>&1'
t "enabled: internet closed again immediately"              1 conn 203.0.113.5 443
t "enabled: unlisted LAN port closed again"                 1 fromlan 9999
check "enable cancelled the re-enable timer"                '! status_has "re-enables" && status_has "STATE: ENFORCING"'
fw enable >/dev/null 2>&1; check "enable is idempotent"     '[[ $? == 0 ]] && nft list table inet sparky_fw >/dev/null 2>&1'
for m in 999 0 abc -5; do check "disable refuses MINUTES=$m" '! fw disable "$m" >/dev/null 2>&1 && nft list table inet sparky_fw >/dev/null 2>&1'; done
fw disable >/dev/null 2>&1
check "disable defaults to 30 minutes"                      'grep -q -- "--on-active=1800s" "$tmp/systemd-run.log"'
fw enable >/dev/null 2>&1

echo "--- script: egress-only window"
fw open 1 >/dev/null 2>&1
t "open: internet reachable"                                0 conn 203.0.113.5 443
t "open: inbound filtering unchanged"                       1 fromlan 9999
check "status shows the window"                             'status_has "egress window: OPEN"'
fw open 5 >/dev/null 2>&1; check "open renews a running window" '[[ $? == 0 ]]'
fw close >/dev/null 2>&1
t "close: internet closed"                                  1 conn 203.0.113.5 443
check "closing a closed window says so"                     'fw close 2>&1 | grep -q "no egress window"'
check "open refuses MINUTES above the cap"                  '! fw open 999 >/dev/null 2>&1'

echo "--- script: check / revert-to-nothing / misc"
fw check "$tmp/enforce.nft" >"$tmp/o" 2>&1; check "check passes a good ruleset"     '[[ $? == 0 ]] && grep -q "ruleset parses (mode: enforce)" "$tmp/o"'
echo "table inet x {" > "$tmp/garbage.nft"
check "check refuses a bad ruleset"                         '! fw check "$tmp/garbage.nft" >/dev/null 2>&1'
fw apply "$tmp/garbage.nft" >/dev/null 2>&1
check "apply refuses a bad ruleset and leaves the old one"  '[[ $? != 0 ]] && status_has "STATE: ENFORCING"'
rm -rf "$CONF_DIR" "$STATE_DIR"; nft delete table inet sparky_fw 2>/dev/null
: > "$tmp/tailscale.log"
fw apply "$tmp/audit.nft" >/dev/null 2>&1; fw revert >/dev/null 2>&1
check "revert with no previous ruleset turns the firewall off" '! nft list table inet sparky_fw >/dev/null 2>&1 && [[ ! -f $CONF_DIR/ruleset.nft ]]'
check "...and gives tailscale its netfilter back"           'grep -q "set --netfilter-mode=on" "$tmp/tailscale.log"'
check "disable with nothing installed refuses"              '! fw disable >/dev/null 2>&1'
check "unknown command exits 64"                            'fw bogus >/dev/null 2>&1; [[ $? == 64 ]]'

echo; echo "$pass passed, $fail failed"
(( fail == 0 ))
