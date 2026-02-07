#!/usr/bin/env bash
set -euo pipefail

# ========= SETTINGS =========
WG_IFACE="wg0"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
WG_CLIENT_DIR="/etc/wireguard/clients"
WG_NET_PREFIX="10.8.0"                 # 10.8.0.0/24
WG_SERVER_PUB="/etc/wireguard/server.pub"
SERVER_ENDPOINT="mindwave.dscloud.biz:51820"
CLIENT_DNS="1.1.1.1"
# ============================

err() { echo "Error: $*" >&2; exit 1; }

need_root() { [[ ${EUID} -eq 0 ]] || err "Run as root: sudo wg-client ..."; }

ensure_prereqs() {
  [[ -f "$WG_CONF" ]] || err "Config not found: $WG_CONF"
  [[ -f "$WG_SERVER_PUB" ]] || err "Server public key not found: $WG_SERVER_PUB"
  command -v wg >/dev/null 2>&1 || err "wg not found. Install: sudo apt install -y wireguard wireguard-tools"
  command -v systemctl >/dev/null 2>&1 || err "systemctl not found"
}

valid_name() {
  local n="$1"
  [[ -n "$n" ]] || err "Client name is empty"
  [[ "$n" != -* ]] || err "Client name cannot start with '-'"
  [[ "$n" =~ ^[a-zA-Z0-9._-]+$ ]] || err "Invalid name. Use letters/numbers/._- only."
}

detect_lan_ip() {
  # Самый полезный IP для scp в локалке — тот, что используется по умолчанию
  ip route get 1.1.1.1 2>/dev/null | awk '
    {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}
  ' || true
}

default_export_user() {
  # Обычно удобнее экспортировать в домашнюю папку пользователя, под которым вы работаете
  echo "${SUDO_USER:-kolandor}"
}

help_text() {
  local lan_ip
  lan_ip="$(detect_lan_ip)"
  [[ -n "$lan_ip" ]] || lan_ip="<pi_lan_ip>"

  cat <<EOF
wg-client — управление клиентами WireGuard

Commands:
  sudo wg-client add <name> [--split <LAN_CIDR>]
      Create a client.
      Default: full-tunnel (all traffic via VPN / home IP).
      --split <LAN_CIDR> : split-tunnel (VPN subnet + your LAN via VPN)

  sudo wg-client list
      List existing clients (from $WG_CLIENT_DIR).

  sudo wg-client show <name>
      Print full client config to terminal (copy/paste friendly) and show QR.

  sudo wg-client export <name> [user]
      Export config to /home/<user>/client-<name>.conf with safe permissions
      so you can download it via scp without giving access to $WG_CLIENT_DIR.
      If [user] is omitted, it uses: ${SUDO_USER:-$(default_export_user)}

      After export, download from Windows PowerShell:
        scp <user>@$lan_ip:client-<name>.conf ".\\client-<name>.conf"

      Example:
        sudo wg-client export phone
        scp ${SUDO_USER:-$(default_export_user)}@$lan_ip:client-phone.conf ".\\client-phone.conf"

      Cleanup (optional):
        rm -f /home/<user>/client-<name>.conf

  sudo wg-client delete <name>
      Delete client: remove peer block from $WG_CONF and delete client files.

  sudo wg-client help
      Show this help.

Examples:
  sudo wg-client add phone
  sudo wg-client add workpc --split 192.168.1.0/24
  sudo wg-client list
  sudo wg-client show phone
  sudo wg-client export phone
  sudo wg-client delete phone

Where configs are stored (root-only):
  $WG_CLIENT_DIR/client-<name>.conf
EOF
}

next_ip() {
  # Select next free 10.8.0.X (server uses .1)
  local max=1
  if [[ -f "$WG_CONF" ]]; then
    while read -r x; do
      [[ -n "$x" ]] || continue
      local last="${x##*.}"
      [[ "$last" =~ ^[0-9]+$ ]] || continue
      if (( last > max )); then max=$last; fi
    done < <(grep -oE "${WG_NET_PREFIX}\.[0-9]+" "$WG_CONF" | sort -u)
  fi
  local cand=$((max + 1))
  (( cand >= 2 && cand <= 254 )) || err "No free IPs left in ${WG_NET_PREFIX}.0/24"
  echo "${WG_NET_PREFIX}.${cand}"
}

client_files() {
  local name="$1"
  echo "${WG_CLIENT_DIR}/${name}.key" \
       "${WG_CLIENT_DIR}/${name}.pub" \
       "${WG_CLIENT_DIR}/client-${name}.conf"
}

cmd_add() {
  need_root
  ensure_prereqs

  [[ $# -ge 1 ]] || err "Usage: sudo wg-client add <name> [--split <LAN_CIDR>]"
  local name="$1"; shift
  valid_name "$name"

  local mode="full"
  local lan_cidr=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --split)
        mode="split"
        lan_cidr="${2:-}"
        [[ -n "$lan_cidr" ]] || err "--split requires LAN_CIDR, e.g. 192.168.1.0/24"
        shift 2
        ;;
      -h|--help) help_text; exit 0 ;;
      *) err "Unknown option: $1" ;;
    esac
  done

  mkdir -p "$WG_CLIENT_DIR"
  chmod 700 "$WG_CLIENT_DIR"

  local priv_file pub_file conf_file
  read -r priv_file pub_file conf_file < <(client_files "$name")

  if [[ -e "$priv_file" || -e "$pub_file" || -e "$conf_file" ]]; then
    err "Client '${name}' already exists (files present in $WG_CLIENT_DIR)."
  fi

  local client_ip
  client_ip="$(next_ip)"

  umask 077
  wg genkey | tee "$priv_file" > /dev/null
  wg pubkey < "$priv_file" > "$pub_file"

  local client_pub server_pub client_priv
  client_pub="$(cat "$pub_file")"
  server_pub="$(cat "$WG_SERVER_PUB")"
  client_priv="$(cat "$priv_file")"

  # Add peer to wg0.conf with marker "# name"
  cat >> "$WG_CONF" <<EOF

[Peer]
# ${name}
PublicKey = ${client_pub}
AllowedIPs = ${client_ip}/32
EOF

  local allowed_ips
  if [[ "$mode" == "full" ]]; then
    allowed_ips="0.0.0.0/0"
  else
    allowed_ips="${WG_NET_PREFIX}.0/24, ${lan_cidr}"
  fi

  cat > "$conf_file" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${client_ip}/32
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF

  chmod 600 "$priv_file" "$pub_file" "$conf_file"

  systemctl restart "wg-quick@${WG_IFACE}"

  echo "OK: created client '${name}'"
  echo "  IP: ${client_ip}"
  echo "  Config: ${conf_file}"
  echo "Tip: sudo wg-client show ${name}   # copy/paste config + QR"
  echo "Tip: sudo wg-client export ${name} # download via scp"
}

cmd_list() {
  need_root
  ensure_prereqs

  mkdir -p "$WG_CLIENT_DIR"
  chmod 700 "$WG_CLIENT_DIR"

  shopt -s nullglob
  local files=( "$WG_CLIENT_DIR"/client-*.conf )
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No clients found in $WG_CLIENT_DIR"
    return 0
  fi

  echo "Clients:"
  for f in "${files[@]}"; do
    local base name ip
    base="$(basename "$f")"
    name="${base#client-}"
    name="${name%.conf}"
    ip="$(grep -m1 -E '^Address[[:space:]]*=' "$f" | awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}' || true)"
    printf "  %-20s  %-18s  %s\n" "$name" "${ip:-unknown}" "$f"
  done
}

cmd_show() {
  need_root
  ensure_prereqs

  [[ $# -ge 1 ]] || err "Usage: sudo wg-client show <name>"
  local name="$1"
  valid_name "$name"

  local conf_file="${WG_CLIENT_DIR}/client-${name}.conf"
  [[ -f "$conf_file" ]] || err "Config not found: $conf_file"

  echo "===== client-${name}.conf ====="
  echo
  cat "$conf_file"
  echo
  echo "===== end ====="
  echo

  if command -v qrencode >/dev/null 2>&1; then
    echo "QR (scan in Android WireGuard):"
    qrencode -t ansiutf8 < "$conf_file"
  else
    echo "Note: qrencode not installed. Install it for QR output:"
    echo "  sudo apt install -y qrencode"
  fi
}

cmd_export() {
  need_root
  ensure_prereqs

  [[ $# -ge 1 ]] || err "Usage: sudo wg-client export <name> [user]"
  local name="$1"; shift
  valid_name "$name"

  local user="${1:-$(default_export_user)}"
  [[ -n "$user" ]] || err "Export user is empty"

  local conf_src="${WG_CLIENT_DIR}/client-${name}.conf"
  [[ -f "$conf_src" ]] || err "Config not found: $conf_src"

  local home_dir
  home_dir="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$home_dir" && -d "$home_dir" ]] || err "Home not found for user: $user"

  local dst="${home_dir}/client-${name}.conf"
  cp "$conf_src" "$dst"
  chown "${user}:${user}" "$dst"
  chmod 600 "$dst"

  local lan_ip
  lan_ip="$(detect_lan_ip)"
  [[ -n "$lan_ip" ]] || lan_ip="<pi_lan_ip>"

  echo "OK: exported to $dst"
  echo
  echo "Windows PowerShell (download):"
  echo "  scp ${user}@${lan_ip}:client-${name}.conf \".\\client-${name}.conf\""
  echo
  echo "After download (optional cleanup on Pi):"
  echo "  rm -f $dst"
}

rewrite_conf_without_peer() {
  # Удаляет целиком peer-блок:
  # [Peer]
  # # name
  # PublicKey = ...
  # AllowedIPs = ...
  # (и любые другие строки внутри блока до пустой строки или EOF)
  local name="$1"
  local in_peer=0
  local has_tag=0
  local buf_n=0

  awk -v name="$name" '
    function reset_buf() { delete buf; buf_n=0; has_tag=0; in_peer=0; }
    function flush() {
      if (in_peer) {
        if (!has_tag) {
          for (i=1; i<=buf_n; i++) print buf[i];
        }
        reset_buf();
      }
    }
    BEGIN { in_peer=0; has_tag=0; buf_n=0; }
    {
      sub(/\r$/,""); # на всякий: убираем CRLF
      if (in_peer) {
        buf[++buf_n] = $0;
        if ($0 ~ "^#[[:space:]]*" name "[[:space:]]*$") has_tag=1;

        # Конец блока — пустая строка
        if ($0 ~ "^[[:space:]]*$") {
          flush();
        }
        next;
      }

      if ($0 ~ /^\[Peer\][[:space:]]*$/) {
        in_peer=1;
        buf[++buf_n] = $0;
        next;
      }

      print;
    }
    END {
      # EOF может закончиться без пустой строки
      if (in_peer) {
        if (!has_tag) for (i=1; i<=buf_n; i++) print buf[i];
      }
    }
  ' "$WG_CONF"
}

cmd_delete() {
  need_root
  ensure_prereqs

  [[ $# -ge 1 ]] || err "Usage: sudo wg-client delete <name>"
  local name="$1"
  valid_name "$name"

  local priv_file pub_file conf_file
  read -r priv_file pub_file conf_file < <(client_files "$name")

  local tmp
  tmp="$(mktemp)"

  rewrite_conf_without_peer "$name" > "$tmp"

  # Если файл не изменился — peer не найден по "# name"
  if cmp -s "$WG_CONF" "$tmp"; then
    rm -f "$tmp"
    err "Peer '# ${name}' not found in $WG_CONF. (Was it created without the '# name' marker?)"
  fi

  local bak="${WG_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$WG_CONF" "$bak"
  cat "$tmp" > "$WG_CONF"
  rm -f "$tmp"

  rm -f -- "$priv_file" "$pub_file" "$conf_file"

  systemctl restart "wg-quick@${WG_IFACE}"

  echo "OK: deleted client '${name}'"
  echo "  Removed peer from: $WG_CONF"
  echo "  Backup saved as: $bak"
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
    *)
      err "Unknown command: $cmd. Use: sudo wg-client help"
      ;;
  esac
}

main "$@"
