#!/usr/bin/env bash
# Configure Private Automation Hub remotes on a running AAP instance
#
# Stores the Red Hat Automation Hub offline token in ~/.ansible/conf/env.yml.
# Get one at: https://console.redhat.com/ansible/automation-hub/token
#
# Usage:
#   ./deploy.sh    # Configure PAH remotes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../includes/galaxy-auth.sh
source "${SCRIPT_DIR}/../../includes/galaxy-auth.sh"

NAMESPACE="${NAMESPACE:-aap-operator}"
GALAXY_TOKEN_FILE="${GALAXY_TOKEN_FILE:-$HOME/.aap-demo/galaxy-token}"
PAH_CONFIG_FILE="${PAH_CONFIG_FILE:-$HOME/.aap-demo/pah-config.yml}"

export NAMESPACE GALAXY_TOKEN_FILE PAH_CONFIG_FILE

echo "Setting up Private Automation Hub..."
echo ""

detect_galaxy_credentials
if [ -z "${GALAXY_TOKEN:-}" ]; then
  url="https://console.redhat.com/ansible/automation-hub/token"

  if command -v open >/dev/null 2>&1; then
    open "$url"
    echo "Opening browser to Red Hat Automation Hub..."
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
    echo "Opening browser to Red Hat Automation Hub..."
  elif command -v start >/dev/null 2>&1; then
    start "$url"
    echo "Opening browser to Red Hat Automation Hub..."
  else
    echo "Visit this URL in your browser:"
    echo "  $url"
  fi

  echo ""
  echo "Steps:"
  echo "  1. Log in with your Red Hat account"
  echo "  2. Click 'Load token' button"
  echo "  3. Copy the 'Offline Token' (long base64 string, ~1500 characters)"
  echo "  4. Paste the token at the secure prompt below."
  echo ""
  echo "Documentation: docs/collection-authentication.md"
  if [ ! -r /dev/tty ]; then
    echo "ERROR: An interactive terminal is required to enter the token" >&2
    exit 1
  fi
  printf "Automation Hub offline token: " >/dev/tty
  IFS= read -r -s GALAXY_TOKEN </dev/tty
  printf "\n" >/dev/tty
  [ -n "$GALAXY_TOKEN" ] || {
    echo "ERROR: Token must not be empty" >&2
    exit 1
  }
  aap_demo_vault_set "aap_demo.galaxy.offline_token" "$GALAXY_TOKEN"
fi

echo "✓ Galaxy token loaded from encrypted credential storage"
echo ""
echo "Configuring AAP Private Automation Hub remotes..."
configure_pah_remotes
