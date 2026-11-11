#!/usr/bin/env bash
# Restore backups made by backup-dir-to-rclone.sh.
# For each backup name (the remote folder, e.g. "immich"), downloads the
# snapshot and every archive, then extracts them oldest-first into the target.
#
# Usage: restore-from-rclone.sh -r <remote> -c <rclone.conf> -t <target_dir> <backup_name>...
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/rclone.sh"

usage() {
  cat <<USAGE
Usage: ${0##*/} -r <remote> -c <rclone.conf> -t <target_dir> [-w <work_dir>] <backup_name>...

  -r, --remote <name>      rclone remote to restore from
  -c, --config <path>      rclone config file
  -t, --target <path>      directory to extract into
  -w, --work-dir <path>    where archives are downloaded first (default: /mnt/vault/tmp/tarballs)
  -h, --help               show this help
USAGE
}

remote_name="" rconfig="" export_location="" tmp_dir="/mnt/vault/tmp/tarballs" backup_names=()
while (($#)); do
  case "$1" in
  -r | --remote)   need_value "$@"; remote_name=$2; shift 2 ;;
  -c | --config)   need_value "$@"; rconfig=$2; shift 2 ;;
  -t | --target)   need_value "$@"; export_location=$2; shift 2 ;;
  -w | --work-dir) need_value "$@"; tmp_dir=$2; shift 2 ;;
  -h | --help)     usage; exit 0 ;;
  -*)              usage >&2; die "Unknown option: $1" ;;
  *)               backup_names+=("$1"); shift ;;
  esac
done

((${#backup_names[@]})) || die "No backup name given"
[[ -d $export_location ]] || die "Target directory does not exist: ${export_location:-<none>}"
require_cmd tar rclone
rclone_use_config "$rconfig"
rclone_require_remote "$remote_name"
mkdir -p "$tmp_dir"

restored=0 failed=()
for backup_name in "${backup_names[@]}"; do
  # Names contain the date, so sorting them gives oldest-first, the order tar needs.
  if ! listing=$(rclone lsf --files-only "$remote_name:$backup_name"); then
    log ERROR "Backup not found: $backup_name"; failed+=("$backup_name"); continue
  fi
  mapfile -t archives < <(grep '\.tar\.gz$' <<<"$listing" | sort)
  ((${#archives[@]})) || { log ERROR "No archives in $backup_name"; failed+=("$backup_name"); continue; }

  work="$tmp_dir/$backup_name"
  mkdir -p "$work"
  ok=1
  for file in "${archives[@]}"; do
    log INFO "[$backup_name] Downloading $file"
    if ! rclone copy "${RCLONE_LOG_FLAGS[@]}" "$remote_name:$backup_name/$file" "$work"; then
      log ERROR "[$backup_name] Download failed: $file"; ok=0; break
    fi
    log INFO "[$backup_name] Extracting $file to $export_location"
    # /dev/null: on extract, tar uses the archive's own metadata, not the snapshot file.
    if ! tar -xpzf "$work/$file" --listed-incremental=/dev/null -C "$export_location"; then
      log ERROR "[$backup_name] Extract failed: $file"; ok=0; break
    fi
    rm -f "$work/$file"
  done

  if ((ok)); then
    log INFO "[$backup_name] Restored to $export_location"; ((++restored))
  else
    failed+=("$backup_name")
  fi
done

log INFO "Summary: $restored restored, ${#failed[@]} failed${failed:+ (${failed[*]})}"
((${#failed[@]} == 0))
