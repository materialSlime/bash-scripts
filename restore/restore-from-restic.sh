#!/usr/bin/env bash
# List or restore restic snapshots made by backup-dir-to-restic.sh.
# Every snapshot is complete on its own: restore it directly, no chain needed.
#
#   restore-from-restic.sh [-C backup.conf] list [<folder>]
#   restore-from-restic.sh [-C backup.conf] restore <folder> <snapshot|latest> <target_dir> [<path inside folder>]
#
# Examples:
#   restore-from-restic.sh list immich
#   restore-from-restic.sh restore nextcloud latest /mnt/vault/restore
#   restore-from-restic.sh restore turing 3f2a9c1e /tmp/r notes      # just ~/notes
#
# Repository settings come from the backup config (default /etc/backup/backup.conf).
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/restic.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

conf=/etc/backup/backup.conf
if [[ ${1:-} == -C ]]; then
  need_value "$@"
  conf=$2
  shift 2
fi
[[ ${1:-} =~ ^(-h|--help|)$ ]] && { usage; exit 0; }
[[ -r $conf ]] || die "Config not readable: $conf"
source "$conf"
require_cmd restic jq
restic_setup "${RESTIC_REPOSITORY:-}" "${RESTIC_PASSWORD_FILE:-}" "${RCLONE_CONFIG_FILE:-}"
restic_require_repo

cmd=$1
shift
case $cmd in
list)
  if [[ -n ${1:-} ]]; then restic snapshots --tag "$1"; else restic snapshots; fi
  ;;
restore)
  [[ $# -ge 3 ]] || { usage >&2; die "restore needs <folder> <snapshot|latest> <target_dir>"; }
  folder=$1 snap=$2 target=$3 sub=${4:-}
  mkdir -p "$target" || die "Cannot create $target"
  args=(restore "$snap" --target "$target" --verify)
  [[ $snap == latest ]] && args+=(--tag "$folder")
  if [[ -n $sub ]]; then
    # Snapshot paths are absolute (e.g. /mnt/vault/nextcloud): find this folder's root.
    root=$(restic snapshots --json --tag "$folder" --latest 1 | jq -r '.[0].paths[0] // empty')
    [[ -n $root ]] || die "No snapshot found for folder $folder"
    args+=(--include "$root/${sub#/}")
  fi
  log INFO "Restoring $folder ($snap) to $target${sub:+ (only $sub)}"
  restic "${args[@]}" || die "restore failed"
  log INFO "Restored into $target (restic recreates the full original path below it)"
  ;;
*)
  usage >&2
  die "Unknown command: $cmd"
  ;;
esac
