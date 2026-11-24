# open-webui

Self-hosted [Open WebUI](https://github.com/open-webui/open-webui), a chat UI over the [LiteLLM](../litellm/) gateway. One container, on the shared `traefik` Docker network; it reaches the gateway as `http://litellm:4000/v1`. External access goes through [Traefik](../traefik/).

Open WebUI does not talk to a model engine directly: every model it shows is one declared in [`litellm/config.yaml`](../litellm/config.yaml) (today `qwen3.8-flash-next`, served by [`models/qwen38/`](../models/qwen38/)). Ollama is no longer part of this stack.

Adapted from NVIDIA's official playbook: <https://build.nvidia.com/spark/open-webui/instructions>. Diverges in three ways: the image is version-pinned via `.env`, secrets live in `.env`, and the UI is fronted by Traefik on HTTPS instead of being published directly on `:8080`.

## Files

```
open-webui/
├── docker-compose.yml
├── .env.example         # committed
└── .env                 # gitignored
```

## Configure

```bash
cp .env.example .env
# Edit .env:
#   OPEN_WEBUI_TAG     — Open WebUI image tag (e.g. v0.9.5)
#   WEBUI_SECRET_KEY   — generate with: openssl rand -hex 32  (REQUIRED)
#   LITELLM_API_KEY    — a LiteLLM virtual key for this UI (REQUIRED, see below)
#   WEBUI_AUTH         — true (require login) or false (open)
#   ENABLE_SIGNUP      — true initially; flip to false after admin registers
```

### The LiteLLM key

Bring `litellm/` up first, then create a key for this UI instead of handing it the master key, so it can be rotated or revoked on its own:

```bash
curl -s https://litellm.spark-1822.local/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"key_alias": "open-webui"}'
# → copy the "key" value (sk-…) into LITELLM_API_KEY in open-webui/.env
```

### Connection settings are seeded once

`OPENAI_API_BASE_URL` / `OPENAI_API_KEY` in the compose file are Open WebUI *persistent config*: they populate the database on the **first** start, and after that the values in Admin Panel → Settings → Connections win. If you rotate the LiteLLM key later, change it in the UI (or set `ENABLE_PERSISTENT_CONFIG=false` to make the environment authoritative).

## Deploy

Prereqs:

- [Traefik](../traefik/) must be running — it owns `:80`/`:443` and the shared `traefik` Docker network that this stack joins as external.
- [`litellm/`](../litellm/) must be running, and you need a key from it (above).
- The persistent volume `open-webui` (users, chats, config) must exist. It's declared `external: true` so `docker compose down -v` never destroys it. First-time deploy:

  ```bash
  docker volume create open-webui
  ```

Then:

```bash
docker compose up -d
docker compose ps
```

Open WebUI is then reachable at `https://open-webui.spark-1822.local` (LAN; also at `https://open-webui.<tailnet>.ts.net` if the `svc:open-webui` VIP service is set up — see [`tailscale/README.md`](../tailscale/README.md)). The first user to register becomes admin; after that, set `ENABLE_SIGNUP=false` in `.env` and re-run `docker compose up -d` to lock it down.

If the model list is empty, check that the gateway answers and the key is valid:

```bash
docker exec open-webui curl -s -H "Authorization: Bearer $LITELLM_API_KEY" http://litellm:4000/v1/models
```

A model whose backend is stopped still appears in the list (LiteLLM lists what is configured) and fails when used; start it with `make up engine=<name>` from the repo root.

## Upgrade

Bump `OPEN_WEBUI_TAG` in `.env` (or leave it on `latest`), then:

```bash
docker compose pull
docker compose up -d
```

## Logs

```bash
docker compose logs -f open-webui
```

## Uninstall

```bash
docker compose down
docker volume rm open-webui   # destroys users, chats and settings
```

## Migrating from the Ollama-based stack

The previous version of this stack ran an `ollama` container beside Open WebUI. After pulling this change on the host:

1. `docker compose up -d --remove-orphans` in `<repo>/open-webui` stops and removes the old `ollama` container (the compose file no longer defines it).
2. The `open-webui-ollama` volume (every model you pulled, often tens of GiB) is **left in place**. Delete it once you are sure you do not need those models: `docker volume rm open-webui-ollama`.
3. Existing chats and users are kept (same `open-webui` volume). Open WebUI's saved connection settings still point at Ollama: in Admin Panel → Settings → Connections, turn Ollama off and add/verify the OpenAI connection to `http://litellm:4000/v1` (the environment values above only apply to a fresh database).

## See also

- Top-level [README](../README.md)
- [`litellm/`](../litellm/) — the gateway this UI talks to
- [`traefik/`](../traefik/) — TLS-terminating reverse proxy in front of this UI
- Open WebUI docs: <https://docs.openwebui.com/>
