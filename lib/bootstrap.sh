# Install missing apt packages, with a temporary local mirror as fallback.

: "${AETHER_BOOTSTRAP_DNS_1:=178.22.122.100}"
: "${AETHER_BOOTSTRAP_DNS_2:=185.51.200.2}"
: "${AETHER_BOOTSTRAP_UBUNTU_MIRROR:=http://mirror.arvancloud.ir/ubuntu}"
: "${AETHER_BOOTSTRAP_DEBIAN_MIRROR:=http://mirror.arvancloud.ir/debian}"

distro_id() {
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s' "${ID:-unknown}"
}

distro_codename() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    linuxmint|pop)
      printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      ;;
    *)
      printf '%s' "${VERSION_CODENAME:-}"
      ;;
  esac
}

debian_family() {
  [[ -f /etc/debian_version ]] && command -v apt-get >/dev/null 2>&1
}

apt_family_mirror() {
  case "$(distro_id)" in
    debian)
      printf '%s' "$AETHER_BOOTSTRAP_DEBIAN_MIRROR"
      ;;
    *)
      printf '%s' "$AETHER_BOOTSTRAP_UBUNTU_MIRROR"
      ;;
  esac
}

_backup_network() {
  local dest="$1"
  mkdir -p "$dest"
  if [[ -L /etc/resolv.conf ]]; then
    readlink /etc/resolv.conf > "$dest/resolv.link"
  elif [[ -e /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "$dest/resolv.conf"
    printf 'file\n' > "$dest/resolv.marker"
  else
    printf 'absent\n' > "$dest/resolv.marker"
  fi
  if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "$dest/sources.list"
  else
    printf 'absent\n' > "$dest/sources.absent"
  fi
  if [[ -d /etc/apt/sources.list.d ]]; then
    tar -C /etc/apt -czf "$dest/sources.list.d.tar.gz" sources.list.d
  fi
}

_restore_network() {
  local dest="$1"
  [[ -d "$dest" ]] || return 0
  rm -f /etc/resolv.conf
  if [[ -f "$dest/resolv.link" ]]; then
    ln -s "$(cat "$dest/resolv.link")" /etc/resolv.conf
  elif [[ -f "$dest/resolv.marker" ]] && grep -qx 'file' "$dest/resolv.marker"; then
    cp -a "$dest/resolv.conf" /etc/resolv.conf
  fi
  if [[ -f "$dest/sources.list" ]]; then
    cp -a "$dest/sources.list" /etc/apt/sources.list
  else
    rm -f /etc/apt/sources.list
  fi
  rm -rf /etc/apt/sources.list.d
  if [[ -f "$dest/sources.list.d.tar.gz" ]]; then
    tar -C /etc/apt -xzf "$dest/sources.list.d.tar.gz"
  else
    mkdir -p /etc/apt/sources.list.d
  fi
}

_apply_bootstrap_network() {
  local codename mirror
  codename="$(distro_codename)"
  if [[ -z "$codename" ]]; then
    ui_err "Could not detect the distribution codename."
    return 1
  fi
  mirror="$(apt_family_mirror)"
  cat > /etc/resolv.conf <<EOF
nameserver ${AETHER_BOOTSTRAP_DNS_1}
nameserver ${AETHER_BOOTSTRAP_DNS_2}
options timeout:2 attempts:2
EOF
  mkdir -p /etc/apt/sources.list.d
  rm -rf /etc/apt/sources.list.d
  mkdir -p /etc/apt/sources.list.d
  if [[ "$(distro_id)" == "debian" ]]; then
    cat > /etc/apt/sources.list <<EOF
deb ${mirror} ${codename} main contrib non-free
deb ${mirror} ${codename}-updates main contrib non-free
deb ${mirror}-security ${codename}-security main contrib non-free
EOF
  else
    cat > /etc/apt/sources.list <<EOF
deb ${mirror} ${codename} main restricted universe multiverse
deb ${mirror} ${codename}-updates main restricted universe multiverse
deb ${mirror} ${codename}-backports main restricted universe multiverse
deb ${mirror} ${codename}-security main restricted universe multiverse
EOF
  fi
}

apt_options() {
  printf '%s\n' \
    -o Acquire::Retries=2 \
    -o Acquire::http::Timeout=20 \
    -o Acquire::https::Timeout=20
}

install_packages() {
  debian_family || {
    ui_err "These packages need apt. Install them, then run Aether again: $*"
    return 1
  }
  local -a opts
  # shellcheck disable=SC2207
  opts=($(apt_options))
  export DEBIAN_FRONTEND=noninteractive
  if apt-get "${opts[@]}" update && apt-get "${opts[@]}" install -y "$@"; then
    return 0
  fi

  ui_warn "Direct apt did not succeed. Trying a temporary local mirror."
  local session
  session="$(mktemp -d)"
  _backup_network "$session"
  local rc=0
  if _apply_bootstrap_network; then
    apt-get "${opts[@]}" update || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      apt-get "${opts[@]}" install -y "$@" || rc=$?
    fi
  else
    rc=1
  fi
  _restore_network "$session" || true
  rm -rf "$session"
  if [[ "$rc" -ne 0 ]]; then
    ui_err "Could not install: $*"
    return 1
  fi
  ui_ok "Packages installed."
}
