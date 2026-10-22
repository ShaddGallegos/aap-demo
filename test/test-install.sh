#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$TEST_HOME/.aap-demo"
cat >"$TEST_HOME/.aap-demo/config" <<'EOF'
INFRA=crc
ADDONS=ao,portal
EOF

HOME="$TEST_HOME" bash "$SCRIPT_DIR/install.sh" --uninstall >/dev/null

grep -q '^INFRA=crc$' "$TEST_HOME/.aap-demo/config"
if grep -q '^ADDONS=' "$TEST_HOME/.aap-demo/config"; then
  echo "ADDONS state was not removed during uninstall" >&2
  exit 1
fi

echo "✓ uninstall_clears_addon_state"

eval "$(sed -n '/^install_oc() (/,/^)/p' "$SCRIPT_DIR/install.sh")"
eval "$(sed -n '/^install_kubectl() (/,/^)/p' "$SCRIPT_DIR/install.sh")"
mkdir -p "$TEST_HOME/fixture"
printf '#!/bin/sh\nexit 0\n' >"$TEST_HOME/fixture/oc"
cp "$TEST_HOME/fixture/oc" "$TEST_HOME/fixture/kubectl"
tar -czf "$TEST_HOME/clients.tar.gz" -C "$TEST_HOME/fixture" oc kubectl
EXPECTED_HASH=$(shasum -a 256 "$TEST_HOME/clients.tar.gz" | awk '{print $1}')
CLIENT_HASH=$(shasum -a 256 "$TEST_HOME/fixture/kubectl" | awk '{print $1}')
KUBE_VERSION=v1.34.0
HOST_OS=Linux
HOST_ARCH=x86_64
BAD_CHECKSUM=false
DOWNLOAD_FAILURE=false
uname() {
  case "$1" in -s) echo "$HOST_OS" ;; -m) echo "$HOST_ARCH" ;; esac
}
xattr() { return 0; }
curl() {
  [ "$DOWNLOAD_FAILURE" != true ] || return 1
  local url="$2" dest="${4:-}"
  case "$url" in
    */stable.txt) echo "$KUBE_VERSION" ;;
    */kubectl.sha256)
      if [ "$BAD_CHECKSUM" = true ]; then echo invalid; else echo "$CLIENT_HASH"; fi
      ;;
    */kubectl)
      [[ "$url" == *"/linux/$CLIENT_ARCH/kubectl" ]] || return 1
      cp "$TEST_HOME/fixture/kubectl" "$dest"
      ;;
    */sha256sum.txt)
      local hash="$EXPECTED_HASH"
      [ "$BAD_CHECKSUM" != true ] || hash=invalid
      printf '%s  %s\n' "$hash" "$ARCHIVE" >"$dest"
      ;;
    *)
      [[ "$url" == *"/$ARCHIVE" ]] || return 1
      cp "$TEST_HOME/clients.tar.gz" "$dest"
      ;;
  esac
}
for platform in Linux:x86_64:linux Linux:aarch64:linux-arm64 \
  Darwin:x86_64:mac Darwin:arm64:mac-arm64; do
  IFS=: read -r HOST_OS HOST_ARCH suffix <<<"$platform"
  ARCHIVE="openshift-client-${suffix}.tar.gz"
  HOME="$TEST_HOME" install_oc
  test -x "$TEST_HOME/.local/bin/oc"
  test -x "$TEST_HOME/.local/bin/kubectl"
done
echo "✓ architecture-specific Linux/macOS oc and kubectl installation"
if BAD_CHECKSUM=true HOME="$TEST_HOME" install_oc >/dev/null 2>&1; then
  echo "FAIL: invalid client checksum accepted" >&2; exit 1
fi
if DOWNLOAD_FAILURE=true HOME="$TEST_HOME" install_oc >/dev/null 2>&1; then
  echo "FAIL: failed client download accepted" >&2; exit 1
fi
echo "✓ download and checksum failures are explicit"

HOST_OS=Linux
for platform in x86_64:amd64 aarch64:arm64; do
  IFS=: read -r HOST_ARCH CLIENT_ARCH <<<"$platform"
  HOME="$TEST_HOME" install_kubectl
  test -x "$TEST_HOME/.local/bin/kubectl"
done
if BAD_CHECKSUM=true HOME="$TEST_HOME" install_kubectl >/dev/null 2>&1; then
  echo "FAIL: invalid kubectl checksum accepted" >&2; exit 1
fi
if KUBE_VERSION=invalid HOME="$TEST_HOME" install_kubectl >/dev/null 2>&1; then
  echo "FAIL: invalid Kubernetes release accepted" >&2; exit 1
fi
echo "✓ verified standalone kubectl installation and release validation"
