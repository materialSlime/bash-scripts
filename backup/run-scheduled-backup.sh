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
NTFY_URL=${NTFY_URL:-}
NTFY_TOKEN=${NTFY_TOKEN:-}
NTFY_NOTIFY_ON=${NTFY_NOTIFY_ON:-all}
[[ $NTFY_NOTIFY_ON =~ ^(all|failure|none)$ ]] || die "NTFY_NOTIFY_ON must be all, failure or none"

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
docker_stopped_at="" docker_downtime=""
report_file=$(mktemp -t scheduled-backup-report.XXXXXX) || die "Could not create report file"

stop_docker() {
  log INFO "Stopping ${DOCKER_UNITS[*]}"
  systemctl stop "${DOCKER_UNITS[@]}" && docker_state=stopped docker_stopped_at=$SECONDS
}

start_docker() {
  local try
  for try in 1 2 3; do
    log INFO "Starting ${DOCKER_UNITS[*]} (try $try/3)"
    if systemctl start "${DOCKER_UNITS[@]}"; then
      docker_state=restarted
      docker_downtime=$(human_duration $((SECONDS - docker_stopped_at)))
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
uploaded_bytes=$(total_uploaded)
STATUS
  # One line per folder, same fields as the backup-dir-to-rclone.sh report.
  local name rest
  while IFS=$'\t' read -r name rest; do
    printf 'folder.%s=%s\n' "$name" "$rest"
  done <"$report_file" >>"$STATUS_FILE"
}

# total_uploaded   Sum of archive_bytes over successful folders.
total_uploaded() {
  awk -F'\t' '$2 == "ok" && $5 ~ /^[0-9]+$/ { t += $5 } END { print t + 0 }' "$report_file"
}

# folder_lines   One readable line per folder, for the notification and the log.
folder_lines() {
  local name status type changed abytes rbytes rcount secs tries error
  while IFS=$'\t' read -r name status type changed abytes rbytes rcount secs tries error; do
    if [[ $status == ok ]]; then
      printf '✅ %s: %s, %s file(s), %s in %s' "$name" "$type" "$changed" \
        "$(human_bytes "$abytes")" "$(human_duration "$secs")"
      ((tries > 1)) && printf ' (try %s)' "$tries"
      printf ' | Drive: %s in %s archive(s)\n' "$(human_bytes "$rbytes")" "$rcount"
    else
      printf '❌ %s: %s (%s attempt(s), %s)\n' "$name" "$error" "$tries" "$(human_duration "$secs")"
    fi
  done <"$report_file"
}

# docker_line   e.g. "Docker: restarted (down 1h 2m 3s)"
docker_line() {
  printf 'Docker: %s' "$docker_state"
  [[ -n $docker_downtime ]] && printf ' (down %s)' "$docker_downtime"
  printf '\n'
}

# ntfy_send TITLE PRIORITY TAG MESSAGE   No-op when NTFY_URL is unset.
# A failed notification is logged but never changes the backup's exit code.
ntfy_send() {
  [[ -n $NTFY_URL ]] || return 0
  local auth=()
  [[ -n $NTFY_TOKEN ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  if curl -fsS --max-time 30 --retry 3 --retry-delay 10 -o /dev/null \
    "${auth[@]}" -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
    -d "$4" "$NTFY_URL"; then
    log INFO "ntfy notification sent: $1"
  else
    log WARN "ntfy notification failed: $1"
  fi
}

# Runs on every exit (normal, error, or killed with TERM/INT).
finish() {
  trap - EXIT
  if [[ $docker_state == stopped ]]; then
    start_docker || { log ERROR "Docker did NOT come back up"; exit_code=4; }
  fi
  write_status

  local duration details msg
  duration=$(human_duration "$SECONDS")
  details="$(folder_lines)
$(docker_line)"
  log INFO "Per-folder results:"
  while IFS= read -r line; do log INFO "  $line"; done <<<"$details"

  if ((exit_code == 0)); then
    msg="${#ok[@]}/${#BACKUP_DIRS[@]} folders OK, $(human_bytes "$(total_uploaded)") uploaded in $duration
$details"
    if [[ $NTFY_NOTIFY_ON == all ]]; then
      ntfy_send "Backup OK on $(hostname)" default white_check_mark "$msg"
    fi
    if declare -F on_backup_success >/dev/null; then
      on_backup_success "$msg" || log WARN "on_backup_success hook failed"
    fi
  else
    local why
    case $exit_code in
    3) why="Docker could not be stopped, so nothing was backed up" ;;
    4) why="Docker did NOT come back up, check it now" ;;
    *) why="${#failed[@]}/${#BACKUP_DIRS[@]} folder(s) failed" ;;
    esac
    msg="$why ($result, exit $exit_code, $duration)
$details
Log: ${LOG_FILE:-stdout}"
    if [[ $NTFY_NOTIFY_ON == all || $NTFY_NOTIFY_ON == failure ]]; then
      ntfy_send "Backup FAILED on $(hostname)" high rotating_light "$msg"
    fi
    if declare -F on_backup_failure >/dev/null; then
      on_backup_failure "$msg" || log WARN "on_backup_failure hook failed"
    fi
  fi
  rm -f "$report_file"
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
    -a "$ATTEMPTS" --report "$report_file" "$dir"; then
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
