# takeout-to-immich

Docker-first Google Photos Takeout imports for Immich, using `rclone` for
staging and verification and `immich-go` for the actual Takeout-aware import.

## What It Does

- Downloads one complete Google Photos Takeout export from Google Drive with `rclone copy`
- Verifies the staged copy with `rclone check`
- Imports the full export into Immich with `immich-go upload from-google-photos`
- Keeps `payload`, `logs`, and `state` separated so the workflow is resumable and auditable
- Runs inside an ephemeral container so the host does not need `rclone` or `immich-go` installed

## Why This Exists

The dangerous version of this workflow is:

1. download one `50 GB` split ZIP
2. import it
3. delete it
4. repeat

That looks efficient, but Google Photos metadata JSON and media files can span
multiple ZIP parts of the same export. This project treats a complete export
set as the smallest safe batch boundary and keeps the resumability in the
download and upload layers instead.

## Quick Start

1. Copy `.env.example` to `.env`
2. Set `SOURCE_REMOTE`, `STAGE_DIR`, `RCLONE_CONFIG_PATH`, `IMMICH_SERVER`, and `IMMICH_API_KEY`
3. Run the wrapper:

```bash
bash bin/takeout-to-immich --mode download
bash bin/takeout-to-immich --mode verify
bash bin/takeout-to-immich --mode upload
```

The wrapper will:

- pull `ghcr.io/tomerh2001/takeout-to-immich:latest` if available
- fall back to building the local image from this repo if needed
- launch the worker in an ephemeral container

## Docker-Only Usage

If you do not want the wrapper, you can run the published image directly:

```bash
docker run --rm \
  --env-file .env \
  -v "$PWD/config/rclone-google-drive.conf:/config/rclone/rclone.conf:ro" \
  -v /absolute/path/to/google-photos-staging:/absolute/path/to/google-photos-staging \
  ghcr.io/tomerh2001/takeout-to-immich:latest \
  --mode download
```

If your Immich server is only reachable on a Docker network, also add
`--network your-network-name` and set `IMMICH_SERVER` to the container URL,
for example `http://immich:8080`.

## Modes

- `download`: stage the export locally with `rclone copy`
- `verify`: compare source and staged payload with `rclone check`
- `upload`: import the staged payload into Immich
- `cleanup`: remove the local payload after a successful upload
- `all`: run `download`, `verify`, and `upload` in sequence

## Important Safety Rules

- Batch by complete export set, not by individual split ZIP.
- Do not rename Takeout ZIP files.
- Keep `INCLUDE_UNMATCHED=false` unless you are intentionally salvaging incomplete metadata.
- Do not delete staging until the `verify` step and the second upload pass both succeed.

## TrueNAS Helper

If your Google Drive remote already exists as a TrueNAS Cloud Sync credential,
you can materialize an `rclone` config file with:

```bash
bash scripts/export-truenas-cloudsync-rclone-config.sh \
  --credential-name "Google Drive" \
  --output ./config/rclone-google-drive.conf
```

This helper is optional and TrueNAS-specific.

## Releases

GitHub Actions automatically:

- lint and build-test the project on pushes and pull requests
- create GitHub Releases on version tags like `v0.1.0`
- publish versioned container images to `ghcr.io/tomerh2001/takeout-to-immich`

## License

MIT

