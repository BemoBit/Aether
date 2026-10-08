# Package, Docker, download, panel, and settings actions.

backup_docker_once() {
  mkdir -p "${AETHER_BASELINE}/docker"
  if [[ ! -f "${AETHER_BASELINE}/docker/daemon.marker" ]]; then
    if [[ -f /etc/docker/daemon.json ]]; then
      cp -a /etc/docker/daemon.json "${AETHER_BASELINE}/docker/daemon.json"
      printf 'file\n' > "${AETHER_BASELINE}/docker/daemon.marker"
    else
      printf 'absent\n' > "${AETHER_BASELINE}/docker/daemon.marker"
    fi
  fi
  if [[ ! -f "${AETHER_BASELINE}/docker/systemd.marker" ]]; then
    if [[ -f "$AETHER_DOCKER_DROPIN" ]]; then
      cp -a "$AETHER_DOCKER_DROPIN" "${AETHER_BASELINE}/docker/systemd-proxy.conf"
      printf 'file\n' > "${AETHER_BASELINE}/docker/systemd.marker"
    else
      printf 'absent\n' > "${AETHER_BASELINE}/docker/systemd.marker"
    fi
  fi
}

restore_docker() {
  local marker="${AETHER_BASELINE}/docker/daemon.marker"
  local changed=0
  if [[ -f "$marker" || -f "$AETHER_DOCKER_DROPIN" ]]; then
    changed=1
  fi
  if [[ -f "$marker" ]]; then
    mkdir -p /etc/docker
    if grep -qx 'file' "$marker"; then
      cp -a "${AETHER_BASELINE}/docker/daemon.json" /etc/docker/daemon.json
    else
      rm -f /etc/docker/daemon.json
    fi
  fi
  if [[ -f "${AETHER_BASELINE}/docker/systemd.marker" ]] && grep -qx 'file' "${AETHER_BASELINE}/docker/systemd.marker"; then
    mkdir -p "$(dirname "$AETHER_DOCKER_DROPIN")"
    cp -a "${AETHER_BASELINE}/docker/systemd-proxy.conf" "$AETHER_DOCKER_DROPIN"
  else
    rm -f "$AETHER_DOCKER_DROPIN"
  fi
  if [[ "$changed" -eq 1 ]] && command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files docker.service >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart docker >/dev/null 2>&1 || true
  fi
  AETHER_DOCKER=0
  save_config
}

docker_installed() {
  command -v docker >/dev/null 2>&1
}

configure_docker_access() {
  load_config
  has_link || { ui_err "Configure an uplink first."; return 1; }
  docker_installed || { ui_err "Docker is not installed."; return 1; }
  ensure_runtime || return 1
  if [[ "$AETHER_SCOPE" == "tunnel" ]]; then
    ui_info "Full tunnel already covers Docker. Daemon proxy settings were left unchanged."
    return 0
  fi
  backup_docker_once
  mkdir -p /etc/docker "$(dirname "$AETHER_DOCKER_DROPIN")"
  local endpoint="http://${AETHER_LISTEN_HOST}:${AETHER_LISTEN_PORT}"
  if ! python3 - "$endpoint" "$AETHER_NO_PROXY" <<'PY'
import json
import os
import sys

path = "/etc/docker/daemon.json"
proxy, no_proxy = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, encoding="utf-8") as handle:
        cfg = json.load(handle)
cfg["proxies"] = {
    "http-proxy": proxy,
    "https-proxy": proxy,
    "no-proxy": no_proxy,
}
temporary = path + ".aether.tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2)
    handle.write("\n")
os.replace(temporary, path)
PY
  then
    ui_err "Could not update /etc/docker/daemon.json."
    return 1
  fi
  local proxy_esc no_esc
  proxy_esc="$(systemd_escape "$endpoint")"
  no_esc="$(systemd_escape "$AETHER_NO_PROXY")"
  cat > "$AETHER_DOCKER_DROPIN" <<EOF
[Service]
Environment="HTTP_PROXY=${proxy_esc}"
Environment="HTTPS_PROXY=${proxy_esc}"
Environment="NO_PROXY=${no_esc}"
Environment="http_proxy=${proxy_esc}"
Environment="https_proxy=${proxy_esc}"
Environment="no_proxy=${no_esc}"
EOF
  chmod 644 "$AETHER_DOCKER_DROPIN"
  systemctl daemon-reload || true
  if ! systemctl restart docker; then
    ui_err "Docker did not restart. Restoring the previous Docker settings."
    restore_docker || true
    return 1
  fi
  AETHER_DOCKER=1
  save_config
  ui_ok "Docker will pull images through the uplink."
}

docker_access_enabled() {
  load_config
  [[ "${AETHER_DOCKER}" == "1" || -f "$AETHER_DOCKER_DROPIN" ]]
}

require_apt() {
  debian_family || {
    ui_err "Package actions need apt (Debian or Ubuntu)."
    return 1
  }
}

probe_url() {
  local label="$1"
  local url="$2"
  local how="$3"
  local code
  printf '  %-18s' "$label"
  if [[ "$how" == "proxy" ]]; then
    code="$(curl -L -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 25 \
      -x "http://${AETHER_LISTEN_HOST}:${AETHER_LISTEN_PORT}" "$url" 2>/dev/null || printf '000')"
  else
    code="$(curl -L -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 25 \
      "$url" 2>/dev/null || printf '000')"
  fi
  if [[ "$code" != "000" ]]; then
    printf '%sreachable (%s)%s\n' "$C_GREEN" "$code" "$C_RESET"
    return 0
  fi
  printf '%sfailed%s\n' "$C_RED" "$C_RESET"
  return 1
}

check_connection() {
  ensure_runtime || return 1
  command -v curl >/dev/null 2>&1 || {
    ui_err "curl is required for the connection check."
    return 1
  }
  ui_info "Uplink"
  probe_url "General HTTPS" "$AETHER_TEST_GENERAL" proxy || true
  probe_url "Ubuntu archive" "$AETHER_TEST_UBUNTU" proxy || true
  probe_url "GitHub" "$AETHER_TEST_GITHUB" proxy || true
  probe_url "Docker registry" "$AETHER_TEST_DOCKER" proxy || true
  if [[ "$AETHER_SCOPE" == "tunnel" ]]; then
    printf '\n'
    ui_info "System route"
    probe_url "General HTTPS" "$AETHER_TEST_GENERAL" direct || true
    probe_url "GitHub" "$AETHER_TEST_GITHUB" direct || true
  fi
}

configure_from_link() {
  local link
  link="$(trim "${1:-}")"
  if [[ -z "$link" ]]; then
    ui_err "Uplink cannot be empty."
    return 1
  fi
  if ! python3 "$AETHER_LINK_PY" parse --link "$link" --json >/dev/null; then
    return 1
  fi
  load_config
  local old_link="${AETHER_LINK}"
  local old_enabled="${AETHER_ENABLED}"
  local old_scope="${AETHER_SCOPE}"
  local old_port="${AETHER_LISTEN_PORT}"
  AETHER_LINK="$link"
  AETHER_ENABLED=1
  save_config
  if apply_runtime; then
    ui_ok "Uplink is active."
    check_connection || true
    return 0
  fi
  AETHER_LINK="$old_link"
  AETHER_ENABLED="$old_enabled"
  AETHER_SCOPE="$old_scope"
  AETHER_LISTEN_PORT="$old_port"
  save_config
  if ! apply_runtime; then
    ui_err "That uplink could not be applied, and the previous one could not be restored either."
    return 1
  fi
  ui_err "That uplink could not be applied. Previous settings were restored."
  return 1
}

prompt_basic_proxy() {
  local scheme="$1"
  local host="" port="" user="" pass="" auth=""
  host="$(trim "$(ui_ask "Host: ")")"
  if [[ -z "$host" ]]; then
    ui_err "Host cannot be empty."
    return 1
  fi
  if [[ "$host" == *:* ]]; then
    ui_err "For an IPv6 host, paste the full link instead."
    return 1
  fi
  port="$(trim "$(ui_ask "Port: ")")"
  if ! validate_port "$port"; then
    ui_err "Port must be between 1 and 65535."
    return 1
  fi
  user="$(ui_ask "Username (optional): ")"
  if [[ -n "$user" ]]; then
    read -rsp "  Password: " pass || true
    printf '\n'
    auth="$(python3 -c 'import urllib.parse, sys; print("%s:%s@" % (urllib.parse.quote(sys.argv[1], safe=""), urllib.parse.quote(sys.argv[2], safe="")))' "$user" "$pass")"
  fi
  AETHER_INPUT_LINK="${scheme}://${auth}${host}:${port}"
}

update_packages() {
  require_apt || return 1
  ui_info "Updating package lists..."
  if run_with_env apt-get update; then
    ui_ok "Package lists updated."
  else
    ui_err "Update failed."
    return 1
  fi
}

upgrade_packages() {
  require_apt || return 1
  ui_info "Upgrading installed packages..."
  if run_with_env apt-get upgrade -y; then
    ui_ok "Upgrade finished."
  else
    ui_err "Upgrade failed."
    return 1
  fi
}

install_one_package() {
  require_apt || return 1
  local pkg
  pkg="$(trim "$(ui_ask "Package name: ")")"
  if [[ ! "$pkg" =~ ^[A-Za-z0-9][A-Za-z0-9.+:_-]*$ ]]; then
    ui_err "That package name is not valid."
    return 1
  fi
  if run_with_env apt-get install -y "$pkg"; then
    ui_ok "Installed ${pkg}."
  else
    ui_err "Could not install ${pkg}."
    return 1
  fi
}

download_file() {
  local url out
  url="$(trim "$(ui_ask "File URL: ")")"
  out="$(trim "$(ui_ask "Save as: ")")"
  if [[ -z "$url" || -z "$out" ]]; then
    ui_err "A URL and a save path are required."
    return 1
  fi
  case "$url" in
    http://*|https://*) ;;
    *) ui_err "The URL must start with http:// or https://."; return 1 ;;
  esac
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  if run_with_env curl -L --fail --retry 2 --progress-bar -o "$out" "$url"; then
    ui_ok "Saved ${out}."
  else
    ui_err "Download failed."
    return 1
  fi
}

install_docker() {
  require_apt || return 1
  ensure_runtime || return 1
  if docker_installed; then
    ui_ok "Docker is already installed."
    configure_docker_access || true
    return 0
  fi
  ui_info "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  local id codename arch repo
  id="$(distro_id)"
  codename="$(distro_codename)"
  arch="$(dpkg --print-architecture)"
  case "$id" in
    debian) repo="debian" ;;
    ubuntu|linuxmint|pop) repo="ubuntu" ;;
    *)
      ui_err "Docker's apt repository is set up for Debian and Ubuntu."
      return 1
      ;;
  esac
  if [[ -z "$codename" || -z "$arch" ]]; then
    ui_err "Could not detect the distribution codename or architecture."
    return 1
  fi
  if ! run_with_env curl -fsSL "https://download.docker.com/linux/${repo}/gpg" -o /etc/apt/keyrings/docker.asc; then
    ui_err "Could not download the Docker signing key."
    return 1
  fi
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$repo" "$codename" > /etc/apt/sources.list.d/docker.list
  if run_with_env apt-get update && run_with_env apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    configure_docker_access || true
    ui_ok "Docker is installed."
  else
    ui_err "Docker installation failed."
    return 1
  fi
}

check_docker_access() {
  docker_installed || { ui_err "Docker is not installed."; return 1; }
  if [[ "$AETHER_SCOPE" != "tunnel" ]]; then
    configure_docker_access || return 1
  else
    ensure_runtime || return 1
  fi
  ui_info "Pulling hello-world:latest..."
  if docker pull hello-world:latest; then
    ui_ok "Docker can reach the registry."
  else
    ui_err "Docker could not pull hello-world:latest."
    return 1
  fi
}

pull_docker_image() {
  docker_installed || { ui_err "Docker is not installed."; return 1; }
  if [[ "$AETHER_SCOPE" != "tunnel" ]]; then
    configure_docker_access || return 1
  else
    ensure_runtime || return 1
  fi
  local image
  image="$(trim "$(ui_ask "Image (example: nginx:latest): ")")"
  if [[ -z "$image" ]]; then
    ui_err "An image name is required."
    return 1
  fi
  if docker pull "$image"; then
    ui_ok "Pulled ${image}."
  else
    ui_err "Could not pull ${image}."
    return 1
  fi
}

fetch_3xui_releases() {
  local page url payload
  local tmp
  tmp="$(mktemp)"
  : > "$tmp"
  for page in 1 2; do
    url="${AETHER_3XUI_API}?per_page=100&page=${page}"
    payload="$(run_with_env curl -fsSL -A "aether/${AETHER_VERSION}" --connect-timeout 20 --max-time 60 "$url")" || {
      rm -f "$tmp"
      return 1
    }
    printf '%s' "$payload" | python3 -c '
import json, re, sys
def version_tuple(tag):
    nums = [int(item) for item in re.findall(r"\d+", tag or "")][:3]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if not isinstance(data, list):
    raise SystemExit(1)
for item in data:
    if item.get("draft"):
        continue
    tag = item.get("tag_name") or ""
    if not tag or version_tuple(tag) < (2, 3, 5):
        continue
    published = item.get("published_at") or item.get("created_at") or ""
    prerelease = "1" if item.get("prerelease") else "0"
    print(f"{published}\t{tag}\t{prerelease}")
' >> "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  done
  python3 - "$tmp" <<'PY'
import sys
items = []
seen = set()
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        published, tag, prerelease = line.split("\t", 2)
        if tag in seen:
            continue
        seen.add(tag)
        items.append((published, tag, prerelease == "1"))
items.sort(key=lambda item: item[0], reverse=True)
for _published, tag, prerelease in items:
    label = tag + (" (pre-release)" if prerelease else "")
    print(f"{tag}\t{label}")
PY
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

install_3xui_version() {
  local version="$1"
  local tmp installer
  tmp="$(mktemp -d)"
  installer="${tmp}/install.sh"
  ui_info "Downloading the official 3x-ui installer..."
  if ! run_with_env curl -fsSL --connect-timeout 20 --max-time 60 -o "$installer" "$AETHER_3XUI_INSTALLER"; then
    rm -rf "$tmp"
    ui_err "Could not download the 3x-ui installer."
    return 1
  fi
  chmod 700 "$installer"
  ui_info "Running the installer for ${version}..."
  run_forced bash "$installer" "$version"
  local rc=$?
  rm -rf "$tmp"
  if [[ "$rc" -eq 0 ]]; then
    ui_ok "3x-ui ${version} installer finished."
  else
    ui_err "3x-ui ${version} installer failed."
  fi
  return "$rc"
}

enable_access() {
  load_config
  if ! has_link; then
    ui_err "Set an uplink before enabling Aether."
    return 1
  fi
  AETHER_ENABLED=1
  save_config
  if apply_runtime; then
    ui_ok "Aether is enabled."
    return 0
  fi
  AETHER_ENABLED=0
  save_config
  apply_runtime || true
  ui_err "Aether could not be enabled."
  return 1
}

disable_access() {
  load_config
  AETHER_ENABLED=0
  save_config
  apply_runtime || true
  local restore="${AETHER_AUTO_RESTORE:-1}"
  if [[ "$restore" == "1" ]] && ! ui_confirm "Restore Docker proxy settings too?" y; then
    restore=0
  fi
  if [[ "$restore" == "1" ]]; then
    restore_docker || true
    ui_ok "Aether is disabled and Docker proxy settings were restored."
  else
    ui_ok "Aether is disabled. Docker proxy settings were kept."
  fi
}

toggle_restore() {
  load_config
  if ui_confirm "Restore related settings when Aether is disabled?" y; then
    AETHER_AUTO_RESTORE=1
  else
    AETHER_AUTO_RESTORE=0
  fi
  save_config
  ui_ok "Auto-restore is $([[ "$AETHER_AUTO_RESTORE" == "1" ]] && printf 'on' || printf 'off')."
}

reset_uplink() {
  if ! ui_confirm "Remove the saved uplink?" n; then
    ui_info "Canceled."
    return 0
  fi
  load_config
  AETHER_ENABLED=0
  AETHER_LINK=""
  save_config
  apply_runtime || true
  rm -f "$AETHER_SINGBOX_CONF" "$AETHER_PROXYCHAINS"
  ui_ok "Saved uplink removed. Docker settings were not changed."
}

confirm_tunnel() {
  ui_warn "Full tunnel sends all server traffic through the uplink."
  local ip=""
  ip="$(ssh_client_ip || true)"
  if [[ -n "$ip" ]]; then
    ui_info "This SSH client (${ip}) keeps a direct route."
  else
    ui_warn "No SSH client was detected. Use a console the first time you try this."
  fi
  ui_info "If the server becomes unreachable, from the console run: aether scope tool"
  if [[ ! -t 0 && "${AETHER_ASSUME_YES:-}" != "1" ]]; then
    ui_err "Refusing to enable the full tunnel without confirmation. Set AETHER_ASSUME_YES=1 to proceed."
    return 1
  fi
  ui_confirm "Enable full tunnel now?" n
}

set_scope() {
  local requested="$1"
  load_config
  local previous="${AETHER_SCOPE}"
  case "$requested" in
    tool|application|app) AETHER_SCOPE="tool" ;;
    system|proxy) AETHER_SCOPE="system" ;;
    tunnel|full)
      confirm_tunnel || return 1
      AETHER_SCOPE="tunnel"
      ;;
    *)
      ui_err "Scope must be tool, system, or tunnel."
      return 1
      ;;
  esac
  save_config
  if [[ "$AETHER_ENABLED" == "1" ]]; then
    if ! apply_runtime; then
      AETHER_SCOPE="$previous"
      save_config
      if ! apply_runtime; then
        ui_err "Could not apply that scope, and restoring the previous one also failed."
        return 1
      fi
      ui_err "Could not apply that scope. The previous scope was restored."
      return 1
    fi
  else
    ui_info "Scope saved. It takes effect when Aether is enabled."
  fi
  ui_ok "Scope is now $(scope_label)."
}

update_aether() {
  local url="https://raw.githubusercontent.com/BemoBit/Aether/${AETHER_REPO_REF:-main}/install.sh"
  local tmp rc=0
  tmp="$(mktemp)"
  ui_info "Downloading the latest Aether installer..."
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL --connect-timeout 20 --max-time 90 -o "$tmp" "$url"; then
      if [[ "${AETHER_ENABLED:-0}" == "1" ]] && has_link; then
        ui_info "Direct download failed. Retrying through the uplink."
        ensure_runtime || { rm -f "$tmp"; return 1; }
        exec_with_proxy_env curl -fsSL --connect-timeout 20 --max-time 90 -o "$tmp" "$url" || rc=$?
      else
        rc=1
      fi
    fi
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || rc=$?
  else
    ui_err "curl or wget is required to update Aether."
    rm -f "$tmp"
    return 1
  fi
  if [[ "$rc" -ne 0 || ! -s "$tmp" ]]; then
    ui_err "Could not download the update."
    rm -f "$tmp"
    return 1
  fi
  ui_info "Installing the update. Saved uplinks are kept."
  bash "$tmp" || rc=$?
  rm -f "$tmp"
  if [[ "$rc" -ne 0 ]]; then
    ui_err "Update failed."
    return 1
  fi
  ui_ok "Aether was updated."
  ui_info "Open it again with: sudo aether"
  exit 0
}

show_status() {
  load_config
  local engine docker_state restore_state tunnel_state proxy_files
  engine="$(endpoint_label)"
  if docker_installed; then
    docker_state="installed"
  else
    docker_state="not installed"
  fi
  if docker_access_enabled; then
    docker_state="${docker_state}, proxy on"
  else
    docker_state="${docker_state}, proxy off"
  fi
  if [[ "${AETHER_AUTO_RESTORE}" == "1" ]]; then
    restore_state="on"
  else
    restore_state="off"
  fi
  if ip link show aether0 >/dev/null 2>&1; then
    tunnel_state="up"
  else
    tunnel_state="down"
  fi
  if [[ -f "$AETHER_PROFILE" ]]; then
    proxy_files="published"
  else
    proxy_files="not published"
  fi
  ui_info "Version          ${AETHER_VERSION}"
  ui_info "State            $([[ "$AETHER_ENABLED" == "1" ]] && printf 'enabled' || printf 'disabled')"
  ui_info "Uplink           $(uplink_label)"
  ui_info "Endpoint         ${engine}"
  ui_info "Scope            $(scope_label)"
  ui_info "System proxy     ${proxy_files}"
  ui_info "Tunnel           ${tunnel_state}"
  ui_info "Docker           ${docker_state}"
  ui_info "Auto-restore     ${restore_state}"
  ui_info "Config           ${AETHER_CONFIG_FILE}"
  ui_info "Log              ${AETHER_LOG}"
}
