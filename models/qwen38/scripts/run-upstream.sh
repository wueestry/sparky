#!/usr/bin/env bash
# Run a command with this stack's .env exported, then exec it.
#
#   scripts/run-upstream.sh upstream/scripts/prepare.sh [args]
#
# Upstream's scripts cd into upstream/ and read ./.env from there, not from
# this directory. This loads ../.env into the environment first (upstream's
# config.sh lets the environment win over its defaults), using the same rule
# as config.sh: KEY=value lines are read, never executed.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

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
exec "$@"
