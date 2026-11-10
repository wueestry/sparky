.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:

# Host firewall (nftables). Design: docs/superpowers/specs/2026-11-10-host-firewall-design.md
# Settings (LAN_CIDR, TIMESYNC_USER, MODE, REVERT_SECONDS) live in .env.

BIN      := /usr/local/bin/sparky-firewall
UNIT     := /etc/systemd/system/sparky-firewall.service
CONF_DIR := /etc/sparky-firewall
LIB_DIR  := /var/lib/sparky-firewall
RULES    := build/ruleset.nft

# Optional per-call settings for the commands that take them.
MINUTES ?=
FORCE   ?=
REVERT_SECONDS ?= $(shell sed -n 's/^REVERT_SECONDS=\([0-9][0-9]*\).*/\1/p' .env 2>/dev/null)
SUDOENV := FORCE=$(FORCE) $(if $(REVERT_SECONDS),REVERT_SECONDS=$(REVERT_SECONDS))

.PHONY: help init render check install uninstall apply confirm revert disable enable open close status logs audit-report test _installed

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-13s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "First time (from a LAN ssh session, with a second one open):"
	@echo "  make install → make apply (MODE=audit) → … a few days … → make audit-report"
	@echo "  → set MODE=enforce in .env → make apply → check access from another session → make confirm"
	@echo
	@echo "Internet is CLOSED by default (no registry/hostname allow-list). To pull images, download"
	@echo "models, git pull or update the OS:   make disable   …do it…   make enable"

init:  # internal: first-run .env
	@if [[ ! -f .env ]]; then echo "→ first-time setup: copying .env.example → .env (review LAN_CIDR and MODE)"; cp .env.example .env; fi

render: init  ## Render the ruleset from .env into build/ruleset.nft.
	@./render.sh $(RULES)

_installed:
	@[[ -x $(BIN) ]] || { echo "not installed: run 'make install' first" >&2; exit 1; }

check: render  ## Validate the rendered ruleset and the host around it (nft -c, ufw, nftables.service, tailscale).
	sudo $(if $(wildcard $(BIN)),$(BIN),./sparky-firewall) check $(RULES)

install:  ## Install the control script, the boot unit and config dirs (loads nothing; apply does).
	sudo install -d -m 755 $(CONF_DIR) $(LIB_DIR)
	sudo install -m 755 sparky-firewall          $(BIN)
	sudo install -m 644 sparky-firewall.service  $(UNIT)
	sudo systemctl daemon-reload
	@echo "installed. Next: make apply   (the unit is enabled at boot only by 'make confirm')"

uninstall:  ## Turn the firewall off for good and remove the helper, unit and config.
	-sudo systemctl disable --now sparky-firewall.service
	-sudo nft delete table inet sparky_fw
	-sudo tailscale set --netfilter-mode=on
	sudo rm -rf $(BIN) $(UNIT) $(CONF_DIR) $(LIB_DIR) /run/sparky-firewall
	sudo systemctl daemon-reload
	@echo "removed; the host is unfiltered again."

apply: render _installed  ## Load the ruleset now; it AUTO-REVERTS unless you `make confirm` (MODE=enforce needs a reviewed audit, or FORCE=1).
	sudo env $(SUDOENV) $(BIN) apply $(RULES)

confirm: _installed  ## Keep the applied ruleset and load it at boot. Run from a SECOND ssh session.
	sudo $(BIN) confirm

revert: _installed  ## Go back to the previous ruleset (or none) right now.
	sudo $(BIN) revert

disable: _installed  ## Turn the firewall OFF to reach the internet. Re-enables itself (MINUTES=30, max 240).
	sudo $(BIN) disable $(MINUTES)

enable: _installed  ## Turn the firewall back ON now.
	sudo $(BIN) enable

open: _installed  ## Narrower than disable: open EGRESS only for MINUTES=15 (max 120); inbound stays filtered.
	sudo $(BIN) open $(MINUTES)

close: _installed  ## End the egress window.
	sudo $(BIN) close

status: _installed  ## ENFORCING / AUDIT / DISABLED, egress window, timers, counters.
	@sudo $(BIN) status

logs: _installed  ## Recent blocked (or, in audit mode, would-be-blocked) traffic.
	@sudo $(BIN) logs

audit-report: _installed  ## Summarise audit-mode traffic by user and destination; unlocks MODE=enforce.
	@sudo $(BIN) audit-report

test:  ## Run the ruleset and control-script tests (needs nft, ip, python3, unprivileged user namespaces).
	./test-ruleset.sh
