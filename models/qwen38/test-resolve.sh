#!/usr/bin/env bash
# Tests for scripts/resolve.sh against the real upstream/ checkout, with a stub
# `docker` so no daemon, GPU or checkpoint is needed. Run: ./test-resolve.sh
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[[ -f $here/upstream/start.sh ]] || { echo "upstream/ is empty: git submodule update --init" >&2; exit 2; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/stack"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/docker"; chmod +x "$tmp/bin/docker"
cp -r "$here/scripts" "$tmp/stack/"; ln -s "$here/upstream" "$tmp/stack/upstream"
export PATH="$tmp/bin:$PATH" HF_CACHE="$tmp/hf" KERNEL_CACHE="$tmp/kc" STATE_DIR="$tmp/state" LOG_DIR="$tmp/logs"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run()  { ( cd "$tmp/stack" && env "$@" ./scripts/resolve.sh ) >"$tmp/out" 2>&1; }
cenv() { grep -E "^$1=" "$tmp/stack/.generated/compose.env" | head -1 | cut -d= -f2-; }

run; rc=$?
check "defaults: resolve succeeds"                  '(( rc == 0 ))'
check "image comes from upstream's config"          '[[ "$(cenv TF_IMAGE)" == tensorfold-qwen38:* ]]'
check "serve command starts with tensorfold-native serve" "[[ \$(cenv TF_COMMAND) == \"'tensorfold-native serve /root/.cache/huggingface/hub/\"* ]]"
check "defaults: --parallel 5, --context 262144"    '[[ "$(cenv TF_COMMAND)" == *"--parallel 5"* && "$(cenv TF_COMMAND)" == *"--context 262144"* ]]'
check "port + served name resolved"                 '[[ "$(cenv TF_PORT)" == 8888 && "$(cenv TF_SERVED_NAME)" == Qwen3.8-Flash-Next ]]'
check "engine.env carries TF_FLASHNEXT_*"           'grep -q "^TF_FLASHNEXT_DRAFTS=6$" "$tmp/stack/.generated/engine.env"'
check "HF mount is the configured cache"            '[[ "$(cenv TF_HF_CACHE)" == "$HF_CACHE" ]]'
check "kernel cache dir created under KERNEL_CACHE" '[[ "$(cenv TF_KERNEL_CACHE)" == "$KERNEL_CACHE"/* && -d "$(cenv TF_KERNEL_CACHE)" ]]'
check "no API key by default"                       '! grep -q TENSORFOLD_API_KEY "$tmp/stack/.generated/engine.env"'
check "memory shortfall is recorded for check.sh"   'grep -q "memory available" "$tmp/stack/.generated/dryrun.log" || [[ $(awk "/MemAvailable/{print int(\$2/1048576)}" /proc/meminfo) -ge 107 ]]'

run PARALLEL=2 CONTEXT=131072 VISION=0 TF_FLASHNEXT_DRAFTS=3 PORT=9001 HOST_PORT=19001; rc=$?
check "overrides: resolve succeeds"                 '(( rc == 0 ))'
check "overrides reach the serve command"           '[[ "$(cenv TF_COMMAND)" == *"--parallel 2"* && "$(cenv TF_COMMAND)" == *"--context 131072"* && "$(cenv TF_COMMAND)" != *--vision* ]]'
check "overrides reach engine.env"                  'grep -q "^TF_FLASHNEXT_DRAFTS=3$" "$tmp/stack/.generated/engine.env"'
check "PORT / HOST_PORT split"                      '[[ "$(cenv TF_PORT)" == 9001 && "$(cenv TF_HOST_PORT)" == 19001 ]]'

run TENSORFOLD_API_KEY=sk-test123; rc=$?
check "API key (name-only -e) lands in engine.env"  '(( rc == 0 )) && grep -q "^TENSORFOLD_API_KEY=sk-test123$" "$tmp/stack/.generated/engine.env"'
check "engine.env is not world-readable"            '[[ "$(stat -c %a "$tmp/stack/.generated/engine.env")" == 600 ]]'

run 'TENSORFOLD_API_KEY=a$b'; rc=$?
check "an API key with shell metacharacters is refused" '(( rc != 0 )) && grep -q "unexpected characters" "$tmp/out"'

# .env is read by upstream's rule (KEY=value, never executed)
printf 'PARALLEL=3\nCONTEXT=65536 # comment\n$(touch %s/pwned)\n' "$tmp" > "$tmp/stack/.env"
run; rc=$?
check ".env values apply, comments stripped"        '(( rc == 0 )) && [[ "$(cenv TF_COMMAND)" == *"--parallel 3"* && "$(cenv TF_COMMAND)" == *"--context 65536"* ]]'
check ".env is never executed"                      '[[ ! -e "$tmp/pwned" ]]'
rm -f "$tmp/stack/.env"

# upstream changing its dry-run output must fail loudly
cp -r "$here/upstream" "$tmp/up2" 2>/dev/null
sed -i 's/^\[dry-run\]/[preview]/; s/\[dry-run\]\\n/[preview]\\n/' "$tmp/up2/start.sh"
rm "$tmp/stack/upstream"; ln -s "$tmp/up2" "$tmp/stack/upstream"
run; rc=$?
check "changed dry-run format fails with a clear message" '(( rc != 0 )) && grep -q "no .\[dry-run\]. command" "$tmp/out"'

echo; echo "$pass passed, $fail failed"
(( fail == 0 ))
