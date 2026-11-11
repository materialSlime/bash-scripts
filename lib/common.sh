# shellcheck shell=bash
# Shared helpers: logging, fatal errors, dependency checks.
# Source it, don't run it:  source "$SCRIPT_DIR/../lib/common.sh"

LOG_DATE_FORMAT='%Y-%m-%d %H:%M:%S'

# log LEVEL message...   e.g. log INFO "Starting"
log() {
  local level=$1
  shift
  printf '%s [%-5s] %s\n' "$(date "+$LOG_DATE_FORMAT")" "$level" "$*"
}

# die message...   Usage/config errors. Exits with code 2.
die() {
  log ERROR "$*"
  exit 2
}

# require_cmd cmd...   Exit if any command is missing.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

# need_value OPTION "$@"   Exit unless OPTION is followed by a real value.
need_value() {
  [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "Option $1 needs a value"
}
