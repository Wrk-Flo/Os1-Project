# Local Model Lanes — OS1 / Eden on this Mac

This document maps what each local model is for, when it loads, and how OS1
scripts + Eden Shell + Hermes share the single Ollama instance on this 8 GB
M1 MacBook Air.

The architecture is **local-first by default, OpenRouter only as a fallback
when the local leg fails or times out**. Azure is paused. There is no
"cloud primary" lane right now.

## Hardware constraint

- Apple M1, 8 GB unified memory.
- Single Ollama daemon (`com.ollama.ollama`) at `http://127.0.0.1:11434`.
- `OLLAMA_MAX_LOADED_MODELS=1` — only one model fits warm at a time.
- `OLLAMA_KEEP_ALIVE=-1` — the loaded model stays in memory indefinitely.
- `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0` — Q8 KV cache
  halves attention memory cost.
- `OLLAMA_CONTEXT_LENGTH=65536` — every model loads with 64K cells, which
  satisfies Hermes Agent's hard 64K minimum.

These knobs are set by `scripts/configure-ollama-tunings.sh` and persisted
via `~/Library/LaunchAgents/com.os1.ollama-env.plist` (RunAtLoad on login).

Because `MAX_LOADED_MODELS=1`, switching models has a cost: ~3-7 s cold load
of the new model + the old model is evicted. So the lane design tries to
**keep one model loaded most of the time**.

## Models present (verified via `ollama list`, 2026-05-21)

| Model | Size | Role |
| --- | --- | --- |
| `llama3.2:1b` | 1.3 GB | Hermes default (fast chat, tool routing, small context turns) |
| `llama3.2:3b` | 2.0 GB | OS1 daily brief default (synthesis from real Gmail/Cal/Reminders/LinkedIn signal) |
| `qwen2.5-coder:3b` | 1.9 GB | Backup coding / code-aware classification |
| `qwen2.5-coder:1.5b` | 986 MB | Lightest fallback for the smoke-mode business-ops cycle |
| `qwen3:4b` | 2.5 GB | Optional reasoning batch (impractical for interactive — emits long reasoning traces) |
| `deepseek-r1:latest` / `deepseek-r1:8b` | 5.2 GB | Reasoning-only lane; not valid for Hermes tool-calling fallback because Ollama rejects tool calls for this model |
| `deepseek-coder:6.7b` | 3.8 GB | Heavier coding lane (Eden code automation, OS1 script reasoning) |
| `nomic-embed-text:latest` | 274 MB | Local embeddings (unlocks RAG/memory without OpenAI embedding cost) |
| `llama3:8b` | 4.7 GB | Legacy — historical default; do not pick unless explicitly needed |
| `glm-5:cloud` | — | Cloud stub; only used when the operator explicitly routes to GLM Cloud |

Total installed disk: ~21 GB across model weights. Only one is loaded into
memory at any time.

## Lane → model mapping

```
                              ┌──────────────────────┐
                              │   Ollama (loopback)  │
                              │  127.0.0.1:11434/v1  │
                              └──────────┬───────────┘
                                         │
       ┌─────────────────────────────────┼─────────────────────────────────┐
       │                                 │                                 │
┌──────┴──────┐                  ┌───────┴──────┐                  ┌───────┴──────┐
│  fast_lane  │                  │ reason_lane  │                  │  code_lane   │
│ llama3.2:1b │                  │ deepseek-r1  │                  │ qwen2.5-     │
│ (Hermes)    │                  │ :latest (8B) │                  │ coder:3b     │
└─────────────┘                  └──────────────┘                  └──────────────┘

┌─────────────┐                  ┌──────────────┐                  ┌──────────────┐
│ memory_lane │                  │  brief_lane  │                  │ embed_lane   │
│ llama3.2:1b │                  │ llama3.2:3b  │                  │ nomic-embed- │
│ (summaries) │                  │ (OS1 brief)  │                  │ text         │
└─────────────┘                  └──────────────┘                  └──────────────┘

                              ┌──────────────────────┐
                              │ OpenRouter (fallback)│
                              │ z-ai/glm-4.5-air:free│
                              └──────────────────────┘
```

## Who uses what

| Consumer | Primary model | Falls back to | Wrapper |
| --- | --- | --- | --- |
| Hermes Agent (interactive CLI / Telegram / cron) | `llama3.2:1b` | `llama3.2:3b` via Hermes `fallback_model` config | native Hermes provider; fallback must support tools |
| OS1 daily real-business-brief | `llama3.2:3b` (`OS1_FALLBACK_PRIMARY_MODEL` default) | OpenRouter `z-ai/glm-4.5-air:free` after `OS1_FALLBACK_PRIMARY_TIMEOUT=60s` | `scripts/llm-task-with-fallback.sh` |
| OS1 hourly business-ops smoke | `qwen2.5-coder:1.5b` (smallest fast model for the canned `daily operations brief` smoke prompt) | same OpenRouter fallback if needed | `scripts/ollama-task.sh` |
| Eden Shell `callFoundryModel` | `qwen2.5-coder:3b` (Eden's PROJECT_STATE default `OLLAMA_MODEL`) | `llama_cpp` → `openai` per Eden's `EDEN_MODEL_FALLBACK_CHAIN=ollama,llama_cpp,openai,azure` (Azure currently disabled) | Eden backend |
| Eden voice agent (ElevenLabs Chief of Staff) | **`claude-haiku-4-5` via ElevenLabs** — NOT local. Cloud for voice latency. Local Ollama is reserved for tool-side capability calls only. | `claude-sonnet-4-5` → `gemini-3.1-flash-lite-preview` via ElevenLabs backup cascade | ElevenLabs Conversational AI |

### Why the voice agent is cloud, not local

The recommendation document this layout came from explicitly calls this out:
voice-first applications are latency-sensitive. A 3-7 s cold model load on
an 8 GB CPU-only Mac is fine for a daily batch brief, but it's a death
sentence for conversational voice. ElevenLabs handles the chat LLM on
their managed infrastructure (paying ~$0.001/turn with Haiku). The local
Ollama gets called only for OS1's batch / read-only capability handlers,
not for the voice agent's reasoning.

## When OpenRouter (the only paid cloud lane right now) fires

`scripts/llm-task-with-fallback.sh` fires OpenRouter when ALL of:

1. The primary local Ollama call exceeded `OS1_FALLBACK_PRIMARY_TIMEOUT`
   (default 60 s), OR returned a non-zero exit, OR returned empty output.
2. `OS1_FALLBACK_DISABLE` is not set.
3. `OPENROUTER_API_KEY` env or `~/.openrouter-key` file is present.

The wrapper logs to stderr which leg ran when `OS1_LLM_DEBUG=1`.

## Costs

- Local: $0 incremental. Disk: ~21 GB across all pulled models.
- OpenRouter: ~$0/turn on the `z-ai/glm-4.5-air:free` model when it's not
  rate-limited; ~$0.0005-0.001/turn on cheap paid models if we switch.
- ElevenLabs: voice + Haiku LLM, ~$0.001-0.01/turn depending on length.
  This is the only meaningful ongoing cost.

## How to change a lane

- **Switch the brief model**: set `OLLAMA_MODEL` in
  `~/Library/LaunchAgents/com.os1.local.real-business-brief.plist`
  `EnvironmentVariables`, then `launchctl bootout` + `launchctl bootstrap`.
- **Switch Hermes default**: edit `model.default` in `~/.hermes/config.yaml`
  and `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway`.
- **Switch Hermes fallback**: edit `fallback_model` in
  `~/.hermes/config.yaml`; use a tool-capable model such as `llama3.2:3b`.
  Do not use `deepseek-r1:*` as Hermes primary/fallback while Hermes tools are
  enabled, because Ollama returns HTTP 400 for tool calls on that family.
- **Switch Eden's `callFoundryModel` default**: set `OLLAMA_MODEL` in
  `~/Library/LaunchAgents/biz.wrkflo.eden-os-voice-shell.plist`
  `EnvironmentVariables`, then `npm run install:launchd` from the Eden
  repo (it regenerates the plist + restarts).
- **Switch the voice agent's LLM**: PATCH the ElevenLabs agent's
  `conversation_config.agent.prompt.llm` field via the ElevenLabs API
  (key at `~/.elevenlabs/api_key`), OR change the value in
  `scripts/configure-elevenlabs-agent.mjs` and run
  `npm run configure:elevenlabs` from the Eden repo.

## Adding a new lane

To add a new lane (e.g. a dedicated "tool_calling" lane on a different
model):

1. `ollama pull <model>` and verify it's in `ollama list`.
2. Add it to this document's table.
3. Wire whichever consumer needs it via the env-knob path above (don't
   hard-code model names in scripts).
4. Run `scripts/configure-ollama-tunings.sh --preload <model>` to
   pre-warm it (subject to the `MAX_LOADED_MODELS=1` constraint — the
   currently-loaded model gets evicted).

## What's NOT here (and why)

- **LM Studio**: optional GUI; not installed because the operator works in
  terminals and Ollama already provides the OpenAI-compatible endpoint.
  If visual model comparison becomes useful later, add it then.
- **vLLM**: requires an NVIDIA GPU; this Mac has none. Skip.
- **MLX-LM**: a viable upgrade path on Apple Silicon (Metal-native, often
  faster than Ollama's llama.cpp backend). Defer until Ollama tuning
  hits a real ceiling for a specific lane.
- **Hugging Face Pro**: not paid for. Free tier covers downloads. The
  `HF_TOKEN` is saved at `~/.huggingface_token` for gated models when
  needed.
- **Cloud OpenAI / Anthropic direct keys**: not wired into OS1 itself.
  Eden's voice agent is the only path that pays a frontier provider, and
  it routes through ElevenLabs which handles billing.

## References

- `scripts/configure-ollama-tunings.sh` — applies the 6 env knobs +
  installs the persistence LaunchAgent.
- `scripts/llm-task-with-fallback.sh` — the Ollama-first / OpenRouter-
  fallback wrapper used by the daily brief.
- `scripts/ollama-task.sh` — the local-only LLM caller (no fallback).
- `scripts/llm-task-openrouter.sh` — the OpenRouter-only caller (used
  as the fallback leg).
- `~/Library/LaunchAgents/com.os1.ollama-env.plist` — persistence layer
  for the Ollama tunings.
- `~/.hermes/config.yaml` — Hermes default + fallback model selection.
- `~/Library/LaunchAgents/biz.wrkflo.eden-os-voice-shell.plist` — Eden's
  `EDEN_MODEL_FALLBACK_CHAIN` and `OLLAMA_MODEL`.
