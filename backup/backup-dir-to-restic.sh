#!/usr/bin/env bash
# Back up one or more directories to a restic repository: one snapshot per
# directory, tagged with the directory's name (e.g. tag "immich").
#
# restic deduplicates by content, so moved files and metadata-only changes
# (chown, chmod, SELinux relabels) add almost nothing. Every snapshot is
# complete on its own: no full/incremental chain.
#
# Failure rules:
#   * A snapshot is only written once all its data is uploaded; a failed or
#     crashed attempt never leaves a snapshot that looks complete.
#   * Chunks uploaded by a failed attempt stay in the repository, so a retry
#     (or next week's run) continues instead of starting over.
#   * Stale locks from a crashed run are cleared with `restic unlock` first.
#   * restic exit 3 (snapshot saved, but some files couldn't be read) counts as
#     OK with a warning; the unreadable files are logged.
#
# With --report FILE, one tab-separated line per directory is appended:
#   name status files_new files_changed files_unmodified data_added total_bytes
#   seconds attempts snapshot error
#
# Exit codes: 0 = all directories backed up
#             1 = one or more directories failed
#             2 = usage/config error (nothing was attempted)
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/restic.sh"

usage() {
  cat <<USAGE
Usage: ${0##*/} -r <repository> -p <password_file> [options] <dir>...

  -r, --repo <repo>          restic repository, e.g. rclone:gdrive:restic-backup
  -p, --password-file <f>    file holding the repository password
  -c, --rclone-config <f>    rclone config (for rclone: repositories)
  -H, --host <name>          host name stored in snapshots (default: $(hostname -s))
  -x, --exclude-file <f>     restic exclude patterns, one per line
  -a, --attempts <n>         tries per directory before giving up (default: 2)
      --report <file>        append a per-directory result line (see header)
  -h, --help                 show this help
USAGE
}

repo="" pwfile="" rconfig="" host=$(hostname -s) exclude_file="" attempts=2 report="" dirs=()
while (($#)); do
  case "$1" in
  -r | --repo)          need_value "$@"; repo=$2; shift 2 ;;
  -p | --password-file) need_value "$@"; pwfile=$2; shift 2 ;;
  -c | --rclone-config) need_value "$@"; rconfig=$2; shift 2 ;;
  -H | --host)          need_value "$@"; host=$2; shift 2 ;;
  -x | --exclude-file)  need_value "$@"; exclude_file=$2; shift 2 ;;
  -a | --attempts)      need_value "$@"; attempts=$2; shift 2 ;;
  --report)             need_value "$@"; report=$2; shift 2 ;;
  -h | --help)          usage; exit 0 ;;
  -*)                   usage >&2; die "Unknown option: $1" ;;
  *)                    dirs+=("$1"); shift ;;
  esac
done

[[ $attempts =~ ^[1-9][0-9]*$ ]] || die "--attempts must be a positive number"
((${#dirs[@]})) || die "No directory given to back up"
[[ -z $exclude_file || -r $exclude_file ]] || die "Exclude file not readable: $exclude_file"
require_cmd restic jq
restic_setup "$repo" "$pwfile" "$rconfig"
restic_require_repo

tmp_dir=$(mktemp -d -t backup-dir-to-restic.XXXXXX) || die "Could not create temp dir"
trap 'rm -rf "$tmp_dir"' EXIT

# One progress line a minute in --json mode instead of many per second.
export RESTIC_PROGRESS_FPS=0.0166

# report_line FIELDS...   (see header for the field order)
report_line() {
  [[ -n $report ]] || return 0
  local IFS=$'\t'
  printf '%s\n' "$*" >>"$report"
}

# backup_one DIR   Returns 0 on success, 1 on failure.
backup_one() {
  local dir=${1%/} name attempt rc start=$SECONDS error="" out err summary
  if [[ ! -d $dir ]]; then
    log ERROR "Not a directory: $dir"
    report_line "${dir##*/}" failed - - - - - 0 0 - "directory not found: $dir"
    return 1
  fi
  dir=$(readlink -f "$dir")
  name=${dir##*/}
  out="$tmp_dir/$name.json"
  err="$tmp_dir/$name.err"

  local args=(backup --json --tag "$name" --host "$host" --exclude-caches)
  [[ -n $exclude_file ]] && args+=(--exclude-file "$exclude_file")

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    ((attempt > 1)) && { log INFO "[$name] Retrying in $((60 * (attempt - 1)))s"; sleep $((60 * (attempt - 1))); }
    log INFO "[$name] Attempt $attempt/$attempts: $dir -> $RESTIC_REPOSITORY"

    # Removes only locks whose process is gone (e.g. after a crash).
    restic unlock >/dev/null 2>&1

    restic "${args[@]}" "$dir" >"$out" 2>"$err"
    rc=$?

    # Per-file problems (unreadable files etc.); in --json mode restic writes
    # them to stderr as JSON lines.
    local nerr
    nerr=$(jq -Rr 'fromjson? | select(.message_type=="error") | .error.message // "error"' "$err" 2>/dev/null |
      tee "$tmp_dir/$name.fileerrors" | wc -l)
    ((nerr)) && { log WARN "[$name] $nerr file(s) could not be read:"; head -5 "$tmp_dir/$name.fileerrors" | while IFS= read -r l; do log WARN "[$name]   $l"; done; }

    summary=$(jq -c 'select(.message_type=="summary")' "$out" 2>/dev/null | tail -1)

    if [[ ($rc == 0 || $rc == 3) && -n $summary ]]; then
      local fnew fchg funm added total snap
      read -r fnew fchg funm added total snap < <(jq -r '[.files_new, .files_changed, .files_unmodified,
        .data_added_packed // .data_added, .total_bytes_processed, (.snapshot_id // "-")[0:8]] | @tsv' <<<"$summary")
      ((rc == 3)) && log WARN "[$name] Snapshot saved, but some files were skipped (see above)"
      log INFO "[$name] OK: $fnew new, $fchg changed, $funm unchanged files; $(human_bytes "$added") added to repo in $(human_duration $((SECONDS - start))) (snapshot $snap)"
      report_line "$name" ok "$fnew" "$fchg" "$funm" "$added" "$total" $((SECONDS - start)) "$attempt" "$snap" ""
      return 0
    fi

    # Prefer restic's own exit message; fall back to the last stderr line.
    error=$(jq -Rr 'fromjson? | select(.message_type=="exit_error") | .message' "$err" 2>/dev/null | tail -1)
    [[ -n $error ]] || error=$(grep -v '^\s*$' "$err" | tail -1)
    error=${error:-restic exit $rc}
    error=${error//$'\t'/ }
    log WARN "[$name] Attempt failed (restic exit $rc): $error"
  done

  log ERROR "[$name] FAILED after $attempts attempt(s): $error"
  report_line "$name" failed - - - - - $((SECONDS - start)) "$attempts" - "$error"
  return 1
}

ok=() failed=()
for dir in "${dirs[@]}"; do
  if backup_one "$dir"; then ok+=("$dir"); else failed+=("$dir"); fi
done

log INFO "Summary: ${#ok[@]} ok, ${#failed[@]} failed${failed:+ (${failed[*]})}"
((${#failed[@]} == 0))
