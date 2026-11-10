.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:

# Tailscale runs as a host service (tailscaled, installed from Tailscale's
# package, kernel mode, root) — not as a container. This directory holds the
# declarative part: which services this node serves, and how to apply them.

BIN      := /usr/local/bin/sparky-tailscale-serve
UNIT     := /etc/systemd/system/sparky-tailscale-serve.service
CONF_DIR := /etc/sparky-tailscale
SERVICES := $(CONF_DIR)/services.json

# Name this node registers as: https://<TS_HOSTNAME>.<tailnet>.ts.net
TS_HOSTNAME ?= spark-1822
# Extra `tailscale up` flags, e.g. UP_ARGS='--advertise-tags=tag:server'.
UP_ARGS ?=

.PHONY: help check install uninstall up apply status logs

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "First time: install Tailscale (https://tailscale.com/kb/1031/install-linux), then"
	@echo "  make check → make install → make up → make apply   (README has the details)"

check:  ## Is tailscale installed, recent enough, and is tailscaled running?
	@command -v tailscale >/dev/null || { echo "tailscale is not installed: https://tailscale.com/kb/1031/install-linux" >&2; exit 1; }
	@tailscale version | head -1
	@tailscale serve set-config --help >/dev/null 2>&1 || { echo "this tailscale has no 'serve set-config': upgrade it" >&2; exit 1; }
	@systemctl is-active --quiet tailscaled || { echo "tailscaled is not running: sudo systemctl enable --now tailscaled" >&2; exit 1; }
	@echo "ok: tailscaled is running and supports declarative services"

install:  ## Install the apply script, the boot-time unit and services.json (idempotent).
	sudo install -d -m 755 $(CONF_DIR)
	sudo install -m 644 services.json                   $(SERVICES)
	sudo install -m 755 sparky-tailscale-serve          $(BIN)
	sudo install -m 644 sparky-tailscale-serve.service  $(UNIT)
	sudo systemctl daemon-reload
	sudo systemctl enable sparky-tailscale-serve.service
	@echo "installed. log in with: make up   — then: make apply"

uninstall:  ## Stop applying on boot and remove the helper (tailscaled and the node stay).
	sudo systemctl disable --now sparky-tailscale-serve.service 2>/dev/null || true
	sudo rm -f $(UNIT) $(BIN) $(SERVICES)
	sudo systemctl daemon-reload
	@echo "removed. To also drop the served config: sudo tailscale serve reset"

up:  ## Log this host into the tailnet (interactive; prints a URL). TS_HOSTNAME=… UP_ARGS=… to change.
	sudo tailscale up --hostname=$(TS_HOSTNAME) --accept-dns=false $(UP_ARGS)

apply:  ## Re-install services.json and apply it now (use after editing it).
	sudo install -m 644 services.json $(SERVICES)
	sudo $(BIN) apply

status:  ## Show what is served and which services this node advertises.
	@sudo $(BIN) status

logs:  ## Journal of the boot-time apply unit.
	journalctl -u sparky-tailscale-serve.service --no-pager -n 50
