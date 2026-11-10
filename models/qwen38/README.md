# qwen38

[Qwen3.8 Flash Next](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local) (NVIDIA's QAD FP4 checkpoint) served by [TensorFold](https://github.com/ashhart/TensorFold)'s Zig engine on the DGX Spark's single GPU, using [MiaAI-Lab's recipe](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold). OpenAI-compatible API, 262,144-token window, up to 5 concurrent requests, image and video input, MTP speculative drafts. Upstream's README has the benchmarks and the engine details; this page covers how it is wired into this repo.

It is reached through [`litellm/`](../../litellm/) as model `qwen3.8-flash-next`. The engine itself has **no Traefik router** (it has no auth by default). For debugging it listens on `127.0.0.1:8888` on the host.

| | |
|---|---|
| Container | `qwen38` (on the `traefik` network, port 8888) |
| Memory | ~81 GiB weights + KV pool + 9 GiB reserve ≈ 90–110 GiB of the GB10's unified memory. Stop other GPU engines first |
| Disk | ~96 GiB checkpoint + ~40 GiB image build |
| Restart policy | `no`: start it deliberately |

## How it relates to upstream

`upstream/` is a git submodule, pinned to a commit and **never edited here**. Upstream's `start.sh` is a rootful `docker run` wrapper (host networking, `--gpus all`, `ss`/`nvidia-smi` PID probing), so instead of patching it this stack splits the job:

| Decided by upstream (via the submodule) | Decided here (`docker-compose.yml`) |
|---|---|
| image + patch set, Zig/TensorFold pins, checkpoint and its revision | network: `traefik`, no host networking, no host port beyond loopback |
| every `tensorfold-native serve` argument | GPU reservation, `ipc: host`, ulimits |
| all `TENSORFOLD_*` / `TF_FLASHNEXT_*` tuning | healthcheck, logging, restart policy, `no-new-privileges` |
| download and verification (`scripts/prepare.sh`, run unchanged) | Traefik/LiteLLM wiring |

`scripts/resolve.sh` joins the two: it runs upstream's own `DRY_RUN=1 ./start.sh`, which prints the exact `docker run` it *would* execute, and turns that into `.generated/compose.env` (image, command, mounts) and `.generated/engine.env` (engine variables). So an upstream change to a serve flag, a tuning default or a checkpoint pin reaches this stack by bumping the submodule, with nothing to port. `make update` verifies that still holds, and `./test-resolve.sh` covers the resolver (stub `docker`, no GPU needed).

## First-time setup

Prerequisites on the host: rootless Docker with the NVIDIA runtime (the same as the other GPU stacks), the `traefik/` stack up, and the Hugging Face CLI (`pipx install 'huggingface_hub[cli]'`). The CLI is required: without it upstream's `prepare.sh` downloads from inside a container as your UID, and under rootless Docker that UID maps to a subuid that cannot write your cache.

```bash
git submodule update --init models/qwen38/upstream   # once, after cloning
cd models/qwen38
cp .env.example .env        # adjust paths/limits; `make` also does this on first run
make prepare                # pulls upstream's prebuilt image (or builds it) and downloads ~96 GiB
make up                     # pre-flight checks, then waits until /health answers (a few minutes)
make smoke                  # one chat completion over the loopback port
```

Then declare it to LiteLLM (already done in `litellm/config.yaml`) and `make up` there.

Every knob of the recipe works in `.env` under the same name as upstream's (`CONTEXT`, `PARALLEL`, `VISION`, `KV_DTYPE`, `THINKING`, `DRAFTS`, `MODEL_ID`, …; see `upstream/scripts/config.sh`). `make env` re-resolves after any change; `make up` does it for you.

## Day to day

```bash
make status                 # container + /health
make logs
make down                   # frees the GPU memory
make up                     # …and back
```

`make up` refuses to start when the image or checkpoint is missing, when the engine rejects the arguments, or when less memory is free than the recipe needs (`MEM_CHECK=0` overrides: on the GB10 running out of unified memory can hang the host, so don't).

## Updating from upstream

```bash
cd models/qwen38
make update                 # fetch, show commits and what changed in start.sh/config.sh/prepare.sh, bump the submodule, re-resolve
make prepare check up smoke # new image / checkpoint pin, new arguments
git add upstream && git commit -m "chore(qwen38): bump upstream to <sha>"
```

`make update REF=<sha>` picks a commit instead of `origin/main`. If upstream changes the *shape* of its dry-run output, `make update` fails and puts the submodule back, so read the diff it prints and adapt `scripts/resolve.sh`. The `gitsubmodule` entry in `.github/dependabot.yml` also opens a weekly PR for new upstream commits; treat it as a prompt to run the steps above, not as something safe to merge unchecked.

If a rootless problem ever *does* need a change inside upstream, prefer making it in `docker-compose.yml` or `scripts/` first. If it truly needs a patch, keep it as a `git apply`-able file next to the submodule rather than a commit inside it, so the pin stays a plain upstream commit.

## Rootless Docker notes

- **Networking.** Host networking isn't used (under rootless it is rootlesskit's namespace, not the host's). LiteLLM reaches the engine as `http://qwen38:8888` over the `traefik` network.
- **GPU.** The compose file asks for the NVIDIA device the same way `vllm/` and `llama-cpp/` do. If your setup uses CDI instead, replace the `deploy` block with `devices: ["nvidia.com/gpu=all"]` (Docker ≥ 28.3).
- **`memlock`.** The engine wants `memlock` unlimited. A rootless daemon cannot raise limits above its own: if the container logs a locked-memory error, set `LimitMEMLOCK=infinity` in a systemd drop-in for the user's `docker.service` and restart it.
- **Permissions.** `HF_CACHE`, `KERNEL_CACHE` and `STATE_DIR` must be writable by the user running `make` (container root maps to that user). `.generated/` holds `engine.env`, which contains `TENSORFOLD_API_KEY` if you set one: it is `chmod 600` and gitignored.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `make up`: `only N GiB memory available` | Another engine holds the GPU's memory: `make down engine=<other>` from the repo root |
| `check: network 'traefik' is missing` | Bring up `traefik/` first |
| `resolve: no '[dry-run]' command…` | Upstream changed `start.sh`: see "Updating from upstream" |
| Healthy container, LiteLLM returns 5xx | `docker logs litellm`; check `api_base` and `QWEN38_API_KEY` vs `TENSORFOLD_API_KEY` |
| `docker compose` complains about `TF_*` variables | Run via `make` (it passes `.generated/compose.env`) or `make env` first |
