#!/usr/bin/env bash
# Remove Aether. Safe to run from the installed copy or a git checkout.
set -euo pipefail

resolve_root() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="${dir}/${src}"
  done
  cd "$(dirname "$src")" && pwd
}

AETHER_ROOT="$(resolve_root)"
# shellcheck disable=SC1091
. "${AETHER_ROOT}/versions.env"
# shellcheck disable=SC1091
. "${AETHER_ROOT}/lib/ui.sh"
# shellcheck disable=SC1091
. "${AETHER_ROOT}/lib/config.sh"
# shellcheck disable=SC1091
. "${AETHER_ROOT}/lib/bootstrap.sh"
# shellcheck disable=SC1091
. "${AETHER_ROOT}/lib/engine.sh"
# shellcheck disable=SC1091
. "${AETHER_ROOT}/lib/actions.sh"

usage() {
  cat <<EOF
Usage: sudo bash uninstall.sh [--no-restore] [--purge]

  --no-restore   Leave Docker daemon.json and system proxy files in place
  --purge        Also remove /etc/aether, /var/lib/aether, and the log
EOF
}

main() {
  require_root
  local restore="yes"
  local purge="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-restore) restore="no" ;;
      --purge) purge="yes" ;;
      --help|-h) usage; exit 0 ;;
      *) ui_err "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done

  if [[ -f "$AETHER_CONFIG_FILE" ]]; then
    load_config
    AETHER_ENABLED=0
    save_config
  fi
  stop_service || true

  if [[ "$restore" == "yes" ]]; then
    clear_system_proxy || true
    restore_docker || true
  else
    ui_warn "System proxy files and Docker settings were left in place."
  fi

  rm -f /usr/local/bin/aether
  if [[ -L /usr/local/bin/ae ]]; then
    local target
    target="$(readlink /usr/local/bin/ae || true)"
    case "$target" in
      /usr/local/bin/aether|*/aether) rm -f /usr/local/bin/ae ;;
    esac
  fi

  if [[ "$purge" == "yes" ]]; then
    rm -rf "$AETHER_CONFIG_DIR" "$AETHER_STATE_DIR" "$AETHER_LOG"
  fi

  # The running script may live in this directory. Bash has already read it.
  rm -rf /usr/local/lib/aether

  ui_ok "Aether is uninstalled."
  if [[ "$purge" != "yes" ]]; then
    ui_info "Saved settings were kept. Run uninstall.sh --purge to remove them."
  fi
}

main "$@"
