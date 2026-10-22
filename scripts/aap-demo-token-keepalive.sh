#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../includes/credential-vault.sh
source "${REPO_ROOT}/includes/credential-vault.sh"

ACTION="${1:-status}"
UNIT_NAME="aap-demo-token-keepalive"
LINUX_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
MAC_LABEL="com.github.aap-demo.token-keepalive"
MAC_PLIST="$HOME/Library/LaunchAgents/${MAC_LABEL}.plist"
LOG_DIR="${AAP_DEMO_DIR:-$HOME/.aap-demo}/logs"
LOG_FILE="$LOG_DIR/token-keepalive.log"
SSO_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"

log_result() {
  local code="$1" message="$2"
  printf '%s rc=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$code" "$message"
}

notify_invalid() {
  local message="$1"
  case "$(uname -s)" in
    Linux)
      command -v notify-send >/dev/null 2>&1 &&
        notify-send --urgency=critical "aap-demo offline token needs renewal" "$message" || true
      ;;
    Darwin)
      command -v osascript >/dev/null 2>&1 &&
        osascript -e "display notification \"${message//\"/\\\"}\" with title \"aap-demo offline token needs renewal\" sound name \"Basso\"" \
          >/dev/null 2>&1 || true
      ;;
  esac
}

check_token() {
  local label="$1" key="$2" client_id="$3" token response http_code
  token=$(aap_demo_vault_get "$key" 2>/dev/null || true)
  if [ -z "$token" ]; then
    log_result 0 "$label token is not configured; skipped"
    return 0
  fi

  response=$(printf '%s' "$token" | curl --silent --show-error \
    --connect-timeout 15 --max-time 45 \
    --write-out '\n%{http_code}' \
    --request POST \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "refresh_token@-" \
    "$SSO_URL" 2>/dev/null) || {
      log_result 2 "$label token could not be checked because Red Hat SSO is unreachable"
      return 2
    }
  http_code="${response##*$'\n'}"
  unset token response
  if [ "$http_code" = 200 ]; then
    log_result 0 "$label offline token is live"
    return 0
  fi
  log_result 1 "$label offline token was rejected by Red Hat SSO (HTTP $http_code)"
  notify_invalid "$label token was rejected. Run the corresponding aap-demo credential command to replace it."
  return 1
}

run_checks() {
  local invalid=false unreachable=false rc
  check_token "Red Hat Customer Portal" "aap_demo.redhat.offline_token" "rhsm-api" || {
    rc=$?
    [ "$rc" -eq 1 ] && invalid=true
    [ "$rc" -eq 2 ] && unreachable=true
  }
  check_token "Automation Hub" "aap_demo.galaxy.offline_token" "cloud-services" || {
    rc=$?
    [ "$rc" -eq 1 ] && invalid=true
    [ "$rc" -eq 2 ] && unreachable=true
  }
  [ "$invalid" = false ] || return 1
  [ "$unreachable" = false ] || return 2
  return 0
}

install_linux() {
  mkdir -p "$LINUX_UNIT_DIR"
  chmod 700 "$LINUX_UNIT_DIR"
  cat >"$LINUX_UNIT_DIR/${UNIT_NAME}.service" <<EOF
[Unit]
Description=aap-demo offline-token keepalive

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash "${SCRIPT_DIR}/aap-demo-token-keepalive.sh" run
EOF
  cat >"$LINUX_UNIT_DIR/${UNIT_NAME}.timer" <<EOF
[Unit]
Description=Run aap-demo offline-token keepalive daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
Unit=${UNIT_NAME}.service

[Install]
WantedBy=timers.target
EOF
  chmod 600 "$LINUX_UNIT_DIR/${UNIT_NAME}.service" "$LINUX_UNIT_DIR/${UNIT_NAME}.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now "${UNIT_NAME}.timer"
  systemctl --user start "${UNIT_NAME}.service"
}

install_macos() {
  mkdir -p "$(dirname "$MAC_PLIST")" "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  cat >"$MAC_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${MAC_LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/env</string><string>bash</string>
    <string>${SCRIPT_DIR}/aap-demo-token-keepalive.sh</string><string>run</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_FILE}</string>
  <key>StandardErrorPath</key><string>${LOG_FILE}</string>
</dict></plist>
EOF
  chmod 600 "$MAC_PLIST"
  plutil -lint "$MAC_PLIST" >/dev/null
  launchctl bootout "gui/$(id -u)/${MAC_LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$MAC_PLIST"
}

status_keepalive() {
  case "$(uname -s)" in
    Linux)
      if [ ! -f "$LINUX_UNIT_DIR/${UNIT_NAME}.timer" ]; then
        echo "aap-demo token keepalive is not enabled"
        return 1
      fi
      systemctl --user --no-pager status "${UNIT_NAME}.timer" || return 1
      systemctl --user list-timers "${UNIT_NAME}.timer" --no-pager
      ;;
    Darwin)
      if [ ! -f "$MAC_PLIST" ]; then
        echo "aap-demo token keepalive is not enabled"
        return 1
      fi
      launchctl print "gui/$(id -u)/${MAC_LABEL}"
      [ ! -f "$LOG_FILE" ] || tail -n 5 "$LOG_FILE"
      ;;
    *) printf 'Unsupported platform\n' >&2; return 1 ;;
  esac
}

disable_keepalive() {
  case "$(uname -s)" in
    Linux)
      systemctl --user disable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 || true
      rm -f "$LINUX_UNIT_DIR/${UNIT_NAME}.service" "$LINUX_UNIT_DIR/${UNIT_NAME}.timer"
      systemctl --user daemon-reload
      ;;
    Darwin)
      launchctl bootout "gui/$(id -u)/${MAC_LABEL}" >/dev/null 2>&1 || true
      rm -f "$MAC_PLIST"
      ;;
    *) printf 'Unsupported platform\n' >&2; return 1 ;;
  esac
  echo "✓ aap-demo token keepalive disabled"
}

case "$ACTION" in
  enable)
    run_checks || {
      rc=$?
      [ "$rc" -eq 2 ] || exit "$rc"
      echo "WARNING: Red Hat SSO is unreachable; installing the keepalive for a later retry." >&2
    }
    case "$(uname -s)" in
      Linux) install_linux ;;
      Darwin) install_macos ;;
      *) echo "ERROR: Token keepalive supports Linux and macOS" >&2; exit 1 ;;
    esac
    echo "✓ aap-demo token keepalive enabled"
    ;;
  status) status_keepalive ;;
  disable) disable_keepalive ;;
  run) run_checks ;;
  *)
    echo "Usage: aap-demo credentials keepalive [enable|status|disable|run]" >&2
    exit 2
    ;;
esac
