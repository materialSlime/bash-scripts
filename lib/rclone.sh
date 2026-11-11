# shellcheck shell=bash
# rclone helpers. Requires lib/common.sh to be sourced first.

# rclone_use_config PATH
# Exports RCLONE_CONFIG so every later rclone call uses this config file;
# no call can forget to pass --config.
rclone_use_config() {
  [[ -n ${1:-} ]] || die "No rclone config given (use -c|--config <path>)"
  [[ -f $1 ]] || die "rclone config not found: $1"
  export RCLONE_CONFIG="$1"
}

# rclone_require_remote NAME   Exit unless NAME is a remote in the config.
rclone_require_remote() {
  [[ -n ${1:-} ]] || die "No rclone remote given (use -r|--remote <name>)"
  local remotes
  remotes=$(rclone listremotes) || die "Could not read remotes from $RCLONE_CONFIG"
  grep -qxF "$1:" <<<"$remotes" || die "rclone remote does not exist: $1"
}

# Progress output for cron logs: one stats line every 5 minutes instead of
# a redraw every 500ms (that redraw is what made the old log 43 MB).
RCLONE_LOG_FLAGS=(--stats=5m --stats-one-line --stats-log-level NOTICE)
