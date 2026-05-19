#!/bin/bash

set -euo pipefail

RESOURCE_GROUP="${OS1_AZURE_RESOURCE_GROUP:-os1-project-rg}"
VM_NAME="${OS1_AZURE_VM_NAME:-os1-hermes-dev}"
NSG_NAME="${OS1_AZURE_NSG_NAME:-${VM_NAME}NSG}"
SSH_RULE_NAME="${OS1_AZURE_SSH_RULE_NAME:-AllowSSHFromMosesMac}"
SSH_RULE_PRIORITY="${OS1_AZURE_SSH_RULE_PRIORITY:-1000}"
SSH_USER="${OS1_AZURE_SSH_USER:-hermes}"
SSH_KEY="${OS1_AZURE_SSH_KEY:-$HOME/.ssh/id_ed25519}"
DRY_RUN="${OS1_AZURE_DRY_RUN:-0}"
ALLOW_MUTATIONS="${OS1_AZURE_ALLOW_MUTATIONS:-0}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  preflight              Show Azure account/subscription readiness without mutations.
  local-fallback         Print local OSS fallback commands without contacting Azure.
  status                 Show VM power state, public IP, and SSH allowlist rule.
  refresh-ssh-allowlist  Set the SSH NSG rule source to this Mac's current public IP.
  start                  Start the standalone OS1 Azure VM.
  stop                   Stop the VM but keep it allocated.
  deallocate             Stop and deallocate the VM to reduce compute cost.
  restart                Restart the VM.
  ssh-smoke              Test non-interactive SSH, python3, and Hermes CLI visibility.
  tools-status           Check Node, Hermes, configured MCP servers, and gateway state.

Environment overrides:
  OS1_AZURE_RESOURCE_GROUP   Default: os1-project-rg
  OS1_AZURE_VM_NAME          Default: os1-hermes-dev
  OS1_AZURE_NSG_NAME         Default: <vm-name>NSG
  OS1_AZURE_SSH_RULE_NAME    Default: AllowSSHFromMosesMac
  OS1_AZURE_OPERATOR_CIDR    Optional explicit source CIDR for refresh-ssh-allowlist
  OS1_AZURE_SSH_USER         Default: hermes
  OS1_AZURE_SSH_KEY          Default: ~/.ssh/id_ed25519
  OS1_AZURE_DRY_RUN=1        Print Azure mutations instead of running them
  OS1_AZURE_ALLOW_MUTATIONS=1 Required for Azure write commands. Default: 0
  OS1_AZURE_VERBOSE=1        Include extra Azure identifiers in read-only output
EOF
}

print_local_fallback() {
    cat <<'EOF'
Local fallback (no Azure, Key Vault, or VM mutation):
  ollama serve
  ollama pull qwen2.5-coder:3b
  scripts/configure-local-oss-models.sh ollama

For llama.cpp, run an OpenAI-compatible server on 127.0.0.1:8080, then:
  scripts/configure-local-oss-models.sh llama-cpp

See docs/local-oss-runtime.md.
EOF
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: missing required command: $command_name" >&2
        exit 1
    fi
}

require_az() {
    local output

    if ! command -v az >/dev/null 2>&1; then
        echo "error: missing required command: az" >&2
        print_local_fallback >&2
        exit 1
    fi

    if ! output="$(az account show --only-show-errors 2>&1 >/dev/null)"; then
        echo "error: Azure CLI is not logged in; run 'az login' first." >&2
        if contains_disabled_azure_error "$output"; then
            echo "error: Azure account reports a disabled/read-only subscription." >&2
        fi
        print_local_fallback >&2
        exit 1
    fi
}

az_tsv() {
    az "$@" --only-show-errors -o tsv
}

subscription_state() {
    az_tsv account show --query "state"
}

contains_disabled_azure_error() {
    grep -Eiq 'ReadOnlyDisabledSubscription|DisabledSubscription|SubscriptionDisabled|subscription[^[:alnum:]]+is[^[:alnum:]]+disabled|read[ -]?only|PastDue|billing' <<<"$1"
}

ensure_azure_mutation_enabled() {
    local state

    if [[ "$ALLOW_MUTATIONS" != "1" ]]; then
        echo "error: Azure mutations are disabled by default for the current Azure-disabled posture." >&2
        echo "Set OS1_AZURE_ALLOW_MUTATIONS=1 only after 'scripts/azure/os1-vm.sh preflight' reports a healthy subscription." >&2
        print_local_fallback >&2
        exit 1
    fi

    state="$(subscription_state 2>/dev/null || true)"
    if [[ -z "$state" || "$state" != "Enabled" ]]; then
        echo "error: refusing Azure mutation because subscription state is '${state:-unknown}'." >&2
        print_local_fallback >&2
        exit 1
    fi
}

ensure_azure_mutation_or_dry_run() {
    if [[ "$DRY_RUN" != "1" ]]; then
        ensure_azure_mutation_enabled
    fi
}

run_az_mutation() {
    local output

    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'dry-run: az'
        printf ' %q' "$@"
        printf '\n'
        return
    fi

    ensure_azure_mutation_enabled

    if ! output="$(az "$@" --only-show-errors 2>&1 >/dev/null)"; then
        if contains_disabled_azure_error "$output"; then
            echo "error: Azure subscription is disabled/read-only; refusing Azure mutation." >&2
            print_local_fallback >&2
        fi
        echo "$output" >&2
        exit 1
    fi
}

public_ip() {
    az_tsv vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --show-details \
        --query "publicIps"
}

power_state() {
    az_tsv vm get-instance-view \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]"
}

provisioning_state() {
    az_tsv vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "provisioningState"
}

current_operator_cidr() {
    local value

    value="${OS1_AZURE_OPERATOR_CIDR:-}"
    if [[ -z "$value" ]]; then
        require_command curl
        value="$(curl -fsS --max-time 8 https://api.ipify.org)"
    fi

    if [[ -z "$value" ]]; then
        echo "error: unable to determine current public IP; set OS1_AZURE_OPERATOR_CIDR." >&2
        exit 1
    fi

    if [[ "$value" != */* ]]; then
        if [[ "$value" == *:* ]]; then
            value="$value/128"
        else
            value="$value/32"
        fi
    fi

    printf '%s\n' "$value"
}

show_status() {
    local ip rule_source state

    state="$(power_state 2>/dev/null || true)"
    ip="$(public_ip 2>/dev/null || true)"

    echo "VM: $VM_NAME"
    echo "Resource group: $RESOURCE_GROUP"
    echo "Power state: ${state:-unknown}"
    echo "Public IP: ${ip:-none}"

    rule_source="$(az_tsv network nsg rule show \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "$SSH_RULE_NAME" \
        --query "sourceAddressPrefix" 2>/dev/null || true)"

    echo "SSH NSG: $NSG_NAME"
    echo "SSH rule: $SSH_RULE_NAME"
    echo "SSH source: ${rule_source:-missing}"

    if [[ -z "$state" && -z "$ip" ]]; then
        echo "Azure status: unavailable; run 'scripts/azure/os1-vm.sh preflight' and use local fallback while Azure is disabled."
    fi
}

show_preflight() {
    local ip state subscription_id subscription_name subscription_state vm_id vm_provisioning

    subscription_id="$(az_tsv account show --query "id")"
    subscription_name="$(az_tsv account show --query "name")"
    subscription_state="$(az_tsv account show --query "state")"

    echo "Azure CLI: logged in"
    echo "Subscription: ${subscription_name:-unknown}"
    if [[ "${OS1_AZURE_VERBOSE:-0}" == "1" ]]; then
        echo "Subscription ID: ${subscription_id:-unknown}"
    fi
    echo "Subscription state: ${subscription_state:-unknown}"
    if [[ "$subscription_state" != "Enabled" ]]; then
        echo "Write readiness: blocked; subscription must be Enabled before start/stop/allowlist commands."
        print_local_fallback
    else
        echo "Write readiness: account reports Enabled; write commands may still fail if ARM marks the subscription read-only."
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "Mutation guard: dry-run; Azure mutations will be printed, not run."
    elif [[ "$ALLOW_MUTATIONS" == "1" ]]; then
        echo "Mutation guard: opt-in enabled; write commands still require subscription state Enabled."
    else
        echo "Mutation guard: active; set OS1_AZURE_ALLOW_MUTATIONS=1 only when Azure writes are intentionally restored."
    fi

    vm_id="$(az_tsv vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "id" 2>/dev/null || true)"
    if [[ -n "$vm_id" ]]; then
        echo "VM lookup: found"
        vm_provisioning="$(provisioning_state 2>/dev/null || true)"
        state="$(power_state 2>/dev/null || true)"
        ip="$(public_ip 2>/dev/null || true)"
        echo "VM provisioning state: ${vm_provisioning:-unknown}"
        echo "VM power state: ${state:-unknown}"
        echo "VM public IP: ${ip:-none}"
        if [[ "$vm_provisioning" == "Failed" ]]; then
            echo "VM readiness: provisioning failed; repair the VM state before relying on SSH or secret sync."
        fi
    else
        echo "VM lookup: missing $RESOURCE_GROUP/$VM_NAME"
    fi
}

refresh_ssh_allowlist() {
    local cidr existing_rule

    ensure_azure_mutation_or_dry_run

    cidr="$(current_operator_cidr)"
    existing_rule="$(az_tsv network nsg rule show \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "$SSH_RULE_NAME" \
        --query "name" 2>/dev/null || true)"

    if [[ -n "$existing_rule" ]]; then
        run_az_mutation network nsg rule update \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "$SSH_RULE_NAME" \
            --source-address-prefixes "$cidr" \
            --destination-port-ranges 22 \
            --protocol Tcp \
            --access Allow \
            --direction Inbound
    else
        run_az_mutation network nsg rule create \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "$SSH_RULE_NAME" \
            --priority "$SSH_RULE_PRIORITY" \
            --source-address-prefixes "$cidr" \
            --destination-port-ranges 22 \
            --protocol Tcp \
            --access Allow \
            --direction Inbound \
            --description "OS1 SSH access from the current operator IP"
    fi

    echo "SSH allowlist source set to $cidr on $NSG_NAME/$SSH_RULE_NAME"
}

ssh_smoke() {
    local ip ssh_target

    require_command ssh
    ip="$(public_ip)"
    if [[ -z "$ip" ]]; then
        echo "error: VM has no public IP." >&2
        exit 1
    fi

    ssh_target="$SSH_USER@$ip"
    ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new \
        "$ssh_target" \
        'set -e; export PATH="$HOME/.local/bin:$HOME/.hermes/hermes-agent/venv/bin:$PATH"; python3 --version; if command -v hermes >/dev/null 2>&1; then hermes version | head -1; else echo "hermes CLI: missing"; exit 1; fi'
}

tools_status() {
    local ip ssh_target

    require_command ssh
    ip="$(public_ip)"
    if [[ -z "$ip" ]]; then
        echo "error: VM has no public IP." >&2
        exit 1
    fi

    ssh_target="$SSH_USER@$ip"
    ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new \
        "$ssh_target" \
        'bash -s' <<'REMOTE'
set -e
export PATH="$HOME/.local/bin:$HOME/.hermes/hermes-agent/venv/bin:$HOME/.hermes/node/bin:$PATH"

printf 'host='
hostname

printf 'python='
python3 --version

printf 'hermes='
if command -v hermes >/dev/null 2>&1; then
    hermes version | head -1
else
    echo 'missing'
fi

printf 'node='
if command -v node >/dev/null 2>&1; then
    node --version
else
    echo 'missing'
fi

printf 'npm='
if command -v npm >/dev/null 2>&1; then
    npm --version
else
    echo 'missing'
fi

printf 'npx='
if command -v npx >/dev/null 2>&1; then
    npx --version
else
    echo 'missing'
fi

python3 - <<'PY'
import pathlib
import json
import sys

config = pathlib.Path.home() / ".hermes" / "config.yaml"
env = pathlib.Path.home() / ".hermes" / ".env"
state = pathlib.Path.home() / ".hermes" / "gateway_state.json"
print(f"config_exists={str(config.exists()).lower()}")
print(f"env_exists={str(env.exists()).lower()}")

env_values = {}
if env.exists():
    for line in env.read_text(errors="ignore").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        env_values[key.strip()] = value.strip().strip("\"'")

print("telegram_bot_token=" + ("set" if env_values.get("TELEGRAM_BOT_TOKEN") else "missing"))
print("telegram_allowed_users=" + ("set" if env_values.get("TELEGRAM_ALLOWED_USERS") else "missing"))
print(f"gateway_state_exists={str(state.exists()).lower()}")
if state.exists():
    try:
        loaded_state = json.loads(state.read_text(errors="ignore") or "{}")
        platforms = loaded_state.get("platforms") if isinstance(loaded_state, dict) else None
        telegram = platforms.get("telegram") if isinstance(platforms, dict) else None
        if isinstance(telegram, dict):
            print("telegram_platform_state=" + str(telegram.get("state", "missing")))
            error_code = telegram.get("error_code")
            print("telegram_error_code=" + (str(error_code) if error_code else "missing"))
            print("telegram_error_message=" + ("set" if telegram.get("error_message") else "missing"))
        else:
            print("telegram_platform_state=missing")
    except Exception as exc:
        print(f"gateway_state_parse=failed:{exc.__class__.__name__}")

try:
    import yaml
except Exception as exc:
    print(f"pyyaml=missing:{exc.__class__.__name__}")
    sys.exit(0)

print("pyyaml=set")

if not config.exists():
    print("mcp_servers=none")
    sys.exit(0)

loaded = yaml.safe_load(config.read_text()) or {}
servers = loaded.get("mcp_servers") if isinstance(loaded, dict) else None
if isinstance(servers, dict) and servers:
    print("mcp_servers=" + ",".join(sorted(str(key) for key in servers.keys())))
else:
    print("mcp_servers=none")
PY

echo 'gateway_status:'
if command -v hermes >/dev/null 2>&1; then
    hermes gateway status 2>&1 | sed -n '1,10p' || true
else
    echo 'Hermes CLI missing; gateway status unavailable.'
fi
REMOTE
}

main() {
    local command="${1:-status}"

    case "$command" in
        help|-h|--help)
            usage
            ;;
        preflight)
            require_az
            show_preflight
            ;;
        local-fallback)
            print_local_fallback
            ;;
        status)
            require_az
            show_status
            ;;
        refresh-ssh-allowlist)
            require_az
            refresh_ssh_allowlist
            ;;
        start|stop|deallocate|restart)
            require_az
            run_az_mutation vm "$command" \
                --resource-group "$RESOURCE_GROUP" \
                --name "$VM_NAME"
            echo "$command requested for $RESOURCE_GROUP/$VM_NAME"
            ;;
        ssh-smoke)
            require_az
            ssh_smoke
            ;;
        tools-status)
            require_az
            tools_status
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
