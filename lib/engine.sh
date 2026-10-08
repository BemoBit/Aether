# sing-box lifecycle, traffic scope, and command routing.

singbox_bin() {
  if [[ -n "${AETHER_ROOT:-}" && -x "${AETHER_ROOT}/bin/sing-box" ]]; then
    printf '%s' "${AETHER_ROOT}/bin/sing-box"
    return 0
  fi
  if [[ -x "${AETHER_LIB}/sing-box" ]]; then
    printf '%s' "${AETHER_LIB}/sing-box"
    return 0
  fi
  if command -v sing-box >/dev/null 2>&1; then
    command -v sing-box
    return 0
  fi
  return 1
}

service_active() {
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$AETHER_SERVICE"
}

port_free() {
  python3 - "$1" <<'PY'
import socket
import sys

sock = socket.socket()
try:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

choose_port() {
  local current="${AETHER_LISTEN_PORT:-$AETHER_DEFAULT_PORT}"
  if ! validate_port "$current"; then
    current="$AETHER_DEFAULT_PORT"
  fi
  if port_free "$current" || service_active; then
    AETHER_LISTEN_PORT="$current"
    return 0
  fi
  local candidate
  for candidate in 2080 2081 2082 2083 2084 2085 2086 2087 2088 2089 2090; do
    if port_free "$candidate"; then
      AETHER_LISTEN_PORT="$candidate"
      save_config
      ui_info "Port ${current} is busy. The local endpoint will use ${candidate}."
      return 0
    fi
  done
  ui_err "No free local port from 2080 to 2090."
  return 1
}

ssh_client_ip() {
  local raw="${SSH_CONNECTION:-}"
  [[ -n "$raw" ]] || return 1
  printf '%s' "${raw%% *}"
}

systemd_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '%s' "$value"
}

render_config() {
  local redirect="${1:-yes}"
  local -a args
  args=(
    python3 "$AETHER_LINK_PY" render
    --link "$AETHER_LINK"
    --out "$AETHER_SINGBOX_CONF"
    --port "$AETHER_LISTEN_PORT"
    --scope "$AETHER_SCOPE"
  )
  if [[ "$AETHER_SCOPE" == "tunnel" ]]; then
    local ip=""
    ip="$(ssh_client_ip || true)"
    if [[ -n "$ip" ]]; then
      args+=(--protect-ip "$ip")
    fi
    if [[ "$redirect" == "no" ]]; then
      args+=(--no-auto-redirect)
    fi
  fi
  "${args[@]}"
}

write_unit() {
  local bin="$1"
  local bin_esc conf_esc
  bin_esc="$(systemd_escape "$bin")"
  conf_esc="$(systemd_escape "$AETHER_SINGBOX_CONF")"
  cat > "$AETHER_UNIT" <<EOF
[Unit]
Description=Aether uplink
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin_esc} run -c ${conf_esc}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$AETHER_UNIT"
}

stop_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$AETHER_SERVICE" >/dev/null 2>&1 || true
    rm -f "$AETHER_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

verify_local_bind() {
  local quiet="${1:-}"
  if ! python3 - "$AETHER_LISTEN_PORT" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.create_connection(("127.0.0.1", port), 2)
sock.close()
PY
  then
    [[ "$quiet" == "quiet" ]] || ui_err "The local endpoint is not accepting connections."
    return 1
  fi
  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi
  local exposed
  exposed="$(ss -ltnH "sport = :${AETHER_LISTEN_PORT}" 2>/dev/null | awk '{ print $4 }' || true)"
  if printf '%s\n' "$exposed" | grep -Eq '^(0\.0\.0\.0|\*|\[::\]):'; then
    [[ "$quiet" == "quiet" ]] || ui_err "The local endpoint is listening on a public address. Stopping it."
    systemctl stop "$AETHER_SERVICE" >/dev/null 2>&1 || true
    return 1
  fi
}

_env_strip() {
  python3 - "$AETHER_ENV_FILE" "$AETHER_ENV_BEGIN" "$AETHER_ENV_END" <<'PY'
import sys

path, begin, end = sys.argv[1:]
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    raise SystemExit
lines = text.splitlines()
kept = []
skipping = False
for line in lines:
    if line.strip() == begin:
        skipping = True
        continue
    if line.strip() == end:
        skipping = False
        continue
    if not skipping:
        kept.append(line)
while kept and kept[-1] == "":
    kept.pop()
payload = ("\n".join(kept) + "\n") if kept else ""
temporary = path + ".aether.tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    handle.write(payload)
import os
os.replace(temporary, path)
PY
}

clear_system_proxy() {
  rm -f "$AETHER_PROFILE" "$AETHER_APT"
  _env_strip || true
}

install_system_proxy() {
  local endpoint="http://${AETHER_LISTEN_HOST}:${AETHER_LISTEN_PORT}"
  local socks="socks5h://${AETHER_LISTEN_HOST}:${AETHER_LISTEN_PORT}"
  cat > "$AETHER_PROFILE" <<EOF
# Managed by Aether. Deleted when the scope is not "system proxy".
export http_proxy="${endpoint}"
export https_proxy="${endpoint}"
export all_proxy="${socks}"
export no_proxy="${AETHER_NO_PROXY}"
export HTTP_PROXY="${endpoint}"
export HTTPS_PROXY="${endpoint}"
export ALL_PROXY="${socks}"
export NO_PROXY="${AETHER_NO_PROXY}"
EOF
  chmod 644 "$AETHER_PROFILE"
  cat > "$AETHER_APT" <<EOF
Acquire::http::Proxy "${endpoint}";
Acquire::https::Proxy "${endpoint}";
EOF
  chmod 644 "$AETHER_APT"
  python3 - "$AETHER_ENV_FILE" "$AETHER_ENV_BEGIN" "$AETHER_ENV_END" "$endpoint" "$socks" "$AETHER_NO_PROXY" <<'PY'
import os
import sys

path, begin, end, http, socks, no_proxy = sys.argv[1:]
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = ""
kept = []
skipping = False
for line in text.splitlines():
    if line.strip() == begin:
        skipping = True
        continue
    if line.strip() == end:
        skipping = False
        continue
    if not skipping:
        kept.append(line)
while kept and kept[-1] == "":
    kept.pop()
block = [
    begin,
    f"http_proxy={http}",
    f"https_proxy={http}",
    f"all_proxy={socks}",
    f"no_proxy={no_proxy}",
    f"HTTP_PROXY={http}",
    f"HTTPS_PROXY={http}",
    f"ALL_PROXY={socks}",
    f"NO_PROXY={no_proxy}",
    end,
]
if kept:
    kept.append("")
kept.extend(block)
temporary = path + ".aether.tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    handle.write("\n".join(kept) + "\n")
os.replace(temporary, path)
PY
}

write_proxychains() {
  cat > "$AETHER_PROXYCHAINS" <<EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

localnet 127.0.0.0/255.0.0.0
localnet 10.0.0.0/255.0.0.0
localnet 172.16.0.0/255.240.0.0
localnet 192.168.0.0/255.255.0.0

[ProxyList]
http ${AETHER_LISTEN_HOST} ${AETHER_LISTEN_PORT}
EOF
  chmod 600 "$AETHER_PROXYCHAINS"
}

_start_service() {
  local redirect="$1"
  local bin="$2"
  render_config "$redirect" || return 1
  if ! "$bin" check -c "$AETHER_SINGBOX_CONF"; then
    ui_err "sing-box rejected the generated config."
    return 1
  fi
  write_unit "$bin"
  systemctl daemon-reload
  systemctl enable "$AETHER_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$AETHER_SERVICE"
}

apply_runtime() {
  load_config
  if [[ "${AETHER_ENABLED}" != "1" ]]; then
    stop_service
    clear_system_proxy
    return 0
  fi
  if ! has_link; then
    ui_err "No uplink is configured."
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    install_packages python3 curl ca-certificates || return 1
  fi
  local bin=""
  if ! bin="$(singbox_bin)"; then
    ui_err "sing-box is missing. Re-run the installer, or place the binary at ${AETHER_LIB}/sing-box."
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    ui_err "systemd is required to keep the uplink running."
    return 1
  fi
  choose_port || return 1
  local redirect="yes"
  if [[ "$AETHER_SCOPE" == "tunnel" && ! -x "$(command -v nft || true)" ]]; then
    ui_warn "nftables is missing, so the full tunnel will start without auto-redirect."
    redirect="no"
  fi
  if ! _start_service "$redirect" "$bin"; then
    if [[ "$AETHER_SCOPE" == "tunnel" && "$redirect" == "yes" ]]; then
      ui_warn "Retrying the full tunnel without nftables redirect."
      if ! _start_service no "$bin"; then
        ui_err "The uplink service did not start."
        journalctl -u "$AETHER_SERVICE" -n 30 --no-pager || true
        return 1
      fi
    else
      ui_err "The uplink service did not start."
      journalctl -u "$AETHER_SERVICE" -n 30 --no-pager || true
      return 1
    fi
  fi
  sleep 0.5
  verify_local_bind || return 1
  if [[ "$AETHER_SCOPE" == "tunnel" ]]; then
    if ! ip link show aether0 >/dev/null 2>&1; then
      ui_err "The tunnel interface aether0 did not come up."
      return 1
    fi
    clear_system_proxy || true
  elif [[ "$AETHER_SCOPE" == "system" ]]; then
    install_system_proxy || return 1
  else
    clear_system_proxy || true
  fi
  write_proxychains || return 1
  log_msg "runtime applied scope=${AETHER_SCOPE} port=${AETHER_LISTEN_PORT}"
}

ensure_runtime() {
  load_config
  if [[ "${AETHER_ENABLED}" != "1" ]] || ! has_link; then
    ui_err "Configure and enable an uplink first."
    return 1
  fi
  if service_active && verify_local_bind quiet; then
    case "$AETHER_SCOPE" in
      system)
        [[ -f "$AETHER_PROFILE" && -f "$AETHER_APT" ]] && return 0
        ;;
      tunnel)
        ip link show aether0 >/dev/null 2>&1 && return 0
        ;;
      *)
        [[ ! -f "$AETHER_PROFILE" && ! -f "$AETHER_APT" ]] && return 0
        ;;
    esac
  fi
  apply_runtime
}

exec_with_proxy_env() {
  local endpoint="http://${AETHER_LISTEN_HOST}:${AETHER_LISTEN_PORT}"
  local socks="socks5h://${AETHER_LISTEN_HOST}:${AETHER_LISTEN_PORT}"
  env \
    http_proxy="$endpoint" \
    https_proxy="$endpoint" \
    HTTP_PROXY="$endpoint" \
    HTTPS_PROXY="$endpoint" \
    all_proxy="$socks" \
    ALL_PROXY="$socks" \
    no_proxy="${AETHER_NO_PROXY}" \
    NO_PROXY="${AETHER_NO_PROXY}" \
    "$@"
}

run_with_env() {
  ensure_runtime || return 1
  if [[ "$AETHER_SCOPE" == "tunnel" ]]; then
    "$@"
    return
  fi
  exec_with_proxy_env "$@"
}

run_forced() {
  ensure_runtime || return 1
  if [[ "$AETHER_SCOPE" == "tunnel" ]]; then
    "$@"
    return
  fi
  write_proxychains
  if command -v proxychains4 >/dev/null 2>&1; then
    env -u http_proxy -u https_proxy -u all_proxy -u ftp_proxy \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u FTP_PROXY \
      proxychains4 -q -f "$AETHER_PROXYCHAINS" "$@"
    return
  fi
  ui_warn "proxychains4 is not installed. Falling back to proxy environment variables."
  exec_with_proxy_env "$@"
}

endpoint_label() {
  local state="stopped"
  if [[ "${AETHER_ENABLED}" != "1" ]]; then
    state="disabled"
  elif service_active; then
    state="running"
  fi
  printf '%s:%s  %s' "$AETHER_LISTEN_HOST" "${AETHER_LISTEN_PORT:-$AETHER_DEFAULT_PORT}" "$state"
}

uplink_label() {
  if ! has_link; then
    printf 'not configured'
    return 0
  fi
  local summary=""
  if ! summary="$(python3 "$AETHER_LINK_PY" parse --link "$AETHER_LINK" --json 2>/dev/null)"; then
    printf 'saved link could not be read'
    return 0
  fi
  printf '%s' "$summary" | python3 -c '
import json, sys
meta = json.load(sys.stdin)
parts = [meta.get("kind") or "uplink"]
security = meta.get("security") or "none"
transport = meta.get("transport") or "-"
if security not in ("", "none"):
    parts.append(security)
if transport not in ("", "-"):
    parts.append(transport)
name = meta.get("name") or ""
label = "/".join(parts) + "  " + str(meta.get("server")) + ":" + str(meta.get("port"))
if name:
    label += "  " + name
print(label)
'
}
