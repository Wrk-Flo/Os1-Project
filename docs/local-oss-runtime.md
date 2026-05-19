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

For the full Hermes Agent runtime, prefer the smallest model that keeps the
workflow responsive on this Mac. The default local profile uses
`qwen2.5-coder:3b`; pull a larger model only when a specific heavier task needs
it:

```sh
ollama pull qwen2.5-coder:3b
```

Then point Hermes at Ollama's OpenAI-compatible endpoint. When `OLLAMA_MODEL`
is not set, the helper chooses `qwen2.5-coder:3b` when it is installed, then
the first model exposed by Ollama:

```sh
scripts/configure-local-oss-models.sh ollama
```

Optional overrides:

```sh
OLLAMA_OPENAI_BASE_URL=http://127.0.0.1:11434/v1 \
OLLAMA_MODEL=qwen2.5-coder:3b \
OLLAMA_NUM_CTX=4096 \
HERMES_MAX_TOKENS=128 \
scripts/configure-local-oss-models.sh ollama
```

Use `qwen2.5-coder:3b` for direct local task scripts and the default Hermes
profile when speed matters. The helper disables Hermes compression by default
for this local-smoke profile because the auxiliary compression model also needs
a large context window. Re-enable it only after the selected local model
responds quickly:

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

## 24/7 Local Operations

For long-running local business operations, keep Azure disabled and supervise
only local services. The local ops runbook installs per-user LaunchAgents for
Ollama and periodic OS1 health checks without `sudo`:

```sh
scripts/install-local-ops-launchd.sh
scripts/install-local-ops-launchd.sh --apply
```

If `Ollama.app` is already keeping the model server alive, use
`scripts/install-local-ops-launchd.sh --health-only --apply` so OS1 monitors
the stack without starting a second `ollama serve`.

See [`docs/local-ops-24-7.md`](local-ops-24-7.md) for logs, restart commands,
model fallback, and production blockers.

Run the readiness and business-smoke gates before treating the Mac as ready for
live local operations:

```sh
scripts/os1-production-readiness.sh --local
scripts/os1-business-smoke.sh --quick
```

For limited internal disk space, keep build outputs disposable and move large
model caches to an external SSD. See [`docs/local-storage.md`](local-storage.md)
and run:

```sh
scripts/os1-storage-report.sh
scripts/os1-clean-storage.sh --all
```

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
