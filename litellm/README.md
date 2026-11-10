# litellm

[LiteLLM](https://docs.litellm.ai/) proxy: the single OpenAI-compatible front door for every model under [`models/`](../models/). Clients authenticate to LiteLLM with a key, pick a model by name, and never see the engines behind it.

```
client ──> traefik ──> litellm:4000 ──> qwen38:8888      (models/qwen38)
                            │
                            └─ litellm-db (Postgres: keys, spend)   [private network, not on `traefik`]
```

- URL on the LAN: `https://litellm.spark-1822.local` (publish the alias: `cd /opt/mdns && make add ALIAS=litellm`). The router matches any `litellm.<domain>`; for a tailnet name, add a `svc:litellm` VIP service as described in [`tailscale/README.md`](../tailscale/README.md).
- Direct on the host: `http://127.0.0.1:4000`.
- Admin UI: `/ui`, log in with the master key.

## Setup

```bash
cd /opt/litellm
cp .env.example .env
# fill LITELLM_MASTER_KEY (sk-…), LITELLM_SALT_KEY, POSTGRES_PASSWORD:  openssl rand -hex 24
docker volume create litellm-db      # once; external so `down -v` can never delete keys
docker compose up -d
```

The password is embedded in a URL, so keep it to hex or alphanumerics.

```bash
curl -s https://litellm.spark-1822.local/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next","messages":[{"role":"user","content":"Say hi."}]}'
```

The master key is for admin use. Issue one virtual key per client (`/key/generate`, or the UI) so you can rotate or revoke them independently.

## Models

`config.yaml` is the source of truth (`STORE_MODEL_IN_DB=False`), so the model list is version-controlled. Add an entry per backend, then `docker compose restart litellm`. Backends are reached by container name over the `traefik` network, which is why model stacks need no host ports or Traefik routers.

Defaults chosen for a single GPU: `num_retries: 0` (retrying a failed long request only queues more work), 30-minute timeouts (a 130k-token prefill alone takes about a minute), `drop_params: true` (parameters a backend doesn't know are dropped instead of failing the request).

If a backend is down, LiteLLM returns an error for that model; it does not start it. Start the engine with `make up engine=<name>` from the repo root.

## Upgrades

`LITELLM_TAG=main-stable` floats; pin a release in your host `.env` for production. `POSTGRES_TAG` is pinned to a major version on purpose: a major upgrade needs a dump and restore. LiteLLM applies its own database migrations on start, so back up first (`docker exec litellm-db pg_dump -U litellm litellm > litellm.sql`).

## Open WebUI

[`open-webui/`](../open-webui/) is the chat UI over this gateway (`OPENAI_API_BASE_URL=http://litellm:4000/v1` plus its own virtual key; see its README for creating the key). Bring this stack up first.
