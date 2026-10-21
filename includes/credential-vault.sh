#!/usr/bin/env bash
# Shared Ansible Vault-backed credential storage for aap-demo.

if [ -n "${_AAP_DEMO_CREDENTIAL_VAULT_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_CREDENTIAL_VAULT_LOADED=1

_AAP_DEMO_VAULT_PATHS_EXPLICIT=false
if [ -n "${AAP_DEMO_VAULT_FILE+x}" ] || [ -n "${AAP_DEMO_VAULT_PASSWORD_FILE+x}" ]; then
  _AAP_DEMO_VAULT_PATHS_EXPLICIT=true
fi
AAP_DEMO_VAULT_FILE="${AAP_DEMO_VAULT_FILE:-$HOME/.ansible/conf/env.yml}"
AAP_DEMO_VAULT_PASSWORD_FILE="${AAP_DEMO_VAULT_PASSWORD_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
AAP_DEMO_PREVIOUS_VAULT_FILE="${AAP_DEMO_PREVIOUS_VAULT_FILE:-$HOME/.ansible/conf/env-aap-demo.yml}"
AAP_DEMO_PREVIOUS_VAULT_PASSWORD_FILE="${AAP_DEMO_PREVIOUS_VAULT_PASSWORD_FILE:-$HOME/.ansible/conf/.vaultpass-aap-demo.txt}"
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
  local config_dir source_file source_password plain_target plain_source merged encrypted
  local -a source_files source_passwords
  source_files=("$AAP_DEMO_PREVIOUS_VAULT_FILE" "$AAP_DEMO_LEGACY_VAULT_FILE")
  source_passwords=("$AAP_DEMO_PREVIOUS_VAULT_PASSWORD_FILE" "$AAP_DEMO_LEGACY_VAULT_PASSWORD_FILE")
  config_dir=$(dirname "$AAP_DEMO_VAULT_FILE")
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"

  if [ ! -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ]; then
    if [ -e "$AAP_DEMO_VAULT_FILE" ]; then
      _err "Vault exists without its password file: $AAP_DEMO_VAULT_FILE"
      return 1
    fi
    local index
    for index in "${!source_files[@]}"; do
      if [ -s "${source_files[$index]}" ] && [ -s "${source_passwords[$index]}" ]; then
        cp "${source_passwords[$index]}" "$AAP_DEMO_VAULT_PASSWORD_FILE"
        _aap_demo_private_mode "$AAP_DEMO_VAULT_PASSWORD_FILE"
        break
      fi
    done
  fi

  local index
  for index in "${!source_files[@]}"; do
    source_file="${source_files[$index]}"
    source_password="${source_passwords[$index]}"
    [ -s "$source_file" ] || continue
    [ -s "$source_password" ] || {
      _err "Legacy Vault exists without its password file: $source_file"
      return 1
    }
    [ -s "$AAP_DEMO_VAULT_PASSWORD_FILE" ] || return 0
    _aap_demo_vault_require_tools || return 1

    plain_target=$(mktemp "${config_dir}/.env.target.XXXXXX")
    plain_source=$(mktemp "${config_dir}/.env.source.XXXXXX")
    merged=$(mktemp "${config_dir}/.env.merged.XXXXXX")
    encrypted=$(mktemp "${config_dir}/.env.vault.XXXXXX")
    chmod 600 "$plain_target" "$plain_source" "$merged" "$encrypted"

    if [ -s "$AAP_DEMO_VAULT_FILE" ]; then
      if ! ansible-vault view --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
        "$AAP_DEMO_VAULT_FILE" >"$plain_target"; then
        rm -f "$plain_target" "$plain_source" "$merged" "$encrypted"
        _err "Unable to decrypt $AAP_DEMO_VAULT_FILE; legacy credentials were not changed"
        return 1
      fi
    else
      printf '{}\n' >"$plain_target"
    fi
    if ! ansible-vault view --vault-password-file "$source_password" \
      "$source_file" >"$plain_source"; then
      rm -f "$plain_target" "$plain_source" "$merged" "$encrypted"
      _err "Unable to decrypt legacy Vault: $source_file"
      return 1
    fi

    if ! python3 - "$plain_target" "$plain_source" >"$merged" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    target = yaml.safe_load(stream) or {}
with open(sys.argv[2], encoding="utf-8") as stream:
    source = yaml.safe_load(stream) or {}
if not isinstance(target, dict) or not isinstance(source, dict):
    raise SystemExit("Vault roots must be YAML mappings")

def merge_missing(destination, incoming):
    for key, value in incoming.items():
        if key not in destination:
            destination[key] = value
        elif isinstance(destination[key], dict) and isinstance(value, dict):
            merge_missing(destination[key], value)

legacy = source.get("aap_demo")
if isinstance(legacy, dict):
    current = target.setdefault("aap_demo", {})
    if not isinstance(current, dict):
        raise SystemExit("Existing aap_demo Vault entry must be a mapping")
    merge_missing(current, legacy)
yaml.safe_dump(target, sys.stdout, default_flow_style=False, sort_keys=True)
PY
    then
      rm -f "$plain_target" "$plain_source" "$merged" "$encrypted"
      _err "Unable to merge legacy Vault data"
      return 1
    fi

    if ! ansible-vault encrypt --vault-password-file "$AAP_DEMO_VAULT_PASSWORD_FILE" \
      --output "$encrypted" "$merged" >/dev/null; then
      rm -f "$plain_target" "$plain_source" "$merged" "$encrypted"
      _err "Unable to encrypt merged Vault data"
      return 1
    fi
    rm -f "$plain_target" "$plain_source" "$merged"
    mv "$encrypted" "$AAP_DEMO_VAULT_FILE"
    _aap_demo_private_mode "$AAP_DEMO_VAULT_FILE"
    rm -f "$source_file" "$source_password"
    echo "✓ Migrated credentials into $AAP_DEMO_VAULT_FILE" >&2
  done
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
  umask 077
  if ! python3 -c 'import secrets; print(secrets.token_urlsafe(48))' \
    >"$AAP_DEMO_VAULT_PASSWORD_FILE"; then
    rm -f "$AAP_DEMO_VAULT_PASSWORD_FILE"
    _err "Unable to generate the Ansible Vault password file"
    return 1
  fi
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

  if ! AAP_DEMO_SECRET_KEY="$key" python3 - "$plain" 3< <(printf '%s' "$value") <<'PY'
import os
import sys
import yaml

path = sys.argv[1]
with open(3, encoding="utf-8", closefd=False) as secret_stream:
    secret_value = secret_stream.read()
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
target[parts[-1]] = secret_value
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
