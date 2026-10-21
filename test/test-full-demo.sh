#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AAP_DEMO_SH="$REPO_ROOT/aap-demo.sh"
LOG_FILE=$(mktemp)
trap 'rm -f "$LOG_FILE"' EXIT

cmd_create() {
  printf 'create quiet=%s addons=%s\n' "$QUIET" "$ADDONS" >>"$LOG_FILE"
}

cmd_deploy() {
  printf 'deploy skip_ao=%s\n' "${AAP_DEMO_SKIP_STANDARD_AO:-false}" >>"$LOG_FILE"
}

cmd_enable() {
  printf 'enable %s provider=%s\n' "$1" "${AO_LLM_PROVIDER:-unset}" >>"$LOG_FILE"
}

cmd_fleet() {
  printf 'fleet %s\n' "$*" >>"$LOG_FILE"
}

# shellcheck disable=SC2329
fleet_count() {
  printf '0'
}

cmd_wire() {
  printf 'wire\n' >>"$LOG_FILE"
}

aap_demo_generate_system_info() {
  printf 'system-info\n' >>"$LOG_FILE"
}

_aap_demo_release_operation_lock() {
  printf 'release-lock\n' >>"$LOG_FILE"
}

cmd_dashboard() {
  printf 'dashboard\n' >>"$LOG_FILE"
}

full_demo_function=$(sed -n '/^cmd_full_demo()/,/^}$/p' "$AAP_DEMO_SH")
eval "$full_demo_function"
cmd_full_demo >/dev/null

cat >"$LOG_FILE.expected" <<'EOF'
fleet auth status
create quiet=true addons=mcp-server,ollama,ao,fleet
deploy skip_ao=true
enable ollama provider=unset
enable ao provider=ollama
enable fleet provider=unset
fleet add 3 --image rhel9
wire
system-info
release-lock
dashboard
EOF

if ! cmp -s "$LOG_FILE" "$LOG_FILE.expected"; then
  echo "FAIL: full demo orchestration order is incorrect"
  diff -u "$LOG_FILE.expected" "$LOG_FILE" || true
  rm -f "$LOG_FILE.expected"
  exit 1
fi
rm -f "$LOG_FILE.expected"

fleet_count() {
  printf '3'
}
: >"$LOG_FILE"
cmd_full_demo >/dev/null
if grep -Fq 'fleet add ' "$LOG_FILE"; then
  echo "FAIL: full demo duplicated an existing three-node Fleet"
  exit 1
fi
grep -Fq 'fleet start' "$LOG_FILE"
grep -Fq 'fleet register' "$LOG_FILE"

if QUIET=true "$AAP_DEMO_SH" status --full-demo >/tmp/aap-demo-full-demo-error 2>&1; then
  echo "FAIL: --full-demo was accepted outside create"
  rm -f /tmp/aap-demo-full-demo-error
  exit 1
fi
grep -Fq -- "--full-demo is supported only by create" /tmp/aap-demo-full-demo-error
rm -f /tmp/aap-demo-full-demo-error

echo "PASS: create --full-demo uses the required fail-fast orchestration order"
