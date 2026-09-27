#!/usr/bin/env bash
# tun.sh - multi-server SSH TUN VPN manager.
# Commands: install | remove | start | stop | use | status | help

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
. "$SCRIPT_DIR/lib/strict.sh" && strict_mode_enable || exit 1

readonly PROG="$(basename "$0")"
readonly TUN_D_DIR="$SCRIPT_DIR/tun.d"
readonly UNIT_PATH="/etc/systemd/system/tun@.service"

# ==================================================================
# Global network configuration
# ==================================================================
#
# REAL_IFACE / REAL_GATEWAY: your physical interface and its gateway.
# Find them with:
#
#     ip route | grep '^default'
#
# Example output:
#
#     default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.42 metric 100
#
# REAL_IFACE   = token after "dev"
# REAL_GATEWAY = token after "via"
#
# These don't change mid-connection, so hardcode them.

REAL_IFACE="eth0"
REAL_GATEWAY="192.168.1.1"

# Tunnel addresses. Shared across servers because every server gets its
# own tun<id> interface, so they never collide.
CLIENT_TUN_IP="10.10.0.2"
SERVER_TUN_IP="10.10.0.1"

# Kernel tun device names are tun0..tun255. Pick ids that don't clash
# with any other VPN software on your machine.
readonly TUN_MIN_ID=0
readonly TUN_MAX_ID=255

# ==================================================================
# Global state
# ==================================================================

declare -A SERVER=()
SERVER_ID=""

# ==================================================================
# Help
# ==================================================================

usage() {
  cat <<EOF
Usage: $PROG <command> [<server-id>]

Commands:
  install <id>    Install systemd unit for <id> (enable only).
  remove  <id>    Stop, disable and clean up <id>.
  start   <id>    Bring up the tunnel: ssh, IPs, exception route.
  stop    <id>    Tear down the tunnel and clean up.
  use     <id>    Route the default route via <id>.
  use             Restore the real (non-tun) default route.
  status          Show current state of everything (default).
  help            Show this help.

Internal commands (invoked by systemd; not for direct use):
  run <id>        Run ssh in the foreground (unit ExecStart).

Server <id> is an integer in $TUN_MIN_ID..$TUN_MAX_ID matching
$TUN_D_DIR/<id>.sh, which declares:

  declare -A SERVER=(
    [HOST]="1.2.3.4"
    [USER]="root"
    [SSH_PORT]="22"   # optional, defaults to 22
  )

Tunnel IPs, REAL_IFACE and REAL_GATEWAY live in the global section of
this script.

Examples:
  $PROG install 1
  $PROG start 1
  $PROG use 1
  $PROG use
  $PROG status
EOF
}

# ==================================================================
# Config plumbing (private)
# ==================================================================

validate_id() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || die "server id must be an integer: '$id'"
  (( id >= TUN_MIN_ID && id <= TUN_MAX_ID )) || \
    die "server id out of range $TUN_MIN_ID..$TUN_MAX_ID: $id"
}

server_ids() {
  local f id
  for f in "$TUN_D_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    id=$(basename "$f" .sh)
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
      echo "Warning: ignoring non-numeric config: $f" >&2
      continue
    fi
    if (( id < TUN_MIN_ID || id > TUN_MAX_ID )); then
      echo "Warning: ignoring out-of-range id $id in $f" >&2
      continue
    fi
    printf '%s\n' "$id"
  done
}

# Load $TUN_D_DIR/<id>.sh into the global SERVER map. The file is
# executed in a subshell so nothing it does leaks into this shell,
# then only the SERVER declaration is imported. Dies with a specific
# message on any problem.
load_server_config() {
  local id="$1"
  local file="$TUN_D_DIR/$id.sh"
  [[ -f "$file" ]] || die "server config not found: $file"

  local dump
  dump=$( ( . "$file" 2>/dev/null; declare -p SERVER 2>/dev/null ) ) || \
    die "server config did not define SERVER: $file"

  [[ "$dump" == declare\ -A\ SERVER=* ]] || \
    die "server config must define associative array SERVER: $file"

  unset SERVER
  eval "${dump/#declare -A /declare -g -A }"

  [[ -n "${SERVER[HOST]:-}" ]] || die "server config missing [HOST]: $file"
  [[ -n "${SERVER[USER]:-}" ]] || die "server config missing [USER]: $file"
  [[ -v "SERVER[SSH_PORT]" ]] || SERVER[SSH_PORT]=22
  SERVER_ID="$id"
}

# ==================================================================
# Small helpers (private)
# ==================================================================

service_name() { echo "tun@$1.service"; }

service_installed() { systemctl cat "$(service_name "$1")" &>/dev/null; }
service_state()     { systemctl is-active "$(service_name "$1")" 2>/dev/null || true; }

tun_exists() { ip link show "$1" &>/dev/null; }

exception_route_exists() {
  local host="$1"
  ip route show "$host" 2>/dev/null | grep -q ' via '
}

ensure_exception_route() {
  local host="$1"
  exception_route_exists "$host" && return 0
  ip route replace "$host" via "$REAL_GATEWAY" dev "$REAL_IFACE"
}

remove_exception_route() {
  local host="$1"
  ip route del "$host" via "$REAL_GATEWAY" dev "$REAL_IFACE" 2>/dev/null || true
}

default_via_tun() {
  local tun_dev="$1" line dev
  line=$(ip route show default 2>/dev/null | head -1)
  [[ -z "$line" ]] && return 1
  dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$line")
  [[ "$dev" == "$tun_dev" ]]
}

remote_reachable() {
  local host="$1" port="$2" user="$3"
  timeout 2 ssh -p "$port" \
    -o BatchMode=yes -o ConnectTimeout=1 \
    -o StrictHostKeyChecking=accept-new \
    "$user@$host" true &>/dev/null
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "must run as root (try sudo)"
}

# ==================================================================
# Public commands
# ==================================================================

Install() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Error: install requires <server-id>" >&2; usage >&2; exit 1; }
  require_root
  require systemctl
  validate_id "$id"
  load_server_config "$id"

  if [[ ! -f "$UNIT_PATH" ]] || ! grep -qF "ExecStart=$SCRIPT_PATH run" "$UNIT_PATH"; then
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=SSH TUN VPN to %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH run %i
TimeoutStopSec=10
# No Restart=, no auto-start. Recovery is manual by design.

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  systemctl enable "$(service_name "$id")"
  echo "Installed: $id (enabled, not started)"
}

Remove() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Error: remove requires <server-id>" >&2; usage >&2; exit 1; }
  require_root
  require ip systemctl
  validate_id "$id"
  load_server_config "$id"

  if systemctl is-active --quiet "$(service_name "$id")" 2>/dev/null; then
    Stop "$id"
  fi
  systemctl disable "$(service_name "$id")" 2>/dev/null || true
  remove_exception_route "${SERVER[HOST]}"
  echo "Removed: $id"
}

Start() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Error: start requires <server-id>" >&2; usage >&2; exit 1; }
  require_root
  require ip ssh systemctl
  validate_id "$id"
  load_server_config "$id"

  local host="${SERVER[HOST]}"
  local user="${SERVER[USER]}"
  local port="${SERVER[SSH_PORT]}"
  local tun_dev="tun$id"
  local svc; svc="$(service_name "$id")"

  if [[ "$(service_state "$id")" == "active" ]]; then
    die "service $svc is already active (use stop first)"
  fi

  ensure_exception_route "$host"
  systemctl start "$svc" || die "systemctl start $svc failed"

  local waited=0
  while ! tun_exists "$tun_dev"; do
    if ! systemctl is-active --quiet "$svc"; then
      systemctl status "$svc" --no-pager >&2 || true
      die "service exited before $tun_dev appeared"
    fi
    sleep 0.1
    waited=$((waited + 1))
    if (( waited > 100 )); then
      systemctl stop "$svc" 2>/dev/null || true
      die "$tun_dev did not appear within 10s"
    fi
  done

  ip addr replace "$CLIENT_TUN_IP/32" peer "$SERVER_TUN_IP" dev "$tun_dev"
  ip link set "$tun_dev" up

  ssh -p "$port" -o BatchMode=yes -o ConnectTimeout=5 \
      "${user}@${host}" \
      "ip addr replace $SERVER_TUN_IP/32 peer $CLIENT_TUN_IP dev $tun_dev; \
       ip link set $tun_dev up"

  echo "Started: $id"
}

Stop() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Error: stop requires <server-id>" >&2; usage >&2; exit 1; }
  require_root
  require ip systemctl
  validate_id "$id"
  load_server_config "$id"

  local tun_dev="tun$id"
  local svc; svc="$(service_name "$id")"

  systemctl stop "$svc" 2>/dev/null || true

  if default_via_tun "$tun_dev"; then
    ip route replace default via "$REAL_GATEWAY" dev "$REAL_IFACE" || true
  fi
  ip link del "$tun_dev" 2>/dev/null || true

  echo "Stopped: $id"
}

Use() {
  require_root
  require ip
  local id="${1:-}"

  if [[ -z "$id" ]]; then
    ip route replace default via "$REAL_GATEWAY" dev "$REAL_IFACE"
    echo "Default route restored via $REAL_IFACE ($REAL_GATEWAY)"
    return 0
  fi

  validate_id "$id"
  load_server_config "$id"

  local tun_dev="tun$id"
  tun_exists "$tun_dev" || die "tunnel $id is not up ($tun_dev missing)"

  ensure_exception_route "${SERVER[HOST]}"
  ip route replace default via "$SERVER_TUN_IP" dev "$tun_dev"
  echo "Default route now via server $id ($tun_dev -> $SERVER_TUN_IP)"
}

Status() {
  require ip ssh systemctl

  echo "=== Global ==="
  printf '  Script:          %s\n' "$SCRIPT_PATH"
  printf '  REAL_IFACE:      %s\n' "$REAL_IFACE"
  printf '  REAL_GATEWAY:    %s\n' "$REAL_GATEWAY"
  printf '  CLIENT_TUN_IP:   %s\n' "$CLIENT_TUN_IP"
  printf '  SERVER_TUN_IP:   %s\n' "$SERVER_TUN_IP"
  printf '  Current default: %s\n' \
    "$(ip route show default 2>/dev/null | head -1 || echo '<none>')"

  echo
  echo "=== Servers ==="

  local id any=0
  while IFS= read -r id; do
    any=1
    printf '  [%s]\n' "$id"

    # Probe validity in a subshell so a broken config doesn't abort
    # the whole report.
    if ! ( load_server_config "$id" ) >/dev/null 2>&1; then
      printf '    Config:            INVALID\n'
      continue
    fi
    load_server_config "$id"

    local tun_dev="tun$id"
    local host="${SERVER[HOST]}"
    local user="${SERVER[USER]}"
    local port="${SERVER[SSH_PORT]}"

    printf '    Host:              %s@%s:%s\n' "$user" "$host" "$port"
    printf '    Tun device:        %s\n' "$tun_dev"

    if service_installed "$id"; then
      printf '    Service installed: yes\n'
      printf '    Service state:     %s\n' "$(service_state "$id")"
    else
      printf '    Service installed: no\n'
    fi

    tun_exists "$tun_dev" \
      && printf '    Tun up:            yes\n' \
      || printf '    Tun up:            no\n'

    exception_route_exists "$host" \
      && printf '    Exception route:   yes\n' \
      || printf '    Exception route:   no\n'

    default_via_tun "$tun_dev" \
      && printf '    Carries default:   YES\n' \
      || printf '    Carries default:   no\n'

    remote_reachable "$host" "$port" "$user" \
      && printf '    Remote reachable:  yes\n' \
      || printf '    Remote reachable:  no\n'
  done < <(server_ids)

  (( any == 0 )) && echo "  (no servers configured in $TUN_D_DIR)"
}

# Exposed for systemd (ExecStart of tun@<id>.service), documented
# under "Internal commands" in --help. Do not call directly.
Run() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Error: run requires <server-id>" >&2; usage >&2; exit 1; }
  validate_id "$id"
  load_server_config "$id"

  exec ssh -N -w "$id:$id" \
      -o Tunnel=point-to-point \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -p "${SERVER[SSH_PORT]}" \
      "${SERVER[USER]}@${SERVER[HOST]}"
}

# ==================================================================
# Dispatch
# ==================================================================

main() {
  local cmd="${1:-status}"
  local arg="${2:-}"

  case "$cmd" in
    -h|--help|help) usage; exit 0 ;;

    install) Install "$arg" ;;
    remove)  Remove  "$arg" ;;
    start)   Start   "$arg" ;;
    stop)    Stop    "$arg" ;;
    use)     Use     "$arg" ;;

    status)  Status ;;

    run)     Run "$arg" ;;

    *)
      echo "Error: unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"