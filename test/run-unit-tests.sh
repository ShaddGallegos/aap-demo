#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0
TOTAL=0

run_test() {
  local runner="$1"
  local test_file="$2"

  TOTAL=$((TOTAL + 1))
  printf '\n==> %s\n' "$(basename "$test_file")"
  if ! "$runner" "$test_file"; then
    FAILED=$((FAILED + 1))
  fi
}

for test_file in "$TEST_DIR"/test-*.sh; do
  case "$(basename "$test_file")" in
    test-live-idempotency.sh) continue ;;
  esac
  run_test bash "$test_file"
done

for test_file in "$TEST_DIR"/test-*.py; do
  case "$(basename "$test_file")" in
    test-ao-live-smoke.py) continue ;;
  esac
  run_test python3 "$test_file"
done

echo ""
echo "Unit test files: $((TOTAL - FAILED)) passed, $FAILED failed, $TOTAL total"
[ "$FAILED" -eq 0 ]
