#!/usr/bin/env bash
# server-setup.sh - one-time server-side setup for tun.sh (SSH TUN VPN).
#
# Run as root on each SSH server. Idempotent: safe to re-run.
#
# Commands:
#   install   Apply all changes (sysctl, sshd, firewall, persistence).
#   status    Show current state of everything.
#   help      Show this help.

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
. "$SCRIPT_DIR/lib/strict.sh" && strict_mode_enable || exit 1

readonly PROG="$(basename "$0")"

# ==================================================================
# Configuration
# ==================================================================
#
# CLIENT_TUN_IP: the tunnel client IP (your desktop). Must equal
# CLIENT_TUN_IP in tun.sh on the desktop. All servers share the same
# value because each server only ever sees one client — your desktop.
#
# PUBLIC_IFACE: the server's public network interface. Leave empty to
# auto-detect. Find it manually with:
#     ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'

CLIENT_TUN_IP="10.10.0.2"
PUBLIC_IFACE=""

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_DROP_IN_DIR="/etc/ssh/sshd_config.d"
readonly SSHD_DROP_IN="$SSHD_DROP_IN_DIR/99-tun-vpn.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-tun-vpn.conf"

# ==================================================================
# Help
# ==================================================================

usage() {
  cat <<EOF
Usage: $PROG <command>

Commands:
  install   Apply server-side setup for tun.sh (idempotent).
  status    Show current state.
  help      Show this help.

Setup performed by "install":
  - Load the "tun" kernel module and persist it across reboots.
  - Enable IPv4 forwarding persistently ($SYSCTL_FILE).
  - Set PermitTunnel yes for sshd ($SSHD_DROP_IN).
  - Add iptables FORWARD and MASQUERADE rules for $CLIENT_TUN_IP/32.
  - Persist iptables rules via iptables-persistent.

Assumes the desktop's tun.sh uses CLIENT_TUN_IP=$CLIENT_TUN_IP and
connects as root (or a user sshd will grant tun device access to).

This script does NOT modify PermitRootLogin. On Ubuntu the default
("prohibit-password") already allows key-based root SSH, which is
enough for ssh -w.
EOF
}

# ==================================================================
# Helpers
# ==================================================================

require_root() {
  [[ "$EUID" -eq 0 ]] || die "must run as root (try sudo)"
}

detect_public_iface() {
  [[ -n "$PUBLIC_IFACE" ]] && return 0
  PUBLIC_IFACE=$(ip route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$PUBLIC_IFACE" ]] || die "cannot auto-detect public interface; set PUBLIC_IFACE in this script"
}

# Add an iptables rule if it's not already present.
iptables_add() {
  local table="$1"; shift
  iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
}

# Print whether an iptables rule is present, for status output.
report_rule() {
  local table="$1"; shift
  local spec="$*"
  if iptables -t "$table" -C "$@" 2>/dev/null; then
    printf '  present:  iptables -t %s %s\n' "$table" "$spec"
  else
    printf '  MISSING:  iptables -t %s %s\n' "$table" "$spec"
  fi
}

# ==================================================================
# Setup steps
# ==================================================================

setup_tun_module() {
  modprobe tun
  echo tun > /etc/modules-load.d/tun.conf
}

setup_sysctl() {
  cat > "$SYSCTL_FILE" <<EOF
# Managed by server-setup.sh (tun.sh SSH TUN VPN).
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

setup_sshd() {
  [[ -d "$SSHD_DROP_IN_DIR" ]] || \
    die "$SSHD_DROP_IN_DIR does not exist; add 'PermitTunnel yes' to $SSHD_CONFIG manually"
  grep -qE "^[[:space:]]*Include[[:space:]]+$SSHD_DROP_IN_DIR/\\*\\.conf" "$SSHD_CONFIG" || \
    die "'Include $SSHD_DROP_IN_DIR/*.conf' missing from $SSHD_CONFIG; add 'PermitTunnel yes' manually"

  cat > "$SSHD_DROP_IN" <<EOF
# Managed by server-setup.sh (tun.sh SSH TUN VPN).
PermitTunnel yes
EOF

  sshd -t || die "sshd config test failed after writing $SSHD_DROP_IN"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
}

setup_firewall() {
  detect_public_iface

  iptables_add filter FORWARD \
    -i tun0 -o "$PUBLIC_IFACE" -j ACCEPT

  iptables_add filter FORWARD \
    -i "$PUBLIC_IFACE" -o tun0 \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  iptables_add nat POSTROUTING \
    -s "$CLIENT_TUN_IP/32" -o "$PUBLIC_IFACE" -j MASQUERADE
}

setup_persistence() {
  if ! dpkg -l iptables-persistent 2>/dev/null | grep -q '^ii'; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
  fi
  netfilter-persistent save >/dev/null
}

# ==================================================================
# Public commands
# ==================================================================

Install() {
  require_root
  require ip iptables sysctl systemctl sshd modprobe
  detect_public_iface

  setup_tun_module
  setup_sysctl
  setup_sshd
  setup_firewall
  setup_persistence

  echo "Server setup complete."
  echo "  Public interface: $PUBLIC_IFACE"
  echo "  NAT source:       $CLIENT_TUN_IP/32"
  echo "  IP forwarding:    enabled and persistent"
  echo "  PermitTunnel:     yes (sshd reloaded)"
  echo "  iptables rules:   applied and persistent"
}

Status() {
  require_root
  require ip iptables sysctl systemctl sshd
  detect_public_iface 2>/dev/null || true

  echo "=== Kernel module ==="
  if lsmod | grep -q '^tun '; then
    echo "  tun: loaded"
  else
    echo "  tun: NOT loaded"
  fi
  printf '  /etc/modules-load.d/tun.conf: %s\n' \
    "$( [[ -f /etc/modules-load.d/tun.conf ]] && echo present || echo missing )"

  echo
  echo "=== IP forwarding ==="
  printf '  net.ipv4.ip_forward = %s\n' \
    "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
  printf '  %s: %s\n' "$SYSCTL_FILE" \
    "$( [[ -f "$SYSCTL_FILE" ]] && echo present || echo missing )"

  echo
  echo "=== sshd ==="
  printf '  %s: %s\n' "$SSHD_DROP_IN" \
    "$( [[ -f "$SSHD_DROP_IN" ]] && echo present || echo missing )"
  if sshd -T 2>/dev/null | grep -q '^permittunnel yes'; then
    echo "  effective: PermitTunnel yes"
  else
    echo "  effective: PermitTunnel no (or unknown)"
  fi

  echo
  echo "=== Firewall ==="
  if [[ -n "$PUBLIC_IFACE" ]]; then
    printf '  Public interface: %s\n' "$PUBLIC_IFACE"
    report_rule filter FORWARD -i tun0 -o "$PUBLIC_IFACE" -j ACCEPT
    report_rule filter FORWARD -i "$PUBLIC_IFACE" -o tun0 \
      -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    report_rule nat POSTROUTING -s "$CLIENT_TUN_IP/32" -o "$PUBLIC_IFACE" -j MASQUERADE
  else
    echo "  Public interface: <unknown>"
  fi

  echo
  echo "=== Persistence ==="
  if dpkg -l iptables-persistent 2>/dev/null | grep -q '^ii'; then
    echo "  iptables-persistent: installed"
    printf '  /etc/iptables/rules.v4: %s\n' \
      "$( [[ -f /etc/iptables/rules.v4 ]] && echo present || echo missing )"
  else
    echo "  iptables-persistent: NOT installed"
  fi
}

# ==================================================================
# Dispatch
# ==================================================================

main() {
  local cmd="${1:-status}"
  case "$cmd" in
    -h|--help|help) usage; exit 0 ;;
    install) Install ;;
    status)  Status  ;;
    *)
      echo "Error: unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"