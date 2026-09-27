# lib/strict.sh

# Guard against double-sourcing: re-sourcing is a no-op.
[[ -n "${_STRICT_SH_SOURCED:-}" ]] && return 0
_STRICT_SH_SOURCED=1

# Print "Error: <message>" to stderr and exit 1.
die()  { echo "Error: $*" >&2; exit 1; }

# Succeed when <command> is available on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# Verify each named command is on PATH; die on the first one missing.
require() {
  for cmd in "$@"; do
    have "$cmd" || die "Required command not found: $cmd"
  done
}

# Enable strict mode and sane glob behavior. Requires Bash 4.4+ (for
# inherit_errexit) and dies on older versions.
strict_mode_enable() {
  if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    die "Bash 4.4+ required, found ${BASH_VERSION}"
  fi

  # Fail on errors, undefined variables, and pipe failures.
  set -euo pipefail
  shopt -s inherit_errexit   # Subshells inherit -e (Bash 4.4+)

  # --- Sane glob behavior ---
  shopt -s nullglob          # Unmatched globs vanish instead of staying literal
  shopt -s globstar          # Enable ** for recursive matching
  shopt -s extglob           # Extended patterns: !(...), @(...), +(...)
}
