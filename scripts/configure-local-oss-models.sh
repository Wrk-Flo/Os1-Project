#!/usr/bin/env bash
set -euo pipefail

provider="${1:-ollama}"
case "$provider" in
  ollama)
    config_name="Ollama Local"
    legacy_names="ollama"
    base_url="${OLLAMA_OPENAI_BASE_URL:-http://127.0.0.1:11434/v1}"
    key_env="OLLAMA_API_KEY"
    model="${OLLAMA_MODEL:-}"
    model_env="OLLAMA_MODEL"
    probe_url="${base_url%/}/models"
    preferred_models="llama3.1:8b qwen2.5-coder:3b qwen2.5-coder:1.5b"
    ;;
  llama-cpp|llama_cpp|llamacpp)
    config_name="llama.cpp Local"
    legacy_names="llama_cpp,llama-cpp,llamacpp"
    base_url="${LLAMA_CPP_OPENAI_BASE_URL:-http://127.0.0.1:8080/v1}"
    key_env="LLAMA_CPP_API_KEY"
    model="${LLAMA_CPP_MODEL:-Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf}"
    model_env="LLAMA_CPP_MODEL"
    probe_url="${base_url%/}/models"
    preferred_models=""
    ;;
  lm-studio|lm_studio|lmstudio)
    config_name="LM Studio Local"
    legacy_names="lm_studio,lm-studio,lmstudio"
    base_url="${LM_STUDIO_OPENAI_BASE_URL:-http://127.0.0.1:1234/v1}"
    key_env="LM_STUDIO_API_KEY"
    model="${LM_STUDIO_MODEL:-}"
    model_env="LM_STUDIO_MODEL"
    probe_url="${base_url%/}/models"
    preferred_models=""
    ;;
  *)
    echo "usage: $0 [ollama|llama-cpp|lm-studio]" >&2
    exit 64
    ;;
esac

if ! probe_payload="$(curl -fsS --max-time 5 "$probe_url")"; then
  echo "Local provider probe failed: $probe_url" >&2
  echo "Start the provider first, then rerun this script." >&2
  exit 69
fi

if [[ -z "$model" ]]; then
  model="$(
    printf '%s' "$probe_payload" | python3 -c '
import json
import sys

preferred = sys.argv[1].split()

try:
    payload = json.load(sys.stdin)
    data = payload.get("data", []) if isinstance(payload, dict) else []
    ids = [
        item.get("id")
        for item in data
        if isinstance(item, dict) and isinstance(item.get("id"), str) and item.get("id").strip()
    ]
    for candidate in preferred:
        if candidate in ids:
            print(candidate)
            raise SystemExit
    for item in data:
        if isinstance(item, dict) and item.get("id"):
            print(item["id"])
            break
except Exception:
    pass
' "$preferred_models" || true
  )"
fi

if [[ -z "$model" ]]; then
  echo "No model was supplied or returned by: $probe_url" >&2
  echo "Load a local model first or set ${model_env}, then rerun this script." >&2
  exit 69
fi

context_length="${HERMES_CONTEXT_LENGTH:-}"
ollama_num_ctx="${OLLAMA_NUM_CTX:-}"
case "$provider:$model" in
  ollama:llama3.1:8b)
    context_length="${context_length:-65536}"
    ollama_num_ctx="${ollama_num_ctx:-4096}"
    ;;
  ollama:qwen2.5-coder:*)
    context_length="${context_length:-64000}"
    ollama_num_ctx="${ollama_num_ctx:-4096}"
    ;;
  ollama:*)
    context_length="${context_length:-64000}"
    ollama_num_ctx="${ollama_num_ctx:-4096}"
    ;;
  *)
    context_length="${context_length:-64000}"
    ;;
esac
max_tokens="${HERMES_MAX_TOKENS:-128}"
api_mode="${HERMES_API_MODE:-chat_completions}"
compression_enabled="${HERMES_COMPRESSION_ENABLED:-false}"

python3 - "$config_name" "$legacy_names" "$base_url" "$key_env" "$model" "$context_length" "$max_tokens" "$ollama_num_ctx" "$api_mode" "$compression_enabled" <<'PY'
import json
import os
import pathlib
import shutil
import sys

config_name, legacy_names_raw, base_url, key_env, model, context_length, max_tokens, ollama_num_ctx, api_mode, compression_enabled = sys.argv[1:11]
home = pathlib.Path.home()
hermes_dir = home / ".hermes"
env_path = hermes_dir / ".env"
config_path = hermes_dir / "config.yaml"
auth_path = hermes_dir / "auth.json"
backup_dir = hermes_dir / "backups"
backup_dir.mkdir(parents=True, exist_ok=True)
hermes_dir.mkdir(parents=True, exist_ok=True)

for path in (env_path, config_path, auth_path):
    if path.exists():
        shutil.copy2(path, backup_dir / f"{path.name}.local-oss.bak")

try:
    import yaml
except Exception:
    yaml = None

def positive_int(value, fallback):
    try:
        parsed = int(value)
    except Exception:
        return fallback
    return parsed if parsed > 0 else fallback

def bool_value(value):
    return str(value).strip().lower() in {"1", "true", "yes", "on"}

def read_env_lines():
    if not env_path.exists():
        return []
    return env_path.read_text().splitlines()

def upsert_env(lines, key, value):
    new_line = f'{key}="{value}"'
    for index, line in enumerate(lines):
        if line.lstrip().startswith(key + "="):
            changed = line != new_line
            lines[index] = new_line
            return changed
    lines.append(new_line)
    return True

env_lines = read_env_lines()
env_changed = upsert_env(env_lines, key_env, "local-no-api-key-required")
env_path.write_text("\n".join(env_lines) + "\n")
os.chmod(env_path, 0o600)

config = {}
if yaml is not None and config_path.exists():
    loaded = yaml.safe_load(config_path.read_text()) or {}
    if isinstance(loaded, dict):
        config = loaded

providers = config.get("custom_providers")
if not isinstance(providers, list):
    providers = []

legacy_names = {
    value.strip()
    for value in legacy_names_raw.split(",")
    if value.strip()
}
legacy_names.add(config_name)
normalized_base_url = base_url.rstrip("/")
deduped_providers = []
for item in providers:
    if not isinstance(item, dict):
        deduped_providers.append(item)
        continue
    item_name = str(item.get("name", "") or "").strip()
    item_base_url = str(item.get("base_url", "") or "").rstrip("/")
    if item_base_url == normalized_base_url and item_name in legacy_names and item_name != config_name:
        continue
    deduped_providers.append(item)
providers = deduped_providers

target_provider = {
    "name": config_name,
    "base_url": normalized_base_url,
    "key_env": key_env,
    "api_mode": api_mode,
    "model": model,
    "models": {
        model: {
            "context_length": positive_int(context_length, 64000),
        },
    },
}
provider_changed = False
for index, item in enumerate(providers):
    if isinstance(item, dict) and item.get("name") == config_name:
        provider_changed = item != target_provider
        providers[index] = target_provider
        break
else:
    providers.append(target_provider)
    provider_changed = True

config["custom_providers"] = providers
model_section = dict(config.get("model") if isinstance(config.get("model"), dict) else {})
model_section["provider"] = "custom"
model_section["default"] = model
model_section["base_url"] = normalized_base_url
model_section["api_mode"] = api_mode
model_section["context_length"] = positive_int(context_length, 64000)
model_section["max_tokens"] = positive_int(max_tokens, 128)
if ollama_num_ctx.strip():
    model_section["ollama_num_ctx"] = positive_int(ollama_num_ctx, 4096)
else:
    model_section.pop("ollama_num_ctx", None)
model_section.pop("api_key", None)
config["model"] = model_section

compression_section = dict(config.get("compression") if isinstance(config.get("compression"), dict) else {})
compression_section["enabled"] = bool_value(compression_enabled)
config["compression"] = compression_section

def write_minimal_yaml(path):
    # Fallback used only when PyYAML is unavailable. It keeps the helper local-only
    # instead of installing Python packages outside ~/.hermes.
    lines = [
        "custom_providers:",
        f"- name: {json.dumps(config_name)}",
        f"  base_url: {json.dumps(base_url.rstrip('/'))}",
        f"  key_env: {json.dumps(key_env)}",
        f"  api_mode: {json.dumps(api_mode)}",
        f"  model: {json.dumps(model)}",
        "  models:",
        f"    {json.dumps(model)}:",
        f"      context_length: {positive_int(context_length, 64000)}",
        "model:",
        "  provider: custom",
        f"  default: {json.dumps(model)}",
        f"  base_url: {json.dumps(base_url.rstrip('/'))}",
        f"  api_mode: {json.dumps(api_mode)}",
        f"  context_length: {positive_int(context_length, 64000)}",
        f"  max_tokens: {positive_int(max_tokens, 128)}",
    ]
    if ollama_num_ctx.strip():
        lines.append(f"  ollama_num_ctx: {positive_int(ollama_num_ctx, 4096)}")
    lines.extend([
        "compression:",
        f"  enabled: {str(bool_value(compression_enabled)).lower()}",
        "terminal:",
        "  backend: local",
    ])
    path.write_text("\n".join(lines) + "\n")

if yaml is not None:
    config_path.write_text(yaml.safe_dump(config, sort_keys=False, default_flow_style=False))
else:
    write_minimal_yaml(config_path)
os.chmod(config_path, 0o600)

auth = {}
if auth_path.exists():
    try:
        loaded_auth = json.loads(auth_path.read_text())
        if isinstance(loaded_auth, dict):
            auth = loaded_auth
    except Exception:
        auth = {}
auth["active_provider"] = config_name
auth_path.write_text(json.dumps(auth, indent=2) + "\n")
os.chmod(auth_path, 0o600)

print(json.dumps({
    "ok": True,
    "provider": config_name,
    "base_url": base_url.rstrip("/"),
    "model": model,
    "context_length": positive_int(context_length, 64000),
    "max_tokens": positive_int(max_tokens, 128),
    "ollama_num_ctx": positive_int(ollama_num_ctx, 4096) if ollama_num_ctx.strip() else None,
    "compression": "enabled" if bool_value(compression_enabled) else "disabled",
    "env": "set",
    "yaml_backend": "pyyaml" if yaml is not None else "minimal",
    "changed": {
        "env": bool(env_changed),
        "custom_provider": bool(provider_changed),
        "active_model": True,
        "auth_active_provider": True,
    },
}))
PY
