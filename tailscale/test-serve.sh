#!/usr/bin/env bash
# Tests for sparky-tailscale-serve with a stub `tailscale` (no daemon, no network).
# Run: ./test-serve.sh
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The stub records every call; its behaviour is set through environment variables.
cat > "$tmp/tailscale" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "status --json") echo "{\"BackendState\": \"${STUB_STATE:-Running}\"}" ;;
  "serve set-config") [[ "${3:-}" == --help ]] && { [[ -n "${STUB_NO_SETCONFIG:-}" ]] && exit 1; echo usage; } ;;
  "debug prefs") echo '{"AdvertiseServices": ["svc:a", "svc:b"]}' ;;
esac
exit 0
STUB
chmod +x "$tmp/tailscale"
export TAILSCALE="$tmp/tailscale" STUB_LOG="$tmp/log" WAIT_SECONDS=2

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() { : > "$tmp/log"; "$here/sparky-tailscale-serve" "$@" >"$tmp/out" 2>&1; }

run apply "$here/services.json"; rc=$?
check "apply succeeds when tailscale is running"        '(( rc == 0 ))'
check "node :80 proxies to Traefik on loopback"          'grep -qx "serve --bg --yes --http=80 http://127.0.0.1:80" "$tmp/log"'
check "node :443 proxies with https+insecure"            'grep -qx "serve --bg --yes --https=443 https+insecure://127.0.0.1:443" "$tmp/log"'
check "services applied with --all from the given file"  'grep -qx "serve set-config --all $here/services.json" "$tmp/log"'
check "services come last (after the node-level serve)"  '[[ "$(grep -n "set-config --all" "$tmp/log" | cut -d: -f1)" -gt "$(grep -n -- "--https=443" "$tmp/log" | cut -d: -f1)" ]]'
check "reports how many services were applied"           'grep -q "applied node :80/:443 and 6 services" "$tmp/out"'

STUB_STATE=NeedsLogin run apply "$here/services.json"; rc=$?
check "refuses when not logged in, nothing is applied"   '(( rc != 0 )) && grep -q "not logged in" "$tmp/out" && ! grep -qE "^serve (--bg|set-config --all)" "$tmp/log"'

STUB_NO_SETCONFIG=1 run apply "$here/services.json"; rc=$?
check "refuses an old tailscale without set-config"      '(( rc != 0 )) && grep -q "upgrade it" "$tmp/out" && ! grep -qE "^serve (--bg|set-config --all)" "$tmp/log"'

run apply "$tmp/missing.json"; rc=$?
check "refuses a missing services file"                  '(( rc != 0 )) && grep -q "cannot read" "$tmp/out"'

run status; rc=$?
check "status lists advertised services"                 '(( rc == 0 )) && grep -q "svc:a" "$tmp/out" && grep -q "svc:b" "$tmp/out"'

run bogus; rc=$?
check "unknown command exits 64 with usage"              '(( rc == 64 )) && grep -q usage "$tmp/out"'

# services.json shape: every service has the two endpoints and loopback targets
python3 - "$here/services.json" <<'PY' && ok "services.json: versioned, every service maps tcp:80 and tcp:443 to loopback" || bad "services.json shape"
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d["version"] == "0.0.1" and d["services"]
for name, s in d["services"].items():
    assert re.fullmatch(r"svc:[a-z0-9-]+", name), name
    assert s["endpoints"] == {"tcp:80": "http://127.0.0.1:80", "tcp:443": "https+insecure://127.0.0.1:443"}, name
PY

echo; echo "$pass passed, $fail failed"
(( fail == 0 ))
