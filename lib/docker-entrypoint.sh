#!/usr/bin/env bash
set -euo pipefail

config_path="${RCLONE_CONFIG:-/config/rclone/rclone.conf}"

if [[ -f "$config_path" ]]; then
    cp "$config_path" /tmp/rclone.conf
    chmod 600 /tmp/rclone.conf
    export RCLONE_CONFIG=/tmp/rclone.conf
fi

exec /usr/local/bin/takeout-to-immich-worker "$@"

