#!/usr/bin/env bash
# Scheduled offsite backup. The one entry point cron calls.
#
#   1. Take a lock, so two runs can never overlap.
#   2. Stop Docker, so databases (Immich, Nextcloud) are consistent on disk.
#   3. Back up each directory in BACKUP_DIRS with backup-dir-to-rclone.sh.
#   4. ALWAYS start Docker again, whether the backup succeeded, failed or crashed.
#   5. Write a status file and call the failure hook if anything went wrong.
#
# Usage: run-scheduled-backup.sh [path/to/backup.conf]   (default: /etc/backup/backup.conf)
#
# Exit codes: 0 = success
#             1 = one or more directories failed
#             2 = config error / already running
#             3 = Docker could not be stopped (backup skipped)
#             4 = Docker could not be started again
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/../lib/common.sh"

conf=${1:-/etc/backup/backup.conf}
[[ -r $conf ]] || die "Config not readable: $conf"
# shellcheck source=backup.conf.example
source "$conf"

: "${RCLONE_REMOTE:?set in $conf}" "${RCLONE_CONFIG_FILE:?set in $conf}"
[[ -n ${BACKUP_DIRS+set} ]] && ((${#BACKUP_DIRS[@]})) || die "BACKUP_DIRS is empty in $conf"
STOP_DOCKER=${STOP_DOCKER:-yes}
DOCKER_UNITS=(${DOCKER_UNITS[@]:-docker.socket docker.service})
ATTEMPTS=${ATTEMPTS:-2}
STATUS_FILE=${STATUS_FILE:-/var/lib/backup/last-run.status}
LOCK_FILE=${LOCK_FILE:-/run/lock/scheduled-backup.lock}

# Send all output to the log file when one is set (cron then needs no redirect).
if [[ -n ${LOG_FILE:-} ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec >>"$LOG_FILE" 2>&1
fi

exec 9>"$LOCK_FILE" || die "Cannot open lock file $LOCK_FILE"
flock -n 9 || die "Another backup run is in progress"

started=$(date "+$LOG_DATE_FORMAT")
result=failed docker_state=untouched exit_code=1
ok=() failed=()

stop_docker() {
  log INFO "Stopping ${DOCKER_UNITS[*]}"
  systemctl stop "${DOCKER_UNITS[@]}" && docker_state=stopped
}

start_docker() {
  local try
  for try in 1 2 3; do
    log INFO "Starting ${DOCKER_UNITS[*]} (try $try/3)"
    if systemctl start "${DOCKER_UNITS[@]}"; then
      docker_state=restarted
      return 0
    fi
    sleep 10
  done
  docker_state=restart-failed
  return 1
}

write_status() {
  mkdir -p "$(dirname "$STATUS_FILE")"
  cat >"$STATUS_FILE" <<STATUS
started=$started
finished=$(date "+$LOG_DATE_FORMAT")
result=$result
exit_code=$exit_code
docker=$docker_state
ok=${ok[*]}
failed=${failed[*]}
STATUS
}

# Runs on every exit (normal, error, or killed with TERM/INT).
finish() {
  trap - EXIT
  if [[ $docker_state == stopped ]]; then
    start_docker || { log ERROR "Docker did NOT come back up"; exit_code=4; }
  fi
  write_status
  if ((exit_code != 0)) && declare -F on_backup_failure >/dev/null; then
    on_backup_failure "Backup exit=$exit_code result=$result on $(hostname): failed=[${failed[*]}] docker=$docker_state (see ${LOG_FILE:-journal})" ||
      log WARN "on_backup_failure hook failed"
  fi
  log INFO "Run finished: result=$result exit=$exit_code docker=$docker_state"
  exit "$exit_code"
}
trap finish EXIT
trap 'log ERROR "Interrupted"; exit 1' INT TERM

log INFO "=== Scheduled backup started (config: $conf) ==="

if [[ $STOP_DOCKER == yes ]]; then
  if ! stop_docker; then
    log ERROR "Could not stop Docker; skipping backup so databases aren't copied mid-write"
    exit_code=3
    exit
  fi
fi

for dir in "${BACKUP_DIRS[@]}"; do
  if "$SCRIPT_DIR/backup-dir-to-rclone.sh" -r "$RCLONE_REMOTE" -c "$RCLONE_CONFIG_FILE" \
    -a "$ATTEMPTS" "$dir"; then
    ok+=("$dir")
  else
    failed+=("$dir")
  fi
done

if ((${#failed[@]} == 0)); then
  result=success exit_code=0
elif ((${#ok[@]} > 0)); then
  result=partial exit_code=1
else
  result=failed exit_code=1
fi
exit
