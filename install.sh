#!/usr/bin/env bash
# Install Aether. From a git checkout this copies local files.
# After you publish, the one-liner below downloads the same tree.
set -euo pipefail

# Remote installs download the rest of the tree from this repository.
AETHER_REPO_SLUG="${AETHER_REPO_SLUG:-BemoBit/Aether}"
AETHER_REPO_REF="${AETHER_REPO_REF:-main}"

LIB_DIR="/usr/local/lib/aether"
BIN_LINK="/usr/local/bin/aether"
SHORT_LINK="/usr/local/bin/ae"
CONFIG_DIR="/etc/aether"
CONFIG_FILE="${CONFIG_DIR}/config.env"
STATE_DIR="/var/lib/aether"
TMP_DIR=""

trap '[[ -n "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"' EXIT

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf 'Run the installer as root: sudo bash install.sh\n' >&2
    exit 1
  fi
}

fetch() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    printf 'curl or wget is required to download files.\n' >&2
    return 1
  fi
}

local_source() {
  local src dir
  src="${BASH_SOURCE[0]}"
  if [[ "$src" == "bash" || "$src" == "-" || ! -f "$src" ]]; then
    return 1
  fi
  dir="$(cd "$(dirname "$src")" && pwd)"
  [[ -f "${dir}/aether" && -f "${dir}/lib/link.py" ]] || return 1
  printf '%s' "$dir"
}

download_source() {
  if [[ "$AETHER_REPO_SLUG" == "your-github-user/aether" ]]; then
    printf 'Set AETHER_REPO_SLUG to your GitHub repository before a remote install.\n' >&2
    return 1
  fi
  local base="https://raw.githubusercontent.com/${AETHER_REPO_SLUG}/${AETHER_REPO_REF}"
  local rel
  TMP_DIR="$(mktemp -d)"
  local -a files=(
    aether
    uninstall.sh
    versions.env
    config.example.env
    lib/ui.sh
    lib/config.sh
    lib/bootstrap.sh
    lib/engine.sh
    lib/actions.sh
    lib/menus.sh
    lib/link.py
  )
  for rel in "${files[@]}"; do
    mkdir -p "${TMP_DIR}/$(dirname "$rel")"
    printf 'Fetching %s\n' "$rel" >&2
    fetch "${base}/${rel}" "${TMP_DIR}/${rel}"
  done
  chmod 755 "${TMP_DIR}/aether" "${TMP_DIR}/uninstall.sh"
  printf '%s' "$TMP_DIR"
}

copy_tree() {
  local src="$1"
  local rel
  install -d -m 755 "${LIB_DIR}/lib"
  install -m 755 "${src}/aether" "${LIB_DIR}/aether"
  install -m 755 "${src}/uninstall.sh" "${LIB_DIR}/uninstall.sh"
  install -m 644 "${src}/versions.env" "${LIB_DIR}/versions.env"
  install -m 644 "${src}/config.example.env" "${LIB_DIR}/config.example.env"
  for rel in ui.sh config.sh bootstrap.sh engine.sh actions.sh menus.sh link.py; do
    install -m 644 "${src}/lib/${rel}" "${LIB_DIR}/lib/${rel}"
  done
  ln -sfn "${LIB_DIR}/aether" "$BIN_LINK"
  if [[ -e "$SHORT_LINK" && ! -L "$SHORT_LINK" ]]; then
    printf 'Left the existing %s command in place.\n' "$SHORT_LINK"
  else
    ln -sfn "$BIN_LINK" "$SHORT_LINK"
  fi
}

singbox_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

install_singbox() {
  local version arch url work archive extracted bin
  # shellcheck disable=SC1091
  . "${LIB_DIR}/versions.env"
  arch="$(singbox_arch)" || {
    printf 'Unsupported architecture for sing-box: %s\n' "$(uname -m)" >&2
    return 1
  }
  version="$SINGBOX_VERSION"
  if [[ -x "${LIB_DIR}/sing-box" ]]; then
    local have
    have="$("${LIB_DIR}/sing-box" version 2>/dev/null | awk '{ print $NF; exit }')"
    if [[ "$have" == "$version" ]]; then
      printf 'sing-box %s is already installed.\n' "$version"
      return 0
    fi
  fi
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
  work="$(mktemp -d)"
  archive="${work}/sing-box.tar.gz"
  printf 'Downloading sing-box %s for linux-%s\n' "$version" "$arch"
  if ! fetch "$url" "$archive"; then
    rm -rf "$work"
    printf 'Could not download sing-box.\nPlace the binary at %s/sing-box and run aether again.\n' "$LIB_DIR" >&2
    return 1
  fi
  extracted="${work}/extracted"
  mkdir -p "$extracted"
  tar -xzf "$archive" -C "$extracted"
  bin="$(find "$extracted" -type f -name sing-box -print -quit)"
  if [[ -z "$bin" ]]; then
    rm -rf "$work"
    printf 'The sing-box archive did not contain a binary.\n' >&2
    return 1
  fi
  install -m 755 "$bin" "${LIB_DIR}/sing-box"
  rm -rf "$work"
}

write_config() {
  install -d -m 700 "$CONFIG_DIR" "$STATE_DIR" "${STATE_DIR}/baseline"
  if [[ -f "$CONFIG_FILE" ]]; then
    return 0
  fi
  umask 077
  cat > "$CONFIG_FILE" <<'EOF'
AETHER_ENABLED=0
AETHER_SCOPE=tool
AETHER_LINK=
AETHER_LISTEN_PORT=2080
AETHER_AUTO_RESTORE=1
AETHER_DOCKER=0
AETHER_NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local
EOF
  chmod 600 "$CONFIG_FILE"
}

install_base_packages() {
  local src="$1"
  # shellcheck disable=SC1091
  . "${src}/lib/ui.sh"
  # shellcheck disable=SC1091
  . "${src}/lib/bootstrap.sh"
  if debian_family; then
    install_packages python3 curl ca-certificates iproute2 || return 1
    install_packages proxychains4 || install_packages proxychains || true
    install_packages nftables || true
  else
    printf 'This is not an apt distribution. Install python3, curl, and ca-certificates yourself.\n'
  fi
}

main() {
  require_root
  local src=""
  if ! src="$(local_source)"; then
    src="$(download_source)"
  fi
  copy_tree "$src"
  write_config
  install_base_packages "$src" || printf 'Base packages were not fully installed.\n' >&2
  install_singbox || true
  printf '\nAether is installed.\n'
  printf 'Run: sudo aether\n'
  printf 'Shortcut: sudo ae\n'
}

main "$@"
