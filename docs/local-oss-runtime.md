# Local OSS Runtime

Use this path when the Azure subscription, Azure Key Vault, Azure OpenAI, or
the standalone OS1 Azure VM is unavailable. It keeps OS1/Hermes usable without
Azure CLI reads, Azure writes, Key Vault access, or remote VM mutation.

Hermes Agent is installed separately from OS1. This runbook configures local
OpenAI-compatible model providers for an existing Hermes install; it does not
install the agent.

## Safety Posture

- No Azure resources are created, updated, started, stopped, or deleted.
- No Azure Key Vault, Container App, or Azure OpenAI secrets are read.
- The local setup script only writes local Hermes files under `~/.hermes`:
  `config.yaml`, `.env`, and `auth.json`.
- Existing local Hermes files are backed up under `~/.hermes/backups`.
- The local provider key written by the helper is a placeholder for
  OpenAI-compatible local servers that do not require a real API key.
- The helper does not install Python packages. If PyYAML is unavailable, it
  writes a minimal Hermes local-provider config and keeps the previous config
  backup.
- The helper does not install CUA/Computer Use. For CUA on the local Hermes
  Agent, run `hermes computer-use install` in that Hermes environment.

## Ollama

Start Ollama and install a practical local task model:

```sh
ollama serve
ollama pull qwen2.5-coder:3b
```

For the full Hermes Agent runtime, prefer a model with at least a 64K context
window. On the current 8 GB Mac, `llama3.1:8b` is the smallest installed model
that satisfies Hermes' runtime check:

```sh
ollama pull llama3.1:8b
```

Then point Hermes at Ollama's OpenAI-compatible endpoint. When `OLLAMA_MODEL`
is not set, the helper chooses `llama3.1:8b` if it is installed, then falls
back to the first model exposed by Ollama:

```sh
scripts/configure-local-oss-models.sh ollama
```

Optional overrides:

```sh
OLLAMA_OPENAI_BASE_URL=http://127.0.0.1:11434/v1 \
OLLAMA_MODEL=llama3.1:8b \
OLLAMA_NUM_CTX=4096 \
HERMES_MAX_TOKENS=128 \
scripts/configure-local-oss-models.sh ollama
```

Use `qwen2.5-coder:3b` for direct local task scripts when speed matters; use
`llama3.1:8b` for Hermes Agent itself so the runtime has a 64K context
declaration. The helper disables Hermes compression by default for this
local-smoke profile because the auxiliary compression model also needs a 64K
context window. Re-enable it only after the selected local model responds
quickly:

```sh
HERMES_COMPRESSION_ENABLED=true scripts/configure-local-oss-models.sh ollama
```

## llama.cpp

Run a llama.cpp OpenAI-compatible server on `127.0.0.1:8080`, then configure
Hermes:

```sh
scripts/configure-local-oss-models.sh llama-cpp
```

Optional overrides:

```sh
LLAMA_CPP_OPENAI_BASE_URL=http://127.0.0.1:8080/v1 \
LLAMA_CPP_MODEL=Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf \
HERMES_CONTEXT_LENGTH=64000 \
scripts/configure-local-oss-models.sh llama-cpp
```

If the llama.cpp server was started with an 8K context, keep prompts small.
The 64K declaration is only there to satisfy Hermes Agent's runtime guard
during local smoke tests.

## LM Studio

Run LM Studio's local server on `127.0.0.1:1234` with an
OpenAI-compatible `/v1` endpoint, then configure Hermes:

```sh
scripts/configure-local-oss-models.sh lm-studio
```

If LM Studio does not return a default model from `/v1/models`, set one
explicitly:

```sh
LM_STUDIO_MODEL=your-loaded-model-id scripts/configure-local-oss-models.sh lm-studio
```

## Verification

Run the local health helper first. It reports Ollama reachability, installed
models, disk, memory, native API status, and OpenAI-compatible endpoint status
without printing secrets:

```sh
scripts/ollama-health.sh
```

Check the local provider is serving an OpenAI-compatible models endpoint:

```sh
curl -fsS http://127.0.0.1:11434/v1/models >/dev/null
```

For llama.cpp, use:

```sh
curl -fsS http://127.0.0.1:8080/v1/models >/dev/null
```

The configure script prints JSON with the selected provider, base URL, model,
context settings, and changed-file flags. It does not print secret values.

For short local-only repo triage, log summaries, or draft tasks that do not
need the full Hermes Agent runtime, call Ollama's native API directly:

```sh
OLLAMA_MODEL=qwen2.5-coder:3b scripts/ollama-task.sh "Summarize docs/local-oss-runtime.md"
```

Tune bounded local tasks with `OLLAMA_NUM_PREDICT` and
`OLLAMA_TEMPERATURE`.

## Azure Restoration

When Azure access is restored, keep the first pass read-only:

```sh
scripts/azure/os1-vm.sh preflight
scripts/azure/sync-os1-secrets.py --dry-run
```

Only after the subscription state is `Enabled`, Key Vault reads succeed, and
you intentionally want Azure or VM changes:

```sh
OS1_AZURE_ALLOW_MUTATIONS=1 scripts/azure/os1-vm.sh start
scripts/azure/sync-os1-secrets.py --apply
```
