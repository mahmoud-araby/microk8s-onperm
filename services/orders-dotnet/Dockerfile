# syntax=docker/dockerfile:1.7
# ---- build ---------------------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:8.0 AS build
ARG TARGETARCH
ARG DOTNET_EF_VERSION=8.0.31
WORKDIR /src
RUN dotnet tool install --tool-path /tools dotnet-ef --version ${DOTNET_EF_VERSION}
# Restore first (cached layer as long as project files do not change).
COPY global.json Directory.Build.props .editorconfig ./
COPY src/Orders.Api/Orders.Api.csproj src/Orders.Api/
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet restore src/Orders.Api/Orders.Api.csproj -a $TARGETARCH
COPY src/ src/
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet publish src/Orders.Api/Orders.Api.csproj -c Release -a $TARGETARCH --no-restore \
      -o /app /p:UseAppHost=false
# EF Core migration bundle; the chart's migrations init container runs
#   /app/efbundle --connection "Host=...;Database=...;Username=...;Password=..."
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    RID=linux-$( [ "$TARGETARCH" = "amd64" ] && echo x64 || echo "$TARGETARCH" ) \
 && /tools/dotnet-ef migrations bundle --project src/Orders.Api/Orders.Api.csproj --configuration Release \
      -r $RID -o /app/efbundle

# ---- runtime: Ubuntu chiseled (distroless-like, no shell, no package manager) --------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:8.0-noble-chiseled
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="orders" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/mahmoud-araby/microk8s-onperm"
WORKDIR /app
COPY --from=build /app ./
ENV APP_VERSION=${APP_VERSION} \
    ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_gcServer=0 \
    DOTNET_EnableDiagnostics=0 \
    DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp/.net \
    TMPDIR=/tmp
# The chiseled image ships a non-root "app" user (UID 1654); the platform contract (and the chart's
# securityContext.runAsUser) uses UID 10001, so we run as 10001 explicitly. Nothing is written outside /tmp,
# so readOnlyRootFilesystem works (DOTNET_EnableDiagnostics=0 disables the diagnostics IPC socket; the single-file
# efbundle extracts to /tmp/.net).
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["dotnet", "Orders.Api.dll"]
