# Architecture

sparky is the configuration of one machine, `spark-1822` (an NVIDIA DGX Spark), that serves an LLM to the local network and a tailnet. `/opt` on the host is a checkout of this repository; every stack lives in place at `/opt/<name>/` and is run with Docker Compose or, for host services, systemd.

## Components

| Stack | Runs as | Job |
|---|---|---|
| `traefik/` | container, publishes host `:80` and `:443` | TLS termination and Host-header routing for everything |
| `litellm/` (+ Postgres) | containers | One OpenAI-compatible endpoint, API keys and spend tracking, in front of every model |
| `models/qwen38/` | container, GPU | The model engine (TensorFold, MiaAI-Lab's recipe, vendored as a submodule) |
| `open-webui/` | container | Chat UI, a client of LiteLLM |
| `tailscale/` | host systemd services | `tailscaled` in kernel mode plus a unit that applies the Serve config |
| `mdns/` | host systemd template units | `<name>.spark-1822.local` aliases via Avahi |
| `firewall/` | host systemd unit + nftables | Default-deny in both directions (see [`firewall.md`](firewall.md)) |

Docker is **rootless**. That has two consequences the rest of the design leans on: containers have no host bridge, and anything a container sends to the outside is made by the Docker user's processes on the host.

## Request paths

There are two ways in, and they converge on Traefik:

```
LAN client      ──(mDNS *.spark-1822.local)──────────────────────>  traefik :80/:443 ─┐
tailnet client  ──(MagicDNS, WireGuard)──> tailscaled ──> 127.0.0.1:80/443 ───────────┤
                                                                                       v
                                         Host-header router ──> litellm:4000 ──> qwen38:8888
                                                           └──> open-webui:8080 ──> litellm:4000
```

- **LAN.** `mdns/` publishes one alias per hostname (`litellm`, `open-webui`, `traefik`) pointing at the host's primary IPv4 address. A client resolves `litellm.spark-1822.local`, connects to Traefik on `:443`, and is routed by the `Host` header.
- **Tailnet.** `tailscaled` terminates TLS with a real, publicly trusted MagicDNS certificate and forwards to Traefik on loopback. Port `:80` goes to `http://127.0.0.1:80`; port `:443` goes to `https+insecure://127.0.0.1:443`, because Traefik's own certificate is signed by a CA that `tailscaled` does not trust and that hop never leaves the machine. The node itself is served directly; each backend that should have its own tailnet hostname (`litellm.<tailnet>.ts.net`) is a Tailscale VIP service declared in `tailscale/services.json`.
- **Model traffic never leaves the box.** Open WebUI calls `http://litellm:4000/v1`; LiteLLM calls `http://qwen38:8888/v1`. Both hops are container-to-container on the shared network.
- The engine itself has **no Traefik router**: it has no auth by default, and LiteLLM is the one place that holds API keys. It is reachable on `127.0.0.1:8888` for debugging only.

## Networks

| Network | Owner | Members | Purpose |
|---|---|---|---|
| `traefik` | `traefik/` stack (`attachable`) | traefik, litellm, qwen38, open-webui | Shared front-end network. Every other stack joins it as `external: true`. Traefik dials containers by name over it (`providers.docker.network: traefik`) |
| `litellm-internal` | `litellm/` | litellm, litellm-db | `internal: true`: Postgres is reachable by LiteLLM only, with no route out |
| host loopback | — | `litellm` `:4000`, `qwen38` `:8888` | Published to `127.0.0.1` only, for curl and benchmarking |

Only Traefik publishes on a non-loopback address (`0.0.0.0:80`, `0.0.0.0:443`). Everything else is reached through it or over the shared network.

## Routing

Routes are declared where the service is defined. A service opts in with Docker labels in its own compose file:

```
traefik.enable=true
traefik.http.routers.<name>.rule=HostRegexp(`<name>.{x:.+}`)
traefik.http.routers.<name>.entryPoints=websecure
traefik.http.routers.<name>.tls=true
traefik.http.services.<name>.loadbalancer.server.port=<port>
```

The rule matches on the first DNS label only, so one definition answers on `<name>.spark-1822.local` (LAN) and `<name>.<tailnet>.ts.net` (tailnet) alike. Anything that cannot be a label, today only Traefik's own dashboard, lives in `traefik/dynamic/*.yml`; the file provider hot-reloads it. Port `:80` redirects to `:443` permanently.

Streaming matters here: idle and forwarding timeouts are disabled on the `websecure` entry point and the default servers transport, because a long generation can go quiet longer than Traefik's 180 s default and would otherwise be cut mid-stream.

## TLS

Two independent roots, one per path:

- **LAN:** Traefik serves a wildcard certificate (`traefik/certs/wildcard.crt`) signed by an internal CA that `make ca-cert` and `make wildcard-cert` mint. The names on the wildcard come from the host's short hostname (`<host>.local` and `*.<host>.local`), the same name `mdns/` publishes aliases under; after a rename, re-run `make wildcard-cert`. Clients install `traefik-root.crt` once. The Let's Encrypt resolver is scaffolded in `traefik.yml` but off, since `.local` names cannot be issued public certificates.
- **Tailnet:** Tailscale provisions publicly trusted certificates for the MagicDNS name; clients need nothing.

## The model engine

`models/qwen38/` runs a recipe it does not own. `upstream/` is a git submodule, pinned and never edited. Upstream's `start.sh` is a rootful `docker run` wrapper, so `scripts/resolve.sh` runs upstream's own `DRY_RUN=1 ./start.sh`, parses the `docker run` it would have executed, and writes `.generated/compose.env` (image, command, mounts) and `.generated/engine.env` (engine variables). `docker-compose.yml` then supplies only what is local: the `traefik` network, the GPU reservation, `ipc: host`, ulimits, the healthcheck and `restart: "no"`. Bumping the submodule is enough to pick up a new serve flag or checkpoint pin; `make update` verifies the resolver still understands upstream.

The engine claims about 90 GiB of the GB10's unified memory eagerly, which is why it never restarts by itself and why the top-level `Makefile` acts on one service at a time and never stops the others.

## State and secrets

| What | Where | In git |
|---|---|---|
| Per-stack settings and secrets | `<stack>/.env` (`root:docker 640`) | no, only `.env.example` |
| LiteLLM database (keys, spend) | external Docker volume `litellm-db` | no |
| Open WebUI users and chats | external Docker volume `open-webui` | no |
| Traefik CA and wildcard key | `traefik/certs/` | no |
| Resolved engine config | `models/qwen38/.generated/` | no |
| Model weights, kernel cache | `/opt/hf/.cache/...` | no |
| Firewall ruleset and state | `/etc/sparky-firewall/`, `/var/lib/sparky-firewall/`, `/run/sparky-firewall/` | no |

The two databases are **external** volumes, created once by hand, so `docker compose down -v` can never delete keys, spend history or chats. Models are declared in `litellm/config.yaml` and `STORE_MODEL_IN_DB` is off, so the model list is version-controlled.

## Offline by default

The host firewall closes the internet, so the steady state must not need it. Loading models is offline (`HF_HUB_OFFLINE=1`); Traefik has update checks and anonymous usage off; LiteLLM and Open WebUI have their telemetry and version checks off (these would only fail, noisily, against the firewall). What does need the internet is operations: `git pull`, `docker compose pull`, `make prepare`, OS updates. Those run inside a deliberate `make disable` … `make enable` window.

## How a change reaches the host

```
edit → commit → push → ssh host: git -C /opt pull --ff-only --recurse-submodules → apply in the stack
```

Applying depends on the stack: model stacks run `make up` (after `make update` for a new upstream commit), Traefik hot-reloads labels and `dynamic/*.yml` and restarts only if `traefik.yml` changed, other stacks run `docker compose up -d`. Host services (`mdns/`, `tailscale/`, `firewall/`) have a `make install` that copies their helper and unit into place; the repo checkout is not what systemd runs, so a transient timer never depends on `/opt` being mounted or current.

## Conventions

- **Tags float in `.env.example`, pin in the host `.env`.** A fresh `cp .env.example .env` should boot; production should pin an immutable tag or a digest.
- **`no-new-privileges`, bounded json-file logs and healthchecks** on every container.
- **Compose files fail early on a missing secret** (`${VAR:?message}`), so a half-configured stack does not start.
- **Each host service ships its own tests** (`firewall/test-ruleset.sh`, `tailscale/test-serve.sh`, `models/qwen38/test-resolve.sh`) that stub what they must and touch no real system.
