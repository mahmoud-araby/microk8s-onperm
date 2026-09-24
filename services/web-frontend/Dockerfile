# syntax=docker/dockerfile:1.7
# ---- build ---------------------------------------------------------------------------------------------------------
# Node 22 LTS (Node 20 reached end-of-life in April 2026).
FROM --platform=$BUILDPLATFORM node:22-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund
COPY . .
RUN npm run build

# ---- runtime -------------------------------------------------------------------------------------------------------
# nginx-unprivileged runs as UID 101 and listens on 8080; its writable paths live in /tmp and are group-0 writable,
# so it also runs fine when the chart forces runAsUser 10001 (platform contract) with readOnlyRootFilesystem.
FROM nginxinc/nginx-unprivileged:1.29-alpine
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="web" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/mahmoud-araby/microk8s-onperm"
COPY nginx.conf /etc/nginx/conf.d/default.conf
# config.js is overridden at runtime by the chart's ConfigMap (window.__CONFIG__ per tenant).
COPY --from=build /src/dist /usr/share/nginx/html
USER 101
EXPOSE 8080
