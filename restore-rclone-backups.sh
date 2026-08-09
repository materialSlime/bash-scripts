#!/usr/bin/env bash

#consume flags and there args
for argument in "$@"; do
  case "$argument" in
  -r | --remote)
    if [[ ! "$2" == -* ]]; then
      remote_name="$2"
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
  -t | --target)
    if [[ ! "$2" == -* ]]; then
      export_location="$2"
      shift 1
    fi
    shift 1
    ;;
  -h | --help)
    echo "Usage:
          -r|--remote <remote_name>         Remote to use from rclone remotes.
          -c|--config <path_to_config>      Config file to use for rclone.
          -t|--target <path_to_export_to>   Directory path to extarct to. 
          -h|--help Prints this help message.

        "
    exit 0
    ;;

  -*)
    log "$(date "$date_format")" "ERROR" "Invalid flags or arguments given"
    exit 42
    ;;
  esac
done

# remote_name="gdrive-crypt"
# rconfig="/home/neo/.config/rclone/rclone.conf"
# export_location="/mnt/vault/restore"

tmp_dir="/mnt/vault/tmp/tarbals"
backup_names=("$@")

mkdir -p "$tmp_dir"

cleanup() {
  rm -rf "${tmp_dir%/*}"
}
# trap cleanup EXIT

for backup_name in "${backup_names[@]}"; do
  backup_files=($(rclone lsf "$remote_name:$backup_name" 2>/dev/null))
  if [[ "$?" -gt 0 ]]; then
    echo "Backup for $backup_name not found."
    continue
  fi

  # Logic to find and remove snar file from array by iterating over backup_files array
  file_index=0
  for file in "${backup_files[@]}"; do
    if [[ "$file" == *.snar ]]; then
      snar_file="$file"
      unset "backup_files[$file_index]"
      break
    fi
    ((++file_index))
  done

  # download snar file in tmp dir
  mkdir "$tmp_dir/$backup_name"
  echo "Downloading $snar_file."
  rclone copy --config "$rconfig" "$remote_name:$backup_name/$snar_file" "$tmp_dir/$backup_name"

  # iterate over backup files, download in temp dir and extract at export location
  for file in "${backup_files[@]}"; do
    printf "Downloading %s \n" "$file"
    rclone copy --progress --config "$rconfig" "$remote_name:$backup_name/$file" "$tmp_dir/$backup_name"

    printf "Download complete now extracting %s at %s\n" "$file" "$export_location"

    tar -xpf "$tmp_dir/$backup_name/$file" \
      --listed-incremental "$tmp_dir/$backup_name/$snar_file" \
      -C "$export_location"

  done
  echo "Restored $backup_name at $export_location."
done
echo "Restored ${#backup_names[@]}. Script executed successfullly."
