# syntax=docker/dockerfile:1.7
# ---- build --------------------------------------------------------------------------------------------------------
FROM maven:3-eclipse-temurin-26 AS build
WORKDIR /src
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B -q -DskipTests package \
 && java -Djarmode=tools -jar target/app.jar extract --layers --launcher --destination /extracted

# ---- runtime ------------------------------------------------------------------------------------------------------
FROM eclipse-temurin:21-jre-noble
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="payments" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/mahmoud-araby/microk8s-onperm"
WORKDIR /app
# Layer order: least → most frequently changing, so image pulls on the cluster reuse dependency layers.
COPY --from=build /extracted/dependencies/ ./
COPY --from=build /extracted/spring-boot-loader/ ./
COPY --from=build /extracted/snapshot-dependencies/ ./
COPY --from=build /extracted/application/ ./
ENV APP_VERSION=${APP_VERSION} \
    TZ=UTC \
    JAVA_OPTS_DEFAULT="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -Djava.io.tmpdir=/tmp -Duser.home=/tmp"
# Non-root, read-only root FS friendly (only /tmp must be writable; mount an emptyDir there).
USER 10001:10001
EXPOSE 8080
# Extra JVM flags (e.g. -javaagent injected by the chart) go through JAVA_TOOL_OPTIONS.
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS_DEFAULT $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
