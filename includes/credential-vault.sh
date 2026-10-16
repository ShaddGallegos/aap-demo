#!/usr/bin/env bash
# Shared Ansible Vault-backed credential storage for aap-demo.

if [ -n "${_AAP_DEMO_CREDENTIAL_VAULT_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_CREDENTIAL_VAULT_LOADED=1

_AAP_DEMO_VAULT_PATHS_EXPLICIT=false
if [ -n "${AAP_DEMO_VAULT_FILE+x}" ] || [ -n "${AAP_DEMO_VAULT_PASSWORD_FILE+x}" ]; then
  _AAP_DEMO_VAULT_PATHS_EXPLICIT=true
fi
AAP_DEMO_VAULT_FILE="${AAP_DEMO_VAULT_FILE:-$HOME/.ansible/conf/env-aap-demo.yml}"
AAP_DEMO_VAULT_PASSWORD_FILE="${AAP_DEMO_VAULT_PASSWORD_FILE:-$HOME/.ansible/conf/.vaultpass-aap-demo.txt}"
AAP_DEMO_LEGACY_VAULT_FILE="${AAP_DEMO_LEGACY_VAULT_FILE:-$HOME/.ansible/conf/env_microshift.yml}"
AAP_DEMO_LEGACY_VAULT_PASSWORD_FILE="${AAP_DEMO_LEGACY_VAULT_PASSWORD_FILE:-$HOME/.ansible/conf/.vaultpass_microshift.txt}"
AAP_DEMO_SECRET_PROMPT_DEVICE="${AAP_DEMO_SECRET_PROMPT_DEVICE:-/dev/tty}"
AAP_DEMO_SECRET_PROMPT_OUTPUT="${AAP_DEMO_SECRET_PROMPT_OUTPUT:-/dev/tty}"

_aap_demo_private_mode() {
  chmod 600 "$1"
}

_aap_demo_vault_require_tools() {
  if ! command -v ansible-vault >/dev/null 2>&1; then
    _err "ansible-vault is required for encrypted credential storage"
    return 1
  fi
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    _err "Python PyYAML is required for encrypted credential storage"
    return 1
  fi
}

_aap_demo_vault_migrate_legacy() {
  [ "$_AAP_DEMO_VAULT_PATHS_EXPLICIT" = false ] || return 0
  [ ! -e "$AAP_DEMO_VAULT_FILE" ] || return 0
  [ -s "$AAP_DEMO_LEGACY_VAULT_FILE" ] || return 0
  [ -s "$AAP_DEMO_LEGACY_VAULT_PASSWORD_FILE" ] || {
    _err "Legacy Vault exists without its password file: $AAP_DEMO_LEGACY_VAULT_FILE"
    return 1
  }

  local config_dir
  config_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"
  if [ -e "$AAP_DEMO_VAULT_PASSWORD_FILE" ]; then
    _err "Cannot migrate legacy Vault because $AAP_DEMO_VAULT_PASSWORD_FILE already exists"
    return 1
  fi

  mv "$AAP_DEMO_LEGACY_VAULT_FILE" "$AAP_DEMO_VAULT_FILE"
  mv "$AAP_DEMO_LEGACY_VAULT_PASSWORD_FILE" "$AAP_DEMO_VAULT_PASSWORD_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE"
  echo "✓ Migrated credentials to $AAP_DEMO_VAULT_FILE" >&2
}

_aap_demo_vault_ensure_password_file() {
  _aap_demo_vault_migrate_legacy || return 1
  local config_dir
  config_dir=$(dirname "$AAP_DEMO_VAULT_PASSWORD_FILE")
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"

  if [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ]; then
    _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE"
    return 0
  fi
  if [ "${QUIET:-false}" = "true" ]; then
    _err "Vault password file is missing: $AAP_DEMO_VAULT_PASSWORD_FILE"
    return 1
  fi
  if [ ! -r "$AAP_DEMO_SECRET_PROMPT_DEVICE" ]; then
    _err "Cannot securely prompt for the Ansible Vault password"
    return 1
  fi

  local password confirmation
  printf "Create Ansible Vault password: " >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  exec 9<"$AAP_DEMO_SECRET_PROMPT_DEVICE"
  IFS= read -r -s password <&9
  printf "\nConfirm Ansible Vault password: " >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  IFS= read -r -s confirmation <&9
  exec 9<&-
  printf "\n" >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"

  if [ -z "$password" ]; then
    _err "Vault password must not be empty"
    return 1
  fi
  if [ "$password" != "$confirmation" ]; then
    _err "Vault passwords do not match"
    return 1
  fi

  umask 077
  printf '%s\n' "$password" >"$AAP_DEMO_VAULT_PASSWORD_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE"
}

_aap_demo_vault_ensure_file() {
  _aap_demo_vault_require_tools || return 1
  _aap_demo_vault_ensure_password_file || return 1

  local vault_dir
  vault_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  mkdir -p "$vault_dir"
  chmod 700 "$vault_dir"

  if [ -s "$AAP_DEMO_VAULT_FILE" ]; then
    _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
    return 0
  fi

  local plain encrypted
  plain=$(mktemp "${vault_dir}/.env-aap-demo.plain.XXXXXX")
  encrypted=$(mktemp "${vault_dir}/.env-aap-demo.vault.XXXXXX")
  chmod 600 "$plain" "$encrypted"
  printf 'aap_demo: {}\n' >"$plain"
  if ! ansible-vault encrypt \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    --output "$encrypted" "$plain" >/dev/null; then
    rm -f "$plain" "$encrypted"
    _err "Failed to initialize encrypted credential file"
    return 1
  fi
  rm -f "$plain"
  mv "$encrypted" "$AAP_DEMO_VAULT_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
}

aap_demo_vault_get() {
  local key="$1"
  _aap_demo_vault_migrate_legacy || return 1
  [ -s "$AAP_DEMO_VAULT_FILE" ] || return 1
  [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || return 1
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE"

  ansible-vault view \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    "$AAP_DEMO_VAULT_FILE" 2>/dev/null |
    AAP_DEMO_SECRET_KEY="$key" python3 -c '
import os
import sys
import yaml

value = yaml.safe_load(sys.stdin) or {}
for part in os.environ["AAP_DEMO_SECRET_KEY"].split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
if not isinstance(value, str) or not value:
    raise SystemExit(1)
sys.stdout.write(value)
'
}

aap_demo_vault_set() {
  local key="$1"
  local value="$2"
  _aap_demo_vault_ensure_file || return 1

  local vault_dir plain encrypted
  vault_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  plain=$(mktemp "${vault_dir}/.env-aap-demo.plain.XXXXXX")
  encrypted=$(mktemp "${vault_dir}/.env-aap-demo.vault.XXXXXX")
  chmod 600 "$plain" "$encrypted"

  if ! ansible-vault view \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    "$AAP_DEMO_VAULT_FILE" >"$plain"; then
    rm -f "$plain" "$encrypted"
    _err "Unable to decrypt $AAP_DEMO_VAULT_FILE"
    return 1
  fi

  if ! AAP_DEMO_SECRET_KEY="$key" AAP_DEMO_SECRET_VALUE="$value" python3 - "$plain" <<'PY'
import os
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = yaml.safe_load(stream) or {}
target = data
parts = os.environ["AAP_DEMO_SECRET_KEY"].split(".")
for part in parts[:-1]:
    child = target.get(part)
    if not isinstance(child, dict):
        child = {}
        target[part] = child
    target = child
target[parts[-1]] = os.environ["AAP_DEMO_SECRET_VALUE"]
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(data, stream, default_flow_style=False, sort_keys=True)
PY
  then
    rm -f "$plain" "$encrypted"
    _err "Unable to update encrypted credentials"
    return 1
  fi

  if ! ansible-vault encrypt \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    --output "$encrypted" "$plain" >/dev/null; then
    rm -f "$plain" "$encrypted"
    _err "Unable to encrypt updated credentials"
    return 1
  fi
  rm -f "$plain"
  mv "$encrypted" "$AAP_DEMO_VAULT_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
}

aap_demo_vault_delete() {
  local key="$1"
  [ -s "$AAP_DEMO_VAULT_FILE" ] || return 0
  [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || return 1

  local vault_dir plain encrypted
  vault_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  plain=$(mktemp "${vault_dir}/.env-aap-demo.plain.XXXXXX")
  encrypted=$(mktemp "${vault_dir}/.env-aap-demo.vault.XXXXXX")
  chmod 600 "$plain" "$encrypted"

  if ! ansible-vault view \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    "$AAP_DEMO_VAULT_FILE" >"$plain"; then
    rm -f "$plain" "$encrypted"
    _err "Unable to decrypt $AAP_DEMO_VAULT_FILE"
    return 1
  fi

  AAP_DEMO_SECRET_KEY="$key" python3 - "$plain" <<'PY'
import os
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = yaml.safe_load(stream) or {}
target = data
parts = os.environ["AAP_DEMO_SECRET_KEY"].split(".")
for part in parts[:-1]:
    target = target.get(part)
    if not isinstance(target, dict):
        break
else:
    if isinstance(target, dict):
        target.pop(parts[-1], None)
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(data, stream, default_flow_style=False, sort_keys=True)
PY

  if ! ansible-vault encrypt \
    --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
    --output "$encrypted" "$plain" >/dev/null; then
    rm -f "$plain" "$encrypted"
    _err "Unable to encrypt updated credentials"
    return 1
  fi
  rm -f "$plain"
  mv "$encrypted" "$AAP_DEMO_VAULT_FILE"
  _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
}
