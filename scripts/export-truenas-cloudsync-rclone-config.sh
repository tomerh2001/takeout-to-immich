#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: export-truenas-cloudsync-rclone-config.sh (--credential-name NAME | --credential-id ID) --output PATH

Exports a TrueNAS Cloud Sync Google Drive credential into an rclone config file.

This helper is optional and only useful on hosts that already have a Google
Drive Cloud Sync credential configured in TrueNAS middleware.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

credential_name=""
credential_id=""
output_path=""

while (($#)); do
    case "$1" in
        --credential-name)
            credential_name="${2:-}"
            shift 2
            ;;
        --credential-id)
            credential_id="${2:-}"
            shift 2
            ;;
        --output)
            output_path="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$output_path" ]] || fail "--output is required"
if [[ -n "$credential_name" && -n "$credential_id" ]]; then
    fail "Use either --credential-name or --credential-id, not both"
fi
if [[ -z "$credential_name" && -z "$credential_id" ]]; then
    fail "Either --credential-name or --credential-id is required"
fi

require_cmd sudo
require_cmd midclt
require_cmd jq
require_cmd install

query_json="$(sudo -n midclt call cloudsync.credentials.query)"

if [[ -n "$credential_id" ]]; then
    selector=".[] | select((.id | tostring) == \"$credential_id\")"
else
    selector=".[] | select(.name == \"$credential_name\")"
fi

credential_json="$(printf '%s' "$query_json" | jq -c "$selector" | head -n1)"
[[ -n "$credential_json" ]] || fail "Could not find the requested Cloud Sync credential"

provider_type="$(printf '%s' "$credential_json" | jq -r '.provider.type')"
[[ "$provider_type" == "GOOGLE_DRIVE" ]] || fail "Selected credential is not a Google Drive credential"

client_id="$(printf '%s' "$credential_json" | jq -r '.provider.client_id')"
client_secret="$(printf '%s' "$credential_json" | jq -r '.provider.client_secret')"
token="$(printf '%s' "$credential_json" | jq -r '.provider.token')"
team_drive="$(printf '%s' "$credential_json" | jq -r '.provider.team_drive // ""')"

mkdir -p "$(dirname "$output_path")"
install -m 600 /dev/null "$output_path"

{
    printf '[google-drive]\n'
    printf 'type = drive\n'
    printf 'scope = drive\n'
    printf 'client_id = %s\n' "$client_id"
    printf 'client_secret = %s\n' "$client_secret"
    printf 'token = %s\n' "$token"
    printf 'team_drive = %s\n' "$team_drive"
} >"$output_path"

printf 'Wrote %s\n' "$output_path"
