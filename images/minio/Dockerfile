# MinIO server built from source and published to Harbor as platform/minio:<MINIO_RELEASE>.
# The upstream minio/minio project is source-only (no maintained binaries/images); the last release tag is pinned here.
# Used by the in-cluster MinIO tenant (gitops/platform/core/minio). The external MinIO VMs can reuse the binary
# (docker create + docker cp /usr/bin/minio) when ansible minio_server_binary_source is "url".
ARG GO_VERSION=1.24
FROM golang:${GO_VERSION}-bookworm AS build
ARG MINIO_RELEASE=RELEASE.2025-10-15T17-29-55Z
WORKDIR /src
RUN git clone --depth 1 --branch "${MINIO_RELEASE}" https://github.com/minio/minio.git . \
 && CGO_ENABLED=0 go build -trimpath -tags kqueue \
      -ldflags "-s -w $(go run buildscripts/gen-ldflags.go 2>/dev/null || true)" \
      -o /out/minio .

FROM alpine:3.22 AS runtime
ARG MINIO_RELEASE
LABEL org.opencontainers.image.title="minio" \
      org.opencontainers.image.version="${MINIO_RELEASE}" \
      org.opencontainers.image.source="https://github.com/minio/minio"
RUN apk add --no-cache ca-certificates
COPY --from=build /out/minio /usr/bin/minio
ENV MINIO_CONFIG_ENV_FILE=config.env
EXPOSE 9000 9090
USER 10001:10001
ENTRYPOINT ["/usr/bin/minio"]
