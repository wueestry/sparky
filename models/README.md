# models/

One subfolder per served model. Each is a self-contained Compose stack that:

- joins the shared `traefik` Docker network and listens there **without** a Traefik router, so the only public door is [`litellm/`](../litellm/);
- is started and stopped on its own (`make up` / `make down` inside the folder, or `make up engine=<name>` from the repo root);
- is declared once in [`litellm/config.yaml`](../litellm/config.yaml), which is how clients reach it.

| Folder | Model | Source |
|---|---|---|
| [`qwen38/`](qwen38/) | Qwen3.8 Flash Next (NVIDIA FP4 QAD) on TensorFold, one GPU | [MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold), vendored as a git submodule |

## Adding a model

1. Create `models/<name>/`. If the model comes from an upstream recipe repo, add it as a submodule at `models/<name>/upstream` and keep it unpatched; put everything this host needs in files beside it (see `qwen38/` for the pattern: upstream decides *what* runs, the compose file decides *how* it runs on rootless Docker).
2. Give the container a short, unique name (`container_name: <name>`), join the `traefik` network, bind any debug port to `127.0.0.1` only.
3. Add a `model_list` entry to `litellm/config.yaml` pointing at `http://<name>:<port>/v1`, then `docker compose restart litellm`.
4. Add the folder to the table above and to the top-level `Makefile`'s `ENGINES` list.

GPU memory is shared by everything: these engines claim it eagerly, so stop the other one first (`make down engine=<other>` from the repo root). On the GB10, exhausting unified memory can hang the host rather than fail cleanly.
