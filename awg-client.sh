#!/usr/bin/env bash
set -euo pipefail

# ========= SETTINGS (AmneziaWG) =========
AWG_DIR="/etc/amnezia/amneziawg"
AWG_PARAMS="${AWG_DIR}/params"
AWG_CLIENT_DIR="${AWG_DIR}/clients"
# =======================================

# ======= Colors / UI =======
is_tty() { [[ -t 1 ]]; }

c_reset=$'\033[0m'
c_dim=$'\033[2m'
c_bold=$'\033[1m'
c_red=$'\033[31m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_blue=$'\033[34m'
c_cyan=$'\033[36m'

if ! is_tty; then
  c_reset=""; c_dim=""; c_bold=""; c_red=""; c_green=""; c_yellow=""; c_blue=""; c_cyan=""
fi

ui_hr() { echo "${c_dim}------------------------------------------------------------${c_reset}"; }
ui_h1() { echo "${c_bold}${c_cyan}$*${c_reset}"; }
ui_ok() { echo "${c_green}OK:${c_reset} $*"; }
ui_warn() { echo "${c_yellow}WARN:${c_reset} $*"; }
ui_info() { echo "${c_blue}INFO:${c_reset} $*"; }
ui_err() { echo "${c_red}ERROR:${c_reset} $*" >&2; }
die() { ui_err "$*"; exit 1; }
# ===========================

need_root() { [[ ${EUID} -eq 0 ]] || die "Run as root (e.g., sudo awg-client ...)."; }

ensure_prereqs() {
  [[ -f "$AWG_PARAMS" ]] || die "Params not found: $AWG_PARAMS (install AmneziaWG using amneziawg-install.sh first)."

  # shellcheck disable=SC1090
  source "$AWG_PARAMS"

  : "${SERVER_AWG_NIC:?missing SERVER_AWG_NIC in params}"
  : "${SERVER_AWG_IPV4:?missing SERVER_AWG_IPV4 in params}"
  : "${SERVER_AWG_IPV6:?missing SERVER_AWG_IPV6 in params}"
  : "${SERVER_PORT:?missing SERVER_PORT in params}"
  : "${SERVER_PUB_IP:?missing SERVER_PUB_IP in params}"
  : "${SERVER_PUB_KEY:?missing SERVER_PUB_KEY in params}"
  : "${CLIENT_DNS_1:?missing CLIENT_DNS_1 in params}"
  : "${CLIENT_DNS_2:?missing CLIENT_DNS_2 in params}"
  : "${ALLOWED_IPS:?missing ALLOWED_IPS in params}"
  : "${SERVER_AWG_JC:?missing SERVER_AWG_JC in params}"
  : "${SERVER_AWG_JMIN:?missing SERVER_AWG_JMIN in params}"
  : "${SERVER_AWG_JMAX:?missing SERVER_AWG_JMAX in params}"
  : "${SERVER_AWG_S1:?missing SERVER_AWG_S1 in params}"
  : "${SERVER_AWG_S2:?missing SERVER_AWG_S2 in params}"
  : "${SERVER_AWG_H1:?missing SERVER_AWG_H1 in params}"
  : "${SERVER_AWG_H2:?missing SERVER_AWG_H2 in params}"
  : "${SERVER_AWG_H3:?missing SERVER_AWG_H3 in params}"
  : "${SERVER_AWG_H4:?missing SERVER_AWG_H4 in params}"

  AWG_CONF="${AWG_DIR}/${SERVER_AWG_NIC}.conf"
  [[ -f "$AWG_CONF" ]] || die "Server config not found: $AWG_CONF"

  command -v awg >/dev/null 2>&1 || die "Command 'awg' not found. Install: sudo apt install -y amneziawg amneziawg-tools"
  command -v awg-quick >/dev/null 2>&1 || die "Command 'awg-quick' not found (should be provided by amneziawg-tools)."
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found."
}

valid_name() {
  local n="$1"
  [[ -n "$n" ]] || die "Client name is empty."
  [[ "$n" != -* ]] || die "Client name cannot start with '-'."
  [[ "$n" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid client name. Use letters/numbers/._- only."
  ((${#n} <= 15)) || die "Client name is too long (max 15 chars)."
}

ensure_dirs() {
  mkdir -p "$AWG_CLIENT_DIR"
  chmod 700 "$AWG_CLIENT_DIR"
}

detect_lan_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true
}

default_export_user() {
  echo "${SUDO_USER:-kolandor}"
}

base_ipv4_prefix() {
  # From 10.66.66.1 -> 10.66.66
  echo "$SERVER_AWG_IPV4" | awk -F'.' '{print $1"."$2"."$3}'
}

base_ipv6_prefix() {
  # From fd42:42:42::1 -> fd42:42:42
  echo "$SERVER_AWG_IPV6" | awk -F'::' '{print $1}'
}

next_dot_ip() {
  # Find next free X in [2..254] by checking existing AllowedIPs entries in server config.
  local dot
  for dot in {2..254}; do
    if ! grep -q -F "$(base_ipv4_prefix).${dot}/32" "$AWG_CONF"; then
      echo "$dot"
      return 0
    fi
  done
  die "No free client IPv4 addresses left in $(base_ipv4_prefix).0/24"
}

client_conf_path() {
  local name="$1"
  echo "${AWG_CLIENT_DIR}/client-${name}.conf"
}

# Apply config changes reliably.
# First try syncconf (no restart). If it fails, fallback to systemd restart.
apply_changes() {
  ui_info "Applying changes to interface ${SERVER_AWG_NIC} ..."

  local tmp="/root/awg-strip.$$.$RANDOM.conf"

  # Redirection must happen in a shell
  if sh -c "awg-quick strip '${SERVER_AWG_NIC}' > '${tmp}'" 2>/dev/null; then
    if awg syncconf "${SERVER_AWG_NIC}" "${tmp}" 2>/dev/null; then
      rm -f "${tmp}" || true
      ui_ok "Changes applied via awg syncconf."
      return 0
    fi
  fi

  rm -f "${tmp}" 2>/dev/null || true
  ui_warn "syncconf failed; falling back to systemd restart (awg-quick@${SERVER_AWG_NIC})."
  systemctl restart "awg-quick@${SERVER_AWG_NIC}"
  ui_ok "Service restarted."
}

# Маркер для exported temp files (чтобы clean удалял безопасно)
export_marker_line() {
  echo "# Exported by awg-client"
}

# Создаём экспорт в home и помечаем файлы маркером
export_to_home() {
  local name="$1"
  local user="$2"
  local conf_src="$3"

  local home_dir
  home_dir="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$home_dir" && -d "$home_dir" ]] || die "Home directory not found for user: $user"

  local dst="${home_dir}/client-${name}.conf"

  {
    export_marker_line
    cat "$conf_src"
  } > "$dst"

  chown "${user}:${user}" "$dst"
  chmod 600 "$dst"

  local lan_ip
  lan_ip="$(detect_lan_ip)"
  [[ -n "$lan_ip" ]] || lan_ip="<server_lan_ip>"

  ui_ok "Exported to ${dst}"
  echo
  ui_info "Windows PowerShell (download):"
  echo "  scp ${user}@${lan_ip}:client-${name}.conf \".\\client-${name}.conf\""
  echo
  ui_info "Optional cleanup on server (or use: sudo awg-client clean):"
  echo "  rm -f ${dst}"
}

help_text() {
  ensure_prereqs
  local lan_ip
  lan_ip="$(detect_lan_ip)"
  [[ -n "$lan_ip" ]] || lan_ip="<server_lan_ip>"

  ui_h1 "awg-client — AmneziaWG client manager"
  ui_hr
  echo "Server:"
  echo "  Interface: ${SERVER_AWG_NIC}"
  echo "  Config:    ${AWG_CONF}"
  echo "  Params:    ${AWG_PARAMS}"
  echo "  Endpoint:  ${SERVER_PUB_IP}:${SERVER_PORT}"
  ui_hr

  echo "${c_bold}Usage:${c_reset}"
  echo "  sudo awg-client ${c_green}<command>${c_reset} [options]"
  echo

  echo "${c_bold}Commands:${c_reset}"
  echo "  ${c_green}add${c_reset} ${c_dim}<name>${c_reset} [--split ${c_dim}<LAN_CIDR>${c_reset}] [--home [${c_dim}user${c_reset}]]"
  echo "      Create a new client and add it to the server config."
  echo "      Default is full-tunnel (client routes everything through VPN)."
  echo "      Options:"
  echo "        --split <LAN_CIDR>   Split-tunnel: route VPN subnets + your LAN via VPN."
  echo "        --home [user]       Also export a copy to /home/<user>/client-<name>.conf"
  echo "                            (marked so 'clean' can remove it safely)."
  echo

  echo "  ${c_green}list${c_reset}"
  echo "      List managed clients (configs found in ${AWG_CLIENT_DIR})."
  echo

  echo "  ${c_green}show${c_reset} ${c_dim}<name>${c_reset}"
  echo "      Print the client config to stdout and show a QR code (if qrencode is installed)."
  echo

  echo "  ${c_green}export${c_reset} ${c_dim}<name>${c_reset} [${c_dim}user${c_reset}]"
  echo "      Export config to /home/<user>/client-<name>.conf (marked for safe cleanup)."
  echo

  echo "  ${c_green}delete${c_reset} ${c_dim}<name>${c_reset}"
  echo "      Delete a managed client: remove peer block from server config + delete local config file."
  echo

  echo "  ${c_green}clean${c_reset} [--dry-run] [--yes]"
  echo "      Cleanup helper:"
  echo "        1) Remove exported temp files in /home/* and /root that were created by this script"
  echo "           (only files with a marker '# Exported by awg-client')."
  echo "        2) Remove unmanaged peers from server config:"
  echo "           peers that exist in server config but have NO matching file in ${AWG_CLIENT_DIR}."
  echo "        3) Remove orphan local configs:"
  echo "           files in ${AWG_CLIENT_DIR} that have NO matching marker in server config."
  echo "      Options:"
  echo "        --dry-run   Show what would be removed, without changing anything."
  echo "        --yes       Do not ask for confirmation."
  echo

  echo "  ${c_green}restore${c_reset} [list] | ${c_dim}<N|backup-file>${c_reset} [--dry-run] [--yes]"
  echo "      Restore server config from a backup file."
  echo "      - 'restore' or 'restore list' shows available backups."
  echo "      - 'restore <N>' restores by number from the list."
  echo "      - 'restore <backup-file>' restores by exact filename."
  echo "      Options:"
  echo "        --dry-run   Show what would be restored, without changing anything."
  echo "        --yes       Do not ask for confirmation."
  echo

  echo "  ${c_green}maint${c_reset} [--dry-run] [--yes] [--reboot]"
  echo "      Perform server maintenance (Ubuntu/Debian):"
  echo "        - apt update"
  echo "        - apt full-upgrade -y"
  echo "        - apt autoremove -y"
  echo "        - apt autoclean -y"
  echo "      Options:"
  echo "        --dry-run   Show what would be executed, without changing anything."
  echo "        --yes       Do not ask for confirmation."
  echo "        --reboot    Reboot at the end (recommended if /var/run/reboot-required exists)."
  echo

  echo "  ${c_green}reload${c_reset}"
  echo "      Reload AmneziaWG-related resources:"
  echo "        - sysctl --system"
  echo "        - restart awg-quick@<iface>"
  echo "        - restart netfilter-persistent (if present)"
  echo "        - show awg status"
  echo

  ui_hr
  echo "${c_bold}Download example (Windows PowerShell):${c_reset}"
  echo "  scp <user>@${lan_ip}:client-<name>.conf \".\\client-<name>.conf\""
}

cmd_add() {
  need_root
  ensure_prereqs
  ensure_dirs

  [[ $# -ge 1 ]] || die "Usage: sudo awg-client add <name> [--split <LAN_CIDR>] [--home [user]]"
  local name="$1"; shift
  valid_name "$name"

  local mode="full"
  local lan_cidr=""
  local do_home="no"
  local home_user=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --split)
        mode="split"
        lan_cidr="${2:-}"
        [[ -n "$lan_cidr" ]] || die "--split requires LAN_CIDR (e.g., 192.168.1.0/24)."
        shift 2
        ;;
      --home)
        do_home="yes"
        # optional user
        if [[ "${2:-}" =~ ^[a-z_][a-z0-9_-]*$ ]] && getent passwd "${2:-}" >/dev/null 2>&1; then
          home_user="$2"
          shift 2
        else
          home_user="$(default_export_user)"
          shift 1
        fi
        ;;
      -h|--help) help_text; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  # Prevent duplicates by marker in server config (installer format)
  if grep -q -E "^### Client ${name}\$" "$AWG_CONF"; then
    die "Client '${name}' already exists in server config: $AWG_CONF"
  fi

  local conf_file
  conf_file="$(client_conf_path "$name")"
  [[ ! -e "$conf_file" ]] || die "Client config already exists: $conf_file"

  local dot client_ipv4 client_ipv6
  dot="$(next_dot_ip)"
  client_ipv4="$(base_ipv4_prefix).${dot}"
  client_ipv6="$(base_ipv6_prefix)::${dot}"

  umask 077

  # Client keys + PSK (same commands as installer)
  local client_priv client_pub psk
  client_priv="$(awg genkey)"
  client_pub="$(echo "$client_priv" | awg pubkey)"
  psk="$(awg genpsk)"

  local endpoint="${SERVER_PUB_IP}:${SERVER_PORT}"

  local allowed_ips_client
  if [[ "$mode" == "full" ]]; then
    allowed_ips_client="${ALLOWED_IPS}"
  else
    # Split: route VPN subnets + LAN via VPN
    allowed_ips_client="$(base_ipv4_prefix).0/24, $(base_ipv6_prefix)::/64, ${lan_cidr}"
  fi

  ui_h1 "Creating client: ${name}"
  ui_hr
  ui_info "IPv4: ${client_ipv4}/32"
  ui_info "IPv6: ${client_ipv6}/128"
  ui_info "Endpoint: ${endpoint}"
  ui_info "Mode: ${mode}"
  ui_hr

  # Write client config (includes Amnezia parameters in [Interface])
  cat >"$conf_file" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${client_ipv4}/32,${client_ipv6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}
Jc = ${SERVER_AWG_JC}
Jmin = ${SERVER_AWG_JMIN}
Jmax = ${SERVER_AWG_JMAX}
S1 = ${SERVER_AWG_S1}
S2 = ${SERVER_AWG_S2}
H1 = ${SERVER_AWG_H1}
H2 = ${SERVER_AWG_H2}
H3 = ${SERVER_AWG_H3}
H4 = ${SERVER_AWG_H4}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${psk}
Endpoint = ${endpoint}
AllowedIPs = ${allowed_ips_client}
PersistentKeepalive = 25
EOF

  chmod 600 "$conf_file"

  # Add peer to server config with installer-compatible marker
  cat >>"$AWG_CONF" <<EOF

### Client ${name}
[Peer]
PublicKey = ${client_pub}
PresharedKey = ${psk}
AllowedIPs = ${client_ipv4}/32,${client_ipv6}/128

EOF

  apply_changes

  ui_ok "Client created: ${name}"
  ui_info "Config stored (root-only): ${conf_file}"

  if [[ "$do_home" == "yes" ]]; then
    echo
    ui_info "Exporting a copy to user's home: ${home_user}"
    export_to_home "$name" "$home_user" "$conf_file"
  else
    echo
    ui_info "Tip: sudo awg-client show ${name}"
    ui_info "Tip: sudo awg-client export ${name}"
  fi
}

cmd_list() {
  need_root
  ensure_prereqs
  ensure_dirs

  shopt -s nullglob
  local files=( "$AWG_CLIENT_DIR"/client-*.conf )
  shopt -u nullglob

  ui_h1 "Managed clients (configs found in ${AWG_CLIENT_DIR})"
  ui_hr

  if [[ ${#files[@]} -eq 0 ]]; then
    ui_warn "No client config files found."
    ui_info "Server markers in ${AWG_CONF}:"
    grep -E "^### Client " "$AWG_CONF" || true
    return 0
  fi

  for f in "${files[@]}"; do
    local base name addr
    base="$(basename "$f")"
    name="${base#client-}"
    name="${name%.conf}"
    addr="$(grep -m1 -E '^Address[[:space:]]*=' "$f" | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}' || true)"
    printf "  ${c_green}%-15s${c_reset}  %-45s  ${c_dim}%s${c_reset}\n" "$name" "${addr:-unknown}" "$f"
  done
}

cmd_show() {
  need_root
  ensure_prereqs
  ensure_dirs

  [[ $# -ge 1 ]] || die "Usage: sudo awg-client show <name>"
  local name="$1"
  valid_name "$name"

  local conf_file
  conf_file="$(client_conf_path "$name")"
  [[ -f "$conf_file" ]] || die "Config not found: $conf_file"

  ui_h1 "Client config: ${name}"
  ui_hr
  cat "$conf_file"
  ui_hr

  if command -v qrencode >/dev/null 2>&1; then
    ui_info "QR (scan in Amnezia app):"
    qrencode -t ansiutf8 -l L < "$conf_file"
  else
    ui_warn "qrencode is not installed."
    ui_info "Install it to show QR codes: sudo apt install -y qrencode"
  fi
}

cmd_export() {
  need_root
  ensure_prereqs
  ensure_dirs

  [[ $# -ge 1 ]] || die "Usage: sudo awg-client export <name> [user]"
  local name="$1"; shift
  valid_name "$name"

  local user="${1:-$(default_export_user)}"
  [[ -n "$user" ]] || die "Export user is empty."

  local conf_src
  conf_src="$(client_conf_path "$name")"
  [[ -f "$conf_src" ]] || die "Config not found: $conf_src"

  ui_h1 "Exporting client config: ${name}"
  ui_hr
  export_to_home "$name" "$user" "$conf_src"
}

cmd_delete() {
  need_root
  ensure_prereqs
  ensure_dirs

  [[ $# -ge 1 ]] || die "Usage: sudo awg-client delete <name>"
  local name="$1"
  valid_name "$name"

  local conf_file
  conf_file="$(client_conf_path "$name")"

  if ! grep -q -E "^### Client ${name}\$" "$AWG_CONF"; then
    die "Client marker not found in server config: '### Client ${name}'"
  fi

  local bak="${AWG_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$AWG_CONF" "$bak"

  # Delete peer block and its trailing blank line
  sed -i "/^### Client ${name}\$/,/^$/d" "$AWG_CONF"

  apply_changes

  rm -f -- "$conf_file"

  ui_ok "Client deleted: ${name}"
  ui_info "Server config backup: ${bak}"
  ui_info "Deleted config file: ${conf_file}"
}

# Получить список имён клиентов из server config (markers "### Client NAME")
server_marked_clients() {
  grep -E '^### Client ' "$AWG_CONF" | sed -E 's/^### Client[[:space:]]+//' || true
}

# Проверка: есть ли marker для клиента в server config
server_has_client_marker() {
  local name="$1"
  grep -q -E "^### Client ${name}\$" "$AWG_CONF"
}

# Удалить peer block по marker "### Client NAME"
server_remove_client_by_marker() {
  local name="$1"
  sed -i "/^### Client ${name}\$/,/^$/d" "$AWG_CONF"
}

cmd_clean() {
  need_root
  ensure_prereqs
  ensure_dirs

  local dry_run="no"
  local assume_yes="no"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="yes"; shift ;;
      --yes) assume_yes="yes"; shift ;;
      -h|--help)
        echo "Usage: sudo awg-client clean [--dry-run] [--yes]"
        return 0
        ;;
      *) die "Unknown option for clean: $1" ;;
    esac
  done

  ui_h1 "Cleaning up"
  ui_hr

  if [[ "$dry_run" == "yes" ]]; then
    ui_warn "DRY-RUN: no files or configs will be modified."
  else
    if [[ "$assume_yes" != "yes" ]]; then
      ui_warn "This will MODIFY server config and/or delete files."
      echo -n "Type ${c_bold}DELETE${c_reset} to continue: "
      read -r ans
      [[ "$ans" == "DELETE" ]] || die "Aborted."
    fi
  fi

  # 1) Remove exported temp files (marked)
  ui_info "Searching for exported temp files (marked) in /home/* and /root ..."
  local removed_exports=0
  local f

  shopt -s nullglob
  local candidates=(/home/*/client-*.conf /root/client-*.conf)
  shopt -u nullglob

  for f in "${candidates[@]:-}"; do
    [[ -f "$f" ]] || continue
    if head -n 1 "$f" | grep -qF "$(export_marker_line)"; then
      if [[ "$dry_run" == "yes" ]]; then
        ui_info "Would remove exported temp file: $f"
      else
        rm -f -- "$f"
        ui_ok "Removed exported temp file: $f"
      fi
      ((removed_exports++))
    fi
  done

  if ((removed_exports == 0)); then
    ui_info "No marked exported temp files found."
  fi

  echo
  # 2) Remove unmanaged peers: present in server config but missing local managed config
  ui_info "Searching for unmanaged clients in server config (no matching file in ${AWG_CLIENT_DIR}) ..."
  local unmanaged=()
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ ! -f "$(client_conf_path "$name")" ]]; then
      unmanaged+=("$name")
    fi
  done < <(server_marked_clients)

  if (( ${#unmanaged[@]} == 0 )); then
    ui_info "No unmanaged clients found."
  else
    ui_warn "Unmanaged clients found: ${unmanaged[*]}"
    if [[ "$dry_run" == "yes" ]]; then
      for name in "${unmanaged[@]}"; do
        ui_info "Would remove peer block from server config: ${name}"
      done
      ui_info "Would apply changes."
    else
      local bak="${AWG_CONF}.bak.clean.$(date +%Y%m%d-%H%M%S)"
      cp -a "$AWG_CONF" "$bak"
      for name in "${unmanaged[@]}"; do
        server_remove_client_by_marker "$name"
        ui_ok "Removed peer block from server config: ${name}"
      done
      apply_changes
      ui_ok "Applied changes."
      ui_info "Backup created: ${bak}"
    fi
  fi

  echo
  # 3) Remove orphan local configs: exist locally but no marker in server config
  ui_info "Searching for orphan local configs (no marker in server config) ..."
  shopt -s nullglob
  local local_files=( "$AWG_CLIENT_DIR"/client-*.conf )
  shopt -u nullglob

  local removed_orphans=0
  for f in "${local_files[@]:-}"; do
    [[ -f "$f" ]] || continue
    local base n
    base="$(basename "$f")"
    n="${base#client-}"; n="${n%.conf}"
    if ! server_has_client_marker "$n"; then
      if [[ "$dry_run" == "yes" ]]; then
        ui_info "Would remove orphan local config: $f"
      else
        rm -f -- "$f"
        ui_ok "Removed orphan local config: $f"
      fi
      ((removed_orphans++))
    fi
  done

  if ((removed_orphans == 0)); then
    ui_info "No orphan local configs found."
  fi

  ui_hr
  ui_ok "Clean completed."
}

# --- Backups / restore helpers ---

list_backups() {
  # Lists backups for the server config, newest first
  shopt -s nullglob
  local arr=( "${AWG_CONF}".bak* )
  shopt -u nullglob

  if (( ${#arr[@]} == 0 )); then
    return 1
  fi

  # Sort by mtime (newest first)
  ls -1t "${AWG_CONF}".bak* 2>/dev/null || true
}

print_backups() {
  local i=1
  local b
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    local ts size
    ts="$(stat -c '%y' "$b" 2>/dev/null | cut -d'.' -f1 || echo "?")"
    size="$(stat -c '%s' "$b" 2>/dev/null || echo "?")"
    printf "  ${c_green}%2d${c_reset}) ${c_dim}%s${c_reset}  (%s bytes, %s)\n" "$i" "$b" "$size" "$ts"
    ((i++))
  done
}

resolve_backup_arg() {
  # Accepts a number (index in list) OR a path (exact filename).
  local arg="$1"

  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    local idx="$arg"
    local -a backups=()
    mapfile -t backups < <(list_backups || true)
    (( idx >= 1 && idx <= ${#backups[@]} )) || die "Invalid backup number: $idx"
    echo "${backups[$((idx-1))]}"
    return 0
  fi

  # Exact filename/path
  [[ -f "$arg" ]] || die "Backup file not found: $arg"
  echo "$arg"
}

cmd_restore() {
  need_root
  ensure_prereqs

  local dry_run="no"
  local assume_yes="no"

  # Parse flags first (any order)
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="yes"; shift ;;
      --yes) assume_yes="yes"; shift ;;
      -h|--help)
        echo "Usage: sudo awg-client restore [list] | <N|backup-file> [--dry-run] [--yes]"
        return 0
        ;;
      *) args+=("$1"); shift ;;
    esac
  done

  local sub="${args[0]:-list}"

  ui_h1 "Restore"
  ui_hr

  if [[ "$sub" == "list" || -z "$sub" ]]; then
    ui_info "Available backups for: ${AWG_CONF}"
    if ! list_backups | print_backups; then
      ui_warn "No backups found."
    fi
    return 0
  fi

  # sub is N or file
  local backup_file
  backup_file="$(resolve_backup_arg "$sub")"

  if [[ "$dry_run" == "yes" ]]; then
    ui_warn "DRY-RUN: no files or configs will be modified."
    ui_info "Would restore:"
    echo "  From: ${backup_file}"
    echo "  To:   ${AWG_CONF}"
    ui_info "Would apply changes to interface ${SERVER_AWG_NIC}."
    return 0
  fi

  if [[ "$assume_yes" != "yes" ]]; then
    ui_warn "This will OVERWRITE ${AWG_CONF} and apply changes."
    echo -n "Type ${c_bold}RESTORE${c_reset} to continue: "
    read -r ans
    [[ "$ans" == "RESTORE" ]] || die "Aborted."
  fi

  # Safety backup of current config
  local safety="${AWG_CONF}.bak.restore.$(date +%Y%m%d-%H%M%S)"
  cp -a "$AWG_CONF" "$safety"

  cp -a "$backup_file" "$AWG_CONF"
  ui_ok "Restored server config from backup."
  ui_info "Safety backup created: $safety"

  apply_changes
  ui_ok "Restore completed."
}

# --- Maintenance / reload ---

cmd_maint() {
  need_root
  ensure_prereqs

  local dry_run="no"
  local assume_yes="no"
  local do_reboot="no"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="yes"; shift ;;
      --yes) assume_yes="yes"; shift ;;
      --reboot) do_reboot="yes"; shift ;;
      -h|--help)
        echo "Usage: sudo awg-client maint [--dry-run] [--yes] [--reboot]"
        return 0
        ;;
      *) die "Unknown option for maint: $1" ;;
    esac
  done

  ui_h1 "Maintenance"
  ui_hr

  if [[ "$dry_run" == "yes" ]]; then
    ui_warn "DRY-RUN: no packages will be changed."
    ui_info "Would run:"
    echo "  apt update"
    echo "  apt full-upgrade -y"
    echo "  apt autoremove -y"
    echo "  apt autoclean -y"
    echo
    ui_info "Would then check /var/run/reboot-required."
    ui_info "Use --reboot to reboot automatically after upgrade."
    return 0
  fi

  if [[ "$assume_yes" != "yes" ]]; then
    ui_warn "This will upgrade system packages."
    echo -n "Type ${c_bold}UPGRADE${c_reset} to continue: "
    read -r ans
    [[ "$ans" == "UPGRADE" ]] || die "Aborted."
  fi

  ui_info "Running apt update / full-upgrade ..."
  ui_hr

  # Noninteractive + auto-restart services when possible (reduces prompts)
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  apt update
  apt full-upgrade -y
  apt autoremove -y
  apt autoclean -y

  ui_hr
  ui_ok "Maintenance upgrade completed."

  # Quick post-check
  ui_info "Post-check:"
  echo "  Kernel: $(uname -r)"
  echo "  Service: awg-quick@${SERVER_AWG_NIC} (status below)"
  echo

  systemctl status "awg-quick@${SERVER_AWG_NIC}" --no-pager || true
  echo
  awg show || true

  if [[ -f /var/run/reboot-required ]]; then
    ui_warn "A reboot is required (/var/run/reboot-required exists)."
    if [[ "$do_reboot" == "yes" ]]; then
      ui_warn "Rebooting now..."
      reboot
    else
      ui_info "Run: sudo reboot"
    fi
  else
    ui_ok "No reboot-required flag found."
    if [[ "$do_reboot" == "yes" ]]; then
      ui_warn "Rebooting (forced by --reboot)..."
      reboot
    fi
  fi
}

cmd_reload() {
  need_root
  ensure_prereqs

  ui_h1 "Reload"
  ui_hr

  ui_info "Applying sysctl settings ..."
  sysctl --system >/dev/null 2>&1 || true
  ui_ok "sysctl applied (best effort)."

  ui_info "Restarting AmneziaWG service: awg-quick@${SERVER_AWG_NIC} ..."
  systemctl restart "awg-quick@${SERVER_AWG_NIC}"
  ui_ok "awg-quick@${SERVER_AWG_NIC} restarted."

  if systemctl list-unit-files | grep -q '^netfilter-persistent\.service'; then
    ui_info "Restarting netfilter-persistent ..."
    systemctl restart netfilter-persistent || true
    ui_ok "netfilter-persistent restart attempted."
  else
    ui_info "netfilter-persistent service not found (skipping)."
  fi

  ui_hr
  ui_info "Status:"
  systemctl status "awg-quick@${SERVER_AWG_NIC}" --no-pager || true
  echo
  awg show || true
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    help|-h|--help|"")
      help_text
      ;;
    add)
      shift
      cmd_add "$@"
      ;;
    list|ls)
      shift
      cmd_list
      ;;
    show)
      shift
      cmd_show "$@"
      ;;
    export)
      shift
      cmd_export "$@"
      ;;
    delete|del|rm)
      shift
      cmd_delete "$@"
      ;;
    clean)
      shift
      cmd_clean "$@"
      ;;
    restore)
      shift
      cmd_restore "$@"
      ;;
    maint|maintenance)
      shift
      cmd_maint "$@"
      ;;
    reload|restart)
      shift
      cmd_reload "$@"
      ;;
    *)
      die "Unknown command: $cmd. Use: sudo awg-client help"
      ;;
  esac
}

main "$@"