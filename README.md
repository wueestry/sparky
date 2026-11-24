# sparky

<p align="center">
  <img src="sparky.svg" alt="sparky" width="220" height="260">
</p>

Configuration for the NVIDIA DGX Spark workstation `spark-1822` — a single-box, self-hosted LLM setup:

- **`models/`** — one stack per self-contained model recipe, GPU-accelerated on the GB10, starting with **Qwen3.8 Flash Next** on [MiaAI-Lab's TensorFold recipe](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold) (vendored as an unpatched git submodule, rootless-compatible).
- **LiteLLM** as the OpenAI-compatible gateway in front of the models (keys, routing, spend tracking).
- **Open WebUI** for the chat UI, over LiteLLM.
- **Traefik** as the HTTPS reverse proxy in front of everything (docker-label-driven, mints its own internal CA).
- **Tailscale** as a host service (kernel mode) for tailnet-only ingress (peer-to-peer over WireGuard; no public DNS, no public ports).
- **Host firewall** (nftables, default-deny both ways): only the LAN (`192.168.1.0/24`) and Tailscale are reachable. The internet, container registries included, is closed unless you turn the firewall off on purpose.
- **mDNS** helper publishing `<sub>.spark-1822.local` aliases on the LAN.

## Topology

Two ingress paths into the same backends:

```
LAN client      ──(mDNS *.spark-1822.local)──>  traefik :80/:443  ──>  backend
tailnet client  ──(MagicDNS, WireGuard)──>  tailscaled :443  ──>  traefik 127.0.0.1:80/443  ──>  backend
```

Backends (`litellm`, the stacks under `models/`, `open-webui`) all sit on a single shared Docker network named `traefik` — defined by the `traefik/` stack, joined as `external: true` by everyone else. The proxy attaches to the same network and dials container names directly; Tailscale runs on the host, outside Docker, and reaches Traefik through its published ports.

TLS comes from two different roots: Traefik mints its own internal CA (clients install `traefik-root.crt` once); Tailscale auto-provisions publicly-trusted MagicDNS certs for the tailnet hostname.

## Layout

```
.
├── traefik/       # HTTPS reverse proxy (docker-label-driven)
├── tailscale/     # Tailscale host service — declarative Serve config + apply helper
├── firewall/      # Host firewall (nftables): LAN + Tailscale only, internet closed by default
├── models/        # one subfolder per model recipe (qwen38/ …), served behind litellm
├── litellm/       # LiteLLM gateway (+ Postgres) in front of models/
├── open-webui/    # Open WebUI (chat UI over litellm)
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
| [`tailscale/`](tailscale/) | Tailscale as a host service (`tailscaled`, kernel mode) — tailnet-only ingress over WireGuard; Serve config fronts `traefik`, applied by a small helper | `https://spark-1822.<tailnet>.ts.net` |
| [`firewall/`](firewall/) | Default-deny nftables firewall: in and out only to the LAN and Tailscale, no registry/hostname allow-list. `make disable` / `make enable` to reach the internet on purpose; audit mode, confirm-or-revert applies | host-level |
| [`models/qwen38/`](models/qwen38/) | Qwen3.8 Flash Next on TensorFold (MiaAI-Lab recipe as an unpatched submodule, rootless-compatible, ~5 concurrent streams, 262k context). Reached only through LiteLLM | `127.0.0.1:8888` on the host; no router of its own |
| [`litellm/`](litellm/) | LiteLLM OpenAI-compatible gateway + Postgres: one endpoint and key set for every model under `models/` | `https://litellm.spark-1822.local` |
| [`open-webui/`](open-webui/) | Open WebUI chat UI, talking to LiteLLM (no GPU) | `https://open-webui.spark-1822.local` |
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
   for a in traefik litellm open-webui; do make add ALIAS=$a; done
   ```

4. **Bring up the services** — each one attaches to the `traefik` network and Traefik auto-routes via the `traefik.*` labels in its compose.

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

5. **(Optional) Tailnet ingress via Tailscale** — only if you want this host reachable from your tailnet. Tailscale runs on the host, not in Docker: install it from [Tailscale's package](https://tailscale.com/kb/1031/install-linux), then:

   ```bash
   cd /opt/tailscale
   make check && make install       # helper + boot-time unit; services.json goes to /etc/sparky-tailscale
   make up                          # log the host in (open the printed URL)
   make apply                       # serve the node and the VIP services → Traefik
   ```

   The node registers as `spark-1822.<tailnet>.ts.net` with a real publicly-trusted MagicDNS cert; Tailscale Serve wires `:80`/`:443` on the tailnet to Traefik. For per-backend tailnet URLs (`https://litellm.<tailnet>.ts.net`, `https://traefik.<tailnet>.ts.net`, …), create one [Tailscale VIP Service](https://tailscale.com/kb/1417/services) per backend in the admin console and list it in `tailscale/services.json` — see [`tailscale/README.md`](tailscale/README.md) for the full walk-through.

6. **(Recommended) Lock the host down with the firewall** — after Tailscale (it depends on it) and from a LAN SSH session with a second one open:

   ```bash
   cd /opt/firewall
   cp .env.example .env             # check LAN_CIDR
   make check && make install && make apply   # `make apply MODE=audit` first: logs, blocks nothing; reverts in 2 min…
   make confirm                     # …unless you run this from a SECOND ssh session
   make audit-report                # a few days later; then plain `make apply` (enforce is the default) and confirm again
   ```

   From then on the internet is closed by default: pulling images, downloading models, `git pull` and OS updates need `make disable` … `make enable` (see below and [`firewall/README.md`](firewall/README.md)).

## Deploy workflow

`/opt` on the host **is** a checkout of this repo — every stack lives in place at `/opt/<name>/`. Edit locally, commit, push; then pull on the host:

```bash
ssh spark-1822.local 'sudo git -C /opt pull --ff-only --recurse-submodules'
```

With the firewall installed, the host can't reach GitHub until you turn the firewall off for the pull (it re-enables itself, and always on reboot):

```bash
ssh spark-1822.local 'make -C /opt/firewall disable MINUTES=10 \
  && sudo git -C /opt pull --ff-only --recurse-submodules; make -C /opt/firewall enable'
```

Anything else that downloads (`docker compose pull`, `make prepare`, `apt upgrade`) follows the same pattern: `make -C /opt/firewall disable`, do it, `make -C /opt/firewall enable`.

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

## Contributions
- This work is heavily based on [sparky](https://github.com/a1exus/sparky) by a1exus
