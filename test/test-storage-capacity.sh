#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SCRIPT_DIR="$REPO_ROOT"

# shellcheck source=../includes/storage-capacity.sh
source "$REPO_ROOT/includes/storage-capacity.sh"

[ "$(aap_demo_capacity_recommended_disk "")" = 120 ]
[ "$(aap_demo_capacity_recommended_disk "ao mcp-server ollama")" = 160 ]

all_addons=$(jq -r '.addons | keys | join(" ")' "$AAP_DEMO_CAPACITY_MODEL")
all_plan=$(aap_demo_capacity_plan "$all_addons")
[ "$(jq -r '.recommended_vm_disk_gib' <<<"$all_plan")" = 210 ]
[ "$(jq -r '.host_only_gib' <<<"$all_plan")" = 65 ]
[ "$(jq -r '.addons.fleet.vm_gib' <<<"$all_plan")" = 0 ]
[ "$(jq -r '.addons.fleet.host_gib' <<<"$all_plan")" = 25 ]

cli_addons=$(sed -n 's/^AVAILABLE_ADDONS="\([^"]*\)"/\1/p' "$REPO_ROOT/aap-demo.sh" | tr ' ' '\n' | sort)
model_addons=$(jq -r '.addons | keys[]' "$AAP_DEMO_CAPACITY_MODEL" | sort)
[ "$cli_addons" = "$model_addons" ]

unset CRC_DISK CRC_PV_SIZE VM_DISK_SIZE VM_PV_SIZE
ADDONS="ao,mcp-server,ollama"
aap_demo_capacity_resolve_crc_sizes
[ "$CRC_DISK" = 160 ]
[ "$CRC_PV_SIZE" = 70 ]

unset CRC_PV_SIZE VM_DISK_SIZE VM_PV_SIZE
CRC_DISK=137
aap_demo_capacity_resolve_crc_sizes
[ "$CRC_DISK" = 137 ]
[ "$CRC_PV_SIZE" = 70 ]

unset CRC_PV_SIZE VM_DISK_SIZE VM_PV_SIZE
CRC_DISK=60
aap_demo_capacity_resolve_crc_sizes
[ "$CRC_DISK" = 60 ]
[ "$CRC_PV_SIZE" = 30 ]

infra_exec_cmd() {
  printf '%s\n' "${MOCK_DISK_VALUES}"
}

MOCK_DISK_VALUES="50 45 5"
warning=$(aap_demo_capacity_warn_enable ao "" 2>&1)
grep -q 'Disk capacity planning warning' <<<"$warning"
grep -q 'Continuing without resize' <<<"$warning"
grep -q 'destructive rebuild' <<<"$warning"

MOCK_DISK_VALUES="200 100 100"
warning=$(aap_demo_capacity_warn_enable ao "" 2>&1)
[ -z "$warning" ]

echo "✓ storage capacity calculations, overrides, PV sizing, and warnings"
