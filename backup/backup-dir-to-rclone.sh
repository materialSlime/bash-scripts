#!/usr/bin/env bash
# Incremental GNU tar backup of one or more directories, streamed to an rclone
# remote without writing the archive to local disk.
#
# Remote layout, one folder per directory:
#   <remote>:<dirname>/<dirname>-YYYY-MM-DD-HH-MM-SS.tar.gz first run = full, then incrementals
#   <remote>:<dirname>/<dirname>.snar                       tar snapshot for the next incremental
#
# Failure rules:
#   * The .snar file is uploaded only after the archive upload succeeds,
#     so a failed run can never break the incremental chain.
#   * If an attempt fails, the partial archive is deleted from the remote and
#     the attempt is retried with a freshly downloaded snapshot.
#   * One failed directory doesn't stop the others; the exit code reports it.
#
# With --report FILE, one tab-separated line per directory is appended:
#   name status type changed_files archive_bytes remote_bytes remote_archives seconds attempts error
#
# Exit codes: 0 = all directories backed up
#             1 = one or more directories failed
#             2 = usage/config error (nothing was attempted)
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/rclone.sh"

usage() {
  cat <<USAGE
Usage: ${0##*/} -r <remote> -c <rclone.conf> [-a <attempts>] <dir>...

  -r, --remote <name>     rclone remote to upload to
  -c, --config <path>     rclone config file
  -a, --attempts <n>      tries per directory before giving up (default: 2)
      --report <file>     append a per-directory result line (see header)
  -h, --help              show this help
USAGE
}

remote="" rconfig="" attempts=2 report="" dirs=()
while (($#)); do
  case "$1" in
  -r | --remote)   need_value "$@"; remote=$2; shift 2 ;;
  -c | --config)   need_value "$@"; rconfig=$2; shift 2 ;;
  -a | --attempts) need_value "$@"; attempts=$2; shift 2 ;;
  --report)        need_value "$@"; report=$2; shift 2 ;;
  -h | --help)     usage; exit 0 ;;
  -*)              usage >&2; die "Unknown option: $1" ;;
  *)               dirs+=("$1"); shift ;;
  esac
done

[[ $attempts =~ ^[1-9][0-9]*$ ]] || die "--attempts must be a positive number"
((${#dirs[@]})) || die "No directory given to back up"
require_cmd tar rclone
rclone_use_config "$rconfig"
rclone_require_remote "$remote"

tmp_dir=$(mktemp -d -t backup-dir-to-rclone.XXXXXX) || die "Could not create temp dir"
trap 'rm -rf "$tmp_dir"' EXIT

# backup_one DIR   Returns 0 on success, 1 on failure.
# report_line NAME STATUS TYPE CHANGED ARCHIVE_BYTES REMOTE_BYTES REMOTE_ARCHIVES SECONDS ATTEMPTS ERROR
report_line() {
  [[ -n $report ]] || return 0
  local IFS=$'\t'
  printf '%s\n' "$*" >>"$report"
}

backup_one() {
  local dir=${1%/} name parent work snar archive attempt tar_rc rcat_rc
  local start=$SECONDS type=- changed=- error=""
  if [[ ! -d $dir ]]; then
    log ERROR "Not a directory: $dir"
    report_line "${dir##*/}" failed - - - - - 0 0 "directory not found: $dir"
    return 1
  fi
  dir=$(readlink -f "$dir")
  name=${dir##*/}
  parent=${dir%/*}
  parent=${parent:-/}
  work="$tmp_dir/$name"
  snar="$work/$name.snar"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    ((attempt > 1)) && { log INFO "[$name] Retrying in $((60 * (attempt - 1)))s"; sleep $((60 * (attempt - 1))); }

    rm -rf "$work" && mkdir -p "$work"
    archive="$name-$(date +%Y-%m-%d-%H-%M-%S).tar.gz"
    log INFO "[$name] Attempt $attempt/$attempts: $dir -> $remote:$name/$archive"

    if ! rclone mkdir "$remote:$name"; then
      error="could not create remote folder"
      log WARN "[$name] Could not create remote folder"
      continue
    fi

    # List the folder rather than just trying the download, so that
    # "no snapshot yet" (full backup) and "remote unreachable" (fail) are
    # told apart. The old script treated both as "no snapshot".
    local listing
    if ! listing=$(rclone lsf --files-only "$remote:$name"); then
      error="could not list remote folder"
      log WARN "[$name] Could not list remote folder"
      continue
    fi
    if grep -qxF "$name.snar" <<<"$listing"; then
      if ! rclone copyto "$remote:$name/$name.snar" "$snar"; then
        error="snapshot download failed"
        log WARN "[$name] Snapshot exists but download failed"
        continue
      fi
      type=incremental
      log INFO "[$name] Snapshot found: incremental backup"
    else
      type=full
      log INFO "[$name] No snapshot on remote: full backup"
    fi

    # --index-file keeps the verbose file list out of the log; used to count changed files.
    tar --create --gzip --preserve-permissions --file=- \
      --verbose --index-file="$work/index" \
      --listed-incremental="$snar" -C "$parent" "$name" |
      rclone rcat "${RCLONE_LOG_FLAGS[@]}" "$remote:$name/$archive"
    tar_rc=${PIPESTATUS[0]} rcat_rc=${PIPESTATUS[1]}

    # tar exit 1 = "some files changed while being read": archive is still valid.
    if ((tar_rc > 1 || rcat_rc != 0)); then
      error="upload failed (tar=$tar_rc, rclone=$rcat_rc)"
      log WARN "[$name] Upload failed (tar=$tar_rc, rclone=$rcat_rc); removing partial archive"
      rclone deletefile "$remote:$name/$archive" 2>/dev/null
      continue
    fi
    ((tar_rc == 1)) && log WARN "[$name] Some files changed while being archived"

    if ! rclone copyto "$snar" "$remote:$name/$name.snar"; then
      # Without the matching snapshot, this archive would confuse the chain.
      error="snapshot upload failed"
      log WARN "[$name] Snapshot upload failed; removing archive to keep the chain consistent"
      rclone deletefile "$remote:$name/$archive" 2>/dev/null
      continue
    fi

    # Stats: files in this archive (directory entries end in "/"), sizes on the remote.
    changed=$(grep -vc '/$' "$work/index")
    local sizes archive_bytes=- remote_bytes=- remote_archives=-
    if sizes=$(rclone lsf --files-only --format sp --separator $'\t' "$remote:$name"); then
      read -r archive_bytes remote_bytes remote_archives < <(awk -F'\t' -v a="$archive" '
        $2 ~ /\.tar\.gz$/ { total += $1; n++ }
        $2 == a { size = $1 }
        END { print (size == "" ? "-" : size), total + 0, n + 0 }' <<<"$sizes")
    fi

    log INFO "[$name] OK: $type, $changed file(s), $(human_bytes "$archive_bytes") uploaded in $(human_duration $((SECONDS - start))); $remote_archives archive(s), $(human_bytes "$remote_bytes") on remote"
    report_line "$name" ok "$type" "$changed" "$archive_bytes" "$remote_bytes" "$remote_archives" $((SECONDS - start)) "$attempt" ""
    return 0
  done

  log ERROR "[$name] FAILED after $attempts attempt(s): $error"
  report_line "$name" failed "$type" - - - - $((SECONDS - start)) "$attempts" "$error"
  return 1
}

ok=() failed=()
for dir in "${dirs[@]}"; do
  if backup_one "$dir"; then ok+=("$dir"); else failed+=("$dir"); fi
done

log INFO "Summary: ${#ok[@]} ok, ${#failed[@]} failed${failed:+ (${failed[*]})}"
((${#failed[@]} == 0))
