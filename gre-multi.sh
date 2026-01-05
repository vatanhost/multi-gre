#!/bin/bash
set -e

GREEN=$(tput setaf 2 2>/dev/null || true)
CYAN=$(tput setaf 6 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

BASE="10.10"        # ثابت
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
  [[ -n "$w" ]] && echo "$w" || echo "$DEFAULT_WAN"
}

# --- GRE helpers (local omitted by design for simplicity) ---
create_gre_no_local() {
  local tun="$1" remote_ip="$2" cidr="$3" mtu="$4"

  ip tunnel add "$tun" mode gre remote "$remote_ip" ttl 255 2>/dev/null || true
  ip link set "$tun" up
  ip addr add "$cidr" dev "$tun" 2>/dev/null || true
  [[ -n "$mtu" ]] && ip link set "$tun" mtu "$mtu" || true
}

# For IRAN hub (explicit local for stability)
create_gre_with_local() {
  local tun="$1" local_ip="$2" remote_ip="$3" cidr="$4" mtu="$5"

  ip tunnel add "$tun" mode gre local "$local_ip" remote "$remote_ip" ttl 255 2>/dev/null || true
  ip link set "$tun" up
  ip addr add "$cidr" dev "$tun" 2>/dev/null || true
  [[ -n "$mtu" ]] && ip link set "$tun" mtu "$mtu" || true
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

  iptables -t nat -C POSTROUTING -o "$wan_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$wan_if" -j MASQUERADE

  iptables -C FORWARD -i "$gre_if" -o "$wan_if" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$gre_if" -o "$wan_if" -j ACCEPT

  iptables -C FORWARD -i "$wan_if" -o "$gre_if" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$wan_if" -o "$gre_if" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

health_check_one() {
  local tun="$1" my_ip="$2" peer_ip="$3"
  echo "${CYAN}--- Health Check: ${tun} ---${RESET}"

  if ip link show "$tun" >/dev/null 2>&1; then
    local state
    state=$(ip -o link show "$tun" | awk '{print $9}' 2>/dev/null || true)
    echo "Link: ${tun} state=${state:-unknown}"
  else
    echo "${RED}Link: ${tun} NOT FOUND${RESET}"
    return 0
  fi

  if ip -4 addr show dev "$tun" | grep -q "$my_ip"; then
    echo "IP:   ${my_ip} OK"
  else
    echo "${RED}IP:   ${my_ip} NOT SET${RESET}"
  fi

  if ping -c 2 -W 1 "$peer_ip" >/dev/null 2>&1; then
    echo "${GREEN}PING: ${peer_ip} OK${RESET}"
  else
    echo "${RED}PING: ${peer_ip} FAIL${RESET}"
  fi
  echo
}

health_check_all_existing() {
  banner
  echo "${CYAN}[*] Checking all gre* interfaces...${RESET}"
  local any=0
  for t in $(ip -o link show | awk -F': ' '{print $2}' | grep -E "^gre[0-9]+$" || true); do
    any=1
    local idx
    idx=$(echo "$t" | sed 's/^gre//')
    local net="${BASE}.${idx}"
    # We don't know if this host is IR or Foreign, so test both peer IPs (best-effort)
    echo "${CYAN}--- ${t} (${net}.0/30) ---${RESET}"
    ip -br a show dev "$t" || true
    ping -c 1 -W 1 "${net}.1" >/dev/null 2>&1 && echo "${GREEN}PING ${net}.1 OK${RESET}" || echo "${YELLOW}PING ${net}.1 no${RESET}"
    ping -c 1 -W 1 "${net}.2" >/dev/null 2>&1 && echo "${GREEN}PING ${net}.2 OK${RESET}" || echo "${YELLOW}PING ${net}.2 no${RESET}"
    echo
  done
  [[ $any -eq 0 ]] && echo "${YELLOW}No gre* interfaces found.${RESET}"
}

set_iran_default_route() {
  local tun="$1" gw="$2"
  ip route replace default via "$gw" dev "$tun"
}

print_header() {
  echo -e "${CYAN}"
  echo "========================================"
  echo "        GRE Multi-Tunnel Menu"
  echo "========================================"
  echo -e "${RESET}"
}

# ---------------- Menus ----------------

menu_iran() {
  need_root
  banner
  echo "${CYAN}IRAN (Hub) setup${RESET}"
  echo
  read -rp "IRAN public IP: " IRAN_IP
  read -rp "How many FOREIGN servers? " N
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

    banner
    echo "${CYAN}[*] Creating ${TUN} ...${RESET}"
    create_gre_with_local "$TUN" "$IRAN_IP" "$FIP" "$IR_CIDR" "$MTU"
  done

  # Optional: default route via gre1
  banner
  echo "${CYAN}Optional:${RESET} Send ALL internet via FOREIGN1 (gre1)."
  echo "1) Yes"
  echo "2) No"
  read -rp "Select: " opt
  if [[ "$opt" == "1" ]]; then
    set_iran_default_route "gre1" "${BASE}.1.1"
    echo "${GREEN}[+] Default route set via gre1 (${BASE}.1.1)${RESET}"
  else
    echo "${YELLOW}[-] Skipped default route${RESET}"
  fi

  # Health check
  banner
  echo "${CYAN}[*] Health check (IRAN) ...${RESET}"
  for i in $(seq 1 "$N"); do
    TUN="gre$i"
    NET="${BASE}.${i}"
    health_check_one "$TUN" "${NET}.2" "${NET}.1"
  done

  pause
}

menu_foreign() {
  need_root
  banner
  echo "${CYAN}FOREIGN (Spoke) setup${RESET}"
  echo
  read -rp "IRAN public IP: " IR_IP
  read -rp "Tunnel number (1/2/3/...): " IDX
  read -rp "MTU for GRE (default 1400): " MTU
  MTU=${MTU:-1400}

  banner
  echo "${CYAN}[*] Enabling IP Forward...${RESET}"
  enable_forward
  echo "${GREEN}[+] ip_forward enabled${RESET}"

  TUN="gre${IDX}"
  NET="${BASE}.${IDX}"
  FR_CIDR="${NET}.1/30"

  banner
  echo "${CYAN}[*] Creating ${TUN} ...${RESET}"
  create_gre_no_local "$TUN" "$IR_IP" "$FR_CIDR" "$MTU"
  echo "${GREEN}[+] ${TUN} created${RESET}"

  # NAT out
  WAN=$(detect_wan_if)
  banner
  echo "${CYAN}[*] Applying NAT out (WAN=${WAN}) ...${RESET}"
  foreign_iptables_apply "$TUN" "$WAN"
  echo "${GREEN}[+] NAT/Forward applied${RESET}"

  # Health check
  banner
  echo "${CYAN}[*] Health check (FOREIGN) ...${RESET}"
  health_check_one "$TUN" "${NET}.1" "${NET}.2"

  pause
}

show_status() {
  banner
  echo "${CYAN}--- Interfaces (gre*) ---${RESET}"
  ip -br a | grep -E "^gre[0-9]+" || echo "No gre* interfaces."
  echo
  echo "${CYAN}--- Routes ---${RESET}"
  ip route | sed -n '1,60p'
  echo
  echo "${CYAN}--- iptables nat (top) ---${RESET}"
  iptables -t nat -S | sed -n '1,80p'
  echo
  health_check_all_existing
}

# ---------------- Main loop ----------------
while true; do
  banner
  print_header
  echo "1) IRAN (Hub) - Add multiple FOREIGN tunnels (only asks FOREIGN IPs)"
  echo "2) FOREIGN (Spoke) - Create tunnel + NAT out (only asks IRAN IP)"
  echo "3) Show status + Health Check"
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
