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

cat >"$TEST_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
cat >"$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"access_token":"discarded"}\n200'
EOF
cat >"$TEST_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SYSTEMCTL_LOG"
exit 0
EOF
chmod +x "$TEST_DIR/bin/uname" "$TEST_DIR/bin/curl" "$TEST_DIR/bin/systemctl"
export PATH="$TEST_DIR/bin:$PATH"
export TEST_SYSTEMCTL_LOG="$TEST_DIR/systemctl.log"

_err() { printf 'ERROR: %s\n' "$*" >&2; }
# shellcheck source=../includes/credential-vault.sh
source "$REPO_ROOT/includes/credential-vault.sh"
aap_demo_vault_set aap_demo.redhat.offline_token customer-portal-fixture
aap_demo_vault_set aap_demo.galaxy.offline_token automation-hub-fixture

output=$(bash "$REPO_ROOT/scripts/aap-demo-token-keepalive.sh" run)
grep -q 'Customer Portal offline token is live' <<<"$output"
grep -q 'Automation Hub offline token is live' <<<"$output"
if grep -q 'fixture\|discarded' <<<"$output"; then
  echo "FAIL: keepalive output exposed token material" >&2
  exit 1
fi

bash "$REPO_ROOT/scripts/aap-demo-token-keepalive.sh" enable >/dev/null
timer="$HOME/.config/systemd/user/aap-demo-token-keepalive.timer"
service="$HOME/.config/systemd/user/aap-demo-token-keepalive.service"
test -f "$timer"
test -f "$service"
grep -q '^Persistent=true$' "$timer"
grep -q 'enable --now aap-demo-token-keepalive.timer' "$TEST_SYSTEMCTL_LOG"

"$REPO_ROOT/aap-demo.sh" credentials keepalive status >/dev/null
"$REPO_ROOT/aap-demo.sh" credentials keepalive disable >/dev/null
test ! -e "$timer"
test ! -e "$service"

echo "PASS: token keepalive is opt-in, persistent, Vault-backed, and secret-free"
