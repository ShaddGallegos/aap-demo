#!/usr/bin/env bash
# Red Hat Customer Portal authentication for Fleet image operations.

if [ -n "${_FLEET_AUTH_LOADED:-}" ]; then return 0; fi
_FLEET_AUTH_LOADED=1

FLEET_REDHAT_SECRET_KEY="aap_demo.redhat.offline_token"
FLEET_CDN_USERNAME_KEY="aap_demo.redhat.cdn_username"
FLEET_CDN_PASSWORD_KEY="aap_demo.redhat.cdn_password"
FLEET_REDHAT_ACCOUNT_NUMBER_KEY="aap_demo.redhat.account_number"
FLEET_REDHAT_SUBSCRIPTION_ID_KEY="aap_demo.redhat.aap_subscription_id"
FLEET_REDHAT_TOKEN_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
FLEET_REDHAT_TOKEN_PAGE="https://access.redhat.com/management/api"

_fleet_redhat_open_token_page() {
  echo "Generate an offline token at:"
  echo "  $FLEET_REDHAT_TOKEN_PAGE"
  [ "${FLEET_REDHAT_OPEN_TOKEN_PAGE:-true}" = "true" ] || return 0
  if command -v xdg-open >/dev/null 2>&1 \
    && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
    xdg-open "$FLEET_REDHAT_TOKEN_PAGE" >/dev/null 2>&1 &
    echo "Opening the Red Hat API Tokens page in your browser..."
  elif command -v open >/dev/null 2>&1; then
    open "$FLEET_REDHAT_TOKEN_PAGE" >/dev/null 2>&1 &
    echo "Opening the Red Hat API Tokens page in your browser..."
  fi
}

_fleet_redhat_prompt_offline_token() {
  if [ "${QUIET:-false}" = "true" ]; then
    _err "Red Hat offline token is not configured or is no longer valid"
    return 1
  fi
  if [ ! -r "$AAP_DEMO_SECRET_PROMPT_DEVICE" ]; then
    _err "Cannot securely prompt for the Red Hat offline token"
    return 1
  fi

  local token
  _fleet_redhat_open_token_page >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  printf "Red Hat Customer Portal offline token: " >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  IFS= read -r -s token <"$AAP_DEMO_SECRET_PROMPT_DEVICE"
  printf "\n" >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  if [ -z "$token" ]; then
    _err "Red Hat offline token must not be empty"
    return 1
  fi
  aap_demo_vault_set "$FLEET_REDHAT_SECRET_KEY" "$token"
}

_fleet_redhat_prompt_cdn_credentials() {
  if [ "${QUIET:-false}" = "true" ]; then
    _err "CDN username and password are not configured"
    return 1
  fi
  if [ ! -r "$AAP_DEMO_SECRET_PROMPT_DEVICE" ]; then
    _err "Cannot securely prompt for CDN credentials"
    return 1
  fi

  local username password
  exec 9<"$AAP_DEMO_SECRET_PROMPT_DEVICE"
  printf "Red Hat CDN username: " >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  IFS= read -r username <&9
  printf "Red Hat CDN password: " >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  IFS= read -r -s password <&9
  exec 9<&-
  printf "\n" >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"

  if [ -z "$username" ] || [ -z "$password" ]; then
    _err "CDN username and password must not be empty"
    return 1
  fi
  aap_demo_vault_set "$FLEET_CDN_USERNAME_KEY" "$username" || return 1
  aap_demo_vault_set "$FLEET_CDN_PASSWORD_KEY" "$password"
}

_fleet_redhat_prompt_account_number() {
  if [ "${QUIET:-false}" = "true" ]; then
    _err "Red Hat account number is not configured"
    return 1
  fi
  if [ ! -r "$AAP_DEMO_SECRET_PROMPT_DEVICE" ]; then
    _err "Cannot securely prompt for the Red Hat account number"
    return 1
  fi

  local account_number
  printf "Red Hat account number: " >"$AAP_DEMO_SECRET_PROMPT_OUTPUT"
  IFS= read -r account_number <"$AAP_DEMO_SECRET_PROMPT_DEVICE"
  if [[ ! "$account_number" =~ ^[0-9]+$ ]]; then
    _err "Red Hat account number must contain only digits"
    return 1
  fi
  aap_demo_vault_set "$FLEET_REDHAT_ACCOUNT_NUMBER_KEY" "$account_number"
}

fleet_redhat_ensure_cdn_credentials() {
  local allow_prompt="${1:-true}"
  local username password
  username=$(aap_demo_vault_get "$FLEET_CDN_USERNAME_KEY" 2>/dev/null || true)
  password=$(aap_demo_vault_get "$FLEET_CDN_PASSWORD_KEY" 2>/dev/null || true)
  if [ -n "$username" ] && [ -n "$password" ]; then
    return 0
  fi
  [ "$allow_prompt" = "true" ] || return 1
  _fleet_redhat_prompt_cdn_credentials
}

fleet_redhat_ensure_account_number() {
  local allow_prompt="${1:-true}"
  local account_number
  account_number=$(aap_demo_vault_get "$FLEET_REDHAT_ACCOUNT_NUMBER_KEY" 2>/dev/null || true)
  if [[ "$account_number" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  [ "$allow_prompt" = "true" ] || return 1
  _fleet_redhat_prompt_account_number
}

fleet_redhat_store_project_metadata() {
  local preset cluster_name kubeconfig
  preset="${CRC_PRESET:-microshift}"
  cluster_name="${AAP_DEMO_CLUSTER_NAME:-crc-${preset}}"
  kubeconfig="${KUBECTL_KUBECONFIG:-$HOME/.aap-demo/kubeconfig.microshift}"
  aap_demo_vault_set "aap_demo.project.name" "aap-demo" || return 1
  aap_demo_vault_set "aap_demo.cluster.name" "$cluster_name" || return 1
  aap_demo_vault_set "aap_demo.cluster.provider" "${INFRA_TYPE:-crc}" || return 1
  aap_demo_vault_set "aap_demo.cluster.kubeconfig" "$kubeconfig"
}

_fleet_redhat_exchange_token() {
  local offline_token="$1"
  local response
  response=$(printf '%s' "$offline_token" | curl --silent --show-error \
    --write-out '\n%{http_code}' \
    --request POST \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=rhsm-api" \
    --data-urlencode "refresh_token@-" \
    "$FLEET_REDHAT_TOKEN_URL") || {
      _err "Unable to contact Red Hat SSO"
      return 1
    }

  local http_code="${response##*$'\n'}"
  if [ "$http_code" != "200" ]; then
    return 1
  fi
  response="${response%$'\n'*}"

  local access_token
  access_token=$(python3 -c '
import json
import sys
value = json.load(sys.stdin).get("access_token", "")
if not value:
    raise SystemExit(1)
sys.stdout.write(value)
' <<<"$response") || {
    return 1
  }
  printf '%s' "$access_token"
}

fleet_redhat_access_token() {
  local allow_prompt="${1:-true}"
  local offline_token
  offline_token=$(aap_demo_vault_get "$FLEET_REDHAT_SECRET_KEY" 2>/dev/null || true)

  if [ -n "$offline_token" ]; then
    local access_token
    if access_token=$(_fleet_redhat_exchange_token "$offline_token"); then
      printf '%s' "$access_token"
      return 0
    fi
  fi

  [ "$allow_prompt" = "true" ] || return 1
  echo "Stored Red Hat token is missing or invalid; a new token is required." >&2
  _fleet_redhat_prompt_offline_token || return 1
  offline_token=$(aap_demo_vault_get "$FLEET_REDHAT_SECRET_KEY") || return 1
  _fleet_redhat_exchange_token "$offline_token"
}

fleet_redhat_auth() {
  local subcmd="${1:-configure}"
  case "$subcmd" in
    configure)
      fleet_redhat_ensure_cdn_credentials true || return 1
      fleet_redhat_ensure_account_number true || return 1
      fleet_redhat_store_project_metadata || return 1
      local access_token
      if access_token=$(fleet_redhat_access_token true); then
        unset access_token
        echo "✓ Red Hat Customer Portal authentication is valid"
        echo "  Credentials: $AAP_DEMO_VAULT_FILE"
      else
        _err "Red Hat Customer Portal authentication failed"
        return 1
      fi
      ;;
    status)
      if [ ! -s "$AAP_DEMO_VAULT_FILE" ]; then
        echo "Red Hat Customer Portal authentication: not configured"
        return 1
      fi
      if ! fleet_redhat_ensure_cdn_credentials false; then
        echo "Red Hat CDN credentials: not configured"
        return 1
      fi
      if ! fleet_redhat_ensure_account_number false; then
        echo "Red Hat account number: not configured"
        return 1
      fi
      local access_token
      if access_token=$(fleet_redhat_access_token false); then
        unset access_token
        echo "Red Hat Customer Portal authentication: valid"
      else
        echo "Red Hat Customer Portal authentication: expired or invalid"
        return 1
      fi
      ;;
    reset)
      aap_demo_vault_delete "$FLEET_REDHAT_SECRET_KEY"
      aap_demo_vault_delete "$FLEET_CDN_USERNAME_KEY"
      aap_demo_vault_delete "$FLEET_CDN_PASSWORD_KEY"
      aap_demo_vault_delete "$FLEET_REDHAT_ACCOUNT_NUMBER_KEY"
      aap_demo_vault_delete "$FLEET_REDHAT_SUBSCRIPTION_ID_KEY"
      echo "✓ Red Hat Customer Portal and CDN credentials removed"
      ;;
    *)
      _err "Unknown Fleet auth command: $subcmd"
      echo "Usage: aap-demo fleet auth [configure|status|reset]"
      return 1
      ;;
  esac
}
