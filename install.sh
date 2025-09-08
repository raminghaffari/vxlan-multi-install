#!/usr/bin/env bash
set -euo pipefail

# ========== Helpers ==========
bold() { printf "\e[1m%s\e[0m\n" "$*"; }
info() { printf "[*] %s\n" "$*"; }
ok()   { printf "[✓] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*"; }
err()  { printf "[x] %s\n" "$*" >&2; }

require_root() { [ "$EUID" -eq 0 ] || { err "Run as root."; exit 1; }; }

default_iface() { ip route show default | awk '/default/ {print $5; exit}'; }
valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ipcalc -cs "$1" >/dev/null 2>&1; }
valid_cidr30() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/30$ ]]; }

ask() { # ask "prompt" "default"
  local p="$1" d="${2-}" a
  if [ -n "$d" ]; then read -rp "$p [$d]: " a; echo "${a:-$d}"
  else read -rp "$p: " a; echo "$a"; fi
}

ensure_tools() {
  if ! command -v ip >/dev/null; then
    info "Installing iproute2..."
    apt-get update -y && apt-get install -y iproute2
  fi
  if ! command -v iptables >/dev/null; then
    info "Installing iptables..."
    apt-get install -y iptables
  fi
  if ! command -v ipcalc >/dev/null; then
    info "Installing ipcalc..."
    apt-get install -y ipcalc
  fi
  systemctl --version >/dev/null || { err "systemd is required."; exit 1; }
}

yes_no() {
  local q="$1" a; read -rp "$q [y/N]: " a; [[ "${a,,}" == y* ]]
}

# ========= systemd Template =========
install_template() {
  mkdir -p /etc/vxlan
  local unit=/etc/systemd/system/vxlan@.service
  cat > "$unit" <<'EOF'
[Unit]
Description=VXLAN instance %i (point-to-point)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/vxlan/%i.conf
ExecStart=/usr/sbin/ip link add ${IFACE} type vxlan id ${VNI} dev ${WAN_IFACE} local ${LOCAL_PUBLIC} remote ${REMOTE_PUBLIC} dstport ${VXPORT} nolearning
ExecStart=/usr/sbin/ip link set dev ${IFACE} mtu ${VX_MTU}
ExecStart=/usr/sbin/ip addr add ${LOCAL_ADDR} dev ${IFACE}
ExecStart=/usr/sbin/ip link set up dev ${IFACE}
ExecStop=/usr/sbin/ip link del ${IFACE}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "systemd template installed: $unit"
}

enable_instance() {
  local name="$1"
  systemctl enable --now "vxlan@${name}.service"
  ok "Enabled vxlan@${name}"
}

disable_instance() {
  local name="$1"
  systemctl disable --now "vxlan@${name}.service" || true
  ok "Disabled vxlan@${name}"
}

# ========= Firewall helpers =========
allow_udp_from() {
  local src="$1" port="$2"
  iptables -C INPUT -p udp -s "$src" --dport "$port" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p udp -s "$src" --dport "$port" -j ACCEPT
}

persist_iptables() {
  if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    info "Installing iptables-persistent (optional)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent || true
  fi
  netfilter-persistent save || true
  ok "Firewall rules saved."
}

# ========= Config helpers =========
write_conf() {
  # args: name iface vni wan local_public remote_public vxport vx_mtu local_addr
  local name="$1" iface="$2" vni="$3" wan="$4" lp="$5" rp="$6" port="$7" mtu="$8" laddr="$9"
  cat >"/etc/vxlan/${name}.conf" <<EOF
IFACE=${iface}
VNI=${vni}
WAN_IFACE=${wan}
LOCAL_PUBLIC=${lp}
REMOTE_PUBLIC=${rp}
VXPORT=${port}
VX_MTU=${mtu}
LOCAL_ADDR=${laddr}
EOF
  ok "Wrote /etc/vxlan/${name}.conf"
}

delete_conf() {
  local name="$1"
  rm -f "/etc/vxlan/${name}.conf"
  ok "Removed /etc/vxlan/${name}.conf"
}

list_instances() {
  ls -1 /etc/vxlan/*.conf 2>/dev/null | sed 's#.*/##; s#\.conf$##' || true
}

# ========= Actions =========
install_iran_multi() {
  bold "Install on IRAN server (connect to multiple FOREIGN servers)"
  local wan mtu lp n
  wan="$(default_iface)"; wan="$(ask 'WAN interface' "$wan")"
  lp="$(ask 'Public IP of this (IRAN) server' "$(curl -fsSL ifconfig.me 2>/dev/null || echo)")"
  while ! valid_ip "$lp"; do lp="$(ask 'Invalid IP. Enter IRAN public IP again')"; done
  mtu="$(ask 'VXLAN MTU' "1450")"

  install_template

  n="$(ask 'How many FOREIGN servers to add?' "1")"
  for ((i=1;i<=n;i++)); do
    bold "-- FOREIGN server #$i --"
    local rp vni port laddr name ifc
    rp="$(ask 'FOREIGN public IP')"; while ! valid_ip "$rp"; do rp="$(ask 'Invalid IP. Enter FOREIGN public IP again')"; done
    vni="$(ask 'VNI' "$((87+i))")"
    port="$(ask 'UDP port' "4789")"
    laddr="$(ask 'Private address for IRAN side (/30)' "10.8.$((80+i)).1/30")"
    while ! valid_cidr30 "$laddr"; do laddr="$(ask 'Invalid /30. Example: 10.8.88.1/30')"; done
    name="$(ask 'Instance name (systemd)' "x${i}")"
    ifc="vxlan${vni}"

    write_conf "$name" "$ifc" "$vni" "$wan" "$lp" "$rp" "$port" "$mtu" "$laddr"
    allow_udp_from "$rp" "$port"
    enable_instance "$name"
  done

  if yes_no "Persist firewall rules (iptables-persistent)?"; then persist_iptables; fi
  ok "IRAN installation done."
}

install_foreign_single() {
  bold "Install on FOREIGN server (single peer with IRAN)"
  local wan lp rp vni port mtu laddr name ifc
  wan="$(default_iface)"; wan="$(ask 'WAN interface' "$wan")"
  lp="$(ask 'Public IP of this (FOREIGN) server' "$(curl -fsSL ifconfig.me 2>/dev/null || echo)")"
  while ! valid_ip "$lp"; do lp="$(ask 'Invalid IP. Enter this FOREIGN public IP again')"; done
  rp="$(ask 'IRAN public IP')"; while ! valid_ip "$rp"; do rp="$(ask 'Invalid IP. Enter IRAN public IP again')"; done
  vni="$(ask 'VNI' "88")"
  port="$(ask 'UDP port' "4789")"
  mtu="$(ask 'VXLAN MTU' "1450")"
  laddr="$(ask 'Private address for FOREIGN side (/30)' "10.8.88.2/30")"
  while ! valid_cidr30 "$laddr"; do laddr="$(ask 'Invalid /30. Example: 10.8.88.2/30')"; done
  name="$(ask 'Instance name (systemd)' "x1")"
  ifc="vxlan${vni}"

  install_template
  # Note: LOCAL_PUBLIC on FOREIGN is lp; remote is rp (IRAN)
  write_conf "$name" "$ifc" "$vni" "$wan" "$rp" "$lp" "$port" "$mtu" "$laddr"
  allow_udp_from "$rp" "$port"
  enable_instance "$name"

  if yes_no "Persist firewall rules (iptables-persistent)?"; then persist_iptables; fi
  ok "FOREIGN installation done."
}

add_peer_iran() {
  bold "Add a new FOREIGN peer (on IRAN server)"
  local wan lp
  wan="$(default_iface)"; wan="$(ask 'WAN interface' "$wan")"
  lp="$(ask 'IRAN public IP' "$(curl -fsSL ifconfig.me 2>/dev/null || echo)")"
  while ! valid_ip "$lp"; do lp="$(ask 'Invalid IP. Enter IRAN public IP again')"; done

  local rp vni port mtu laddr name ifc
  rp="$(ask 'FOREIGN public IP')"; while ! valid_ip "$rp"; do rp="$(ask 'Invalid IP. Enter FOREIGN public IP again')"; done
  vni="$(ask 'VNI' "99")"
  port="$(ask 'UDP port' "4789")"
  mtu="$(ask 'VXLAN MTU' "1450")"
  laddr="$(ask 'Private address for IRAN side (/30)' "10.8.99.1/30")"
  while ! valid_cidr30 "$laddr"; do laddr="$(ask 'Invalid /30. Example: 10.8.99.1/30')"; done
  name="$(ask 'Instance name' "x$(date +%H%M)")"
  ifc="vxlan${vni}"

  write_conf "$name" "$ifc" "$vni" "$wan" "$lp" "$rp" "$port" "$mtu" "$laddr"
  allow_udp_from "$rp" "$port"
  enable_instance "$name"
}

remove_peer() {
  bold "Remove an instance"
  local list; list="$(list_instances)"
  [ -z "$list" ] && { warn "No configs found."; return; }
  echo "Instances:"
  echo "$list" | nl -w2 -s'. '
  local name; name="$(ask 'Instance name to remove')"
  disable_instance "$name"
  delete_conf "$name"
  ok "Removed $name"
}

list_status() {
  bold "List & status"
  local list; list="$(list_instances)"
  if [ -z "$list" ]; then warn "No instances."; return; fi
  for n in $list; do
    systemctl is-active "vxlan@$n.service" >/dev/null 2>&1 && s=active || s=inactive
    echo "- $n : $s"
    [ -f "/etc/vxlan/$n.conf" ] && awk '{print "   " $0}' "/etc/vxlan/$n.conf"
  done
}

uninstall_all() {
  bold "Full uninstall (services & configs)"
  local list; list="$(list_instances)"
  for n in $list; do disable_instance "$n"; done
  rm -f /etc/systemd/system/vxlan@.service
  rm -rf /etc/vxlan
  systemctl daemon-reload
  ok "Cleanup done."
}

# ========= Menu =========
main_menu() {
  require_root
  ensure_tools
  while true; do
    echo ""
    bold "VXLAN Multi-Peer Installer"
    echo "1) Install on IRAN server (connect to multiple FOREIGN servers)"
    echo "2) Install on FOREIGN server (single peer with IRAN)"
    echo "3) Add a new FOREIGN peer (IRAN)"
    echo "4) Remove an instance"
    echo "5) List & status"
    echo "6) Persist firewall (iptables-persistent)"
    echo "7) Full uninstall"
    echo "0) Exit"
    read -rp "Choose: " c
    case "${c:-}" in
      1) install_iran_multi ;;
      2) install_foreign_single ;;
      3) add_peer_iran ;;
      4) remove_peer ;;
      5) list_status ;;
      6) persist_iptables ;;
      7) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid option." ;;
    esac
  done
}

main_menu
