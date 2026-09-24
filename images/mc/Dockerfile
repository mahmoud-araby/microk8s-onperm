# MinIO client (mc) built from source and published to Harbor as platform/mc:<MC_RELEASE>.
# MinIO no longer publishes community binaries/images, and Kyverno only admits images from Harbor,
# so every chart (tenant bucket provisioning Job, sync mounts) uses this image.
ARG GO_VERSION=1.24
FROM golang:${GO_VERSION}-bookworm AS build
ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z
WORKDIR /src
RUN git clone --depth 1 --branch "${MC_RELEASE}" https://github.com/minio/mc.git . \
 && CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X github.com/minio/mc/cmd.ReleaseTag=${MC_RELEASE}" \
      -o /out/mc .

# Alpine (not distroless): the charts drive mc from /bin/sh scripts (provisioning Job, sync loops, heartbeat probes).
FROM alpine:3.22 AS runtime
RUN apk add --no-cache ca-certificates tini
ARG MC_RELEASE
LABEL org.opencontainers.image.title="mc" \
      org.opencontainers.image.version="${MC_RELEASE}" \
      org.opencontainers.image.source="https://github.com/minio/mc"
COPY --from=build /out/mc /usr/bin/mc
# Writable config dir lives on the /tmp emptyDir (read-only root filesystem in the charts).
ENV MC_CONFIG_DIR=/tmp/.mc HOME=/tmp
USER 10001:10001
ENTRYPOINT ["/sbin/tini", "--", "/usr/bin/mc"]
