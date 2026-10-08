#!/usr/bin/env bash
# Regression test for migration from MicroShift-named Vault files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "${TEST_HOME}/.ansible/conf"
printf 'vault-password\n' >"${TEST_HOME}/.ansible/conf/.vaultpass_microshift.txt"
chmod 600 "${TEST_HOME}/.ansible/conf/.vaultpass_microshift.txt"
cat >"${TEST_HOME}/legacy.yml" <<'EOF'
aap_demo:
  redhat:
    offline_token: legacy-token
EOF
ansible-vault encrypt \
  --vault-password-file "${TEST_HOME}/.ansible/conf/.vaultpass_microshift.txt" \
  --output "${TEST_HOME}/.ansible/conf/env_microshift.yml" \
  "${TEST_HOME}/legacy.yml"

HOME="$TEST_HOME" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail
_err() { printf 'ERROR: %s\n' "$*" >&2; }
source "${REPO_ROOT}/includes/credential-vault.sh"
value=$(aap_demo_vault_get "aap_demo.redhat.offline_token")
[ "$value" = "legacy-token" ]
[ -f "$HOME/.ansible/conf/env-aap-demo.yml" ]
[ -f "$HOME/.ansible/conf/.vaultpass-aap-demo.txt" ]
[ ! -e "$HOME/.ansible/conf/env_microshift.yml" ]
[ ! -e "$HOME/.ansible/conf/.vaultpass_microshift.txt" ]
EOF

echo "PASS: migrates legacy MicroShift Vault files"
