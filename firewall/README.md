# firewall

A default-deny host firewall (nftables) for `spark-1822`. Only two things are reachable, in either direction:

- the **local network**, `192.168.1.0/24` (SSH, HTTPS to Traefik, mDNS, ping), and
- **Tailscale** (the tailnet interface, plus `tailscaled`'s own connections to the control plane, relays and peers).

**Everything else is closed by default, including every container registry (`docker.io`, `ghcr.io`, `nvcr.io`), Hugging Face, GitHub and the OS mirrors.** There is no hostname or registry allow-list. When you need the internet (pull images, download a model, `git pull`, update the OS) you turn the firewall off on purpose and back on afterwards:

```bash
make disable        # firewall OFF (re-enables itself after 30 min; MINUTES=90 for a model download)
docker compose pull # …or make prepare, git pull, apt upgrade
make enable         # firewall back ON, right now
```

How it is implemented, rule by rule, and its limits: [`docs/firewall.md`](../docs/firewall.md).

## Files

```
firewall/
├── ruleset.nft.in             # the ruleset template (LAN, NTP servers, audit/enforce are filled in)
├── render.sh                  # .env → build/ruleset.nft, with validation
├── sparky-firewall            # control script, installed to /usr/local/bin (apply/confirm/disable/enable/…)
├── sparky-firewall.service    # loads the confirmed ruleset before the network comes up
├── Makefile                   # the commands below
├── .env.example               # LAN_CIDR, NTP_SERVERS, MODE, REVERT_SECONDS
├── test-ruleset.sh            # 78 checks in a throwaway namespace (no root, no effect on the real network)
└── README.md
```

## What is allowed

| Direction | Allowed | Everything else |
|---|---|---|
| **In** | from the LAN: tcp 22, 80, 443; mDNS; ping (rate-limited); IGMP. From `tailscale0`: all (tailnet ACLs decide). Loopback; replies to what the host started; DHCP replies | dropped silently, logged (rate-limited) |
| **Out** | to the LAN: everything. To `tailscale0`: everything. `tailscaled`'s own sockets (they carry Tailscale's bypass mark, so control plane, relays and peers need no IP list). NTP only to the LAN or to the `NTP_SERVERS` you list. Loopback; mDNS; IGMP; DHCP | **rejected immediately** (a clean "connection refused", not a hang), logged |
| **IPv6** | loopback and `tailscale0` only | rejected |

Containers are covered without per-container rules: with rootless Docker their outbound connections are made by the Docker user's processes on the host, so they hit the same default-deny. A compromised container can talk to the LAN and nothing else.

## First time

Prerequisites: Tailscale runs on the host ([`tailscale/`](../tailscale/)); `nft` is installed (`apt install nftables`); `ufw` is inactive.

Do this from a **LAN SSH session, with a second one open** (and the tailnet as another way in):

```bash
cd /opt/firewall
cp .env.example .env        # check LAN_CIDR (192.168.1.0/24) and NTP_SERVERS
make check                  # validates the ruleset, warns about ufw / nftables.service / tailscale
make install                # script + boot unit; loads nothing
make apply MODE=audit       # the default is MODE=enforce, which is refused until an audit was reviewed; audit logs what WOULD be blocked, blocks nothing
make confirm                # keep it (and load it at boot)
```

`make apply` always **reverts itself after 120 s unless you confirm**: it is the safety net against locking yourself out. Run `make confirm` from the second session once you have checked you can still get in.

Then let it run through a few days that include a deploy, a `make prepare` and an OS update, and read what it saw:

```bash
make audit-report           # who (which user) wanted which destination, with counts
```

When the list holds nothing you need permanently, enforce (`MODE=enforce` is the default in `.env`):

```bash
make apply                  # blocks now; reverts in 120 s unless…
make confirm                # …you confirm from a second session
```

`make apply` refuses `MODE=enforce` until `audit-report` has been run (`FORCE=1` overrides).

## Day to day

| Command | Does |
|---|---|
| `make status` | `STATE: ENFORCING`, `AUDIT` or `DISABLED — re-enables in 12m`; egress window; armed timers; rule counters |
| **`make disable`** | **Firewall OFF** (inbound too). `MINUTES=30` by default, max 240; it **re-enables itself** when the time is up |
| **`make enable`** | **Firewall back ON now**; cancels the timer. Idempotent |
| `make open` | Narrower than `disable`: opens *egress only* for `MINUTES=15` (max 120) and keeps inbound filtered. Closes by itself, no timer needed. `make close` ends it early |
| `make logs` | Recent blocked (or would-be-blocked) traffic |
| `make revert` | Back to the previous ruleset right now |

`disable` is runtime-only: the boot unit stays enabled, so a **reboot always comes back filtered**. Connections that were opened while the firewall was off are not tracked by conntrack; they are picked up mid-stream when it re-enables and usually survive, but a very long transfer can reset. Re-enable *after* the pull finishes, and give `MINUTES` room.

Deploying from your laptop:

```bash
ssh spark-1822.local 'make -C /opt/firewall disable MINUTES=10 \
  && sudo git -C /opt pull --ff-only --recurse-submodules; make -C /opt/firewall enable'
```

## How it works

- **One table**, `inet sparky_fw`, replaced atomically on every load. The files here never `flush ruleset`, so they cannot disturb any other table.
- **`tailscaled` is allowed by what it is**, not by IP: it marks its own sockets `0x80000`, and the ruleset matches that mark. (A cgroup match would break on every service restart.) `make apply` sets `tailscale set --netfilter-mode=off`, because Tailscale's own firewall chains and this ruleset would otherwise both have to accept the same packets; the anti-spoofing rule it would have added is in the ruleset.
- **NTP** goes to the LAN (the router or a LAN time server) or to the IPv4 addresses in `NTP_SERVERS`, nothing else: there is no "this user may reach any host on udp/123" rule, since that would be a free tunnel out. Point `timesyncd`/`chrony` at the LAN server (or at one of the listed IPs) so the clock, and Tailscale's TLS, stays right.
- **Blocked inbound is dropped, blocked outbound is rejected**, so a refused `docker pull` fails in milliseconds with a clear error instead of stalling.
- **Audit mode** is the same ruleset with the final rule logging (with the owning UID) and accepting. `audit-report` summarises it.
- **Boot:** `sparky-firewall.service` loads the confirmed ruleset before `network-pre.target`. If it ever fails to load the host boots unfiltered and the unit fails loudly (fail open, not unreachable); the ruleset is validated with `nft -c` before it is ever installed, so that is the unlikely path.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Locked out after `make apply` | Wait 2 minutes: it reverts by itself. Or from the console: `sudo sparky-firewall revert` |
| `docker pull` / `hf download` / `git pull` fails at once with "connection refused" | That is the firewall working: `make disable`, do it, `make enable` |
| `tailscale status` shows peers unreachable | `make status` (is it `DISABLED`?); `make logs` for `sparky-fw out:` lines from the `tailscaled` user; check `tailscale debug prefs \| grep Netfilter` is `off` |
| Clock drifts / `timedatectl` says not synchronised | NTP is only allowed to the LAN and `NTP_SERVERS`: point `timesyncd`/`chrony` at the router, or list the server's IPv4 address in `.env` |
| Rules vanish after something reloads | `ufw` or the stock `nftables.service` (with `flush ruleset`) is active: `make check` warns; disable them |
| `make disable` says nothing is installed | Run `make apply` (and `make confirm`) first |

## Tests

```bash
make test       # or ./test-ruleset.sh
```

It renders the real template and runs the real control script in a user+network namespace with a veth-connected "LAN" peer and a stand-in "internet", so it needs no root and cannot touch the host's network. It covers inbound and outbound rules, fast rejection, the Tailscale mark, IPv6, the egress window and its self-expiry, **disable/enable** (internet and unlisted ports open while off, closed again immediately after, timer armed and cancelled, caps enforced), apply/confirm/revert (including a second apply before confirming), audit mode and `audit-report`, and the renderer's input validation. `systemd-run`, `systemctl` and `tailscale` are stubs. What it cannot cover is real `tailscale0` traffic and real systemd timers: see the spike list in the design doc.
