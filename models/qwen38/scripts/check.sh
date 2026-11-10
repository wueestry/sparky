#!/usr/bin/env bash
# Pre-flight for `make up`: everything upstream/start.sh checks before it
# launches, minus what is rootful-only. Run after `make env`.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

die() { echo "check: $*" >&2; exit 1; }
ok()  { echo "check: ok: $*"; }
[[ -f .generated/compose.env ]] || die "run make env first"
set -a; . .generated/compose.env; set +a

command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is the rootless daemon running? systemctl --user status docker)"
if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then ok "rootless Docker"
else echo "check: note: this Docker daemon is not rootless; the stack works there too"; fi
docker network inspect traefik >/dev/null 2>&1 || die "network 'traefik' is missing: bring up traefik/ first"
# prepare.sh falls back to `docker run --user $(id -u)` for downloads without
# the hf CLI, and under rootless that UID maps to a subuid that cannot write
# the cache. Require the host CLI instead.
command -v hf >/dev/null || die "the 'hf' CLI is missing (pipx install 'huggingface_hub[cli]'): prepare.sh would fall back to a container download that cannot write the cache under rootless Docker"

docker image inspect "$TF_IMAGE" >/dev/null 2>&1 || die "image $TF_IMAGE is missing: make prepare"
[[ "$(docker image inspect -f '{{index .Config.Labels "tf.kernels"}}' "$TF_IMAGE")" == embedded ]] ||
  die "$TF_IMAGE is not an image of this recipe: make prepare REBUILD=1"
ok "image $TF_IMAGE"
[[ -f "$TF_MODEL_DIR/config.json" ]] || die "checkpoint not found at $TF_MODEL_DIR: make prepare"
ok "checkpoint $TF_MODEL_DIR"

# Same trick as start.sh: the engine rejects bad arguments before it touches the
# model path ("neither a directory"), so run it offline against a dummy path.
read -ra c <<<"$TF_COMMAND"
c[2]=/nonexistent/argument-check
code=0
docker run --rm --network none --entrypoint /opt/tensorfold/native/bin/tensorfold-native "$TF_IMAGE" \
  "${c[@]:1}" >/dev/null 2>.generated/args.err || code=$?
if (( code == 2 )) || ! grep -q 'neither a directory' .generated/args.err; then
  cat .generated/args.err >&2
  die "tensorfold-native serve rejects these arguments"
fi
ok "serve arguments accepted"

if grep -q 'memory available' .generated/dryrun.log; then
  msg=$(grep 'memory available' .generated/dryrun.log | tail -1)
  if [[ "${MEM_CHECK:-1}" == 0 ]]; then echo "check: warning: $msg"
  else die "$msg (MEM_CHECK=0 starts anyway; stop other GPU engines first: make down engine=<name> from the repo root)"; fi
else
  ok "enough memory available"
fi
