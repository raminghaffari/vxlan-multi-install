#!/usr/bin/env bash
set -euo pipefail

# ===== Helpers =====
bold(){ printf "\e[1m%s\e[0m\n" "$*"; }
ok(){ printf "[✓] %s\n" "$*"; }
warn(){ printf "[!] %s\n" "$*"; }
err(){ printf "[x] %s\n" "$*" >&2; }

require_root(){ [ "$EUID" -eq 0 ] || { err "Run as root."; exit 1; }; }
default_iface(){ ip route show default | awk '/default/ {print $5; exit}'; }

ask(){ local p="$1" d="${2-}" a; if [ -n "$d" ]; then read -rp "$p [$d]: " a; echo "${a:-$d}"; else read -rp "$p: " a; echo "$a"; fi; }

valid_ipv4(){
  local ip=$1 IFS=.
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r a b c d <<<"$ip"
  for o in $a $b $c $d; do ((o>=0&&o<=255)) || return 1; done
  return 0
}

ensure_tools(){
  command -v ip >/dev/null || { apt-get update -y && apt-get install -y iproute2; }
  command -v iptables >/dev/null || apt-get install -y iptables
  systemctl --version >/dev/null || { err "systemd is required."; exit 1; }
}

# ===== Modified systemd template for Iran mode =====
install_template(){
  local unit=/etc/systemd/system/vxlan@.service
  [ -f "$unit" ] && return 0
  mkdir -p /etc/vxlan
  cat > "$unit" <<'EOF'
[Unit]
Description=VXLAN instance %i (point-to-point)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/vxlan/%i.conf
ExecStartPre=/bin/bash -c 'ip addr show ${WAN_IFACE} | grep -q ${LOCAL_PUBLIC} || ip addr add ${LOCAL_PUBLIC}/32 dev ${WAN_IFACE}'
ExecStart=/usr/sbin/ip link add ${IFACE} type vxlan id ${VNI} dev ${WAN_IFACE} local ${LOCAL_PUBLIC} remote ${REMOTE_PUBLIC} dstport ${VXPORT}
ExecStart=/bin/sleep 1
ExecStart=/usr/sbin/ip addr add ${LOCAL_ADDR} dev ${IFACE}
ExecStart=/usr/sbin/ip link set up dev ${IFACE}
ExecStop=/usr/sbin/ip link del ${IFACE}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "Installed systemd template."
}

allow_udp_from(){ local src="$1" port="$2"; iptables -C INPUT -p udp -s "$src" --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp -s "$src" --dport "$port" -j ACCEPT; }

persist_rules(){
  if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent || true
  fi
  netfilter-persistent save || true
  ok "Firewall rules persisted."
}

# ===== Table utilities =====
cfg_val(){ awk -F= -v k="$1" '$1==k{print $2}' "$2"; }

list_instances(){ ls -1 /etc/vxlan/*.conf 2>/dev/null | sed 's#.*/##; s#\.conf$##' || true; }

print_table(){
  local names=(); mapfile -t names < <(list_instances)
  [ "${#names[@]}" -gt 0 ] || { warn "No instances found."; return 1; }
  printf "%-3s %-12s %-6s %-9s %-15s %-15s %-15s %-6s %-8s\n" "#" "NAME" "VNI" "IFACE" "LOCAL_PUBLIC" "REMOTE_PUBLIC" "LOCAL_ADDR" "PORT" "STATUS"
  local i=1 n f vni ifc lp rp la pt st
  for n in "${names[@]}"; do
    f="/etc/vxlan/$n.conf"
    vni=$(cfg_val VNI "$f"); ifc=$(cfg_val IFACE "$f"); lp=$(cfg_val LOCAL_PUBLIC "$f")
    rp=$(cfg_val REMOTE_PUBLIC "$f"); la=$(cfg_val LOCAL_ADDR "$f"); pt=$(cfg_val VXPORT "$f")
    systemctl is-active "vxlan@$n" >/dev/null 2>&1 && st=active || st=inactive
    printf "%-3s %-12s %-6s %-9s %-15s %-15s %-15s %-6s %-8s\n" "$i" "$n" "$vni" "$ifc" "$lp" "$rp" "${la%/*}" "$pt" "$st"
    i=$((i+1))
  done
  return 0
}

# ===== Peer-IP helper & Connectivity check =====
get_peer_ip(){ # input: LOCAL_ADDR like 10.8.X.Y/30 -> outputs peer IP (no /cidr)
  local la="$1" ip="${la%/*}"; IFS=. read -r a b c d <<<"$ip"
  if [ "$d" = "1" ]; then echo "$a.$b.$c.2"; else echo "$a.$b.$c.1"; fi
}

run_check(){
  bold "Connectivity check"
  local names=(); mapfile -t names < <(list_instances)
  [ "${#names[@]}" -gt 0 ] || { warn "No instances found."; return; }

  printf "%-12s %-6s %-9s %-15s %-15s %-6s %-8s %-10s %-10s\n" \
    "NAME" "VNI" "IFACE" "LOCAL_ADDR" "PEER_ADDR" "PORT" "SVC" "PING" "UDP_RX"

  local n f vni ifc la peer rp port svc pingres udprx cnt
  for n in "${names[@]}"; do
    f="/etc/vxlan/$n.conf"
    vni=$(cfg_val VNI "$f")
    ifc=$(cfg_val IFACE "$f")
    la=$(cfg_val LOCAL_ADDR "$f")
    rp=$(cfg_val REMOTE_PUBLIC "$f")
    port=$(cfg_val VXPORT "$f")
    peer=$(get_peer_ip "$la")

    systemctl is-active "vxlan@$n" >/dev/null 2>&1 && svc=active || svc=down

    if ping -c1 -W1 "$peer" >/dev/null 2>&1; then pingres=OK; else pingres=FAIL; fi

    cnt=$(iptables -nvL 2>/dev/null | awk -v ip="$rp" -v p="$port" '$0 ~ ip && $0 ~ "udp dpt:"p {print $1; exit}')
    [ -n "${cnt:-}" ] || cnt=0
    udprx="$cnt"

    printf "%-12s %-6s %-9s %-15s %-15s %-6s %-8s %-10s %-10s\n" \
      "$n" "$vni" "$ifc" "${la%/*}" "$peer" "$port" "$svc" "$pingres" "$udprx"
  done

  echo
  echo "Legend:"
  echo "  PING   = reachability over the VXLAN IPs (.1 ↔ .2)."
  echo "  UDP_RX = number of UDP packets seen on THIS host from REMOTE_PUBLIC to the tunnel port."
  echo "Hints:"
  echo "  - PING=FAIL but UDP_RX>0: remote VXLAN/IP config likely wrong."
  echo "  - UDP_RX=0: VXLAN UDP to this host not arriving (firewall/ISP/port)."
}

# ===== IRAN mode (modified) =====
run_iran(){
  bold "IRAN mode (connect to multiple FOREIGN servers)"
  local WAN_IFACE IR_PUBLIC VX_MTU count
  WAN_IFACE="$(ask 'WAN interface' "$(default_iface)")"
  IR_PUBLIC="$(ask 'IRAN public IP' "$(curl -fsSL ifconfig.me 2>/dev/null || true)")"
  while ! valid_ipv4 "$IR_PUBLIC"; do IR_PUBLIC="$(ask 'Invalid IP, re-enter IRAN public IP')"; done
  VX_MTU="$(ask 'VXLAN MTU' "1450")"
  count="$(ask 'How many FOREIGN servers?' "1")"
  while ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; do count="$(ask 'Enter a positive integer')" ; done

  install_template

  printf "\n%-7s %-5s %-16s %-14s %-14s %-7s\n" "Tunnel" "VNI" "Subnet" "IRAN_IP" "FOREIGN_IP" "PORT"
  for ((i=1;i<=count;i++)); do
    bold "-- FOREIGN #$i --"
    local F_PUBLIC VNI PORT SUBNET IR_IP FO_IP IFACE NAME
    read -rp "FOREIGN public IP: " F_PUBLIC
    while ! valid_ipv4 "$F_PUBLIC"; do read -rp "Invalid IP. FOREIGN public IP: " F_PUBLIC; done

    VNI=$((88+i))
    PORT=$((4789+i))
    SUBNET="10.8.$VNI.0/30"
    IR_IP="10.8.$VNI.1/30"
    FO_IP="10.8.$VNI.2/30"
    IFACE="vxlan$VNI"
    NAME="peer$i"

    # ایجاد فایل conf
    cat >"/etc/vxlan/${NAME}.conf" <<EOF
IFACE=${IFACE}
VNI=${VNI}
WAN_IFACE=${WAN_IFACE}
LOCAL_PUBLIC=${IR_PUBLIC}
REMOTE_PUBLIC=${F_PUBLIC}
VXPORT=${PORT}
VX_MTU=${VX_MTU}
LOCAL_ADDR=${IR_IP}
EOF

    # فعال سازی systemd
    systemctl enable --now "vxlan@${NAME}" >/dev/null || true
    allow_udp_from "$F_PUBLIC" "$PORT"
    printf "%-7s %-5s %-16s %-14s %-14s %-7s\n" "$i" "$VNI" "$SUBNET" "${IR_IP%/*}" "${FO_IP%/*}" "$PORT"
  done

  if [[ "$(ask 'Persist firewall rules (iptables-persistent)?' 'N')" =~ ^[Yy]$ ]]; then persist_rules; fi
  ok "IRAN configuration finished."
}

# ===== Rest of script (FOREIGN mode, remove, list, check, uninstall) remain unchanged =====
# You can keep the original functions for run_foreign, run_remove, run_list, run_check, run_full_uninstall
# ===== Main menu =====
require_root
ensure_tools
bold "VXLAN Unified Installer"
echo "1) IRAN mode (multi FOREIGN)"
echo "2) FOREIGN mode (single peer)"
echo "3) Remove an instance"
echo "4) List & status"
echo "5) Full uninstall (remove ALL tunnels)"
echo "6) Connectivity check"
echo "0) Exit"
read -rp "Choose: " CH

case "${CH:-}" in
  1) run_iran ;;
  2) run_foreign ;;
  3) run_remove ;;
  4) run_list ;;
  5) run_full_uninstall ;;
  6) run_check ;;
  0) exit 0 ;;
  *) err "Invalid option." ;;
esac
