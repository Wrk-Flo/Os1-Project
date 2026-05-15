#!/usr/bin/env python3
"""Sync selected Azure Key Vault secrets to the OS1 Hermes VM.

The script never prints secret values. Secrets are fetched with `az`, sent to
the VM over SSH stdin, and reported only as set/missing.
"""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import time
from dataclasses import dataclass


DEFAULT_VAULT = "wrkflo-kv"
DEFAULT_HOST = "os1-hermes-dev"
DEFAULT_OPENAI_SECRET = "openai-api-key"
DEFAULT_COMPOSIO_SECRET = "composio-api-key"
DEFAULT_TELEGRAM_RESOURCE_GROUP = "wrkflo"
DEFAULT_TELEGRAM_CONTAINER_APP = "wrkflo-orchestrator"
DEFAULT_TELEGRAM_SECRET = "telegram-bot-token"


@dataclass(frozen=True)
class SecretRef:
    label: str
    vault: str
    name: str


REMOTE_SCRIPT = r"""
import base64
import json
import os
import pathlib
import shutil
import subprocess
import sys

payload = json.load(sys.stdin)

openai_key = base64.b64decode(payload["openai_api_key_b64"]).decode()
composio_key = base64.b64decode(payload["composio_api_key_b64"]).decode()
telegram_token_b64 = payload.get("telegram_bot_token_b64") or ""
telegram_token = base64.b64decode(telegram_token_b64).decode() if telegram_token_b64 else ""
activate_model = payload.get("activate_model") or "gpt-5.4-mini"

home = pathlib.Path.home()
hermes_dir = home / ".hermes"
env_path = hermes_dir / ".env"
config_path = hermes_dir / "config.yaml"
auth_path = hermes_dir / "auth.json"
backup_dir = hermes_dir / "backups"
backup_dir.mkdir(parents=True, exist_ok=True)

for path in (env_path, config_path, auth_path):
    if path.exists():
        shutil.copy2(path, backup_dir / f"{path.name}.os1-sync.bak")

try:
    import yaml
except Exception:
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet", "--user", "pyyaml"],
        check=True,
        timeout=60,
    )
    import yaml

hermes_dir.mkdir(parents=True, exist_ok=True)


def read_env():
    if not env_path.exists():
        return []
    return env_path.read_text().splitlines()


def upsert_env(lines, key, value):
    safe = value.replace("\\", "\\\\").replace('"', '\\"')
    new_line = f'{key}="{safe}"'
    for index, line in enumerate(lines):
        if line.lstrip().startswith(key + "="):
            changed = line != new_line
            lines[index] = new_line
            return changed
    lines.append(new_line)
    return True


lines = read_env()
openai_changed = upsert_env(lines, "OPENAI_API_KEY", openai_key)
telegram_changed = False
if telegram_token:
    telegram_changed = upsert_env(lines, "TELEGRAM_BOT_TOKEN", telegram_token)
env_path.write_text("\n".join(lines) + "\n")
os.chmod(env_path, 0o600)

config = {}
if config_path.exists():
    loaded = yaml.safe_load(config_path.read_text()) or {}
    if isinstance(loaded, dict):
        config = loaded

custom_provider = {
    "name": "openai",
    "base_url": "https://api.openai.com/v1",
    "key_env": "OPENAI_API_KEY",
}
providers = config.get("custom_providers")
if not isinstance(providers, list):
    providers = []

provider_changed = False
for index, item in enumerate(providers):
    if isinstance(item, dict) and item.get("name") == "openai":
        provider_changed = item != custom_provider
        providers[index] = custom_provider
        break
else:
    providers.append(custom_provider)
    provider_changed = True

config["custom_providers"] = providers

model = dict(config.get("model") if isinstance(config.get("model"), dict) else {})
model["provider"] = "openai"
model["default"] = activate_model
model["base_url"] = "https://api.openai.com/v1"
model.pop("api_key", None)
model.pop("api_mode", None)
config["model"] = model

mcp_servers = config.get("mcp_servers")
if not isinstance(mcp_servers, dict):
    mcp_servers = {}

previous_composio = mcp_servers.get("composio")
target_composio = {
    "url": "https://connect.composio.dev/mcp",
    "headers": {"x-consumer-api-key": composio_key},
}
mcp_servers["composio"] = target_composio
config["mcp_servers"] = mcp_servers

config_path.write_text(yaml.safe_dump(config, sort_keys=False, default_flow_style=False))
os.chmod(config_path, 0o600)

auth = {}
if auth_path.exists():
    try:
        loaded_auth = json.loads(auth_path.read_text())
        if isinstance(loaded_auth, dict):
            auth = loaded_auth
    except Exception:
        auth = {}
auth["active_provider"] = "openai"
auth_path.write_text(json.dumps(auth, indent=2) + "\n")
os.chmod(auth_path, 0o600)

print(json.dumps({
    "success": True,
    "openai_env": "set",
    "openai_provider": "set",
    "active_model": activate_model,
    "composio_mcp": "set",
    "telegram_env": "set" if telegram_token else "skipped",
    "backups": "set",
    "changed": {
        "openai_env": bool(openai_changed),
        "telegram_env": bool(telegram_changed),
        "openai_provider": bool(provider_changed),
        "composio_mcp": previous_composio != target_composio,
    },
}))
"""


def run(command: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def fetch_secret(ref: SecretRef) -> str:
    last_error = ""
    for attempt in range(1, 4):
        result = run([
            "az",
            "keyvault",
            "secret",
            "show",
            "--vault-name",
            ref.vault,
            "--name",
            ref.name,
            "--query",
            "value",
            "-o",
            "tsv",
        ])
        value = result.stdout.rstrip("\n")
        if result.returncode == 0 and value:
            return value
        detail = result.stderr.strip().splitlines()[:2]
        last_error = "; ".join(detail) or "empty secret response"
        if attempt < 3:
            time.sleep(2 * attempt)

    raise RuntimeError(f"{ref.label}=missing ({last_error})")


def fetch_containerapp_secret(resource_group: str, app_name: str, secret_name: str) -> str:
    last_error = ""
    for attempt in range(1, 4):
        result = run([
            "az",
            "containerapp",
            "secret",
            "show",
            "--resource-group",
            resource_group,
            "--name",
            app_name,
            "--secret-name",
            secret_name,
            "--query",
            "value",
            "-o",
            "tsv",
        ])
        value = result.stdout.rstrip("\n")
        if result.returncode == 0 and value:
            return value
        detail = result.stderr.strip().splitlines()[:2]
        last_error = "; ".join(detail) or "empty secret response"
        if attempt < 3:
            time.sleep(2 * attempt)

    raise RuntimeError(f"telegram_bot_token=missing ({last_error})")


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync OS1 VM credentials from Azure Key Vault.")
    parser.add_argument("--vault", default=DEFAULT_VAULT)
    parser.add_argument("--openai-vault", default=None)
    parser.add_argument("--composio-vault", default=None)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--openai-secret", default=DEFAULT_OPENAI_SECRET)
    parser.add_argument("--composio-secret", default=DEFAULT_COMPOSIO_SECRET)
    parser.add_argument("--telegram-resource-group", default=DEFAULT_TELEGRAM_RESOURCE_GROUP)
    parser.add_argument("--telegram-container-app", default=DEFAULT_TELEGRAM_CONTAINER_APP)
    parser.add_argument("--telegram-secret", default=DEFAULT_TELEGRAM_SECRET)
    parser.add_argument("--skip-telegram", action="store_true")
    parser.add_argument("--activate-model", default="gpt-5.4-mini")
    parser.add_argument("--dry-run", action="store_true", help="Check secret availability without writing to the VM.")
    args = parser.parse_args()

    refs = [
        SecretRef("openai_api_key", args.openai_vault or args.vault, args.openai_secret),
        SecretRef("composio_api_key", args.composio_vault or args.vault, args.composio_secret),
    ]

    try:
        secrets = {ref.label: fetch_secret(ref) for ref in refs}
        if not args.skip_telegram:
            secrets["telegram_bot_token"] = fetch_containerapp_secret(
                args.telegram_resource_group,
                args.telegram_container_app,
                args.telegram_secret,
            )
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print("openai_api_key=set")
    print("composio_api_key=set")
    print(f"telegram_bot_token={'skipped' if args.skip_telegram else 'set'}")
    if args.dry_run:
        print("dry_run=true")
        print("vm_write=skipped")
        return 0

    payload = {
        "openai_api_key_b64": base64.b64encode(secrets["openai_api_key"].encode()).decode(),
        "composio_api_key_b64": base64.b64encode(secrets["composio_api_key"].encode()).decode(),
        "telegram_bot_token_b64": base64.b64encode(secrets.get("telegram_bot_token", "").encode()).decode(),
        "activate_model": args.activate_model,
    }
    remote_code = REMOTE_SCRIPT.replace(
        "payload = json.load(sys.stdin)",
        f"payload = {json.dumps(payload)}",
        1,
    )
    ssh = run(["ssh", args.host, "python3", "-"], input_text=remote_code)
    if ssh.returncode != 0:
        print("error: vm_write=failed", file=sys.stderr)
        if ssh.stderr.strip():
            print(ssh.stderr.strip(), file=sys.stderr)
        return ssh.returncode

    try:
        result = json.loads(ssh.stdout)
    except json.JSONDecodeError:
        print("error: vm_write returned invalid status", file=sys.stderr)
        return 1

    for key in ("openai_env", "openai_provider", "active_model", "composio_mcp", "telegram_env", "backups"):
        print(f"{key}={result.get(key, 'missing')}")
    print("vm_write=set")
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    raise SystemExit(main())
