.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:
.DELETE_ON_ERROR:

SERVICE := qwen38
COMPOSE := docker compose -f docker-compose.yml --env-file .generated/compose.env
# Seconds `make up` waits for the model to load and /health to answer.
WAIT ?= 1800
REF ?= origin/main

.PHONY: help init env prepare check up down logs status smoke update

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "First time:  make prepare   (builds/pulls the image, downloads ~96 GiB) → make up"
	@echo "Upgrading:   make update [REF=<sha|origin/main>] → make prepare check up smoke"
	@echo "Settings:    .env (every upstream/scripts/config.sh knob works) — see .env.example"

init:  # internal: first-run .env
	@if [[ ! -f .env ]]; then \
	    echo "→ first-time setup: copying .env.example → .env"; \
	    cp .env.example .env; \
	fi
	@[[ -f upstream/start.sh ]] || { echo "upstream/ is empty: git submodule update --init models/qwen38/upstream" >&2; exit 1; }

env: init  ## Regenerate .generated/ from upstream's own start.sh (image, serve args, engine variables).
	@./scripts/resolve.sh

prepare: init  ## Build or pull the image and download the checkpoint (upstream's prepare.sh, unchanged). REBUILD=1 rebuilds.
	@./scripts/run-upstream.sh upstream/scripts/prepare.sh $(if $(REBUILD),--rebuild)
	@$(MAKE) --no-print-directory env

check: env  ## Pre-flight: docker, image, checkpoint, serve arguments, free memory.
	@./scripts/check.sh

up: check  ## Start the engine and wait until /health answers (loading takes a few minutes).
	$(COMPOSE) up -d --wait --wait-timeout $(WAIT)

down:  ## Stop the engine and free its GPU memory.
	@if [[ -f .generated/compose.env ]]; then $(COMPOSE) down; else docker rm -f $(SERVICE) >/dev/null 2>&1 || true; fi

logs:  ## Follow the engine log.
	docker logs -f --tail 100 $(SERVICE)

status:  ## Container state and /health.
	@docker ps -a --filter name='^$(SERVICE)$$' --format '{{.Names}}  {{.Status}}'
	@. .generated/compose.env 2>/dev/null; curl -fsS --max-time 5 "http://127.0.0.1:$${TF_HOST_PORT:-8888}/health" && echo || echo "not answering on the loopback port"

smoke:  ## One chat completion through the loopback port.
	@. .generated/compose.env; \
	curl -fsS --max-time 180 "http://127.0.0.1:$$TF_HOST_PORT/v1/chat/completions" -H 'Content-Type: application/json' \
	    -d '{"model":"'"$$TF_SERVED_NAME"'","max_tokens":32,"temperature":0,"chat_template_kwargs":{"enable_thinking":false},"messages":[{"role":"user","content":"Reply with OK."}]}' \
	    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(repr(r["choices"][0]["message"]["content"]), r["usage"]["completion_tokens"], "tokens")'

update:  ## Bump upstream/ to REF (default origin/main), show what changed, verify this overlay still fits.
	@./scripts/update-upstream.sh "$(REF)"
