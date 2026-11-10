.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:

# Top-level control for the LLM services. Acts on ONE engine at a time —
# it never stops the others, so e.g. bringing vLLM up leaves ollama alone.
#
# Run from the directory that holds the stack subdirs: the repo root, or
# /opt on the host (where vllm/, llama-cpp/, open-webui/, … are siblings).
# Override ROOT if they live elsewhere.
#
# GPU note: vLLM (--gpu-memory-utilization 0.9), llama-cpp classic mode
# (-ngl 999) and qwen38 (~90 GiB: weights + KV pool + reserve) claim memory
# eagerly, so they can't share the GB10 with another eager engine. ollama and
# llama-cpp router mode are lazy. Managing that trade-off is left to you —
# `make down engine=<other>` first when needed. litellm uses no GPU.
ROOT ?= .

# LLM services this Makefile knows about. ollama + open-webui live together
# in the open-webui compose project (the UI depends_on ollama). qwen38 lives
# under models/ (one subfolder per model); litellm is the gateway in front of
# them.
ENGINES := vllm llama-cpp qwen38 litellm ollama open-webui

.PHONY: help list sync up down

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Engines: $(ENGINES)"
	@echo "  make up engine=vllm ENV=<variant>   — start one engine"
	@echo "  make up engine=llama-cpp            — llama-cpp, empty ENV = router mode"
	@echo "  make up engine=qwen38               — Qwen3.8 Flash Next (models/qwen38; first: make prepare there)"
	@echo "  make up engine=litellm              — the LiteLLM gateway"
	@echo "  make down engine=vllm               — stop just that engine"
	@echo "  make list                           — model variants for vllm / llama-cpp"
	@echo "  make sync                           — after hf download / git pull: sync both stacks"
	@echo
	@echo "What's running: docker ps -a   |   what's on the GPU: nvidia-smi"

list:  ## List available model variants for vllm and llama-cpp.
	@echo "vllm:";      $(MAKE) -s -C $(ROOT)/vllm list      2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"
	@echo "llama-cpp:"; $(MAKE) -s -C $(ROOT)/llama-cpp list 2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"

sync:  ## Reconcile vllm + llama-cpp against the HF cache (run after `hf download` or `git pull`).
	@echo "== vllm";      $(MAKE) --no-print-directory -C $(ROOT)/vllm sync
	@echo
	@echo "== llama-cpp"; $(MAKE) --no-print-directory -C $(ROOT)/llama-cpp sync

up:  ## Start one engine. Usage: make up engine=<name> [ENV=<variant>]
	@case "$(engine)" in \
	    vllm|llama-cpp) \
	        $(MAKE) -C "$(ROOT)/$(engine)" up ENV="$(ENV)" ;; \
	    qwen38) \
	        $(MAKE) -C "$(ROOT)/models/qwen38" up ;; \
	    litellm) \
	        ( cd "$(ROOT)/litellm" && docker compose up -d ) ;; \
	    ollama) \
	        ( cd "$(ROOT)/open-webui" && docker compose up -d ollama ) ;; \
	    open-webui) \
	        ( cd "$(ROOT)/open-webui" && docker compose up -d ) ;; \
	    "") \
	        echo "usage: make up engine=<name> [ENV=<variant>]" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	    *) \
	        echo "unknown engine: $(engine)" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	esac

down:  ## Stop one engine (leaves the others running). Usage: make down engine=<name>
	@case "$(engine)" in \
	    vllm|llama-cpp|qwen38|litellm|ollama|open-webui) \
	        if [[ "$$(docker inspect -f '{{.State.Running}}' "$(engine)" 2>/dev/null)" == "true" ]]; then \
	            echo "→ stopping $(engine)"; docker stop "$(engine)" >/dev/null; \
	            if [[ "$(engine)" == "ollama" ]]; then \
	                echo "  note: ollama has restart:unless-stopped — a Docker daemon"; \
	                echo "        restart will bring it back and it may contend for the GPU."; \
	            fi; \
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
