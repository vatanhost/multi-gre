#!/bin/bash
set -e

GREEN=$(tput setaf 2 2>/dev/null || true)
CYAN=$(tput setaf 6 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

BASE="10.10"        # ثابت - بدون پرسش
DEFAULT_WAN="eth0"  # اگر auto-detect نشد

banner() {
  echo -e "${GREEN}"
  echo "██╗   ██╗ █████╗ ████████╗ █████╗ ███╗   ██╗"
  echo "██║   ██║██╔══██╗╚══██╔══╝██╔══██╗████╗  ██║"
  echo "██║   ██║███████║   ██║   ███████║██╔██╗ ██║"
  echo "╚██╗ ██╔╝██╔══██║   ██║   ██╔══██║██║╚██╗██║"
  echo " ╚████╔╝ ██║  ██║   ██║   ██║  ██║██║ ╚████║"
  echo "  ╚═══╝  ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝"
  echo "               VATAN.HOST"
  echo -e "${RESET}"
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${RED}[!] Run as root (sudo).${RESET}"
    exit 1
  fi
}

pause(){ read -rp "Press Enter to continue..."; }

enable_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
}

detect_wan_if() {
  local w
  w=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
  if [[ -n "$w" ]]; then
    echo "$w"
  else
    echo "$DEFAULT_WAN"
  fi
}

create_gre() {
  local tun="$1" local_ip="$2" remote_ip="$3" cidr="$4" mtu="$5"

  banner
  echo "${CYAN}[*] Creating $tun ...${RESET}"

  ip tunnel add "$tun" mode gre local "$local_ip" remote "$remote_ip" ttl 255 2>/dev/null || true
  ip link set "$tun" up
  ip addr add "$cidr" dev "$tun" 2>/dev/null || true
  [[ -n "$mtu" ]] && ip link set "$tun" mtu "$mtu" || true

  echo "${GREEN}[+] $tun OK  (${cidr})  local=${local_ip} remote=${remote_ip} mtu=${mtu}${RESET}"
}

delete_gre_all() {
  banner
  echo "${YELLOW}[*] Deleting all gre* tunnels...${RESET}"
  for t in $(ip -o link show | awk -F': ' '{print $2}' | grep -E "^gre[0-9]+$" || true); do
    ip link set "$t" down 2>/dev/null || true
    ip tunnel del "$t" 2>/dev/null || true
    echo "${YELLOW}[-] Deleted $t${RESET}"
  done
}

foreign_iptables_apply() {
  local gre_if="$1" wan_if="$2"

  banner
  echo "${CYAN}[*] Applying NAT/Forward (GRE:$gre_if -> WAN:$wan_if) ...${RESET}"

  iptables -t nat -C POSTROUTING -o "$wan_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$wan_if" -j MASQUERADE

  iptables -C FORWARD -i "$gre_if" -o "$wan_if" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$gre_if" -o "$wan_if" -j ACCEPT

  iptables -C FORWARD -i "$wan_if" -o "$gre_if" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$wan_if" -o "$gre_if" -m state --state RELATED,ESTABLISHED -j ACCEPT

  echo "${GREEN}[+] iptables OK${RESET}"
}

show_status() {
  banner
  echo "${CYAN}--- Interfaces (gre*) ---${RESET}"
  ip -br a | grep -E "^gre[0-9]+" || echo "No gre* interfaces."
  echo
  echo "${CYAN}--- Routes ---${RESET}"
  ip route | sed -n '1,40p'
  echo
  echo "${CYAN}--- iptables nat ---${RESET}"
  iptables -t nat -S | sed -n '1,80p'
}

set_iran_default_route() {
  local tun="$1" gw="$2"
  banner
  echo "${CYAN}[*] Setting default route via $tun ($gw) ...${RESET}"
  ip route replace default via "$gw" dev "$tun"
  echo "${GREEN}[+] Default route set${RESET}"
}

print_header() {
  echo -e "${CYAN}"
  echo "========================================"
  echo "        GRE Multi-Tunnel Menu"
  echo "========================================"
  echo -e "${RESET}"
}

menu_iran() {
  need_root
  echo
  read -rp "IRAN public IP: " IRAN_IP
  read -rp "How many FOREIGN servers to add? " N
  read -rp "MTU for GRE (default 1400): " MTU
  MTU=${MTU:-1400}

  banner
  echo "${CYAN}[*] Enabling IP Forward...${RESET}"
  enable_forward
  echo "${GREEN}[+] ip_forward enabled${RESET}"

  for i in $(seq 1 "$N"); do
    echo
    read -rp "FOREIGN$i public IP: " FIP
    TUN="gre$i"
    NET="${BASE}.${i}"
    IR_CIDR="${NET}.2/30"
    create_gre "$TUN" "$IRAN_IP" "$FIP" "$IR_CIDR" "$MTU"
    echo "${YELLOW}    Foreign side: ${NET}.1/30 on ${TUN}${RESET}"
  done

  echo
  banner
  echo "${CYAN}Optional:${RESET} Send ALL internet via gre1 (default route)."
  echo "1) Yes (default via ${BASE}.1.1 dev gre1)"
  echo "2) No"
  read -rp "Select: " opt
  if [[ "$opt" == "1" ]]; then
    set_iran_default_route "gre1" "${BASE}.1.1"
  fi

  pause
}

menu_foreign() {
  need_root
  echo
  read -rp "FOREIGN public IP: " F_IP
  read -rp "IRAN public IP: " IR_IP
  read -rp "Tunnel number (e.g. 1 for gre1): " IDX
  read -rp "MTU for GRE (default 1400): " MTU
  MTU=${MTU:-1400}

  banner
  echo "${CYAN}[*] Enabling IP Forward...${RESET}"
  enable_forward
  echo "${GREEN}[+] ip_forward enabled${RESET}"

  TUN="gre${IDX}"
  NET="${BASE}.${IDX}"
  FR_CIDR="${NET}.1/30"
  create_gre "$TUN" "$F_IP" "$IR_IP" "$FR_CIDR" "$MTU"

  WAN=$(detect_wan_if)
  foreign_iptables_apply "$TUN" "$WAN"

  echo
  banner
  echo "${GREEN}[+] FOREIGN ready. WAN=${WAN}${RESET}"
  echo "${YELLOW}    IRAN side: ${NET}.2/30 on ${TUN}${RESET}"
  pause
}

while true; do
  banner
  print_header
  echo "1) IRAN (Hub) - Add multiple FOREIGN tunnels"
  echo "2) FOREIGN (Spoke) - Create tunnel + NAT out"
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
    4) need_root; delete_gre_all; pause ;;
    5) need_root; banner; enable_forward; echo "${GREEN}[+] ip_forward enabled${RESET}"; pause ;;
    0) exit 0 ;;
    *) echo "${RED}[!] Invalid${RESET}"; pause ;;
  esac
done
