# Shared terminal helpers. Sourced by the Aether entrypoint.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_CYAN=$'\033[96m'
  C_GREEN=$'\033[92m'
  C_YELLOW=$'\033[93m'
  C_RED=$'\033[91m'
  C_WHITE=$'\033[97m'
  C_BLUE=$'\033[94m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_WHITE=""
  C_BLUE=""
fi

if [[ "$(locale charmap 2>/dev/null || true)" == "UTF-8" ]]; then
  UI_RULE='─'
else
  UI_RULE='-'
fi

: "${AETHER_LOG:=/var/log/aether.log}"

log_msg() {
  mkdir -p "$(dirname "$AETHER_LOG")" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$AETHER_LOG" 2>/dev/null || true
}

ui_ok() {
  printf '  %s%s%s\n' "$C_GREEN" "$*" "$C_RESET"
  log_msg "ok: $*"
}

ui_warn() {
  printf '  %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"
  log_msg "warn: $*"
}

ui_err() {
  printf '  %s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2
  log_msg "error: $*"
}

ui_info() {
  printf '  %s\n' "$*"
}

ui_rule() {
  local width="${1:-58}"
  local line="" i
  for ((i = 0; i < width; i++)); do
    line+="$UI_RULE"
  done
  printf '  %s%s%s\n' "$C_BLUE" "$line" "$C_RESET"
}

ui_title() {
  printf '  %s%s%s%s\n\n' "$C_BOLD" "$C_WHITE" "$1" "$C_RESET"
}

ui_item() {
  local key="$1"
  local label="$2"
  local hint="${3:-}"
  printf '  %s%s%s%s%s%s  %-20s' \
    "$C_CYAN" "[" "$C_BOLD$C_WHITE" "$key" "$C_RESET" "$C_CYAN]" \
    "$label"
  if [[ -n "$hint" ]]; then
    printf '%s%s%s' "$C_DIM" "$hint" "$C_RESET"
  fi
  printf '\n'
}

ui_clear() {
  if [[ -t 1 ]]; then
    printf '\033[H\033[2J'
  fi
}

ui_pause() {
  [[ -t 0 ]] || return 0
  printf '\n  %sPress Enter%s ' "$C_DIM" "$C_RESET"
  read -r _ || true
}

ui_choose() {
  local choice=""
  # The prompt must stay off stdout. Callers capture this function, and a
  # prompt on stdout used to be read back as the menu choice.
  printf '\n  %s›%s ' "$C_CYAN" "$C_RESET" >&2
  if ! read -r choice; then
    return 1
  fi
  choice="${choice//$'\r'/}"
  choice="$(trim "$choice")"
  printf '%s' "$choice"
}

ui_invalid() {
  ui_warn "That option is not in the menu."
  ui_pause
}

ui_ask() {
  local prompt="$1"
  local _reply=""
  read -rp "  ${prompt}" _reply || true
  _reply="${_reply//$'\r'/}"
  printf '%s' "$(trim "$_reply")"
}

ui_confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local reply
  if [[ ! -t 0 ]]; then
    [[ "$default" == "y" ]]
    return
  fi
  if [[ "$default" == "y" ]]; then
    reply="$(ui_ask "${prompt} [Y/n] ")"
    case "${reply:-Y}" in
      n|N|no|NO) return 1 ;;
      *) return 0 ;;
    esac
  fi
  reply="$(ui_ask "${prompt} [y/N] ")"
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    ui_err "Run Aether as root: sudo aether"
    exit 1
  fi
}

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    ui_err "Aether controls Linux networking. Run it on the server."
    exit 1
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 )) || return 1
}
