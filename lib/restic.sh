# shellcheck shell=bash
# restic helpers. Requires lib/common.sh to be sourced first.
#
# No local archive is ever built: restic reads files, cuts them into ~1 MB
# chunks and uploads them in ~16 MB pack files as they fill. A crashed run
# leaves its uploaded chunks in the repository and the next run reuses them.

# restic_setup REPOSITORY PASSWORD_FILE [RCLONE_CONFIG]
# Exports what every later restic call needs.
restic_setup() {
  [[ -n ${1:-} ]] || die "No restic repository given"
  [[ -n ${2:-} ]] || die "No restic password file given"
  [[ -r $2 ]] || die "restic password file not readable: $2"
  if [[ $(stat -c %a "$2") != 600 && $(stat -c %a "$2") != 400 ]]; then
    log WARN "restic password file $2 should be mode 600 (is $(stat -c %a "$2"))"
  fi
  export RESTIC_REPOSITORY="$1"
  export RESTIC_PASSWORD_FILE="$2"
  # restic starts rclone itself for "rclone:" repositories; rclone reads this.
  [[ -n ${3:-} ]] && export RCLONE_CONFIG="$3"
  # Pack files are staged in TMPDIR; Fedora's /tmp lives in RAM.
  export TMPDIR=${RESTIC_TMPDIR:-/var/tmp}
  # restic finds its cache via $HOME, which systemd-run services and `env -i`
  # don't set; fall back to the user's home from the passwd database.
  if [[ -z ${RESTIC_CACHE_DIR:-} && -z ${XDG_CACHE_HOME:-} && -z ${HOME:-} ]]; then
    RESTIC_CACHE_DIR="$(getent passwd "$(id -u)" | cut -d: -f6)/.cache/restic"
  fi
  [[ -n ${RESTIC_CACHE_DIR:-} ]] && export RESTIC_CACHE_DIR
  return 0
}

# restic_require_repo   Exit unless the repository exists and the password works.
restic_require_repo() {
  local out rc
  out=$(restic cat config --no-lock 2>&1 >/dev/null)
  rc=$?
  case $rc in
  0) return 0 ;;
  10) die "restic repository does not exist: $RESTIC_REPOSITORY (create it with 'restic init')" ;;
  12) die "Wrong restic password for $RESTIC_REPOSITORY" ;;
  *) die "Cannot open restic repository $RESTIC_REPOSITORY (exit $rc): ${out##*$'\n'}" ;;
  esac
}
