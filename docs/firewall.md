# Host firewall: implementation

This page explains how `firewall/` works: what each rule does, how the ruleset is produced and loaded, what the control script does, and where the design is weaker than it sounds. For installing and operating it, see [`firewall/README.md`](../firewall/README.md).

## Goal and non-goals

In and out of the host, **only the LAN (`192.168.1.0/24`) and Tailscale** are allowed. Everything else is closed, container registries included, with no hostname or registry allow-list. When an operation needs the internet, the operator turns the firewall off on purpose (`make disable`), does the work, and turns it back on (`make enable`).

The aim is containment as much as exposure: the host runs images this repo does not build, loads multi-GB model files and holds the GPU, and a compromised container should have no route to the internet.

Not goals: defending against root on the host, filtering traffic inside the LAN, replacing Tailscale ACLs, FQDN allow-listing, IPv6 on the LAN.

## Design decisions

- **nftables, one `inet` table named `sparky_fw`**, covering IPv4 and IPv6 together. Not `ufw` (it would fight a hand-written ruleset), and rootless Docker installs no iptables rules of its own.
- **Default drop in both directions.** `input`, `output` and `forward` all have `policy drop`.
- **Identity beats destination for Tailscale.** The control plane, DERP relays and peers have no stable addresses and nftables cannot match hostnames, so `tailscaled` is allowed by *what it is*: it sets `SO_MARK = 0x80000` (mask `0xff0000`) on every socket it creates, and the output chain matches `meta mark & 0xff0000 == 0x80000`. A cgroup match was rejected because nft resolves the cgroup path at load time, so the ruleset would fail to load while the service was stopped and go stale on every restart. Setting the mark needs `CAP_NET_ADMIN`.
- **Outbound blocks are rejected, inbound blocks are dropped.** A rejected connect fails in milliseconds, so a blocked `docker pull` says so instead of hanging; dropping inbound gives scanners nothing.
- **`tailscaled` stops managing netfilter** (`tailscale set --netfilter-mode=off`). Two sets of base chains would both have to accept the same packet, and Tailscale's `ts-input` can disagree with this ruleset. Its one useful rule, dropping tailnet-range sources on other interfaces, is in this ruleset instead.
- **The internet is reached by disabling the firewall**, not by exceptions. `disable` is time-boxed and a reboot always restores the firewall.

## The ruleset

`firewall/ruleset.nft.in` is a template; `render.sh` fills five placeholders (`@MODE@`, `@LAN_CIDR@`, `@NTP_RULE@`, `@FINAL_IN@`, `@FINAL_OUT@`). The file begins with `table inet sparky_fw` followed by `delete table inet sparky_fw` and then the real definition. `nft -f` runs the whole file as **one atomic transaction**, so a reload replaces the table without a moment in which it is absent, and the file never says `flush ruleset`, so it cannot disturb another table.

### `input` (policy drop)

| Rule | Meaning |
|---|---|
| `ct state invalid drop` | malformed or out-of-state packets |
| `ct state established,related accept` | replies to what the host started |
| `iifname lo accept` | loopback (this is how `tailscaled` reaches Traefik) |
| `iifname tailscale0 accept` | the tailnet; tailnet ACLs are the access control |
| `ip saddr 100.64.0.0/10 counter drop` | tailnet-range source on any *other* interface is spoofed |
| `ip saddr $LAN tcp dport {22, 80, 443} accept` | SSH and Traefik from the LAN |
| `ip saddr $LAN udp dport 5353 accept` | mDNS |
| `ip saddr $LAN icmp type echo-request limit rate 10/second accept` | ping |
| `ip saddr $LAN ip protocol igmp accept` | multicast group membership |
| `udp sport 67 udp dport 68 accept` | DHCP replies |
| `@FINAL_IN@` | log (rate-limited) and drop |

### `output` (policy drop)

| Rule | Meaning |
|---|---|
| `ct state invalid drop`, `established,related accept`, `oifname lo accept` | as above |
| `oifname tailscale0 accept` | anything to the tailnet |
| `meta mark & 0xff0000 == 0x80000 accept` | `tailscaled`'s own sockets: control plane, relays, peers |
| `@NTP_RULE@` | only when `NTP_SERVERS` is set: `ip daddr { … } udp dport 123 accept` |
| `ip daddr @maint_dst accept` | the egress window (below) |
| `ip daddr $LAN accept` | everything to the LAN |
| `ip daddr 224.0.0.251 udp dport 5353 accept` | mDNS |
| `ip protocol igmp accept` | IGMP |
| `ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept` | DHCP discover |
| `@FINAL_OUT@` | log (rate-limited), then `reject with tcp reset` for TCP and `reject with icmpx admin-prohibited` for the rest |

`forward` is empty with policy drop: the host routes nothing. Under rootless Docker nothing needs forwarding.

### IPv6

There are no IPv6 rules beyond loopback and `tailscale0`. IPv6 is therefore rejected everywhere else, including neighbour discovery, which is intended: IPv6 on the LAN is out of scope. Rejecting (not dropping) makes dual-stack clients fall back to IPv4 at once. IPv4 ARP is not filtered by an `inet` table and keeps working.

### Why containers are covered without per-container rules

Rootless containers have no host bridge. Their outbound connections are opened by the Docker user's `rootlesskit` process, so they appear in the host's `output` chain as ordinary sockets, and a default-deny `output` gives every container LAN-only egress. Published ports (`:80`, `:443`) are plain userspace listeners and pass through `input`. Container-to-container traffic never touches the host's netfilter. **This is the one assumption to confirm on the real host** (see "Limits").

A rootful Docker install would break all of this: its DNAT and FORWARD rules would be hit by the empty `forward` chain.

## Rendering

`render.sh` turns the template into `build/ruleset.nft`. Settings come from `.env` (`KEY=value` lines, parsed but **never executed**) or the environment, which wins. The result is loaded as root, so every value is validated first:

| Setting | Default | Validation |
|---|---|---|
| `LAN_CIDR` | `192.168.1.0/24` | IPv4 only; a host address like `192.168.1.1/24` is normalised to its network (with a note); anything wider than a `/8` is refused |
| `NTP_SERVERS` | empty | comma-separated IPv4 addresses; hostnames and IPv6 refused |
| `MODE` | `enforce` | `enforce` or `audit` |

The mode is written into the file's header (`# sparky-fw mode: enforce`), which is how the control script later tells what is loaded.

### Audit mode

`MODE=audit` swaps only the two final rules. Inbound and outbound that would have been blocked are logged (outbound with `flags skuid`, so the owning UID is in the line) and then **accepted**. `audit-report` groups those lines by user and destination so the first enforcing load is made from data rather than a guess.

## Control script

`sparky-firewall` is installed to `/usr/local/bin` by `make install`. The transient systemd timers it arms run this installed copy, so they never depend on the checkout. It manages one thing, the table `inet sparky_fw`, and five pieces of state:

| State | Where | Cleared by |
|---|---|---|
| Active ruleset | `/etc/sparky-firewall/ruleset.nft` | `revert` with no previous |
| Revert target | `/etc/sparky-firewall/ruleset.nft.prev` | `revert`, `uninstall` |
| Timer deadlines | `/run/sparky-firewall/<unit>` (tmpfs) | reboot, `cancel_timer` |
| Audit review marker | `/var/lib/sparky-firewall/audit-reviewed` | never; written by `audit-report` |
| The transient units | `sparky-fw-revert`, `sparky-fw-reenable` | stop, expiry, reboot |

### States

```
NOT APPLIED ──apply──> LOADED (unconfirmed, revert timer armed) ──confirm──> CONFIRMED (loaded at boot)
                            │ timer expires or `revert`                          │
                            v                                                    ├─ disable ──> DISABLED (table deleted, re-enable timer)
                      previous ruleset, or none                                  │                  │ timer, `enable`, or reboot
                                                                                 │ <────────────────┘
                                                                                 └─ open ──> egress window (set element with its own timeout)
```

### Commands

- **`apply FILE`** refuses `enforce` until an audit has been reviewed (`FORCE=1` overrides), validates with `nft -c`, saves the current ruleset as `.prev` unless an unconfirmed apply is already pending (so a second apply cannot make an unconfirmed ruleset the revert target), sets Tailscale's `--netfilter-mode=off`, installs and loads the file, and arms a `systemd-run` timer (`REVERT_SECONDS`, default 120) that runs `revert`.
- **`confirm`** cancels the revert timer and enables the boot unit. It is meant to be run from a **second SSH session** after checking access: that is the whole lock-out protection.
- **`revert`** reloads `.prev`, or, with none, deletes the table and gives netfilter back to Tailscale.
- **`disable [MINUTES]`** deletes the table (everything is open, inbound included) and arms a re-enable timer. Default 30 minutes, cap 240. It refuses when nothing is installed, since there would be nothing to re-enable.
- **`enable`** reloads the installed ruleset and cancels the timer. Idempotent.
- **`open [MINUTES]` / `close`** are a narrower tool: they add or remove `0.0.0.0/0 timeout Nm` in the `maint_dst` set. That opens *egress only*, keeps inbound filtering, and closes by itself when the element expires, with no timer or daemon. Default 15 minutes, cap 120.
- **`status`** prints `ENFORCING`, `AUDIT`, `DISABLED` (with the time left) or `NOT APPLIED`, the egress window, any armed revert, and the live ruleset with counters.
- **`logs`, `audit-report`, `check`** read the kernel log, summarise audit lines, and validate a file plus the host around it (warns about an active `ufw`, an enabled `nftables.service` whose `flush ruleset` would wipe the table, and a missing host Tailscale).

## Boot

`sparky-firewall.service` is a oneshot ordered `Before=network-pre.target` with `DefaultDependencies=no`, so the ruleset is in place before any interface is configured. It loads `/etc/sparky-firewall/ruleset.nft` and is enabled only by `confirm`; `ConditionPathExists` keeps it inert until a ruleset exists. It fails open: if the load ever failed, the host would boot unfiltered and the unit would fail loudly, rather than boot unreachable. That path is unlikely because the file was validated with `nft -c` before it was installed.

Because the disabled state is runtime-only (the table is deleted but the unit stays enabled), **a reboot always restores the firewall**.

## Tailscale interplay

- **Prerequisite:** Tailscale runs on the host in kernel mode (`tailscale/`). A container-based Tailscale would be blocked by this firewall; `check` warns when no host `tailscale` is found.
- **Ingress from the tailnet** arrives on `tailscale0` (accepted) and `tailscaled` proxies it to Traefik on loopback (accepted). The rule is deliberately broad, `iifname tailscale0 accept`, because how Serve and VIP-service traffic enter `input` in kernel mode was not traced; tightening it to `tcp dport {22, 80, 443}` plus ICMP is a follow-up once a trace shows what actually arrives.
- **Egress** is `tailscale0` plus the mark rule. Setting an exit node would route everything through the tailnet, which this ruleset would allow.

## Tests

`./test-ruleset.sh` (`make test`) runs 78 checks inside a throwaway user and network namespace (`unshare -Urn`): no root, no effect on the real network. It renders the real template and drives the real control script; only `systemd-run`, `systemctl` and `tailscale` are stubs. A veth pair to a second namespace plays "the LAN", and an address in that namespace plays "the internet". The checks cover:

- rendering: placeholder substitution, mode recorded, normalisation, refusal of bad `LAN_CIDR`/`NTP_SERVERS`/`MODE`, the NTP rule, the default mode
- inbound: allowed and refused ports, spoofed tailnet sources
- outbound: LAN open, internet rejected fast, IPv6 rejected, the mark rule matching only the exact mark
- the egress window opening, expiring and closing by itself
- atomic reload under live traffic
- the script: audit-gated enforce, apply/confirm/revert and the preserved revert target, disable/enable and their bounds, open/close, status text, `check`, unknown commands

Not covered, because the namespace has none of it: real `tailscale0`, real `tailscaled` marks, real rootless Docker egress, and the boot unit.

## Limits

These are deliberate or known, not hidden:

- **Small holes by design:** DHCP replies are accepted from any source; IGMP leaves to any destination; the LAN match is on source address, not tied to an interface, so a spoofed LAN source from a second interface would pass (the host has one NIC, and the upstream is NAT).
- **`disable` is a total opening**, inbound included, for up to four hours. Use `open` when only egress is needed.
- **The tailnet is trusted wholesale** (`tailscale0` in and out); tailnet ACLs are the control.
- **Unverified on the real host, to check on the first rollout:** that rootless container egress reaches `output` as the Docker user (`docker run alpine wget` while in audit mode should log the Docker user); what exactly arrives on `input` from `tailscale0`; that `tailscaled` sockets carry the `0x80000` mark under the installed Tailscale version (`nft add rule … meta mark & 0xff0000 == 0x80000 counter` during `tailscale up`).
- **NTP:** with `NTP_SERVERS` empty, the time client must be pointed at a LAN server (usually the router). Without a reachable time source the clock drifts and Tailscale's TLS eventually fails.
- **A needed destination discovered after enforcing** is a case for a `disable` window, not an exception; if a standing exception is ever wanted, the clean answer is an FQDN allow-list through a proxy, not more nftables rules.
