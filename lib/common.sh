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

# human_bytes N   ->  "1.2G" ("-" passes through)
human_bytes() {
  [[ $1 =~ ^[0-9]+$ ]] || { printf '%s' "$1"; return; }
  (($1 < 1024)) && { printf "%sB" "$1"; return; }
  numfmt --to=iec --suffix=B --format='%.1f' "$1"
}

# human_duration SECONDS  ->  "1h 23m 4s"
human_duration() {
  local s=$1
  if ((s >= 3600)); then
    printf '%dh %dm %ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
  elif ((s >= 60)); then
    printf '%dm %ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}
