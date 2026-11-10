#!/usr/bin/env bash
# Move the upstream submodule to a new ref and check this overlay still fits.
#
#   scripts/update-upstream.sh [ref]     # default: origin/main
#
# Shows what changed in the files this stack depends on, bumps the submodule,
# and re-runs scripts/resolve.sh against the new start.sh. If resolving breaks,
# the submodule is put back and nothing is left half-updated.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

ref=${1:-origin/main}
up=(git -C upstream)
"${up[@]}" fetch -q origin
old=$("${up[@]}" rev-parse HEAD)
new=$("${up[@]}" rev-parse --verify -q "$ref^{commit}") || { echo "update: unknown ref $ref" >&2; exit 1; }
if [[ "$old" == "$new" ]]; then echo "update: already at ${old:0:12}"; exit 0; fi

echo "== commits ${old:0:8}..${new:0:8}"
"${up[@]}" log --format='%h %ad %s' --date=short "$old..$new" | head -40
echo
echo "== files this overlay depends on (start.sh dry-run format, config.sh, prepare.sh, stop.sh)"
"${up[@]}" diff --stat "$old" "$new" -- start.sh stop.sh scripts/config.sh scripts/prepare.sh
echo

"${up[@]}" checkout -q "$new"
if ! ./scripts/resolve.sh; then
  echo "update: resolve.sh no longer fits upstream's start.sh at ${new:0:12}: reverting" >&2
  "${up[@]}" checkout -q "$old"
  echo "update: read the diff above (git -C upstream diff ${old:0:8} ${new:0:8} -- start.sh), adapt scripts/resolve.sh, then retry" >&2
  exit 1
fi
cat <<MSG

update: upstream is now ${new:0:12}. Next:
  make prepare && make check     # new image / checkpoint pin, new arguments
  make up && make smoke
  git add models/qwen38/upstream && git commit   # records the bump
MSG
