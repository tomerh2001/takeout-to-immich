ARG IMMICH_GO_VERSION=v0.31.0
FROM alpine:3.21

ARG IMMICH_GO_VERSION

RUN apk add --no-cache bash ca-certificates coreutils curl findutils rclone tar \
    && arch="$(apk --print-arch)" \
    && case "$arch" in \
        x86_64) immich_asset="immich-go_Linux_x86_64.tar.gz" ;; \
        aarch64) immich_asset="immich-go_Linux_arm64.tar.gz" ;; \
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac \
    && base_url="https://github.com/simulot/immich-go/releases/download/${IMMICH_GO_VERSION}" \
    && curl -fsSLO "${base_url}/${immich_asset}" \
    && curl -fsSLO "${base_url}/checksums.txt" \
    && grep " ${immich_asset}$" checksums.txt | sha256sum -c - \
    && tar -xzf "${immich_asset}" -C /usr/local/bin immich-go \
    && chmod +x /usr/local/bin/immich-go \
    && rm -f "${immich_asset}" checksums.txt

COPY lib/takeout-to-immich-worker.sh /usr/local/bin/takeout-to-immich-worker
COPY lib/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/takeout-to-immich-worker /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--help"]

