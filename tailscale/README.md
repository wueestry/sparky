# tailscale

Tailscale as a **host service**: `tailscaled` (installed from Tailscale's package, kernel mode, running as root) joins this machine to your tailnet, and [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve) terminates TLS on the tailnet side and forwards everything to [Traefik](../traefik/), which routes by Host header exactly as it does for LAN clients. This directory holds the declarative part: which services the node serves, and a small helper that applies them at boot.

It used to be a container (a userspace-networking sidecar). It runs on the host now so the node has a real `tailscale0` interface and `tailscaled` is a separate, root-owned systemd service the host firewall can tell apart from every rootless container. See [Migrating from the container](#migrating-from-the-container).

## Files

```
tailscale/
├── services.json                   # the VIP services this node serves (declarative, Tailscale's services format)
├── sparky-tailscale-serve          # applies the node + services config; idempotent
├── sparky-tailscale-serve.service  # systemd oneshot: re-applies at boot, after tailscaled
├── Makefile                        # check / install / up / apply / status / logs
├── test-serve.sh                   # tests for the apply script (stub tailscale, no network)
└── README.md
```

## How it works

```
tailnet client ──(http  :80 )──> tailscaled ──> http://127.0.0.1:80              ┐
tailnet client ──(https :443)──> tailscaled ──> https+insecure://127.0.0.1:443   ┤ Traefik's published ports
                                                                                  ┘ → Host-header routing → backend
```

- `tailscaled` serves two things, both pointing at Traefik's ports published on this host:
  - **The node itself** (`https://spark-1822.<tailnet>.ts.net`): `:80` → `http://127.0.0.1:80` and `:443` → `https+insecure://127.0.0.1:443`. Set with `tailscale serve --bg`.
  - **Every VIP service** in [`services.json`](services.json) (`svc:litellm` → `https://litellm.<tailnet>.ts.net`, …), each with the same two endpoints. Applied with `tailscale serve set-config --all`, which also advertises them.
- **Why `https+insecure` on `:443`.** Traefik's certificate is signed by its own CA, which tailscaled doesn't trust, so verification is skipped on that loopback hop (the client-facing certificate is Tailscale's public MagicDNS one). It is `+insecure` with a plus; `https-insecure://` is not recognised.
- **Why not proxy `:443` to `http://127.0.0.1:80`.** Traefik would 308-redirect to HTTPS, the client would come back through Tailscale `:443`, and the loop never ends.
- `set-config` is services-only: it never touches the node-level `:80`/`:443`, and `--all` replaces every service's handlers, so `services.json` is the full truth for services. `tailscale serve reset` clears everything; re-run `make apply` after one.
- `services.json` contains **no tailnet name**: the client takes the MagicDNS suffix from the daemon. (The old container-era `serve.json` had it hard-coded.)
- Traefik must be up for the targets to answer; the node and services still register without it.

## Install

1. **Install Tailscale** from Tailscale's own package repository: <https://tailscale.com/kb/1031/install-linux>. It must be recent enough to have `tailscale serve set-config` (the declarative services format); `make check` verifies that.
2. **Check, install the helper, log in, apply:**

   ```bash
   cd /opt/tailscale
   make check      # tailscale installed, recent enough, tailscaled running
   make install    # script + boot-time unit + services.json under /etc/sparky-tailscale
   make up         # `tailscale up --hostname=spark-1822 --accept-dns=false` — open the printed URL to log in
   make apply      # serve the node and the services now (the unit does this on every boot)
   make status
   ```

   `TS_HOSTNAME=…` changes the node name; `UP_ARGS='--advertise-tags=tag:server'` adds `tailscale up` flags. Prefer the interactive login over `--auth-key=…`, which lands in shell history and the process list. `--accept-dns=false` keeps tailscaled from rewriting the host's DNS (the resolver Docker's containers inherit); drop it if you want MagicDNS names to resolve on this machine.
3. **Create each VIP service** in the admin console, <https://login.tailscale.com/admin/services>, with required ports `tcp/80` and `tcp/443`. Tailscale can't create services from the node. The names are the keys of `services.json` (`svc:traefik`, `svc:litellm`, …); if your policy doesn't auto-approve hosts, approve this node as a host for each. Nothing else is manual: `make apply` advertises them.

Add or remove a service by editing `services.json`, then `make apply`. Port 80/443 on this machine need Traefik published there, which it is; under rootless Docker that already requires `net.ipv4.ip_unprivileged_port_start` ≤ 80.

## Operations

```bash
make status                          # served config + advertised services
make logs                            # the boot-time apply unit
sudo systemctl status tailscaled
sudo apt-get install --only-upgrade tailscale   # upgrades come from the package, not an image tag
```

Tailscale keeps its serve config in its state, so the node keeps serving across restarts; the unit re-applies `services.json` at boot anyway, so the repo stays the source of truth.

## Migrating from the container

Do this in order:

1. **Before `git pull`** (it deletes the compose file): `cd /opt/tailscale && docker compose down`. The `tailscale-state` volume is left in place; `docker volume rm tailscale-state` once you're done.
2. **Delete the old node** in the admin console (Machines → `spark-1822` → Delete). Otherwise the new node registers as `spark-1822-1` and every URL changes. The VIP services themselves stay; only the node that hosts them changes.
3. `git pull`, then install and log in as above.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Admin console shows a service as "needs configuration" | The node isn't advertising it: `make status`; then `make apply`. After a `tailscale serve reset` always re-apply. |
| `make apply`: `not logged in` | `make up` first. |
| `make apply`/`check`: no `set-config` | The installed tailscale is too old: upgrade the package. |
| 502 from `https://…ts.net` | Traefik isn't up or isn't published on 127.0.0.1:443: `curl -k https://127.0.0.1:443 -H 'Host: traefik.spark-1822.local'`. |
| Node came back as `spark-1822-1` | The old container node wasn't deleted (step 2 above). |

## Firewall

With the host firewall ([`firewall/`](../firewall/)) the node is reachable only from the LAN and the tailnet. The firewall allows `tailscaled` out by its socket mark (`0x80000`, which `tailscaled` sets on its own connections), so the control plane, relays and peers need no IP allow-list, and it accepts everything arriving on `tailscale0` (your tailnet ACLs are the access control). `make apply` in `firewall/` sets `tailscale set --netfilter-mode=off`, because Tailscale's own firewall chains and that ruleset would otherwise both have to accept the same packets; `make revert` / `make uninstall` set it back to `on`. If Tailscale seems broken after enabling the firewall, `make status` there first (is it `DISABLED`?), then `make logs`.

## Retired services

`services.json` is the whole truth: `make apply` replaces every service's handlers, so a service removed from it stops being served. The VIP services of retired stacks (`svc:vllm`, `svc:llama`, `svc:ollama`, `svc:netdata`) should also be deleted in the admin console. `svc:litellm` replaces them as the entry point for models; create it there (ports `tcp/80` + `tcp/443`) before applying.

## See also

- Top-level [README](../README.md) and [`traefik/`](../traefik/): the proxy this serves.
- Tailscale Serve: <https://tailscale.com/kb/1242/tailscale-serve>; services file format: <https://tailscale.com/kb/1589/tailscale-services-configuration-file>; VIP services: <https://tailscale.com/kb/1417/services>.
