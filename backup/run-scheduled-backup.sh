#!/usr/bin/env bash
# Scheduled offsite backup. The one entry point cron calls.
#
#   1. Take a lock, so two runs can never overlap.
#   2. Stop Docker, so databases (Immich, Nextcloud) are consistent on disk.
#   3. Back up each directory in BACKUP_DIRS: BACKEND=restic uses
#      backup-dir-to-restic.sh (default), BACKEND=tar uses backup-dir-to-rclone.sh.
#   4. ALWAYS start Docker again, whether the backup succeeded, failed or crashed.
#   5. restic only, with Docker already back up: apply retention
#      (forget + prune) and verify the repository (check).
#   6. Write a status file and send notifications / call hooks.
#
# Usage: run-scheduled-backup.sh [path/to/backup.conf]   (default: /etc/backup/backup.conf)
#
# Exit codes: 0 = success
#             1 = one or more directories failed
#             2 = config error, repository unusable (wrong password, missing), or already running
#             3 = Docker could not be stopped (backup skipped)
#             4 = Docker could not be started again
#             5 = backups saved, but repository maintenance (prune/check) failed
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/restic.sh"

conf=${1:-/etc/backup/backup.conf}
[[ -r $conf ]] || die "Config not readable: $conf"
# shellcheck source=backup.conf.example
source "$conf"

BACKEND=${BACKEND:-restic}
case $BACKEND in
restic)
  : "${RESTIC_REPOSITORY:?set in $conf}" "${RESTIC_PASSWORD_FILE:?set in $conf}"
  RCLONE_CONFIG_FILE=${RCLONE_CONFIG_FILE:-}
  KEEP_WEEKLY=${KEEP_WEEKLY:-26}
  KEEP_MONTHLY=${KEEP_MONTHLY:-24}
  CHECK_READ_SUBSET=${CHECK_READ_SUBSET:-2%}
  RESTIC_EXCLUDE_FILE=${RESTIC_EXCLUDE_FILE:-}
  ;;
tar)
  : "${RCLONE_REMOTE:?set in $conf}" "${RCLONE_CONFIG_FILE:?set in $conf}"
  ;;
*) die "BACKEND must be restic or tar" ;;
esac
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
maintenance=skipped maintenance_note="" repo_bytes="" preflight_error="" current_dir=""
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
backend=$BACKEND
uploaded_bytes=$(total_uploaded)
maintenance=$maintenance
repo_bytes=$repo_bytes
STATUS
  # One line per folder, same fields as the backup script's --report line.
  local name rest
  while IFS=$'\t' read -r name rest; do
    printf 'folder.%s=%s\n' "$name" "$rest"
  done <"$report_file" >>"$STATUS_FILE"
}

# total_uploaded   Bytes added/uploaded over successful folders
# (restic report: data_added is field 6; tar report: archive_bytes is field 5).
total_uploaded() {
  local col=5
  [[ $BACKEND == restic ]] && col=6
  awk -F'\t' -v c="$col" '$2 == "ok" && $c ~ /^[0-9]+$/ { t += $c } END { print t + 0 }' "$report_file"
}

# folder_lines   One readable line per folder, for the notification and the log.
folder_lines() {
  if [[ $BACKEND == restic ]]; then
    local name status fnew fchg funm added total secs tries snap error
    while IFS=$'\t' read -r name status fnew fchg funm added total secs tries snap error; do
      if [[ $status == ok ]]; then
        printf '✅ %s: %s new, %s changed, %s unchanged; %s added in %s' "$name" "$fnew" "$fchg" "$funm" \
          "$(human_bytes "$added")" "$(human_duration "$secs")"
        ((tries > 1)) && printf ' (try %s)' "$tries"
        printf ' | %s, snapshot %s\n' "$(human_bytes "$total")" "$snap"
      else
        printf '❌ %s: %s (%s attempt(s), %s)\n' "$name" "$error" "$tries" "$(human_duration "$secs")"
      fi
    done <"$report_file"
    return
  fi
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

# maintenance_line   e.g. "Repo: 812.3GB, 3 old snapshot(s) removed, check OK (2% data read)"
maintenance_line() {
  [[ $BACKEND == restic && $maintenance != skipped ]] || return 0
  printf 'Repo: %s' "$(human_bytes "${repo_bytes:-?}")"
  [[ -n $maintenance_note ]] && printf ', %s' "$maintenance_note"
  printf '\n'
}

# log_output TEXT   Log a command's output line by line, skipping blank lines.
log_output() {
  local line
  while IFS= read -r line; do
    [[ -n ${line//[[:space:]]/} ]] && log INFO "  restic: $line"
  done <<<"$1"
}

# run_maintenance   restic retention + verification. Sets maintenance=ok|failed.
run_maintenance() {
  local removed out
  maintenance=ok
  restic unlock >/dev/null 2>&1

  # One retention group per folder (tag) and host.
  log INFO "Retention: keep $KEEP_WEEKLY weekly + $KEEP_MONTHLY monthly snapshots per folder"
  if out=$(restic forget --json --group-by host,tags \
    --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" 2>&1); then
    removed=$(jq -r '[.[].remove // [] | length] | add // 0' <<<"$out" 2>/dev/null || echo "?")
    log INFO "Retention: $removed old snapshot(s) removed"
    maintenance_note="$removed old snapshot(s) removed"
  else
    log ERROR "restic forget failed: ${out##*$'\n'}"
    maintenance=failed maintenance_note="forget FAILED"
    return 1
  fi

  local rc
  if [[ $removed != 0 ]]; then
    log INFO "Pruning data no snapshot uses any more"
    out=$(restic prune 2>&1)
    rc=$?
    log_output "$out"
    if ((rc != 0)); then
      log ERROR "restic prune failed (exit $rc)"
      maintenance=failed maintenance_note+=", prune FAILED"
      return 1
    fi
  fi

  log INFO "Verifying repository (check, reading $CHECK_READ_SUBSET of the data)"
  out=$(restic check --read-data-subset="$CHECK_READ_SUBSET" 2>&1)
  rc=$?
  log_output "$out"
  if ((rc != 0)); then
    log ERROR "restic check FAILED (exit $rc): the repository may be damaged"
    maintenance=failed maintenance_note+=", check FAILED"
    return 1
  fi
  maintenance_note+=", check OK ($CHECK_READ_SUBSET data read)"

  repo_bytes=$(restic stats --json --mode raw-data 2>/dev/null | jq -r '.total_size // empty')
  return 0
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
  # Cleanup must finish even if Ctrl-C is pressed again: Docker restart,
  # status file and notification.
  trap '' INT TERM HUP
  if [[ $docker_state == stopped ]]; then
    start_docker || { log ERROR "Docker did NOT come back up"; exit_code=4; }
  fi
  write_status

  local duration details msg
  duration=$(human_duration "$SECONDS")
  details="$(folder_lines)
$(maintenance_line)
$(docker_line)"
  details=$(grep -v '^$' <<<"$details")
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
    130) why="Cancelled (Ctrl-C or stop signal) while backing up${current_dir:+ $current_dir}; the next run continues where it stopped" ;;
    2) why="Backup did not start: $preflight_error" ;;
    3) why="Docker could not be stopped, so nothing was backed up" ;;
    4) why="Docker did NOT come back up, check it now" ;;
    5) why="Backups saved, but repository maintenance failed: $maintenance_note" ;;
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
  log INFO "Run finished: result=$result exit=$exit_code docker=$docker_state maintenance=$maintenance"
  exit "$exit_code"
}
trap finish EXIT
trap 'log ERROR "Interrupted"; result=cancelled exit_code=130; exit' INT TERM HUP

log INFO "=== Scheduled backup started (config: $conf) ==="

# Check the repository BEFORE stopping Docker, and report problems via the
# normal notification path (a bare die would exit without telling anyone).
if [[ $BACKEND == restic ]]; then
  if [[ ! -r $RESTIC_PASSWORD_FILE ]]; then
    preflight_error="restic password file not readable: $RESTIC_PASSWORD_FILE"
  else
    restic_setup "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD_FILE" "$RCLONE_CONFIG_FILE"
    out=$(restic cat config --no-lock 2>&1 >/dev/null)
    case $? in
    0) ;;
    10) preflight_error="restic repository does not exist: $RESTIC_REPOSITORY" ;;
    12) preflight_error="wrong restic password for $RESTIC_REPOSITORY" ;;
    *) preflight_error="cannot open restic repository: ${out##*$'\n'}" ;;
    esac
  fi
  if [[ -n $preflight_error ]]; then
    log ERROR "Preflight failed: $preflight_error. Nothing was backed up; Docker was not touched."
    exit_code=2
    exit
  fi
  backup_cmd=("$SCRIPT_DIR/backup-dir-to-restic.sh" -r "$RESTIC_REPOSITORY" -p "$RESTIC_PASSWORD_FILE")
  [[ -n $RCLONE_CONFIG_FILE ]] && backup_cmd+=(-c "$RCLONE_CONFIG_FILE")
  [[ -n $RESTIC_EXCLUDE_FILE ]] && backup_cmd+=(-x "$RESTIC_EXCLUDE_FILE")
else
  backup_cmd=("$SCRIPT_DIR/backup-dir-to-rclone.sh" -r "$RCLONE_REMOTE" -c "$RCLONE_CONFIG_FILE")
fi

if [[ $STOP_DOCKER == yes ]]; then
  if ! stop_docker; then
    log ERROR "Could not stop Docker; skipping backup so databases aren't copied mid-write"
    exit_code=3
    exit
  fi
fi


for dir in "${BACKUP_DIRS[@]}"; do
  current_dir=$dir
  if "${backup_cmd[@]}" -a "$ATTEMPTS" --report "$report_file" "$dir"; then
    ok+=("$dir")
  else
    failed+=("$dir")
  fi
done

# Services come back before maintenance, so prune/check never extend downtime.
if [[ $docker_state == stopped ]]; then
  start_docker || { log ERROR "Docker did NOT come back up"; exit_code=4; result=failed; exit; }
fi

if [[ $BACKEND == restic ]] && ((${#ok[@]} > 0)); then
  run_maintenance
fi

if ((${#failed[@]} == 0)) && [[ $maintenance != failed ]]; then
  result=success exit_code=0
elif ((${#failed[@]} == 0)); then
  result=maintenance-failed exit_code=5
elif ((${#ok[@]} > 0)); then
  result=partial exit_code=1
else
  result=failed exit_code=1
fi
exit
