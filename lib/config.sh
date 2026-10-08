# Paths and the on-disk config. Sourced by the Aether entrypoint.

: "${AETHER_ROOT:=/usr/local/lib/aether}"

AETHER_CONFIG_DIR="/etc/aether"
AETHER_CONFIG_FILE="${AETHER_CONFIG_DIR}/config.env"
AETHER_SINGBOX_CONF="${AETHER_CONFIG_DIR}/sing-box.json"
AETHER_PROXYCHAINS="${AETHER_CONFIG_DIR}/proxychains.conf"
AETHER_STATE_DIR="/var/lib/aether"
AETHER_BASELINE="${AETHER_STATE_DIR}/baseline"
AETHER_LIB="/usr/local/lib/aether"
AETHER_LINK_PY="${AETHER_ROOT}/lib/link.py"
AETHER_SERVICE="aether.service"
AETHER_UNIT="/etc/systemd/system/${AETHER_SERVICE}"
AETHER_DOCKER_DROPIN="/etc/systemd/system/docker.service.d/aether-proxy.conf"
AETHER_PROFILE="/etc/profile.d/aether.sh"
AETHER_APT="/etc/apt/apt.conf.d/80aether"
AETHER_ENV_FILE="/etc/environment"
AETHER_ENV_BEGIN="# BEGIN aether"
AETHER_ENV_END="# END aether"
AETHER_LISTEN_HOST="127.0.0.1"
AETHER_DEFAULT_PORT="2080"
AETHER_DEFAULT_NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local"
AETHER_TEST_GENERAL="${AETHER_TEST_GENERAL:-https://example.com}"
AETHER_TEST_UBUNTU="${AETHER_TEST_UBUNTU:-https://archive.ubuntu.com/ubuntu/}"
AETHER_TEST_GITHUB="${AETHER_TEST_GITHUB:-https://github.com}"
AETHER_TEST_DOCKER="${AETHER_TEST_DOCKER:-https://registry-1.docker.io/v2/}"
AETHER_3XUI_API="${AETHER_3XUI_API:-https://api.github.com/repos/MHSanaei/3x-ui/releases}"
AETHER_3XUI_INSTALLER="${AETHER_3XUI_INSTALLER:-https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh}"

AETHER_ENABLED=0
AETHER_SCOPE="tool"
AETHER_LINK=""
AETHER_LISTEN_PORT="$AETHER_DEFAULT_PORT"
AETHER_AUTO_RESTORE=1
AETHER_DOCKER=0
AETHER_NO_PROXY="$AETHER_DEFAULT_NO_PROXY"

ensure_dirs() {
  mkdir -p "$AETHER_CONFIG_DIR" "$AETHER_STATE_DIR" "$AETHER_BASELINE"
  chmod 700 "$AETHER_CONFIG_DIR" "$AETHER_STATE_DIR" "$AETHER_BASELINE" 2>/dev/null || true
}

create_default_config() {
  [[ -f "$AETHER_CONFIG_FILE" ]] && return 0
  ensure_dirs
  umask 077
  cat > "$AETHER_CONFIG_FILE" <<EOF
AETHER_ENABLED=0
AETHER_SCOPE=tool
AETHER_LINK=
AETHER_LISTEN_PORT=${AETHER_DEFAULT_PORT}
AETHER_AUTO_RESTORE=1
AETHER_DOCKER=0
AETHER_NO_PROXY=${AETHER_DEFAULT_NO_PROXY}
EOF
  chmod 600 "$AETHER_CONFIG_FILE"
}

load_config() {
  ensure_dirs
  create_default_config
  # shellcheck disable=SC1090
  . "$AETHER_CONFIG_FILE"
  AETHER_ENABLED="${AETHER_ENABLED:-0}"
  AETHER_SCOPE="${AETHER_SCOPE:-tool}"
  AETHER_LINK="${AETHER_LINK:-}"
  AETHER_LISTEN_PORT="${AETHER_LISTEN_PORT:-$AETHER_DEFAULT_PORT}"
  AETHER_AUTO_RESTORE="${AETHER_AUTO_RESTORE:-1}"
  AETHER_DOCKER="${AETHER_DOCKER:-0}"
  AETHER_NO_PROXY="${AETHER_NO_PROXY:-$AETHER_DEFAULT_NO_PROXY}"
  case "$AETHER_SCOPE" in
    tool|system|tunnel) ;;
    *) AETHER_SCOPE="tool" ;;
  esac
}

save_config() {
  ensure_dirs
  local tmp
  tmp="$(mktemp "${AETHER_CONFIG_DIR}/config.XXXXXX")"
  {
    printf 'AETHER_ENABLED=%q\n' "${AETHER_ENABLED:-0}"
    printf 'AETHER_SCOPE=%q\n' "${AETHER_SCOPE:-tool}"
    printf 'AETHER_LINK=%q\n' "${AETHER_LINK:-}"
    printf 'AETHER_LISTEN_PORT=%q\n' "${AETHER_LISTEN_PORT:-$AETHER_DEFAULT_PORT}"
    printf 'AETHER_AUTO_RESTORE=%q\n' "${AETHER_AUTO_RESTORE:-1}"
    printf 'AETHER_DOCKER=%q\n' "${AETHER_DOCKER:-0}"
    printf 'AETHER_NO_PROXY=%q\n' "${AETHER_NO_PROXY:-$AETHER_DEFAULT_NO_PROXY}"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$AETHER_CONFIG_FILE"
}

has_link() {
  [[ -n "${AETHER_LINK:-}" ]]
}

scope_label() {
  case "${AETHER_SCOPE:-tool}" in
    system) printf 'system proxy' ;;
    tunnel) printf 'full tunnel' ;;
    *) printf 'application' ;;
  esac
}

scope_hint() {
  case "${AETHER_SCOPE:-tool}" in
    system) printf 'Programs that honor the system proxy use the uplink.' ;;
    tunnel) printf 'All server traffic uses the uplink.' ;;
    *) printf 'Only programs launched through Aether use the uplink.' ;;
  esac
}
