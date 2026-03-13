#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: takeout-to-immich-worker.sh --source-remote REMOTE:PATH --stage-dir DIR [options]

Stages one complete Google Photos Takeout export from Google Drive with rclone,
verifies the staged copy with rclone check, then imports the full batch into
Immich with immich-go.

Required arguments:
  --source-remote REMOTE:PATH   rclone remote folder for one complete Takeout export
  --stage-dir DIR               local base directory for batch staging

Optional arguments:
  --batch-name NAME             local batch name (default: derived from remote path)
  --mode MODE                   one of: all, download, verify, upload, cleanup
                                (default: all)
  --rclone-binary PATH          rclone binary (default: rclone)
  --immich-go-binary PATH       immich-go binary (default: immich-go)
  --immich-go-config PATH       native immich-go YAML/TOML/JSON config
                                (or use IMMICH_GO_CONFIG)
  --rclone-transfers N          parallel transfers for rclone copy (default: 4)
  --rclone-checkers N           parallel checkers for rclone/check (default: 8)
  --upload-passes N             number of immich-go passes to run (default: 2)
  --cleanup-after-success BOOL  remove local payload after successful upload
                                (default: false)
  --force-cleanup               allow cleanup even if upload markers are missing
  --dry-run                     pass dry-run to rclone and immich-go
  -h, --help                    show this help
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

validate_bool() {
    case "$1" in
        true|false) ;;
        *) fail "Expected true or false, got: $1" ;;
    esac
}

slugify() {
    local value="$1"
    value="${value%/}"
    value="${value##*/}"
    value="${value:-takeout-batch}"
    value="$(printf '%s' "$value" | tr ' /' '__' | tr -cd '[:alnum:]_.-')"
    value="${value:-takeout-batch}"
    printf '%s' "$value"
}

log_line() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$batch_log"
}

run_logged() {
    local logfile="$1"
    shift

    {
        printf '\n>>> [%s]' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf ' %q' "$@"
        printf '\n'
    } | tee -a "$logfile" "$batch_log" >/dev/null

    "$@" 2>&1 | tee -a "$logfile" "$batch_log"
}

write_marker() {
    local marker_file="$1"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker_file"
}

local_payload_manifest() {
    find "$payload_dir" -type f -printf '%P\t%s\n' | LC_ALL=C sort >"$state_dir/local-payload-manifest.tsv"
}

ensure_zip_payload() {
    mapfile -d '' zip_files < <(find "$payload_dir" -type f -iname '*.zip' -print0 | LC_ALL=C sort -z)
    if [[ ${#zip_files[@]} -eq 0 ]]; then
        fail "No ZIP files were found in $payload_dir. Stage a ZIP-format Takeout export."
    fi

    mapfile -d '' tgz_files < <(find "$payload_dir" -type f \( -iname '*.tgz' -o -iname '*.tar.gz' \) -print0 | LC_ALL=C sort -z)
    if [[ ${#tgz_files[@]} -gt 0 ]]; then
        fail "TGZ archives were found in $payload_dir. Do not mix ZIP and TGZ Takeout formats in the same batch."
    fi
}

download_batch() {
    mkdir -p "$payload_dir"
    local logfile="$log_dir/download.log"
    log_line "Downloading $source_remote into $payload_dir"

    local cmd=(
        "$rclone_bin" copy
        "$source_remote"
        "$payload_dir"
        --checksum
        --check-first
        --fast-list
        --immutable
        --transfers "$rclone_transfers"
        --checkers "$rclone_checkers"
        --multi-thread-streams 4
        --multi-thread-cutoff 256M
        --low-level-retries 20
        --retries 3
    )

    if [[ "$dry_run" == "true" ]]; then
        cmd+=(--dry-run)
    fi

    run_logged "$logfile" "${cmd[@]}"
    write_marker "$state_dir/download.ok"
    local_payload_manifest
}

verify_batch() {
    mkdir -p "$payload_dir"
    local logfile="$log_dir/verify.log"
    log_line "Verifying staged payload against $source_remote"

    local combined_report="$state_dir/rclone-check.combined.txt"
    local cmd=(
        "$rclone_bin" check
        "$source_remote"
        "$payload_dir"
        --combined "$combined_report"
        --fast-list
        --checkers "$rclone_checkers"
    )

    if [[ "$dry_run" == "true" ]]; then
        cmd+=(--dry-run)
    fi

    run_logged "$logfile" "${cmd[@]}"
    ensure_zip_payload
    local_payload_manifest
    write_marker "$state_dir/verify.ok"
}

upload_batch() {
    ensure_zip_payload
    require_cmd "$immich_go_bin"
    [[ -n "$immich_go_config" ]] || fail "--immich-go-config is required for upload mode (or set IMMICH_GO_CONFIG)"
    [[ -f "$immich_go_config" ]] || fail "immich-go config file not found: $immich_go_config"

    local pass
    for ((pass = 1; pass <= upload_passes; pass++)); do
        local logfile="$log_dir/upload-pass-${pass}.log"
        log_line "Uploading batch $batch_name to Immich (pass ${pass}/${upload_passes})"

        local cmd=(
            "$immich_go_bin"
            --config "$immich_go_config"
        )

        if [[ "$dry_run" == "true" ]]; then
            cmd+=(--dry-run)
        fi

        cmd+=(upload from-google-photos)
        cmd+=("${zip_files[@]}")
        run_logged "$logfile" "${cmd[@]}"
        write_marker "$state_dir/upload-pass-${pass}.ok"
    done

    write_marker "$state_dir/upload.ok"
}

cleanup_payload() {
    if [[ "$force_cleanup" != "true" && ! -f "$state_dir/upload.ok" ]]; then
        fail "Refusing cleanup because upload.ok is missing. Use --force-cleanup if you really want to remove the payload."
    fi

    log_line "Removing local payload directory $payload_dir"
    if [[ "$dry_run" == "true" ]]; then
        printf 'Would remove %s\n' "$payload_dir" | tee -a "$batch_log"
        return
    fi

    rm -rf -- "$payload_dir"
    write_marker "$state_dir/cleanup.ok"
}

source_remote="${SOURCE_REMOTE:-}"
stage_dir="${STAGE_DIR:-}"
batch_name="${BATCH_NAME:-}"
mode="${MODE:-all}"
rclone_bin="${RCLONE_BIN:-rclone}"
immich_go_bin="${IMMICH_GO_BIN:-immich-go}"
immich_go_config="${IMMICH_GO_CONFIG:-/config/immich-go/immich-go.yaml}"
rclone_transfers="${RCLONE_TRANSFERS:-4}"
rclone_checkers="${RCLONE_CHECKERS:-8}"
upload_passes="${UPLOAD_PASSES:-2}"
cleanup_after_success="${CLEANUP_AFTER_SUCCESS:-false}"
force_cleanup="false"
dry_run="${DRY_RUN:-false}"

while (($#)); do
    case "$1" in
        --source-remote)
            source_remote="${2:-}"
            shift 2
            ;;
        --stage-dir)
            stage_dir="${2:-}"
            shift 2
            ;;
        --batch-name)
            batch_name="${2:-}"
            shift 2
            ;;
        --mode)
            mode="${2:-}"
            shift 2
            ;;
        --immich-go-config)
            immich_go_config="${2:-}"
            shift 2
            ;;
        --rclone-binary)
            rclone_bin="${2:-}"
            shift 2
            ;;
        --immich-go-binary)
            immich_go_bin="${2:-}"
            shift 2
            ;;
        --rclone-transfers)
            rclone_transfers="${2:-}"
            shift 2
            ;;
        --rclone-checkers)
            rclone_checkers="${2:-}"
            shift 2
            ;;
        --upload-passes)
            upload_passes="${2:-}"
            shift 2
            ;;
        --cleanup-after-success)
            cleanup_after_success="${2:-}"
            shift 2
            ;;
        --force-cleanup)
            force_cleanup="true"
            shift
            ;;
        --dry-run)
            dry_run="true"
            shift
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

[[ -n "$source_remote" ]] || {
    usage >&2
    fail "--source-remote is required"
}

[[ -n "$stage_dir" ]] || {
    usage >&2
    fail "--stage-dir is required"
}

case "$mode" in
    all|download|verify|upload|cleanup) ;;
    *) fail "--mode must be one of: all, download, verify, upload, cleanup" ;;
esac

[[ "$rclone_transfers" =~ ^[0-9]+$ ]] || fail "--rclone-transfers must be an integer"
[[ "$rclone_checkers" =~ ^[0-9]+$ ]] || fail "--rclone-checkers must be an integer"
[[ "$upload_passes" =~ ^[0-9]+$ ]] || fail "--upload-passes must be an integer"
(( upload_passes >= 1 )) || fail "--upload-passes must be at least 1"

validate_bool "$cleanup_after_success"

batch_name="${batch_name:-$(slugify "$source_remote")}"
batch_root="${stage_dir%/}/${batch_name}"
payload_dir="${batch_root}/payload"
log_dir="${batch_root}/logs"
state_dir="${batch_root}/state"
batch_log="${log_dir}/batch.log"

mkdir -p "$payload_dir" "$log_dir" "$state_dir"
printf '%s\n' "$source_remote" >"$state_dir/source-remote.txt"

require_cmd "$rclone_bin"
require_cmd find
require_cmd tee

log_line "Batch root: $batch_root"
log_line "Mode: $mode"
log_line "Source remote: $source_remote"
log_line "Dry run: $dry_run"
if [[ -n "$immich_go_config" ]]; then
    log_line "immich-go config: $immich_go_config"
fi

case "$mode" in
    all)
        download_batch
        verify_batch
        upload_batch
        if [[ "$cleanup_after_success" == "true" ]]; then
            cleanup_payload
        fi
        ;;
    download)
        download_batch
        ;;
    verify)
        verify_batch
        ;;
    upload)
        upload_batch
        if [[ "$cleanup_after_success" == "true" ]]; then
            cleanup_payload
        fi
        ;;
    cleanup)
        cleanup_payload
        ;;
esac

log_line "Completed mode: $mode"
