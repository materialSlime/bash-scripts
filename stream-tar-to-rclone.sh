#!/usr/bin/env bash

date_format="+%Y-%m-%d %H:%M:%S"
log() {
  printf "%-20s[%-5s] %s\n" "$1" "$2" "$3"
}

#consume flags and there args
for f in "$@"; do
  case "$f" in
  -r | --remote)
    if [[ ! "$2" == -* ]]; then
      remote="$2"
      shift 1
    fi
    shift 1
    ;;

  -c | --config)
    if [[ ! "$2" == -* ]]; then
      rconfig="$2"
      shift 1
    fi
    shift 1
    ;;

  -h | --help)
    echo "Usage:
          -r|--remote <remote_name>     Remote to use from rclone remotes
          -c|--config <path_to_config>  Config file to use for rclone
          -h|--help                     Prints help message

        "
    exit 0
    ;;

  -*)
    log "$(date "$date_format")" "ERROR" "Invalid flags or arguments given"
    exit 42
    ;;
  esac
done

# check if argument provided and valid
if [[ -z "$rconfig" ]]; then
  log "$(date "$date_format")" "ERROR" "No rclone config provided. Use -c|--config <path_to_config> to set it."
  exit 22
elif [[ ! -f "$rconfig" ]]; then
  log "$(date "$date_format")" "ERROR" "Provided rclone config dont exist."
  exit 23
fi

rclone_remotes=$(rclone --config "$rconfig" listremotes)

# this function checks if provided remote exists
remote_exists() {
  for rmt in ${rclone_remotes[@]}; do
    if [[ "${rmt:0:-1}" == "$1" ]]; then
      echo true
    fi
  done
}
if [[ -z "$remote" ]]; then
  log "$(date "$date_format")" "ERROR" "Not rclone remote provided. Use -r|--remote <remote_name> to set it"
  exit 12
elif [[ ! "$(remote_exists "$remote")" ]]; then
  log "$(date "$date_format")" "ERROR" "Provided remote dont exist."
  exit 12
fi

# iterate over arguments and append to $target_directories if is directory
target_directories=()
for dir in "$@"; do
  if [[ -d "$dir" ]]; then

    # if dir path ends with / drop it
    if [[ "$dir" == */ ]]; then
      dir=${dir:0:-1}
    fi
    target_directories+=("$dir")
  else
    log "$(date "$date_format")" "ERROR" "$dir does not exists."
  fi
done

# Is directory to backup
if [[ -z ${target_directories[*]} ]]; then
  log "$(date "$date_format")" "ERROR" "No directory given to backup."
  exit 45
fi

#Setup and cleanup
tmp_dir="/tmp/backup-script"
mkdir "$tmp_dir"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup exit

#loop over valid directory to backup
for dir in "${target_directories[@]}"; do
  dir_name="${dir##*/}"
  backup_name="$dir_name-$(date "+%Y-%m-%d-%H-%M").tar.gz"
  snar_name="$dir_name.snar"

  rclone mkdir --config "$rconfig" "$remote:$dir_name" &>/dev/null

  log "$(date "$date_format")" "INFO" "Seaching snar file for existing backup for $dir"
  rclone copy --config "$rconfig" "$remote:$dir_name/$snar_name" "$tmp_dir" &>/dev/null
  if [[ $? -eq 0 ]]; then
    log "$(date "$date_format")" "INFO" "Found $snar_name for $dir"
  else
    log "$(date "$date_format")" "INFO" "$snar_name not found for $dir, Creating new."
  fi

  tar -cpzf - --listed-incremental="$tmp_dir/$snar_name" \
    -C "${dir%/*}" "$dir_name" |
    rclone rcat "$remote:$dir_name/$backup_name" --config "$rconfig" --progress
  rclone copyto "$tmp_dir/$snar_name" "$remote:$dir_name/$snar_name"

  log "$(date "$date_format")" "INFO" "Streamed $backup_name as compressed tar to rclone's $remote remote."

done
