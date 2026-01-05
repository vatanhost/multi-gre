#!/bin/bash
set -e

CYAN=$(tput setaf 6 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${RED}[!] Run as root (sudo).${RESET}"
    exit 1
  fi
}

pause() { read -rp "Press Enter to continue..."; }

enable_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  # persist (best-effort)
  if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  echo "${GREEN}[+] ip_forward enabled${RESET}"
}

detect_wan_if() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

create_gre() {
  local tun="$1" local_ip="$2" remote_ip="$3" cidr="$4" mtu="$5"
  ip tunnel add "$tun" mode gre local "$local_ip" remote "$remote_ip" ttl 255 2>/dev/null || true
  ip link set "$tun" up
  ip addr add "$cidr" dev "$tun" 2>/dev/null || true
  [[ -n "$mtu" ]] && ip link set "$tun" mtu "$mtu" || true
  echo "${GREEN}[+] Created ${tun} (${cidr}) local=${local_ip} remote=${remote_ip} mtu=${mtu}${RESET}"
}

delete_gre_prefix() {
  local prefix="$1"
  for t in $(ip -o link show | awk -F': ' '{print $2}' | grep -E "^${prefix}[0-9]+$" || true); do
    ip link set "$t" down 2>/dev/null || true
    ip tunnel del "$t" 2>/dev/null || true
    echo "${YELLOW}[-] Deleted $t${RESET}"
  done
}

foreign_iptables_apply() {
  local gre_if="$1" wan_if="$2"
  # NAT out
  iptables -t nat -C POSTROUTING -o "$wan_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$wan_if" -j MASQUERADE

  # forward rules
  iptables -C FORWARD -i "$gre_if" -o "$wan_if" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$gre_if" -o "$wan_if" -j ACCEPT

  iptables -C FORWARD -i "$wan_if" -o "$gre_if" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$wan_if" -o "$gre_if" -m state --state RELATED,ESTABLISHED -j ACCEPT

  echo "${GREEN}[+] iptables NAT/forward applied (GRE:${gre_if} -> WAN:${wan_if})${RESET}"
}

show_status() {
  echo "${CYAN}--- Interfaces (GRE) ---${RESET}"
  ip -br a | grep -E "gre[0-9]+" || echo "No gre* interfaces."
  echo
  echo "${CYAN}--- Routes ---${RESET}"
  ip route | sed -n '1,30p'
  echo
  echo "${CYAN}--- ip rule ---${RESET}"
  ip rule show
  echo
  echo "${CYAN}--- iptables nat ---${RESET}"
  iptables -t nat -S | sed -n '1,40p'
}

set_iran_default_route() {
  local tun="$1" gw="$2"
  ip route replace default via "$gw" dev "$tun"
  echo "${GREEN}[+] Default route set: default via ${gw} dev ${tun}${RESET}"
}

print_header() {
  echo -e "${CYAN}"
  echo "========================================"
  echo "      GRE Multi-Tunnel Menu Script"
  echo "========================================"
  echo -e "${RESET}"
}

menu_main() {
  while true; do
    print_header
    echo "1) IRAN (Hub) - Add multiple FOREIGN tunnels"
    echo "2) FOREIGN (Spoke) - Create single tunnel + NAT out"
    echo "3) Show status"
    echo "4) Delete all GRE tunnels (gre1,gre2,...)"
    echo "5) Enable IP Forward"
    echo "0) Exit"
    echo
    read -rp "Select: " c
    case "$c" in
      1) menu_iran ;;
      2) menu_foreign ;;
      3) show_status; pause ;;
      4) need_root; delete_gre_prefix "gre"; pause ;;
      5) need_root; enable_forward; pause ;;
      0) exit 0 ;;
      *) echo "${RED}[!] Invalid${RESET}"; pause ;;
    esac
  done
}

menu_iran() {
  need_root
  echo
  read -rp "IRAN public IP: " IRAN_IP
  read -rp "How many FOREIGN servers to add? " N
  read -rp "Base subnet (default 10.10): " BASE
  BASE=${BASE:-10.10}
  read -rp "MTU for GRE (default 1400): " MTU
  MTU=${MTU:-1400}

  enable_forward

  for i in $(seq 1 "$N"); do
    echo
    read -rp "FOREIGN$i public IP: " FIP
    TUN="gre$i"
    NET="${BASE}.${i}"
    IR_CIDR="${NET}.2/30"
    create_gre "$TUN" "$IRAN_IP" "$FIP" "$IR_CIDR" "$MTU"
    echo "${YELLOW}    Foreign side should use: ${NET}.1/30 on ${TUN}${RESET}"
  done

  echo
  echo "${CYAN}Optional:${RESET} Set default route on IRAN to send ALL internet via one tunnel."
  echo "a) Set default route via gre1"
  echo "b) Skip"
  read -rp "Choose (a/b): " opt
  if [[ "$opt" == "a" ]]; then
    # gateway of gre1 is BASE.1.1
    GW="${BASE}.1.1"
    set_iran_default_route "gre1" "$GW"
  fi

  pause
}

menu_foreign() {
  need_root
  echo
  read -rp "FOREIGN public IP: " F_IP
  read -rp "IRAN public IP: " IR_IP
  read -rp "Tunnel number (e.g. 1 for gre1): " IDX
  read -rp "Base subnet (must match IRAN, default 10.10): " BASE
  BASE=${BASE:-10.10}
  read -rp "WAN interface (blank=auto detect): " WAN
  if [[ -z "$WAN" ]]; then
    WAN=$(detect_wan_if)
  fi
  if [[ -z "$WAN" ]]; then
    echo "${RED}[!] Could not detect WAN interface. Enter it manually (eth0/ens3/...)${RESET}"
    pause
    return
  fi
  read -rp "MTU for GRE (default 1400): " MTU
  MTU=${MTU:-1400}

  enable_forward

  TUN="gre${IDX}"
  NET="${BASE}.${IDX}"
  FR_CIDR="${NET}.1/30"
  create_gre "$TUN" "$F_IP" "$IR_IP" "$FR_CIDR" "$MTU"

  foreign_iptables_apply "$TUN" "$WAN"

  echo
  echo "${GREEN}[+] FOREIGN ready.${RESET}"
  echo "${YELLOW}    IRAN side should be: ${NET}.2/30 on ${TUN}${RESET}"
  pause
}

menu_main
