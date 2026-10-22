#!/usr/bin/env bash
# Regression test for merging legacy credentials into the shared user Vault.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "${TEST_HOME}/.ansible/conf"
printf 'vault-password\n' >"${TEST_HOME}/.ansible/conf/.vaultpass_microshift.txt"
chmod 600 "${TEST_HOME}/.ansible/conf/.vaultpass_microshift.txt"
printf 'shared-password\n' >"${TEST_HOME}/.ansible/conf/.vaultpass.txt"
chmod 600 "${TEST_HOME}/.ansible/conf/.vaultpass.txt"
cat >"${TEST_HOME}/shared.yml" <<'EOF'
existing_setting: keep-me
aap_demo:
  existing_secret: keep-this-too
EOF
ansible-vault encrypt \
  --vault-password-file "${TEST_HOME}/.ansible/conf/.vaultpass.txt" \
  --output "${TEST_HOME}/.ansible/conf/env.yml" \
  "${TEST_HOME}/shared.yml"
cat >"${TEST_HOME}/legacy.yml" <<'EOF'
aap_demo:
  existing_secret: do-not-overwrite
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
[ "$(aap_demo_vault_get "aap_demo.existing_secret")" = "keep-this-too" ]
[ -f "$HOME/.ansible/conf/env.yml" ]
[ -f "$HOME/.ansible/conf/.vaultpass.txt" ]
[ ! -e "$HOME/.ansible/conf/env_microshift.yml" ]
[ ! -e "$HOME/.ansible/conf/.vaultpass_microshift.txt" ]
ansible-vault view --vault-password-file "$HOME/.ansible/conf/.vaultpass.txt" \
  "$HOME/.ansible/conf/env.yml" |
  python3 -c 'import sys,yaml; assert (yaml.safe_load(sys.stdin) or {}).get("existing_setting") == "keep-me"'
EOF

mkdir -p "${TEST_HOME}/venv/bin"
cat >"${TEST_HOME}/venv/bin/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "import yaml" ]; then
  exit 1
fi
exit 97
EOF
chmod +x "${TEST_HOME}/venv/bin/python3"
cat >"${TEST_HOME}/venv/bin/ansible-vault" <<'EOF'
#!/usr/bin/env bash
exit 98
EOF
chmod +x "${TEST_HOME}/venv/bin/ansible-vault"
HOME="$TEST_HOME" PATH="${TEST_HOME}/venv/bin:${PATH}" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail
_err() { printf 'ERROR: %s\n' "$*" >&2; }
source "${REPO_ROOT}/includes/credential-vault.sh"
[ "$(aap_demo_vault_get "aap_demo.redhat.offline_token")" = "legacy-token" ]
[ "$AAP_DEMO_VAULT_PYTHON" != "$HOME/venv/bin/python3" ]
[ "$AAP_DEMO_ANSIBLE_VAULT" != "$HOME/venv/bin/ansible-vault" ]
EOF

echo "PASS: merges legacy credentials into shared Vault"
