#!/usr/bin/env bash
# tun.sh - multi-server SSH TUN VPN manager.
# Commands: install | remove | start | stop | use | status | watch-leaks | help

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
. "$SCRIPT_DIR/lib/strict.sh" && strict_mode_enable || exit 1

readonly PROG="$(basename "$0")"
readonly TUN_D_DIR="$SCRIPT_DIR/tun.d"
readonly SERVERS_DIR="$TUN_D_DIR/servers"
readonly LOCAL_CONFIG="$TUN_D_DIR/localhost.sh"
readonly UNIT_DIR="/etc/systemd/system"

# ==================================================================
# Global network configuration
# ==================================================================
#
# System-specific values (REAL_IFACE, REAL_GATEWAY, ...) live in
# $LOCAL_CONFIG, not here. That file is generated on first use with
# best-effort auto-detected values:
#
#     ip route | grep '^default'
#     default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.42 metric 100
#         REAL_IFACE   = token after "dev"
#         REAL_GATEWAY = token after "via"
#
# These don't change mid-connection, so they're hardcoded in that file.
# What follows here is global: sensible on any system as-is.

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
#
# SERVER and EXCEPTIONS are pre-declared here (assoc / indexed) so that
# server configs, which are sourced from within load_server_config, can
# fill them with plain assignments. A bare assignment targets the global
# unless `declare`/`local` recreates it in a function scope — which is
# why configs must NOT use `declare` for these (see usage()).

declare -A SERVER=()
declare -a EXCEPTIONS=()
declare -a LEAKS=()
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
  use     <id>    Install and/or start <id> as needed, then route via it.
  use             Restore the real (non-tun) default route.
  status          Show current state of everything (default).
  watch-leaks     Show traffic leaking around the tunnel (tun must be in use).
  help            Show this help.

Internal commands (invoked by systemd; not for direct use):
  run <id>        Run ssh in the foreground (unit ExecStart).

Server <id> is an integer in $TUN_MIN_ID..$TUN_MAX_ID matching
$SERVERS_DIR/<id>.sh, which declares:

  . "$TUN_D_DIR/exceptions.sh"   # shared list of IPs kept off the tunnel

  SERVER[HOST]="1.2.3.4"
  SERVER[USER]="root"
  SERVER[SSH_PORT]="22"   # optional, defaults to 22
  SERVER[DESC]="RU-0"     # optional, human-readable label

  EXCEPTIONS+=( "5.6.7.8" )   # optional extra exceptions for this server

SERVER is a pre-declared associative array, so fill it with plain
key=value assignments — do NOT redeclare it with the declare keyword
inside the config (that would create a local copy in the loading
function's scope). A server's own [HOST] is exempted from the tunnel
automatically.

Each id gets its own unit file $UNIT_DIR/tun-<id>.service, so ids
are installed and removed independently.

Tunnel IPs live in the global section of this script. System-specific
values (REAL_IFACE, REAL_GATEWAY) live in $TUN_D_DIR/localhost.sh,
auto-generated with best-effort detection on first use.

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

# Best-effort: find a physical (non-tun) default route and print
# "<iface> <gateway>". Empty output means detection failed.
detect_real_route() {
  local route dev via

  # Scan the routing table's default routes, skipping any that go
  # through a tun device (i.e. this very VPN when it's up).
  while IFS= read -r route; do
    [[ -z "$route" ]] && continue
    dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$route")
    [[ -n "$dev" && "$dev" != tun* ]] || continue
    via=$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$route")
    printf '%s %s\n' "$dev" "$via"
    return 0
  done < <(ip route show default 2>/dev/null)

  # No usable default route: ask the kernel how it would reach the
  # internet instead.
  route=$(ip route get 8.8.8.8 2>/dev/null | head -1 || true)
  [[ -z "$route" ]] && return 1
  dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$route")
  [[ -n "$dev" && "$dev" != tun* ]] || return 1
  via=$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$route")
  printf '%s %s\n' "$dev" "$via"
  return 0
}

# Load system-specific values (REAL_IFACE, REAL_GATEWAY, ...) from
# $LOCAL_CONFIG. When the file is missing, generate it with
# best-effort auto-detected values. If the file cannot be written
# (e.g. not run as root and the dir is not writable), fall back to
# detected values in memory for this run only.
load_local_config() {
  LOCAL_CONFIG_SOURCE="file"

  if [[ ! -f "$LOCAL_CONFIG" ]]; then
    local line iface gateway
    line=$(detect_real_route || true)
    if [[ -n "$line" ]]; then
      read -r iface gateway <<<"$line"
    else
      iface=""
      gateway=""
    fi

    if {
         cat > "$LOCAL_CONFIG" <<EOF
# $PROG system-specific configuration (auto-generated).
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
# Auto-detection is best-effort. If these values look wrong or are
# empty, edit this file and set them manually.
#
# LEAKS: tcpdump filter expressions for traffic that is *expected* on the
# physical interface even when the tunnel carries the default route, so
# watch-leaks must not report it. Tune these to your network.

REAL_IFACE="$iface"
REAL_GATEWAY="$gateway"

LEAKS=(
  "ether multicast"
  "igmp"
  "arp"
)
EOF
       } 2>/dev/null; then
      LOCAL_CONFIG_SOURCE="generated"
      echo "Note: generated $LOCAL_CONFIG with auto-detected values (review it)." >&2
    else
      LOCAL_CONFIG_SOURCE="auto-detected (not saved)"
      REAL_IFACE="$iface"
      REAL_GATEWAY="$gateway"
      echo "Warning: cannot write $LOCAL_CONFIG; using auto-detected values for this run." >&2
      return 0
    fi
  fi

  . "$LOCAL_CONFIG"

  [[ -n "${REAL_IFACE:-}" && -n "${REAL_GATEWAY:-}" ]] || \
    die "$LOCAL_CONFIG is incomplete: set non-empty REAL_IFACE and REAL_GATEWAY"
}

validate_id() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || die "server id must be an integer: '$id'"
  (( id >= TUN_MIN_ID && id <= TUN_MAX_ID )) || \
    die "server id out of range $TUN_MIN_ID..$TUN_MAX_ID: $id"
}

server_ids() {
  local f id
  for f in "$SERVERS_DIR"/*.sh; do
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

# Load $SERVERS_DIR/<id>.sh into the global SERVER map and EXCEPTIONS
# array. The config is sourced in this shell; because SERVER and
# EXCEPTIONS are pre-declared globals (see "Global state") and the config
# only uses plain assignments, they land in global scope rather than in
# this function's locals. Dies with a specific message on any problem.
load_server_config() {
  local id="$1"
  local file="$SERVERS_DIR/$id.sh"
  [[ -f "$file" ]] || die "server config not found: $file"

  # Reset first so fields a config leaves unset don't leak from whatever
  # server was loaded before.
  SERVER=()
  EXCEPTIONS=()
  . "$file"

  [[ -n "${SERVER[HOST]:-}" ]] || die "server config missing [HOST]: $file"
  [[ -n "${SERVER[USER]:-}" ]] || die "server config missing [USER]: $file"
  [[ -v "SERVER[SSH_PORT]" ]] || SERVER[SSH_PORT]=22
  [[ -v "SERVER[DESC]" ]] || SERVER[DESC]=""
  SERVER_ID="$id"
}

# ==================================================================
# Small helpers (private)
# ==================================================================

# Each server id gets its own unit file, no systemd template involved.
unit_path_for() { printf '%s/tun-%s.service' "$UNIT_DIR" "$1"; }
service_name()  { printf 'tun-%s.service' "$1"; }

# " (DESC)" when the loaded server declares a human-readable [DESC],
# empty string otherwise. Used in human-facing output.
server_label() {
  local desc="${SERVER[DESC]:-}"
  if [[ -n "$desc" ]]; then
    printf ' (%s)' "$desc"
  fi
  return 0
}

# Installed == its own unit file is present on disk.
service_installed() { [[ -f "$(unit_path_for "$1")" ]]; }
service_state()     { systemctl is-active "$(service_name "$1")" 2>/dev/null || true; }

# Absolute path systemd resolves for a unit's ExecStart, or "" if the
# unit is not installed or the path can't be determined. Compared
# against SCRIPT_PATH to detect a unit left over from an older/moved
# checkout.
unit_exec_path() {
  local id="${1:-}"
  local svc; svc="$(service_name "$id")"
  local show path
  show=$(systemctl show -p ExecStart "$svc" 2>/dev/null) || return 0
  [[ "$show" == *path=* ]] || return 0
  path="${show#*path=}"
  path="${path%% *}"
  printf '%s' "$path"
}

# Human-readable reason for a failed unit: the process exit status
# plus the last error line from its journal. Tolerates permission
# problems gracefully (falls back to just the exit status).
service_failure_detail() {
  local svc; svc="$(service_name "$1")"
  local status line
  status=$(systemctl show -p ExecMainStatus "$svc" 2>/dev/null \
    | cut -d= -f2- || true)
  line=$(journalctl -u "$svc" -n 100 --no-pager -o cat 2>/dev/null \
    | grep -a -E 'Disconnecting|Failed at step|No such file|denied|timed out|unreachable|refused|reset|reset by peer' \
    | tail -1 || true)

  if [[ -n "$status" && -n "$line" ]]; then
    printf 'exit %s: %s' "$status" "$line"
  elif [[ -n "$line" ]]; then
    printf '%s' "$line"
  elif [[ -n "$status" ]]; then
    printf 'exit %s' "$status"
  else
    printf 'no log detail available'
  fi
}

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

# Print the effective exception list for the loaded server: its own HOST
# (always exempted, so the tunnel's SSH transport never loops) plus every
# configured EXCEPTIONS entry, deduplicated.
effective_exceptions() {
  local -A seen=()
  local ip
  for ip in "${SERVER[HOST]}" "${EXCEPTIONS[@]}"; do
    [[ -n "$ip" && -z "${seen[$ip]:-}" ]] || continue
    seen["$ip"]=1
    printf '%s\n' "$ip"
  done
}

# Apply/clear exception routes for every IP in effective_exceptions().
ensure_exception_routes() {
  local ip
  while IFS= read -r ip; do
    ensure_exception_route "$ip"
  done < <(effective_exceptions)
}

remove_exception_routes() {
  local ip
  while IFS= read -r ip; do
    remove_exception_route "$ip"
  done < <(effective_exceptions)
}

default_via_tun() {
  local tun_dev="$1" line dev
  line=$(ip route show default 2>/dev/null | head -1)
  [[ -z "$line" ]] && return 1
  dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$line")
  [[ "$dev" == "$tun_dev" ]]
}

# Print the id of the server whose tunnel currently carries the default
# route, or nothing (exit status 1) if none does.
active_server_id() {
  local id
  while IFS= read -r id; do
    if default_via_tun "tun$id"; then
      printf '%s\n' "$id"
      return 0
    fi
  done < <(server_ids)
  return 1
}

ssh_fail_reason() {
  local rc="$1" msg="$2"
  if (( rc == 124 )); then
    printf 'timed out'
    return 0
  fi
  # First non-empty line of stderr, with the routine prefix stripped.
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s' "${line#ssh: }"
    return 0
  done <<<"$msg"
  printf 'connection failed'
  return 0
}

# Probe whether the server answers ssh. Sets REMOTE_ERR to "" on
# success or a short human-readable reason on failure.
remote_reachable() {
  local host="$1" port="$2" user="$3" err rc
  if err=$(timeout 4 ssh -p "$port" \
        -o BatchMode=yes -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=accept-new \
        "$user@$host" true </dev/null 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if (( rc == 0 )); then
    REMOTE_ERR=""
    return 0
  fi
  REMOTE_ERR="$(ssh_fail_reason "$rc" "$err")"
  return 1
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "must run as root (try sudo)"
}

# Defensive: `systemctl disable` already removes the .wants symlink,
# but a partial/hand-edited state shouldn't survive `remove`.
remove_enable_symlinks() {
  local id="$1" svc link
  svc="$(service_name "$id")"
  for link in /etc/systemd/system/*.wants/"$svc"; do
    [[ -e "$link" || -L "$link" ]] && rm -f "$link"
  done
  return 0
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

  local unit_path; unit_path="$(unit_path_for "$id")"

  if [[ ! -f "$unit_path" ]] || ! grep -qF "ExecStart=$SCRIPT_PATH run $id" "$unit_path"; then
    cat > "$unit_path" <<EOF
[Unit]
Description=SSH TUN VPN to $id
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH run $id
TimeoutStopSec=10
# No Restart=, no auto-start. Recovery is manual by design.

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  systemctl enable "$(service_name "$id")"
  echo "Installed: $id$(server_label) (enabled, not started)"
}

Remove() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Error: remove requires <server-id>" >&2; usage >&2; exit 1; }
  require_root
  require ip systemctl
  load_local_config
  validate_id "$id"
  load_server_config "$id"

  # Always run the stop path. A failed unit is not "active", but may
  # still have a tun device/exception route and a failed systemd state.
  Stop "$id"

  # Full teardown of this id's unit: drop the .wants symlink, clear
  # any residual state, remove the unit file itself. Nothing about
  # other ids is touched.
  local svc; svc="$(service_name "$id")"
  local unit_path; unit_path="$(unit_path_for "$id")"

  systemctl disable "$svc" 2>/dev/null || true
  remove_enable_symlinks "$id"
  systemctl reset-failed "$svc" 2>/dev/null || true
  rm -f "$unit_path"
  systemctl daemon-reload

  remove_exception_routes

  echo "Removed: $id$(server_label)"
}

Start() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Error: start requires <server-id>" >&2; usage >&2; exit 1; }
  require_root
  require ip ssh systemctl
  load_local_config
  validate_id "$id"
  load_server_config "$id"

  local host="${SERVER[HOST]}"
  local user="${SERVER[USER]}"
  local port="${SERVER[SSH_PORT]}"
  local tun_dev="tun$id"
  local svc; svc="$(service_name "$id")"

  # If the unit was installed from a moved/older checkout, update it
  # in place. Otherwise systemd would fail with a cryptic 203/EXEC.
  local exec_path
  if service_installed "$id"; then
    exec_path="$(unit_exec_path "$id" || true)"
    if [[ -n "$exec_path" && "$exec_path" != "$SCRIPT_PATH" ]]; then
      echo "Unit $svc points to stale path $exec_path; reinstalling for $SCRIPT_PATH." >&2
      Install "$id"
    fi
  fi

  if [[ "$(service_state "$id")" == "active" ]]; then
    die "service $svc is already active (use stop first)"
  fi

  ensure_exception_routes
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

  echo "Started: $id$(server_label)"
}

Stop() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "Error: stop requires <server-id>" >&2; usage >&2; exit 1; }
  require_root
  require ip systemctl
  load_local_config
  validate_id "$id"
  load_server_config "$id"

  local tun_dev="tun$id"
  local svc; svc="$(service_name "$id")"

  systemctl stop "$svc" 2>/dev/null || true
  systemctl reset-failed "$svc" 2>/dev/null || true

  if default_via_tun "$tun_dev"; then
    ip route replace default via "$REAL_GATEWAY" dev "$REAL_IFACE" || true
  fi
  ip link del "$tun_dev" 2>/dev/null || true
  remove_exception_routes

  echo "Stopped: $id$(server_label)"
}

Use() {
  require_root
  local id="${1:-}"

  if [[ -z "$id" ]]; then
    require ip
    load_local_config
    ip route replace default via "$REAL_GATEWAY" dev "$REAL_IFACE"
    echo "Default route restored via $REAL_IFACE ($REAL_GATEWAY)"
    return 0
  fi

  require ip ssh systemctl
  load_local_config
  validate_id "$id"
  load_server_config "$id"

  local tun_dev="tun$id"

  # Auto-provision: install the unit if it's missing, then make sure the
  # service is actually running. We never roll anything back here — if
  # either step fails, the error propagates and the previous default
  # route (if any) is left untouched.
  if ! service_installed "$id"; then
    echo "Server $id is not installed; installing it now." >&2
    Install "$id"
  fi

  if [[ "$(service_state "$id")" != "active" ]]; then
    echo "Service $(service_name "$id") is not running; starting it now." >&2
    Start "$id"
  fi

  ensure_exception_routes
  ip route replace default via "$SERVER_TUN_IP" dev "$tun_dev"
  echo "Default route now via server $id$(server_label) ($tun_dev -> $SERVER_TUN_IP)"
}

# Print the tcpdump capture filter for leak-watching: everything except
# the effective exceptions and the known leaks in $LEAKS. Emits
# "not ()" when there is nothing to exclude.
leak_filter() {
  local -a terms=()
  local ip leak
  while IFS= read -r ip; do terms+=("host $ip"); done < <(effective_exceptions)
  for leak in "${LEAKS[@]}"; do terms+=("$leak"); done

  local joined="" t
  for t in "${terms[@]}"; do
    if [[ -z "$joined" ]]; then joined="$t"; else joined="$joined or $t"; fi
  done
  printf 'not (%s)' "$joined"
}

WatchLeaks() {
  require_root
  require ip tcpdump
  load_local_config

  # Only while a tunnel carries the default route. Which server that is
  # determines the exception list (its own host plus its EXCEPTIONS).
  local id
  id="$(active_server_id)" || die "tun is not in use"
  load_server_config "$id"

  local filter
  filter="$(leak_filter)"
  [[ "$filter" != "not ()" ]] || \
    die "no exceptions or known leaks configured"

  echo "Watching for leaks on $REAL_IFACE (default via tun$id, server $id$(server_label))" >&2
  echo "Filter: $filter" >&2
  exec tcpdump -i "$REAL_IFACE" -n -nn "$filter"
}

# ==================================================================
# Colors (status output only)
# ==================================================================
#
# Palette semantics: green = healthy/active, yellow = needs attention,
# red = broken. Colors are disabled when stdout is not a terminal or
# when NO_COLOR is set, so piping status through grep/less stays clean.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[0;31m'
  C_YELLOW=$'\033[0;33m'
  C_GREEN=$'\033[0;32m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_YELLOW=""
  C_GREEN=""
  C_RESET=""
fi

# Print $2 wrapped in $1's color. $1 is one of: red, yellow, green,
# or empty (plain text).
paint() {
  local color="$1" text="$2"
  case "$color" in
    red)    printf '%s%s%s' "$C_RED"    "$text" "$C_RESET" ;;
    yellow) printf '%s%s%s' "$C_YELLOW" "$text" "$C_RESET" ;;
    green)  printf '%s%s%s' "$C_GREEN"  "$text" "$C_RESET" ;;
    *)      printf '%s' "$text" ;;
  esac
}

# Color for a systemd active-state value.
paint_service_state() {
  local v="$1"
  case "$v" in
    active)   paint green "$v" ;;
    failed)   paint red "$v" ;;
    inactive) paint yellow "$v" ;;
    *)        printf '%s' "$v" ;;
  esac
}

Status() {
  require ip ssh systemctl
  load_local_config

  # --- Global state, gathered once up front ---
  local lo_color=""
  case "$LOCAL_CONFIG_SOURCE" in
    file)                          lo_color=green ;;
    generated)                     lo_color=yellow ;;
    auto-detected\ \(not\ saved\)) lo_color=red ;;
    *)                             lo_color="" ;;
  esac

  local iface_ok=0
  tun_exists "$REAL_IFACE" && iface_ok=1

  local def_line="" def_dev=""
  def_line=$(ip route show default 2>/dev/null | head -1 || true)
  if [[ -n "$def_line" ]]; then
    def_dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$def_line")
  fi

  # --- Print ---
  echo "=== Global ==="
  printf '  Script:          %s\n' "$SCRIPT_PATH"
  printf '  Local config:     %s (%s)\n' \
    "$LOCAL_CONFIG" "$(paint "$lo_color" "$LOCAL_CONFIG_SOURCE")"
  if (( iface_ok )); then
    printf '  REAL_IFACE:      %s\n' "$REAL_IFACE"
  else
    printf '  REAL_IFACE:      %s\n' "$(paint red "$REAL_IFACE (missing)")"
  fi
  printf '  REAL_GATEWAY:    %s\n' "$REAL_GATEWAY"
  printf '  CLIENT_TUN_IP:   %s\n' "$CLIENT_TUN_IP"
  printf '  SERVER_TUN_IP:   %s\n' "$SERVER_TUN_IP"

  if [[ -z "$def_line" ]]; then
    printf '  Current default: %s\n' "$(paint red '<none>')"
  elif [[ "$def_dev" == tun* ]]; then
    printf '  Current default: %s\n' "$(paint green "$def_line")"
  else
    printf '  Current default: %s\n' "$def_line"
  fi

  echo
  echo "=== Servers ==="

  local id any=0
  while IFS= read -r id; do
    any=1

    # Probe validity in a subshell so a broken config doesn't abort
    # the whole report. Its stderr becomes the error detail.
    local cfg_err=""
    if cfg_err="$( ( load_server_config "$id" ) 2>&1 >/dev/null )"; then
      cfg_err=""
      load_server_config "$id"
    else
      local err_line="${cfg_err%%$'\n'*}"
      err_line="${err_line#Error: }"
      printf '  [%s]\n' "$id"
      if [[ -n "$err_line" ]]; then
        printf '    Config:            %s  (%s)\n' "$(paint red INVALID)" "$err_line"
      else
        printf '    Config:            %s\n' "$(paint red INVALID)"
      fi
      continue
    fi

    local tun_dev="tun$id"
    local host="${SERVER[HOST]}"
    local user="${SERVER[USER]}"
    local port="${SERVER[SSH_PORT]}"
    local desc="${SERVER[DESC]:-}"

    # --- Per-server state, gathered before printing ---
    local svc_state="" installed=0 tun_up=0 carries=0 reachable=0
    local exc_ok=0 exc_total=0 ip
    local exec_path="" stale=0
    if service_installed "$id"; then
      installed=1
      svc_state="$(service_state "$id")"
      exec_path="$(unit_exec_path "$id" || true)"
      # Corrupted unit: installed from a different (e.g. moved) checkout.
      if [[ -n "$exec_path" && "$exec_path" != "$SCRIPT_PATH" ]]; then
        stale=1
      fi
    fi
    tun_exists "$tun_dev" && tun_up=1
    while IFS= read -r ip; do
      exc_total=$((exc_total+1))
      exception_route_exists "$ip" && exc_ok=$((exc_ok+1))
    done < <(effective_exceptions)
    default_via_tun "$tun_dev" && carries=1
    remote_reachable "$host" "$port" "$user" && reachable=1

    # "running" = the unit claims this tunnel should be up right now.
    # No/red states below only count as broken when something says
    # they should be present.
    local running=0
    [[ "$svc_state" == "active" ]] && running=1

    if [[ -n "$desc" ]]; then
      printf '  [%s]  %s\n' "$id" "$desc"
    else
      printf '  [%s]\n' "$id"
    fi
    printf '    Host:              %s@%s:%s\n' "$user" "$host" "$port"
    printf '    Tun device:        %s\n' "$tun_dev"

    if (( installed )); then
      printf '    Service installed: yes\n'
      if (( stale )); then
        printf '    Unit:              %s\n' \
          "$(paint red "STALE: $exec_path")  (run '$PROG install $id')"
      fi
      if [[ "$svc_state" == "failed" ]]; then
        printf '    Service state:     %s  (%s)\n' \
          "$(paint red failed)" "$(service_failure_detail "$id")"
      else
        printf '    Service state:     %s\n' "$(paint_service_state "$svc_state")"
      fi
    else
      printf '    Service installed: no\n'
    fi

    if (( tun_up )); then
      printf '    Tun up:            %s\n' "$(paint green yes)"
    elif (( running )); then
      printf '    Tun up:            %s  (%s missing)\n' "$(paint red no)" "$tun_dev"
    else
      printf '    Tun up:            no\n'
    fi

    if (( exc_total == 0 )); then
      printf '    Exception routes:  %s\n' "$(paint yellow none)"
    elif (( exc_ok == exc_total )); then
      printf '    Exception routes:  %s\n' "$(paint green "$exc_ok/$exc_total")"
    elif (( tun_up || running )); then
      printf '    Exception routes:  %s\n' "$(paint red "$exc_ok/$exc_total")"
    else
      printf '    Exception routes:  %s\n' "$exc_ok/$exc_total"
    fi

    if (( carries )); then
      printf '    Carries default:   %s\n' "$(paint green YES)"
    else
      printf '    Carries default:   no\n'
    fi

    if (( reachable )); then
      printf '    Remote reachable:  %s\n' "$(paint green yes)"
    elif (( running )); then
      printf '    Remote reachable:  %s  (%s)\n' "$(paint red no)" "${REMOTE_ERR:-unknown}"
    else
      printf '    Remote reachable:  no\n'
    fi
  done < <(server_ids)

  if (( any == 0 )); then
    echo "  (no servers configured in $SERVERS_DIR)"
  fi
}

# Exposed for systemd (ExecStart of tun-<id>.service), documented
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

    watch-leaks) WatchLeaks ;;

    run)     Run "$arg" ;;

    *)
      echo "Error: unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

# Only dispatch when executed as a script (not when sourced, e.g. by the
# test harness).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
