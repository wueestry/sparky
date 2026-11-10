.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:

# Top-level control for the LLM services. Acts on ONE service at a time —
# it never stops the others, so e.g. bringing the Qwen engine up leaves the
# gateway alone.
#
# Run from the directory that holds the stack subdirs: the repo root, or
# /opt on the host (where models/, litellm/, open-webui/, … are siblings).
# Override ROOT if they live elsewhere.
#
# GPU note: qwen38 (~90 GiB: weights + KV pool + reserve) claims unified memory
# eagerly, so it can't share the GB10 with another eager engine added under
# models/. litellm and open-webui use no GPU. Managing that trade-off is left
# to you — `make down engine=<other>` first when needed.
ROOT ?= .

# Services this Makefile knows about. qwen38 lives under models/ (one
# subfolder per model); litellm is the gateway in front of them; open-webui is
# the chat UI over litellm.
ENGINES := qwen38 litellm open-webui

.PHONY: help up down

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Services: $(ENGINES)"
	@echo "  make up engine=qwen38               — Qwen3.8 Flash Next (models/qwen38; first: make prepare there)"
	@echo "  make up engine=litellm              — the LiteLLM gateway"
	@echo "  make up engine=open-webui           — the chat UI"
	@echo "  make down engine=qwen38             — stop just that service (frees the GPU memory)"
	@echo
	@echo "What's running: docker ps -a   |   what's on the GPU: nvidia-smi"

up:  ## Start one service. Usage: make up engine=<name>
	@case "$(engine)" in \
	    qwen38) \
	        $(MAKE) -C "$(ROOT)/models/qwen38" up ;; \
	    litellm) \
	        ( cd "$(ROOT)/litellm" && docker compose up -d ) ;; \
	    open-webui) \
	        ( cd "$(ROOT)/open-webui" && docker compose up -d ) ;; \
	    "") \
	        echo "usage: make up engine=<name>" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	    *) \
	        echo "unknown engine: $(engine)" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	esac

down:  ## Stop one service (leaves the others running). Usage: make down engine=<name>
	@case "$(engine)" in \
	    qwen38|litellm|open-webui) \
	        if [[ "$$(docker inspect -f '{{.State.Running}}' "$(engine)" 2>/dev/null)" == "true" ]]; then \
	            echo "→ stopping $(engine)"; docker stop "$(engine)" >/dev/null; \
	        else \
	            echo "$(engine) is not running"; \
	        fi ;; \
	    "") \
	        echo "usage: make down engine=<name>" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	    *) \
	        echo "unknown engine: $(engine)" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	esac
