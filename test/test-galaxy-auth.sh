#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home"
export AAP_DEMO_DIR="$HOME/.aap-demo"
export AAP_DEMO_VAULT_FILE="$HOME/.ansible/conf/env.yml"
export AAP_DEMO_VAULT_PASSWORD_FILE="$HOME/.ansible/conf/.vaultpass.txt"
mkdir -p "$TEST_DIR/bin"

cat >"$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
token=$(cat)
if [ "${TEST_SSO_UNREACHABLE:-false}" = true ]; then
  exit 7
fi
case "$token" in
  compatible-token) printf '200' ;;
  *) printf '400' ;;
esac
EOF
chmod +x "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/galaxy-auth.sh
source "$REPO_ROOT/includes/galaxy-auth.sh"

aap_demo_vault_set aap_demo.redhat.offline_token compatible-token
set +e
prepare_galaxy_credentials >/dev/null
rc=$?
set -e
[ "$rc" -eq 1 ]
if aap_demo_vault_get aap_demo.galaxy.offline_token >/dev/null 2>&1; then
  echo "FAIL: Customer Portal token was copied into Automation Hub credentials" >&2
  exit 1
fi

aap_demo_vault_set aap_demo.galaxy.offline_token compatible-token
GALAXY_TOKEN=""
prepare_galaxy_credentials >/dev/null
[ "$GALAXY_TOKEN" = compatible-token ]

aap_demo_vault_set aap_demo.galaxy.offline_token rejected-token
aap_demo_vault_set aap_demo.redhat.offline_token rejected-token
AAP_DEMO_ANSIBLE_VAULT=""
AAP_DEMO_VAULT_PYTHON=""
GALAXY_TOKEN=""
set +e
prepare_galaxy_credentials >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: rejected Automation Hub token was accepted" >&2
  exit 1
fi
set +e
aap_demo_vault_get aap_demo.galaxy.offline_token >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: rejected Automation Hub token remained in the Vault" >&2
  exit 1
fi

export TEST_SSO_UNREACHABLE=true
aap_demo_vault_set aap_demo.galaxy.offline_token compatible-token
GALAXY_TOKEN=""
set +e
prepare_galaxy_credentials >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]

echo "PASS: Customer Portal and Automation Hub tokens remain separate and validated"
