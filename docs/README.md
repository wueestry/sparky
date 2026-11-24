# Documentation

How sparky is built and why. Each stack's own `README.md` covers deploying and operating it; these pages explain the parts that cut across stacks or need more than a README.

| Page | Read it for |
|---|---|
| [`architecture.md`](architecture.md) | The whole system: request paths, the shared Docker network, TLS, ports, state and secrets, how a change reaches the host |
| [`firewall.md`](firewall.md) | How the default-deny firewall is implemented: the ruleset rule by rule, rendering, the control script's state machine, the Tailscale interplay, boot, tests, and its limits |

Older design and planning documents were removed; the retired llama-cpp router-mode stack they described is in the git history and in `CHANGELOG.md`.
