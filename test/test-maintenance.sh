#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DEMO_SH="${SCRIPT_DIR}/../aap-demo.sh"
MAINTENANCE_SH="${SCRIPT_DIR}/../includes/maintenance.sh"

output=$(QUIET=true "$AAP_DEMO_SH" help)
grep -Fq "maintenance [--apply]" <<<"$output"

if output=$(QUIET=true "$AAP_DEMO_SH" status --apply 2>&1); then
  echo "FAIL: --apply was accepted outside maintenance"
  exit 1
fi
grep -Fq -- "--apply is supported only by maintenance" <<<"$output"

grep -Fq 'crictl ps -a --state Exited -q' "$MAINTENANCE_SH"
grep -Fq 'crictl rmi --prune' "$MAINTENANCE_SH"
grep -Fq 'journalctl --vacuum-time=7d' "$MAINTENANCE_SH"

if grep -Eq 'delete (namespace|pvc)|kubectl delete|oc delete' "$MAINTENANCE_SH"; then
  echo "FAIL: maintenance must not delete Kubernetes resources"
  exit 1
fi

mock_dir=$(mktemp -d)
trap 'rm -rf "$mock_dir"' EXIT

cat >"$mock_dir/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"$mock_dir/crictl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ps) printf 'container-a\ncontainer-b\n' ;;
  images) printf 'image-a\nimage-a\nimage-b\n' ;;
  rm) echo "removed" ;;
  rmi) echo "pruned" ;;
esac
EOF
cat >"$mock_dir/df" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-Pk" ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/mock 100000 80000 20000 80%% /var\n'
else
  printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/mock 100M 80M 20M 80%% /var\n'
fi
EOF
for command in du dnf journalctl fstrim; do
  cat >"$mock_dir/$command" <<EOF
#!/usr/bin/env bash
echo "mock $command"
EOF
done
chmod +x "$mock_dir"/*

output=$(
  # shellcheck disable=SC2030,SC2329
  PATH="$mock_dir:$PATH"
  # shellcheck disable=SC2329
  _infra_ensure_backend() { return 0; }
  # shellcheck disable=SC2329
  infra_exec_cmd() { command "$@"; }
  # shellcheck source=../includes/maintenance.sh
  source "$MAINTENANCE_SH"
  cmd_maintenance preview true
)

grep -Fq 'Removed 2 exited container(s)' <<<"$output"
grep -Fq 'Pruned unused container images' <<<"$output"
grep -Fq 'Vacuumed system journals older than 7 days' <<<"$output"
grep -Fq 'Maintenance complete:' <<<"$output"

uninstall_home="$mock_dir/uninstall-home"
mkdir -p \
  "$uninstall_home/.aap-demo/fleet" \
  "$uninstall_home/.crc/cache" \
  "$uninstall_home/.crc/machines/crc" \
  "$uninstall_home/.local/bin" \
  "$uninstall_home/.local/share/bash-completion/completions"
printf 'pull-secret\n' >"$uninstall_home/.aap-demo/pull-secret.txt"
printf 'generated-credential\n' >"$uninstall_home/.aap-demo/generated-credential"
printf 'bundle\n' >"$uninstall_home/.crc/cache/bundle"
ln -s "$AAP_DEMO_SH" "$uninstall_home/.local/bin/aap-demo"
# shellcheck disable=SC2016
printf '%s\n' \
  '# >>> aap-demo PATH >>>' \
  'case ":$PATH:" in' \
  '  *":$HOME/.local/bin:"*) ;;' \
  '  *) export PATH="$HOME/.local/bin:$PATH" ;;' \
  'esac' \
  '# <<< aap-demo PATH <<<' \
  '# >>> aap-demo bash completion >>>' \
  'if [ -r "$HOME/.local/share/bash-completion/completions/aap-demo" ]; then' \
  '  source "$HOME/.local/share/bash-completion/completions/aap-demo"' \
  'fi' \
  '# <<< aap-demo bash completion <<<' \
  >"$uninstall_home/.bashrc"
# shellcheck disable=SC2016
printf '%s\n' \
  '# AAP Demo - Trust self-signed ingress CA for Node.js (Claude Code MCP)' \
  'export NODE_EXTRA_CA_CERTS="${AAP_DEMO_CONFIG_DIR:-${HOME}/.aap-demo}/crc-ingress-ca.crt"' \
  >"$uninstall_home/.bash_profile"

cat >"$mock_dir/crc" <<EOF
#!/usr/bin/env bash
echo "crc \$*" >>"$mock_dir/uninstall.log"
EOF
cat >"$mock_dir/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >>"$mock_dir/uninstall.log"
EOF
cat >"$mock_dir/podman" <<EOF
#!/usr/bin/env bash
echo "podman \$*" >>"$mock_dir/uninstall.log"
EOF
chmod +x "$mock_dir/crc" "$mock_dir/claude" "$mock_dir/podman"

# shellcheck disable=SC2031
HOME="$uninstall_home" PATH="$mock_dir:$PATH" QUIET=true \
  AAP_DEMO_UNINSTALL_CONFIRM=UNINSTALL bash -c '
    set -euo pipefail
    SCRIPT_DIR=$1
    source "$SCRIPT_DIR/includes/persistent-crio-store.sh"
    source "$SCRIPT_DIR/includes/maintenance.sh"
    _purge_ingress_ca_trust() { return 0; }
    _remove_temp_swap() { return 0; }
    cmd_maintenance uninstall true
  ' _ "$SCRIPT_DIR/.." >/dev/null

[ ! -e "$uninstall_home/.aap-demo/pull-secret.txt" ]
[ ! -e "$uninstall_home/.aap-demo/generated-credential" ]
[ ! -e "$uninstall_home/.aap-demo/fleet" ]
[ ! -e "$uninstall_home/.crc" ]
[ ! -e "$uninstall_home/.local/bin/aap-demo" ]
if grep -q '^# >>> aap-demo bash completion >>>$' "$uninstall_home/.bashrc"; then
  echo "FAIL: uninstall left the Bash completion loader behind"
  exit 1
fi
if grep -q '^# >>> aap-demo PATH >>>$' "$uninstall_home/.bashrc"; then
  echo "FAIL: uninstall left the PATH loader behind"
  exit 1
fi
if grep -q 'NODE_EXTRA_CA_CERTS.*crc-ingress-ca.crt' "$uninstall_home/.bash_profile"; then
  echo "FAIL: uninstall left the shell CA export behind"
  exit 1
fi
grep -Fq 'crc delete -f' "$mock_dir/uninstall.log"
grep -Fq 'crc cleanup' "$mock_dir/uninstall.log"
grep -Fq 'claude mcp remove aap-demo --scope user' "$mock_dir/uninstall.log"

HOME="$uninstall_home" SHELL=/bin/bash bash "${SCRIPT_DIR}/../install.sh" >/dev/null
[ -L "$uninstall_home/.local/bin/aap-demo" ]
[ -f "$uninstall_home/.local/share/bash-completion/completions/aap-demo" ]
[ "$(grep -c '^# >>> aap-demo PATH >>>$' "$uninstall_home/.bashrc")" -eq 1 ]
[ "$(grep -c '^# >>> aap-demo bash completion >>>$' "$uninstall_home/.bashrc")" -eq 1 ]
HOME="$uninstall_home" bash --noprofile --rcfile "$uninstall_home/.bashrc" -i -c \
  'command -v aap-demo && complete -p aap-demo' >/dev/null 2>&1

echo "PASS: maintenance preview, cleanup, and full uninstall paths are safe and explicit"
