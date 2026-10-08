# Interactive menus.

draw_header() {
  load_config
  ui_clear
  local uplink scope hint state_word state_color
  uplink="$(uplink_label)"
  scope="$(scope_label)"
  hint="$(scope_hint)"
  if [[ "${AETHER_ENABLED}" != "1" ]]; then
    state_word="disabled"
    state_color="$C_YELLOW"
  elif service_active; then
    state_word="running"
    state_color="$C_GREEN"
  else
    state_word="stopped"
    state_color="$C_RED"
  fi

  printf '\n'
  printf '  %s%sAETHER%s   %suplink control%s   %sv%s%s\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET" \
    "$C_DIM" "$C_RESET" \
    "$C_DIM" "${AETHER_VERSION}" "$C_RESET"
  ui_rule 58
  printf '\n'
  printf '  %s%-12s%s%s\n' "$C_DIM" "uplink" "$C_RESET" "$uplink"
  printf '  %s%-12s%s%s:%s   %s%s%s\n' \
    "$C_DIM" "endpoint" "$C_RESET" \
    "$AETHER_LISTEN_HOST" "${AETHER_LISTEN_PORT}" \
    "$state_color" "$state_word" "$C_RESET"
  printf '  %s%-12s%s%s%s%s\n' "$C_DIM" "scope" "$C_RESET" "$C_BOLD" "$scope" "$C_RESET"
  printf '\n  %s%s%s\n\n' "$C_DIM" "$hint" "$C_RESET"
}

uplink_menu() {
  while true; do
    draw_header
    ui_title "Uplink"
    ui_info "Paste a share link, or enter an HTTP or SOCKS proxy."
    printf '\n'
    ui_item "1" "Paste a link" "VLESS, VMess, Trojan, Shadowsocks, HTTP, SOCKS"
    ui_item "2" "HTTP proxy" "Host, port, optional login"
    ui_item "3" "SOCKS proxy" "SOCKS5 host and port"
    ui_item "0" "Back" ""
    local choice
    choice="$(ui_choose)" || return 0
    case "$choice" in
      1)
        local link
        link="$(ui_ask "Link: ")"
        configure_from_link "$link" || true
        ui_pause
        ;;
      2)
        if prompt_basic_proxy http; then
          configure_from_link "$AETHER_INPUT_LINK" || true
        fi
        ui_pause
        ;;
      3)
        if prompt_basic_proxy socks5; then
          configure_from_link "$AETHER_INPUT_LINK" || true
        fi
        ui_pause
        ;;
      0) return 0 ;;
      *) ui_invalid ;;
    esac
  done
}

packages_menu() {
  while true; do
    draw_header
    ui_title "Packages"
    ui_item "1" "Update lists" "apt-get update"
    ui_item "2" "Upgrade" "apt-get upgrade"
    ui_item "3" "Install" "One package"
    ui_item "0" "Back" ""
    local choice
    choice="$(ui_choose)" || return 0
    case "$choice" in
      1) update_packages || true; ui_pause ;;
      2) upgrade_packages || true; ui_pause ;;
      3) install_one_package || true; ui_pause ;;
      0) return 0 ;;
      *) ui_invalid ;;
    esac
  done
}

docker_menu() {
  while true; do
    load_config
    draw_header
    ui_title "Docker"
    local toggle="Enable proxy"
    docker_access_enabled && toggle="Disable proxy"
    ui_item "1" "Install" "Docker Engine and Compose"
    ui_item "2" "Check access" "Pull hello-world"
    ui_item "3" "Pull image" "Any image name"
    ui_item "4" "$toggle" "Daemon registry access"
    ui_item "0" "Back" ""
    local choice
    choice="$(ui_choose)" || return 0
    case "$choice" in
      1) install_docker || true; ui_pause ;;
      2) check_docker_access || true; ui_pause ;;
      3) pull_docker_image || true; ui_pause ;;
      4)
        if docker_access_enabled; then
          if ui_confirm "Disable the Docker proxy and restore previous settings?" y; then
            restore_docker || true
            ui_ok "Docker proxy disabled."
          else
            ui_info "Canceled."
          fi
        else
          configure_docker_access || true
        fi
        ui_pause
        ;;
      0) return 0 ;;
      *) ui_invalid ;;
    esac
  done
}

download_menu() {
  draw_header
  ui_title "Download"
  download_file || true
  ui_pause
}

panels_menu() {
  while true; do
    draw_header
    ui_title "VPN panels"
    ui_item "1" "3x-ui" "Sanaei, official installer"
    ui_item "0" "Back" ""
    local choice
    choice="$(ui_choose)" || return 0
    case "$choice" in
      1) install_3xui_menu || true ;;
      0) return 0 ;;
      *) ui_invalid ;;
    esac
  done
}

install_3xui_menu() {
  draw_header
  ui_title "3x-ui"
  ensure_runtime || { ui_pause; return 1; }
  ui_info "Fetching releases..."
  local file
  file="$(mktemp)"
  if ! fetch_3xui_releases > "$file"; then
    rm -f "$file"
    ui_err "Could not fetch 3x-ui releases from GitHub."
    ui_pause
    return 1
  fi
  local -a tags=() labels=()
  local tag label count=0
  while IFS=$'\t' read -r tag label; do
    [[ -n "$tag" ]] || continue
    tags+=("$tag")
    labels+=("$label")
    count=$((count + 1))
    if (( count >= 15 )); then
      break
    fi
  done < "$file"
  rm -f "$file"
  if (( count == 0 )); then
    ui_err "No compatible 3x-ui release was found."
    ui_pause
    return 1
  fi
  printf '\n'
  local i
  for i in "${!labels[@]}"; do
    printf '  %s%2d%s  %s\n' "$C_CYAN" "$((i + 1))" "$C_RESET" "${labels[$i]}"
  done
  printf '  %s 0%s  Back\n' "$C_CYAN" "$C_RESET"
  local choice
  choice="$(ui_choose)" || return 0
  if [[ "$choice" == "0" ]]; then
    return 0
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then
    ui_invalid
    return 1
  fi
  local selected="${tags[$((choice - 1))]}"
  printf '\n'
  ui_info "This runs the official 3x-ui installer through the uplink."
  if ui_confirm "Install 3x-ui ${selected} now?" n; then
    install_3xui_version "$selected" || true
  else
    ui_info "Canceled."
  fi
  ui_pause
}

scope_menu() {
  while true; do
    draw_header
    ui_title "Traffic scope"
    ui_item "1" "Application" "Only programs launched through Aether"
    ui_item "2" "System proxy" "Programs that honor the system proxy"
    ui_item "3" "Full tunnel" "All server traffic"
    ui_item "0" "Back" ""
    local choice
    choice="$(ui_choose)" || return 0
    case "$choice" in
      1) set_scope tool || true; ui_pause ;;
      2) set_scope system || true; ui_pause ;;
      3) set_scope tunnel || true; ui_pause ;;
      0) return 0 ;;
      *) ui_invalid ;;
    esac
  done
}

uninstall_menu() {
  draw_header
  ui_title "Uninstall"
  if ! ui_confirm "Remove Aether from this server?" n; then
    ui_info "Canceled."
    ui_pause
    return 0
  fi
  local -a args=()
  if ! ui_confirm "Restore Docker and system proxy settings first?" y; then
    args+=(--no-restore)
  fi
  if ui_confirm "Also remove saved settings, logs, and backups?" y; then
    args+=(--purge)
  fi
  local uninstaller="${AETHER_ROOT}/uninstall.sh"
  if [[ ! -f "$uninstaller" ]]; then
    uninstaller="${AETHER_LIB}/uninstall.sh"
  fi
  if [[ -f "$uninstaller" ]]; then
    bash "$uninstaller" "${args[@]}"
    exit 0
  fi
  ui_err "Uninstaller not found."
  ui_pause
}

settings_menu() {
  while true; do
    load_config
    draw_header
    ui_title "Settings"
    local toggle="Enable Aether"
    [[ "${AETHER_ENABLED}" == "1" ]] && toggle="Disable Aether"
    ui_item "1" "Status" "Uplink, scope, Docker"
    ui_item "2" "Change uplink" "Replace the saved link"
    ui_item "3" "$toggle" ""
    ui_item "4" "Auto-restore" "What happens on disable"
    ui_item "5" "Reset uplink" "Forget the saved link"
    ui_item "6" "Uninstall" "Remove Aether"
    ui_item "7" "Update" "Download the latest Aether"
    ui_item "0" "Back" ""
    local choice
    choice="$(ui_choose)" || return 0
    case "$choice" in
      1) draw_header; ui_title "Status"; show_status; ui_pause ;;
      2) uplink_menu ;;
      3)
        if [[ "${AETHER_ENABLED}" == "1" ]]; then
          disable_access
        else
          enable_access
        fi
        ui_pause
        ;;
      4) toggle_restore; ui_pause ;;
      5) reset_uplink; ui_pause ;;
      6) uninstall_menu ;;
      7) update_aether || true; ui_pause ;;
      0) return 0 ;;
      *) ui_invalid ;;
    esac
  done
}

main_menu() {
  require_root
  require_linux
  load_config
  if ! has_link; then
    draw_header
    ui_title "Welcome"
    ui_info "Aether needs one uplink. Bring your own proxy or share link."
    ui_info "Nothing is published to the system until you choose a scope."
    printf '\n'
    uplink_menu || true
  fi
  while true; do
    draw_header
    ui_item "1" "Check" "GitHub, Ubuntu, Docker"
    ui_item "2" "Packages" "Update, upgrade, install"
    ui_item "3" "Docker" "Install, pull, registry access"
    ui_item "4" "Download" "Save a file through the uplink"
    ui_item "5" "VPN panels" "Install 3x-ui"
    ui_item "6" "Traffic scope" "Application, system proxy, full tunnel"
    ui_item "7" "Settings" "Uplink, enable, uninstall"
    ui_item "8" "Update" "Download the latest Aether"
    ui_item "0" "Exit" ""
    local choice
    choice="$(ui_choose)" || exit 0
    case "$choice" in
      1) draw_header; ui_title "Check"; check_connection || true; ui_pause ;;
      2) packages_menu ;;
      3) docker_menu ;;
      4) download_menu ;;
      5) panels_menu ;;
      6) scope_menu ;;
      7) settings_menu ;;
      8) update_aether || true; ui_pause ;;
      0) exit 0 ;;
      *) ui_invalid ;;
    esac
  done
}
