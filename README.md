# sparky

<p align="center">
  <img src="sparky.svg" alt="sparky" width="220" height="260">
</p>

Configuration for the [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) workstation `spark-1822` — a single-box, self-hosted LLM setup:

- **`models/`** — one stack per self-contained model recipe, GPU-accelerated on the GB10, starting with **Qwen3.8 Flash Next** on [MiaAI-Lab's TensorFold recipe](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold) (vendored as an unpatched git submodule, rootless-compatible).
- **LiteLLM** as the OpenAI-compatible gateway in front of the models (keys, routing, spend tracking).
- **Open WebUI** for the chat UI, over LiteLLM.
- **Traefik** as the HTTPS reverse proxy in front of everything (docker-label-driven, mints its own internal CA).
- **Tailscale** sidecar for tailnet-only ingress (peer-to-peer over WireGuard; no public DNS, no public ports).
- **Netdata** for real-time observability.
- **mDNS** helper publishing `<sub>.spark-1822.local` aliases on the LAN.

## Topology

Two ingress paths into the same backends:

```
LAN client      ──(mDNS *.spark-1822.local)──>  traefik :80/:443  ──>  backend
tailnet client  ──(MagicDNS, WireGuard)──>  tailscale :443  ──>  traefik :80  ──>  backend
```

Backends (`litellm`, the stacks under `models/`, `open-webui`) all sit on a single shared Docker network named `traefik` — defined by the `traefik/` stack, joined as `external: true` by everyone else. The active proxy and the Tailscale sidecar each attach to the same network and dial container names directly. `netdata` is the exception: it runs with `network_mode: host` (needed for host-level PID/proc telemetry), so it has no endpoint on the `traefik` network — Traefik reaches it via a static route to `host.docker.internal:19999` in `traefik/dynamic/services.yml` instead of container-name DNS.

TLS comes from two different roots: Traefik mints its own internal CA (clients install `traefik-root.crt` once); Tailscale auto-provisions publicly-trusted MagicDNS certs for the tailnet hostname.

## Layout

```
.
├── traefik/       # HTTPS reverse proxy (docker-label-driven)
├── tailscale/     # Tailscale sidecar — tailnet ingress
├── models/        # one subfolder per model recipe (qwen38/ …), served behind litellm
├── litellm/       # LiteLLM gateway (+ Postgres) in front of models/
├── open-webui/    # Open WebUI (chat UI over litellm)
├── netdata/       # Real-time observability
├── mdns/          # Host-side mDNS aliases helper
├── docs/          # Design/planning docs (historical: the retired llama-cpp router mode)
├── Makefile       # top-level service control (up / down)
├── sparky.svg     # Project logo (AI self-portrait)
├── CHANGELOG.md
├── LICENSE
└── README.md
```

Each stack has its own `README.md` — start there for deploy / configure / upgrade details.

## Components

| Stack | Role | URL on LAN |
|---|---|---|
| [`traefik/`](traefik/) | HTTPS reverse proxy, docker-label-driven, mints its own internal CA | publishes `:80`/`:443` |
| [`tailscale/`](tailscale/) | Tailscale sidecar — tailnet-only ingress over WireGuard, optional Serve overlay fronts `traefik` | `https://spark-1822.<tailnet>.ts.net` |
| [`models/qwen38/`](models/qwen38/) | Qwen3.8 Flash Next on TensorFold (MiaAI-Lab recipe as an unpatched submodule, rootless-compatible, ~5 concurrent streams, 262k context). Reached only through LiteLLM | `127.0.0.1:8888` on the host; no router of its own |
| [`litellm/`](litellm/) | LiteLLM OpenAI-compatible gateway + Postgres: one endpoint and key set for every model under `models/` | `https://litellm.spark-1822.local` |
| [`open-webui/`](open-webui/) | Open WebUI chat UI, talking to LiteLLM (no GPU) | `https://open-webui.spark-1822.local` |
| [`netdata/`](netdata/) | Real-time host + container telemetry | `https://netdata.spark-1822.local` |
| [`mdns/`](mdns/) | Host systemd template publishing `<sub>.spark-1822.local` mDNS aliases | host-level |

## Host

| | |
|---|---|
| Hardware | [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) |
| Hostname | `spark-1822.local` |
| OS | Ubuntu (kernel `6.17.0-nvidia`), aarch64 |
| GPU | NVIDIA GB10 (compute capability 12.1, 124 GiB VRAM) |
| Docker | 29.x + Compose v2 |
| GPU runtime | `nvidia-container-toolkit` 1.19 (CDI mode) |

## First-time setup

On a fresh host, in order:

1. **Install the mDNS helper** (host-side; publishes `<sub>.spark-1822.local` aliases):

   ```bash
   cd /opt/mdns && make install
   ```

2. **Bring up the reverse proxy** — this also creates the shared `traefik` Docker network everything else joins:

   ```bash
   cd /opt/traefik
   cp .env.example .env             # then set TRAEFIK_TAG
   make ca-cert                     # one-time: mint Traefik's internal root CA
   make wildcard-cert               # mint the wildcard leaf signed by that root
   docker compose up -d
   ```

   Install `traefik/certs/traefik-root.crt` on each client that should trust the host's LAN URLs (per-OS install table in [`traefik/README.md`](traefik/README.md)).

3. **Publish a mDNS alias for each subdomain** you'll expose:

   ```bash
   cd /opt/mdns
   for a in traefik litellm open-webui netdata; do make add ALIAS=$a; done
   ```

4. **Bring up the services** — each one attaches to the `traefik` network and Traefik auto-routes via the `traefik.*` labels in its compose:

   ```bash
   cd /opt/netdata    && cp .env.example .env && docker compose up -d
   ```

   The Qwen recipe is a git submodule and downloads ~96 GiB the first time; the gateway needs secrets in its `.env` (see [`litellm/README.md`](litellm/README.md)); Open WebUI then needs a key *from* the gateway (see [`open-webui/README.md`](open-webui/README.md)):

   ```bash
   cd /opt && sudo git submodule update --init models/qwen38/upstream
   cd /opt/models/qwen38 && make prepare && make up      # see models/qwen38/README.md
   cd /opt/litellm       && cp .env.example .env         # fill the three secrets
   docker volume create litellm-db && docker compose up -d
   # create a key for Open WebUI (litellm/README.md), then:
   cd /opt/open-webui    && cp .env.example .env         # secret + LITELLM_API_KEY
   docker volume create open-webui && docker compose up -d
   ```

5. **(Optional) Tailnet ingress via Tailscale** — only if you want this host reachable from your tailnet:

   ```bash
   cd /opt/tailscale
   cp .env.example .env             # paste TS_AUTHKEY from the Tailscale admin console
   docker compose up -d
   ```

   The node registers as `spark-1822.<tailnet>.ts.net` with a real publicly-trusted MagicDNS cert; Tailscale Serve wires `:80`/`:443` on the tailnet to Traefik. For per-backend tailnet URLs (`https://litellm.<tailnet>.ts.net`, `https://traefik.<tailnet>.ts.net`, …), create one [Tailscale VIP Service](https://tailscale.com/kb/1417/services) per backend and declare it in `tailscale/serve.json` (applied and advertised automatically on every container start) — see [`tailscale/README.md`](tailscale/README.md) for the full walk-through.

## Deploy workflow

`/opt` on the host **is** a checkout of this repo — every stack lives in place at `/opt/<name>/`. Edit locally, commit, push; then pull on the host:

```bash
ssh spark-1822.local 'sudo git -C /opt pull --ff-only --recurse-submodules'
```

After the pull, apply the change in the relevant stack (each stack's README has details):

- **Model stacks** (`models/<name>/`) — `cd /opt/models/<name> && make up`; to pick up a new upstream recipe commit, `make update` there first (see the stack's README).
- **Traefik** — routing changes via Docker labels or `dynamic/*.yml` files are hot-reloaded; `docker compose restart traefik` only if `traefik.yml` itself changed.
- **Other stacks** — `cd /opt/<name> && docker compose up -d`.

Host-local files outside git stay put across pulls — each stack's `.env` (secrets), generated `.generated/` directories, TLS material (`*.crt`/`*.key`), and `*.bak` backups are all gitignored.

## Managing the services

The top-level [`Makefile`](Makefile) (at `/opt/Makefile` on the host) is a thin wrapper over the LLM services — it acts on **one service at a time and never touches the others**:

```bash
make up engine=qwen38                # Qwen3.8 Flash Next (models/qwen38; `make prepare` there first)
make up engine=litellm               # the gateway (no GPU)
make up engine=open-webui            # the chat UI (no GPU)
make down engine=qwen38              # stop just that one; the rest keep running
```

Services are `qwen38`, `litellm`, `open-webui`. `up engine=qwen38` delegates to that stack's own `make up` (pre-flight checks, then waits for `/health`); the others run `docker compose up -d` in their directory. For what's running use `docker ps -a`; for what's actually on the GPU use `nvidia-smi`.

The Qwen engine claims ~90 GiB of the GB10's unified memory eagerly and can't co-reside with another eager engine. The Makefile deliberately **doesn't** enforce that trade-off — run `make down engine=<other>` first when you add a second engine under `models/` and need the whole GPU (a "running" container isn't necessarily on the GPU).

## Conventions

- **Image tags float by default, pin in production.** The committed `.env.example` files use floating tags (`latest`, or a stable major-line like `v2` for Traefik, or `main-stable` for LiteLLM) so a fresh `cp .env.example .env` bootstraps to a working state without anyone having to look up the current release. **For production deployments, override in your host-local `.env` with a specific, reproducible pin** — an immutable tag (`v2.11.X`, `v0.20.2`) when the registry publishes one, or a content-digest pin (`<tag>@sha256:…`) when only floating tags exist. Each per-service `.env.example` shows the pin format inline.
- **Model stacks** under `models/<name>/`: `.env` holds host-wide values (cache paths, token, the recipe's own knobs); a vendored upstream recipe lives in an unpatched `upstream/` submodule, and a generated `.generated/` directory (gitignored) carries what the compose file needs from it. See [`models/README.md`](models/README.md).
- **Loopback ports.** `litellm/` and the model stacks bind their API to `127.0.0.1` on the host for direct curl / benchmarking — LAN traffic flows through the proxy, and model engines have no Traefik router at all (only `litellm` is exposed).
- **Permissions.** `/opt/<stack>/` is `root:root`. The `.env` files are `root:docker 640` so the `docker`-group user reads them and runs compose without sudo. Editing configs requires `sudo`.
- **Supply chain.** Every third-party Docker image is referenced by tag in `.env.example` (floating for first-bootstrap convenience; pin in your host-local `.env` for production).

## Repo housekeeping

- [`CHANGELOG.md`](CHANGELOG.md) — [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format, [SemVer](https://semver.org/spec/v2.0.0.html) versioning.
- [`docs/`](docs/) — design/planning docs for individual features (e.g. `docs/superpowers/specs/`, `docs/superpowers/plans/`; the llama-cpp router-mode ones describe a stack that has since been retired).
- [`LICENSE`](LICENSE) — MIT.
- [`sparky.svg`](sparky.svg) — project mascot. Drawn by the AI that helped build this repo, as a self-portrait.
