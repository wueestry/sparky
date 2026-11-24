# Host firewall — design

**Status:** implemented (`firewall/`). The behaviour in this document is covered by `firewall/test-ruleset.sh` (74 checks in a throwaway namespace, mutation-checked); nothing has run on `spark-1822` yet, so section 10 (the spike) and a `MODE=audit` period come before enforcing. Deviations from the original design are listed under "Implementation notes" at the end.
**Date:** 2026-11-10.
**Services:** new `firewall/`; touches `tailscale/`, `litellm/`, `open-webui/`, `models/qwen38/`, top-level `README.md`, `CHANGELOG.md`.
**Depends on:** the retirement of `vllm/`, `llama-cpp/` and Ollama (PR #8, merged), the Netdata removal (PR #9), and moving Tailscale to a host service. This spec assumes all three have landed.

## Goal

Block all network access to and from the Spark except:

- the **local network**, `192.168.1.0/24`, and
- **Tailscale**,

**Nothing else is reachable by default.** That explicitly includes every container registry (`docker.io`, `ghcr.io`, `nvcr.io`), Hugging Face, GitHub and the OS package mirrors: there is no hostname or registry allow-list. When an operation needs the internet (image pulls, model downloads, `git pull`, OS updates), the operator **disables the firewall on purpose** (`make disable`), does the work, and **re-enables it** (`make enable`). The disabled state is temporary by construction (it re-enables itself after a timeout, and always on reboot) and visible (`make status`, the journal).

The point is containment as much as exposure: the host runs images this repo does not build (Open WebUI has shipped CRITICAL CVEs in its Python dependencies), loads multi-GB model files, and holds the GPU. A compromised container should have no path to the internet.

## Non-goals

- Defending against root compromise of the host, or filtering traffic *inside* the LAN.
- Replacing Tailscale ACLs. The tailnet is trusted per its own policy.
- L7 filtering, FQDN allow-listing, or proxying (see "Future work").
- IPv6 on the LAN. Decided: not needed, so it is blocked.
- Changing the Docker network topology (the earlier "internal `traefik` network" idea). With Tailscale on the host, identity-based egress rules make it unnecessary for this goal; it can follow separately.

## Background

### What is on the network today

After the three prerequisite changes, the services are:

| Service | Listens on | Reachable from |
|---|---|---|
| Traefik | host `:80`, `:443` (rootless port forward) | LAN clients; `tailscaled` forwards tailnet clients to `127.0.0.1:80/443` |
| `litellm` | `127.0.0.1:4000` (+ `traefik` Docker network) | via Traefik |
| `qwen38` | `127.0.0.1:8888` (+ `traefik` Docker network) | via LiteLLM only (no Traefik router) |
| `open-webui` | `traefik` Docker network only | via Traefik |
| `litellm-db` | private Docker network | LiteLLM only |
| sshd | host `:22` | LAN (and tailnet) |
| avahi / `sparky-mdns-alias@*` | UDP `5353` multicast | LAN |
| `tailscaled` | `tailscale0` + outbound control/DERP/WireGuard | the internet, by design |

Docker is **rootless**. That matters for how a host firewall sees container traffic (next section).

### What needs outbound access, and when

Steady state needs almost nothing: model loading is offline (`HF_HUB_OFFLINE=1`), Traefik has update checks and usage reports off, and TensorFold's update check is off. What needs the internet is *operations*. **None of these destinations is allowed by default**; each is reachable only while the firewall is disabled (or an egress window is open, decision 9):

| Operation | Destinations |
|---|---|
| `git pull` on the host (README deploy workflow) | github.com |
| `docker pull`, `make prepare` image pull/build | ghcr.io, docker.io, nvcr.io, github.com, ziglang.org, storage.googleapis.com |
| Model downloads (`hf download`, `make prepare`) | huggingface.co and its CDN |
| OS updates | Ubuntu archives |
| Time sync | NTP |

### How a host firewall sees rootless Docker

This is the assumption the design leans on, and section 10 verifies it:

- **Egress.** Rootless containers have no host bridge. Their outbound connections are made by the user's rootlesskit/slirp4netns process on the host, so they appear in the host's `OUTPUT` chain as ordinary sockets owned by the Docker user. They are indistinguishable from each other by UID, but distinguishable from root services.
- **Ingress.** Published ports (`:80`, `:443`) are plain userspace listeners, so they *do* traverse the host's `INPUT` chain. (Rootful Docker's DNAT bypasses `INPUT`, which is why host firewalls are famously leaky there.)
- **Container-to-container** traffic never touches the host's netfilter.

Consequence: a default-deny `OUTPUT` policy that allows only the LAN already gives every container LAN-only egress, with no per-container rules. Only `tailscaled`, which genuinely needs the internet, gets an identity-based exception.

## Decisions (locked in)

1. **nftables, on the host, one `inet` table named `sparky_fw`.** Covers IPv4 and IPv6 in one place. Not `ufw` (it would fight a hand-written ruleset), not Docker's own iptables rules (rootless Docker installs none).
2. **Default-deny in both directions** (`input` and `output` policy `drop`, `forward` policy `drop`).
3. **LAN is `192.168.1.0/24`**, a variable (`LAN_CIDR`), not a hard-coded literal.
4. **IPv6 is blocked** except on loopback and `tailscale0`. Blocked outbound IPv6 is *rejected*, not dropped, so dual-stack clients fall back to IPv4 immediately instead of hanging.
5. **Tailscale runs on the host as root, in kernel mode** (a prerequisite). Its traffic is allowed by *what it is*, not by destination: the control plane, DERP relays and peers have no stable IPs, and nftables cannot match hostnames.
6. **Identity for `tailscaled` is its socket mark, not its cgroup.** `tailscaled` sets `SO_MARK = 0x80000` (mask `0xff0000`) on every non-loopback socket it creates, so its packets can be matched with `meta mark & 0xff0000 == 0x80000`. A cgroup match (`socket cgroupv2 … "system.slice/tailscaled.service"`) was considered and rejected: nft resolves the path to a cgroup ID at load time, so the ruleset fails to load when the service isn't running, and the rule would go stale each time `tailscaled` restarts and gets a new cgroup. Only root can set that mark.
7. **NTP goes to the LAN or to explicitly listed servers**, never to "any host" by user: an any-destination udp/123 rule would be a free tunnel out. The LAN rule already covers a router or LAN time server; `NTP_SERVERS` (IPv4 list in `.env`, empty by default) adds `ip daddr { … } udp dport 123`. (Accurate time is required for Tailscale's TLS.)
8. **Outbound blocks are `reject`ed, inbound blocks are `drop`ped.** A rejected connect fails in milliseconds (measured 0.04 s in the namespace test) instead of stalling for a timeout, which keeps `docker pull` and friends from hanging with no explanation. Silently dropping inbound gives scanners nothing.
9. **The internet is closed by default, including every container registry, and is reached by explicitly disabling the firewall.** `make disable` removes the whole `sparky_fw` table (inbound filtering too: everything is open while it is off) and arms a re-enable timer (default 30 min, capped at 240); `make enable` re-loads the ruleset immediately and cancels the timer. The disabled state is runtime-only: the boot unit stays enabled, so a reboot always comes back filtered, and the timer means a forgotten `disable` cannot last. There is no per-registry exception list; if a standing exception is ever wanted that is the FQDN allow-list under "Future work", not part of this change.
   - A **narrower alternative** is kept for when inbound filtering should stay on: `make open MINUTES=15` adds `0.0.0.0/0 timeout 15m` to an nft set, which opens *egress only* and closes by itself with no timer or daemon. (Tested: opens, closes on its own after the timeout, can be closed early.) Use `disable` when you want everything open, `open` when you only need to reach out.
10. **`tailscaled` must stop managing netfilter** (`tailscale set --netfilter-mode=off`). Otherwise two sets of base chains both have to accept the same packet, and Tailscale's `ts-input` chain duplicates, and can disagree with, this ruleset. The anti-spoofing rule it would have installed (tailnet-range source from another interface) is part of this ruleset instead.
11. **Roll out in audit mode first.** The same ruleset can be rendered so that every would-be block logs (with the owning UID) and accepts. It runs for a few days before enforcement, so the first enforcing load is not a guess.
12. **Applying a ruleset is confirm-or-revert**, because a mistake here locks out SSH.
13. **Fail open at boot.** If the ruleset fails to load, the host boots unfiltered (and the unit fails loudly) rather than unreachable. The ruleset is validated (`nft -c`) before it is ever installed, so this is the unlikely path.

## Traffic matrix

### Inbound (`input`, policy drop)

| Rule | Allows |
|---|---|
| `ct state invalid` | drop |
| `ct state established,related` | accept (replies to everything the host started, incl. Tailscale's hole-punched UDP) |
| `iifname lo` | accept |
| `iifname tailscale0` | accept (tailnet ACLs are the access control; tightening is a rollout step) |
| `ip saddr 100.64.0.0/10` from any other interface | drop (spoofed tailnet source; replaces `ts-input`) |
| LAN → tcp `22`, `80`, `443` | accept |
| LAN → udp `5353` | accept (mDNS) |
| LAN → icmp echo-request, ≤10/s | accept |
| LAN → IGMP | accept (multicast group maintenance for avahi) |
| udp sport 67 → dport 68 | accept (DHCP replies) |
| everything else | rate-limited log, then `drop` |

Not opened: udp `41641` from the internet. Direct Tailscale paths come up through outbound-initiated NAT traversal plus the `established` rule; the Spark is behind the LAN router anyway.

### Outbound (`output`, policy drop)

| Rule | Allows |
|---|---|
| `ct state invalid` | drop |
| `ct state established,related` | accept |
| `oifname lo` | accept |
| `oifname tailscale0` | accept (tailnet ACLs) |
| packet mark `0x80000/0xff0000` | accept (`tailscaled`: control plane, DERP, STUN, WireGuard to peers) |
| udp `123` to `NTP_SERVERS` (empty by default; the LAN is already allowed) | accept |
| `ip daddr @maint_dst` | accept, **only while a maintenance window is open** |
| `ip daddr 192.168.1.0/24` | accept (LAN: router DNS, DHCP renewals, SSH replies, mDNS unicast, everything else on the LAN) |
| `224.0.0.251` udp `5353` | accept (mDNS) |
| IGMP | accept |
| `255.255.255.255` udp 68 → 67 | accept (DHCP discover is a broadcast, outside `192.168.1.0/24`) |
| everything else | rate-limited log, then `reject` (`tcp reset` for TCP, `icmpx admin-prohibited` otherwise) |

Everything not listed, notably **all non-loopback IPv6 not on `tailscale0`**, falls into the final reject. ARP is not touched by an `inet` table.

## Architecture

```
                    ┌───────────────────────── host: nftables table inet sparky_fw ─────────────────────────┐
LAN 192.168.1.0/24 ─┤ input : 22, 80, 443, mDNS, ping           ┐                                          │
                    │                                           ├─> sshd, Traefik (rootlesskit :80/:443)   │
tailnet ── tailscale0 ──── accept (tailnet ACLs) ───────────────┘     tailscaled ──> 127.0.0.1:80/443       │
                    │                                                                                       │
                    │ output: LAN ✔   tailscale0 ✔   tailscaled (mark 0x80000) ✔   NTP (LAN / listed) ✔        │
internet ◀──────────┤         rootless Docker user (all containers) ✘ ── reject                              │
                    │         root apt / git / hf ✘ ── reject, unless:                                       │
                    │         `make disable` → table removed, auto re-enable timer;  `make enable` → back    │
                    │         (narrower: `make open MINUTES=15` → egress-only set element, self-expiring)    │
                    └────────────────────────────────────────────────────────────────────────────────────────┘
```

## Detailed design

### New directory `firewall/`

Host-level, in the style of `mdns/` and `tailscale/` (not a Compose stack).

```
firewall/
├── ruleset.nft.in             # the ruleset, with @LAN_CIDR@ / @NTP_RULE@ / @FINAL_IN@ / @FINAL_OUT@ placeholders
├── render.sh                  # fills the placeholders from .env; MODE=enforce|audit
├── sparky-firewall.service    # oneshot: loads the rendered ruleset before the network comes up
├── Makefile                   # check, install, apply, confirm, revert, open, close, status, logs, audit-report
├── .env.example               # LAN_CIDR, NTP_SERVERS, MODE, REVERT_SECONDS
├── test-ruleset.sh            # netns tests (section 9)
└── README.md
```

#### `ruleset.nft.in` and `render.sh`

The appendix is the reference. `render.sh` substitutes:

| Placeholder | Default | Source |
|---|---|---|
| `@LAN_CIDR@` | `192.168.1.0/24` | `.env` |
| `@NTP_RULE@` | empty | `.env` `NTP_SERVERS` (IPv4 list) |
| `@FINAL_OUT@` | `reject` actions | `MODE=enforce`; in `MODE=audit` it is `log … flags skuid` + `accept` |
| `@FINAL_IN@` | `counter drop` | `MODE=enforce`; in audit it is `log` + `accept` |

The rendered file (`/etc/sparky-firewall/ruleset.nft`) is not committed. It begins with `add table` / `delete table` / `table { … }` so a reload is one atomic transaction that never leaves a window with no rules (tested: reload keeps existing access working).

Audit mode (verified to parse and load) replaces the two final rules with, for example:

```
limit rate 30/minute log prefix "sparky-fw AUDIT out: " level warn flags skuid
counter accept
```

`flags skuid` puts the owning UID in the log line, so the audit report can say *which* user (Docker's, root's) wanted *which* destination.

#### Makefile targets

| Target | Does |
|---|---|
| `make check` | `nft --version`, `nft -c -f` on the rendered file, warns if `ufw` is active or another `nftables` flush-ruleset service would clobber the table, prints the Docker user's UID and the detected default route interface |
| `make install` | Renders, installs to `/etc/sparky-firewall/`, installs the unit, `systemctl enable`, runs `tailscale set --netfilter-mode=off` (idempotent) |
| `make apply` | `check`, keep the previous ruleset as `ruleset.nft.prev`, load the new one, **arm a revert timer** (`systemd-run --on-active=$(REVERT_SECONDS) --unit=sparky-fw-revert …`, default 120 s) that loads `ruleset.nft.prev` (or deletes the table if there was none) |
| `make confirm` | Stops the revert timer. Run it from a *second* SSH session after verifying access |
| `make revert` | Runs the revert immediately |
| `make disable [MINUTES=30]` | **Turns the firewall off** (`nft delete table inet sparky_fw`), logs `sparky-fw: DISABLED`, and arms the re-enable timer (`systemd-run --on-active=<n>m --unit=sparky-fw-reenable …` running `make enable`'s load). `MINUTES` is capped at 240. Runtime-only: the boot unit is untouched |
| `make enable` | **Turns it back on now**: loads `/etc/sparky-firewall/ruleset.nft` (same atomic load as `apply`, without the revert timer) and cancels the re-enable timer. Idempotent; also the fix after any manual tampering |
| `make open MINUTES=15` | Narrower than `disable`: adds `0.0.0.0/0 timeout <n>m` to `maint_dst`, opening egress only; `MINUTES` capped at 120 (default 15) |
| `make close` | Deletes that element |
| `make status` | **Prominently** one of `ENFORCING` / `AUDIT` / `DISABLED (re-enables in 12m)`; then `nft list table inet sparky_fw` (rule counters, set elements with *remaining* timeout) and whether a revert or re-enable timer is armed |
| `make logs` | `journalctl -k` filtered to `sparky-fw` |
| `make audit-report` | Summarises audit-mode log lines by (UID, proto, destination, port) with counts, so allow-list decisions are made from data |

`make apply` refuses to run when `MODE=enforce` and no audit period has been recorded (a marker file written by `audit-report`), unless `FORCE=1`.

#### `sparky-firewall.service`

```
[Unit]
Description=sparky host firewall (nftables)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/sparky-firewall/ruleset.nft
ExecStop=/usr/sbin/nft delete table inet sparky_fw

[Install]
WantedBy=sysinit.target
```

It manages only its own table. It never runs `flush ruleset`, so it cannot disturb anything else (the stock `nftables.service` on Ubuntu does flush; `make check` warns if it is enabled and loading a conflicting file).

NTP needs no user rule: the time client must point at a LAN server or an address in `NTP_SERVERS`.

### Changes to existing files

| File | Change |
|---|---|
| `tailscale/Makefile` | `make up` documents/handles `--netfilter-mode=off` (via `UP_ARGS`, or by the `firewall` install step). A note that without this firewall the default `on` is right |
| `tailscale/README.md` | New "Firewall" section: why `netfilter-mode=off`, that `iifname tailscale0` is the tailnet entry point, that `tailscaled` egress is allowed by its socket mark |
| `litellm/docker-compose.yml` | Telemetry off: `LITELLM_TELEMETRY=False` (verify the exact variable against the pinned image). Purely to stop noisy blocked attempts; the firewall is the enforcement |
| `open-webui/docker-compose.yml` | Update checks and online features off: `ENABLE_VERSION_UPDATE_CHECK=false`, and `OFFLINE_MODE=true` if the pinned version supports it (verify). Same rationale |
| `models/qwen38/README.md` | `make prepare` (image pull, ~96 GiB download) now needs the internet, which is closed by default: `make -C /opt/firewall disable MINUTES=90`, then `make prepare`, then `make -C /opt/firewall enable`. `make up` and serving are unaffected (offline) |
| `README.md` | Layout, Components, first-time setup step (after Traefik, Tailscale, before exposing services), and **Deploy workflow**: the `git pull` over SSH now happens inside a window |
| `CHANGELOG.md` | Added entry with the ordered host rollout |
| `docs/` | This spec |

README deploy workflow, as it becomes:

```bash
ssh spark-1822.local 'make -C /opt/firewall disable MINUTES=10 \
  && sudo git -C /opt pull --ff-only --recurse-submodules; make -C /opt/firewall enable'
# `enable` runs even if the pull failed; if the connection drops first, the timer re-enables it
```

Pulling images is the same pattern: `make disable`, `docker compose pull` (or `make prepare`), `make enable`.

(Open question 1 covers the alternative: a push-based deploy so the host needs no internet at all.)

### Interactions to get right

- **Tailscale serve path.** `tailscaled` serves the node and the VIP services and proxies to `127.0.0.1:80/443`. Loopback is accepted, and tailnet clients arrive on `tailscale0`, which is accepted. The reference ruleset is deliberately broad here (`iifname "tailscale0" accept`) because how serve and VIP-service traffic enter the host's `INPUT` chain in kernel mode has not been traced. The rollout tightens it to `tcp dport { 22, 80, 443 }` plus ICMP once a trace shows what actually arrives.
- **DNS.** The host resolver (`systemd-resolved`) forwards to the router, which is in the LAN. Containers' external lookups also work (and the connections then get rejected). Container-to-container names are Docker-internal.
- **DHCP.** If the Spark uses DHCP, discover broadcasts (`255.255.255.255`, sport 68) and replies (sport 67) are explicitly allowed. A static lease or address makes these rules inert but harmless.
- **Docker rootful.** Not used. If it ever is, its own iptables chains and bridge forwarding would need to be reconciled with the `forward` policy drop.
- **`reject` and Docker image pulls.** A pull outside a window fails fast with `connection refused` or `network unreachable`. The README says to open a window; no retry loops hang.
- **Log volume.** Blocked-traffic logging is rate-limited (6/min per direction in enforce mode, 30/min in audit). Counters on the drop/reject rules give totals without log noise.

## Operational impact

| Workflow | Before | After |
|---|---|---|
| Serve models, use Open WebUI/LiteLLM from LAN or tailnet | works | **unchanged** |
| Admin over SSH from LAN or tailnet | works | **unchanged** |
| `git pull` on the host | direct | `make disable` … `make enable`, or push-based (open question 1) |
| `make prepare` (image, checkpoint) | direct | `make disable MINUTES=90` … `make enable` |
| `docker pull` (docker.io, ghcr.io, nvcr.io) / OS updates | direct | **blocked by default**; `make disable` … `make enable` |
| A container calling home (telemetry, version checks, SSRF/exfil from a compromised image) | works | **rejected and logged** |
| Tailscale | works | works (allowed by identity) |

## Testing

### Automated: `firewall/test-ruleset.sh`

Runs without root, in a user+network namespace (`unshare -Urnm`) with a veth-connected "LAN peer" namespace holding the LAN address and a stand-in "internet" address. The prototype used to validate this design already does this; the repository version renders the real template and asserts:

- **Inbound:** LAN → 22/80/443 allowed; LAN → an unlisted port dropped; LAN ping allowed.
- **Outbound:** host → LAN peer allowed; host → "internet" rejected, **fast** (well under the connect timeout); loopback allowed; IPv6 to the peer rejected; `::1` allowed.
- **Identity:** a socket carrying mark `0x80000` reaches the "internet"; one carrying a different mark in the same byte does not.
- **Maintenance window:** opens; closes on its own after its timeout; can be closed early; reopening works.
- **Disable / enable:** after `disable` the "internet" is reachable *and* an unlisted LAN port is open (the whole firewall is off); after `enable` both are blocked again; `enable` is idempotent and works when the table is already loaded; `disable` arms the re-enable timer and `enable` cancels it (the timer command is stubbed: `systemd-run` is not available in the namespace); `MINUTES` above the cap is refused.
- **Reload:** loading the ruleset twice is idempotent and keeps access working.
- **Audit mode:** renders, loads, and accepts what enforce mode would reject (and logs it).
- **Render:** every placeholder is substituted; `nft -c` passes for both modes.

Needs `nft`, `ip`, `python3`, and unprivileged user namespaces; the test skips with a clear message otherwise. Not testable this way: the cgroup/user-based and `tailscale0` rules against real services (section 10).

### On the host: acceptance checklist

1. From another LAN machine: `ssh`, `https://litellm.spark-1822.local`, `https://open-webui.spark-1822.local` work; an unlisted port is closed (`nmap`/`nc`).
2. From a tailnet device: `https://litellm.<tailnet>.ts.net` and `https://spark-1822.<tailnet>.ts.net` work.
3. On the host: `curl -m 5 https://example.com` fails **immediately**; `docker run --rm alpine wget -T 5 -qO- https://example.com` fails immediately.
4. `tailscale status` stays healthy through a `tailscaled` restart (the mark rule survives it; a cgroup rule would not).
5. `make disable MINUTES=1`: (3) succeeds, `docker pull alpine` succeeds, `make status` says `DISABLED (re-enables in …)`; about a minute later it fails again with no further action and `make status` says `ENFORCING`. Then `make disable` followed by `make enable`: blocked again **immediately**, and the timer is gone (`systemctl list-timers sparky-fw-reenable*`).
5a. `make open MINUTES=1`: egress works for a minute while an unlisted inbound port stays closed.
6. Reboot: the ruleset is loaded before the network is up (`nft list table inet sparky_fw` immediately after boot; no connectivity window before it).
7. `make logs` shows blocked attempts with their UID; `make status` shows counters moving.
8. `make apply` with a deliberately bad ruleset leaves the old one active (validation) and, with a valid-but-locking ruleset, reverts itself after `REVERT_SECONDS`.

## Pre-implementation spike (on the Spark, before writing the PR)

Each of these is an assumption above. None changes the *goal*; each could change a rule.

| # | Verify | How | If it fails |
|---|---|---|---|
| 1 | Rootless container egress hits host `OUTPUT` as the Docker user | `sudo nft add table inet spike; … chain output { type filter hook output priority 0; } rule meta skuid <uid> counter log`, then `docker run alpine wget` | Egress is via a different mechanism: reconsider per-network-namespace rules |
| 2 | Published `:80/:443` (rootlesskit) traverses `INPUT`; the real client IP is visible | `nft monitor trace` while curling from a LAN host | Add the rule where it does land, or switch the port driver |
| 3 | What reaches `INPUT` from `tailscale0` for a serve/VIP request | `nft monitor trace` with `meta iifname tailscale0` while browsing the tailnet URL | Decides the tightened tailnet rule; if serve is intercepted before the kernel stack, `tailscale0` can be narrowed to `22` only |
| 4 | `tailscaled`'s control/DERP/WireGuard sockets carry the bypass mark | `nft add rule … meta mark & 0xff0000 == 0x80000 counter` during `tailscale up` / `tailscale ping` | Fall back to `meta skuid 0` plus a destination allow, or `--tun`-less userspace mode |
| 5 | Which NTP client runs, and as which user | `systemctl status systemd-timesyncd chrony`; `ps -o user,cmd -C chronyd,systemd-timesyn` | Point NTP at the router, or list the server in `NTP_SERVERS` |
| 6 | Static address or DHCP; DNS resolver | `nmcli`/`networkctl`, `resolvectl status` | Drop or keep the DHCP rules; confirm DNS goes to a LAN address |
| 7 | `ufw` and `nftables.service` state | `ufw status`; `systemctl is-enabled nftables` | Disable `ufw`; make sure the stock `nftables.service` can't `flush ruleset` over this table |
| 8 | nft version on the host supports every expression used (priority keyword, `reject with icmpx`, interval+timeout sets) | `nft --version`, `nft -c -f` on the rendered file | Rewrite the offending expression; the test suite pins a minimum |
| 9 | Is IPv6 configured on the LAN interface | `ip -6 addr` | Blocking it is intended either way; confirm nothing on the host relies on it |
| 10 | What happens to a long download that is running when the firewall re-enables (and to one started during a `disable`) | Start `docker pull` of a large image during `make disable MINUTES=1`; watch it across the re-enable | If it resets reliably, document "re-enable after the pull" as the rule and consider an opt-in `enable --wait-idle` |

## Rollout

1. **Spike** (above). Update this document with the findings.
2. **PR**: `firewall/`, tests, docs, changelog. Merged with `MODE=enforce` as the shipped default (the audit gate still applies: `make apply MODE=audit` first).
3. **Host, audit** (several days, covering at least one deploy, one `make prepare` and one OS update): `make install apply confirm`; then `make audit-report`. Everything it lists that is *not* expected is the finding, and what is expected becomes either a documented window or an exception.
4. **Host, enforce**: `make apply` (enforce is the default) from one SSH session, verify from a second, `make confirm`. The revert timer is the safety net.
5. **Tighten**: narrow the `tailscale0` rule using spike item 3; review the LAN rules.
6. **Telemetry settings** (`litellm`, `open-webui`) can ship with the PR; they only stop noise.

## Risks

| Risk | Mitigation |
|---|---|
| Lockout from SSH | `nft -c` validation; confirm-or-revert; audit period; apply from a LAN session with Tailscale as a second way in |
| A needed destination discovered only after enforcement | Audit mode with UID logging first; `make disable` for anything operational (no per-destination exceptions) |
| `tailscaled` breaks (control plane or relays unreachable) | Identity-based, so IP changes don't matter; acceptance step 4; `make revert` |
| Clock drift (blocked NTP) breaks Tailscale TLS | NTP to the LAN or listed servers; spike item 5 |
| `nftables.service` / `ufw` / another tool flushes or shadows the table | `make check` detects both; the unit manages only its own table |
| A cgroup- or user-based match fails at load (missing user) | `make check` verifies; the mark rule is deliberately load-time-independent |
| Firewall left disabled (everything, inbound included, is open) | Mandatory re-enable timer (default 30 min, cap 240); a reboot always restores it; `make status` and the journal show `DISABLED`; prefer `make open` when inbound filtering should stay on |
| Egress window left open | Mandatory timeout, 120-minute cap, visible in `make status` |
| A transfer in flight when the firewall re-enables is cut | Connections made while it was off were not tracked by conntrack; they are picked up mid-stream and usually survive, but may reset (spike item 10). Re-enable *after* the pull finishes, and size `MINUTES` generously |
| Ruleset fails to load at boot | Fail open, unit fails loudly; validation makes it unlikely |
| Updates are forgotten because the host can't reach the internet on its own | Documented windows in the deploy workflow; a weekly timer that opens one is possible but out of scope |
| Open WebUI / LiteLLM features that need the internet (web search, remote image fetch) silently stop | Expected and desirable; documented in their READMEs |

## Open questions (defaults assumed so implementation can proceed)

1. **Deploy method.** *Default:* keep `git pull` on the host, inside a window. *Alternative:* push-based deploys from a LAN machine (`git push` to a LAN remote, or `rsync`), so the host never needs the internet for deploys; `make prepare` and OS updates would still need windows.
2. **Tailnet scope.** *Default:* accept everything from `tailscale0` at first, narrow after the spike. Tag the node and tighten the tailnet ACL regardless.
3. **ICMP.** *Default:* echo-request from the LAN only, rate-limited.
4. **Docker-internal egress control** (making the app networks `internal: true`). *Default:* not in this change.

## Future work

- FQDN-based permanent exceptions: dnsmasq with `nftset=` populating an allow-set, for anything that turns out to need standing egress.
- Docker `internal: true` networks as a second wall under the host rules.
- A scheduled weekly disable window for updates (with `make enable` at the end), if remembering to patch becomes a problem.
- Narrowing LAN access further (per-service source addresses).
- Enabling IPv6, if it is ever wanted.

## Appendix: reference ruleset

Loaded and exercised in a user+network namespace with nft 1.1.6 (kernel 7.2): 18 behavioural checks passed — LAN inbound allow/deny, LAN and loopback egress, fast reject of internet egress, IPv6 reject, mark-based identity (matching and non-matching mark), self-expiring and manual maintenance window, idempotent reload. The audit variant also parses and loads, a hyphenated `skuid` name (as `systemd-timesync`) parses, and `nft -c` rejects a user that doesn't exist (`User does not exist`), which is what `make check` relies on. Not exercised: `tailscale0`, real `tailscaled` marks, or a real `skuid` other than root.

```nft
define LAN = 192.168.1.0/24

table inet sparky_fw
delete table inet sparky_fw

table inet sparky_fw {
    # Maintenance window: while it holds 0.0.0.0/0 the host may open IPv4
    # connections anywhere. The element carries its own timeout, so the window
    # closes by itself even if nothing is left running to close it.
    set maint_dst {
        type ipv4_addr
        flags interval, timeout
    }

    chain input {
        type filter hook input priority filter; policy drop;
        ct state invalid drop
        ct state established,related accept
        iifname "lo" accept
        iifname "tailscale0" accept
        ip saddr 100.64.0.0/10 counter drop                       # tailnet source on any other interface: spoofed
        ip saddr $LAN tcp dport { 22, 80, 443 } accept
        ip saddr $LAN udp dport 5353 accept                       # mDNS
        ip saddr $LAN icmp type echo-request limit rate 10/second accept
        ip saddr $LAN ip protocol igmp accept
        udp sport 67 udp dport 68 accept                          # DHCP replies
        limit rate 6/minute log prefix "sparky-fw in: " level warn
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy drop;
        ct state invalid drop
        ct state established,related accept
        oifname "lo" accept
        oifname "tailscale0" accept
        meta mark & 0xff0000 == 0x80000 accept                    # tailscaled's own sockets (its bypass mark)
        # NTP: only when NTP_SERVERS is set: ip daddr { … } udp dport 123 accept
        ip daddr @maint_dst accept
        ip daddr $LAN accept
        ip daddr 224.0.0.251 udp dport 5353 accept                # mDNS
        ip protocol igmp accept
        ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept # DHCP discover
        limit rate 6/minute log prefix "sparky-fw out: " level warn
        meta l4proto tcp counter reject with tcp reset
        counter reject with icmpx type admin-prohibited
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }
}
```

Maintenance window, as used by `make open` / `make close`:

```bash
nft add    element inet sparky_fw maint_dst '{ 0.0.0.0/0 timeout 15m }'
nft delete element inet sparky_fw maint_dst '{ 0.0.0.0/0 }'
```

Facts this design rests on, from Tailscale's source (`net/netns`, `tsconst`, `cmd/tailscale/cli`): non-loopback sockets created by `tailscaled` are marked `0x80000` under the mask `0xff0000` (falling back to binding the socket to a device if `SO_MARK` doesn't work); `--netfilter-mode` takes `on`, `nodivert` or `off`.

## Implementation notes (where the build differs from the design above)

- **Control script.** The logic lives in `firewall/sparky-firewall` (installed to `/usr/local/bin`), not in the Makefile, so the transient systemd timers (`sparky-fw-revert`, `sparky-fw-reenable`) don't depend on the repo checkout. The Makefile targets are thin `sudo` wrappers; the script also has `check`, `apply`, `confirm`, `revert`, `disable`, `enable`, `open`, `close`, `status`, `logs`, `audit-report`.
- **`make install` loads and enables nothing.** `apply` installs and loads a validated ruleset; `confirm` enables the boot unit. The unit has `ConditionPathExists` on the ruleset, so an unconfirmed ruleset can't load at boot by accident.
- **`tailscale set --netfilter-mode=off` happens in `apply`** (not `install`), and `revert` / `uninstall` set it back to `on`.
- **`make check`** runs `nft -c`, warns about an active `ufw` and an enabled `nftables.service`, warns when no host Tailscale is found, and prints the default route. It does not print the Docker user's UID (nothing in the ruleset needs it: egress is default-deny for everyone but `tailscaled`).
- **`MODE` default is `enforce`** (`.env.example` and `render.sh`); `apply` refuses `enforce` until `audit-report` has recorded a review (`FORCE=1` overrides).
- **`apply` keeps the original previous ruleset** across repeated applies before a confirm, so `revert` always returns to the last *confirmed* state.
- **`render.sh` normalises a host address to its network**: `LAN_CIDR=192.168.1.1/24` becomes `192.168.1.0/24` (with a note), and refuses IPv6, anything wider than a /8, and invalid `NTP_SERVERS` entries (hostnames, IPv6).
- **Telemetry variables** (verified against upstream source, not guessed): LiteLLM `LITELLM_TELEMETRY_DISABLED=true` (current images; harmless on older ones), Open WebUI `ENABLE_VERSION_UPDATE_CHECK=false`. `OFFLINE_MODE=true` is documented but left off, because it also stops model downloads and would break RAG embeddings that are not cached yet.
- **Spike items are unchanged and still open**, in particular: that rootless container egress reaches the host `OUTPUT` chain as the Docker user, what `tailscale0` traffic reaches `INPUT`, and what happens to a transfer that spans a re-enable.
