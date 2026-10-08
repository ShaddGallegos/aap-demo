#!/usr/bin/env bash
# Regression tests for Fleet command argument parsing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

_err() {
  printf 'ERROR: %s\n' "$*" >&2
}

# shellcheck source=../addons/fleet/fleet-cli.sh
source "${REPO_ROOT}/addons/fleet/fleet-cli.sh"

fleet_parse_add_args 3 --image /tmp/rhel9.qcow2
if [ "$FLEET_ADD_COUNT" != 3 ] || [ "$FLEET_ADD_IMAGE" != /tmp/rhel9.qcow2 ]; then
  echo "FAIL: separated --image syntax was not parsed" >&2
  exit 1
fi
echo "PASS: parses --image PATH"

fleet_parse_add_args --image=/tmp/rhel9.qcow2 2
if [ "$FLEET_ADD_COUNT" != 2 ] || [ "$FLEET_ADD_IMAGE" != /tmp/rhel9.qcow2 ]; then
  echo "FAIL: equals --image syntax was not parsed" >&2
  exit 1
fi
echo "PASS: parses --image=PATH"

if output=$(fleet_parse_add_args 3 --image /tmp/rhel9.qcow2 ao 2>&1); then
  echo "FAIL: unexpected trailing argument was accepted" >&2
  exit 1
fi
if ! grep -q "Unexpected argument for 'fleet add': ao" <<<"$output"; then
  echo "FAIL: trailing argument did not produce a useful error" >&2
  echo "$output" >&2
  exit 1
fi
echo "PASS: rejects unexpected trailing arguments"

if fleet_parse_add_args 3 --image >/dev/null 2>&1; then
  echo "FAIL: missing image value was accepted" >&2
  exit 1
fi
echo "PASS: rejects missing image value"

export HOME="$TEST_HOME"
# shellcheck source=../addons/fleet/fleet.sh
source "${REPO_ROOT}/addons/fleet/fleet.sh"
list_output=$(fleet_list)
if ! grep -q 'aap-demo fleet add <count> --image <rhel9|rhel10|local-qcow2-path>' <<<"$list_output"; then
  echo "FAIL: empty Fleet list does not show managed-image syntax" >&2
  echo "$list_output" >&2
  exit 1
fi
echo "PASS: empty Fleet list shows managed-image syntax"
