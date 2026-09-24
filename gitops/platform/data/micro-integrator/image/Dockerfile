# Platform Micro Integrator image = stock WSO2 MI + Kafka inbound endpoint + (optionally) CApps.
# Built by CI and pushed to harbor.ops.example.local/platform/wso2mi:<mi-version>-platform.<n>;
# then set that image in ../manifests/30-deployment.yaml. The stock image works for everything
# except the Kafka inbound endpoint (its class is not part of the MI 4.4.0 distribution; Synapse
# fail-safe mode just skips that artifact and logs an error).
#
#   docker build \
#     --build-arg KAFKA_INBOUND_URL=<URL of the WSO2 "Kafka Inbound Endpoint" connector JAR from
#                                    the WSO2 connector store / Maven repo, version for MI 4.4.x> \
#     -t harbor.ops.example.local/platform/wso2mi:4.4.0-platform.1 .
FROM wso2/wso2mi:4.4.0
# pin: verify latest before upgrade (4.5.0 / 4.6.0 exist; re-test deployment.toml + artifacts)

ARG KAFKA_INBOUND_URL
ARG KAFKA_CLIENTS_VERSION=3.9.1
ARG MI_HOME=/home/wso2carbon/wso2mi-4.4.0

# Kafka inbound endpoint + Kafka client library (lib/ jars are OSGi-bundled at startup).
ADD --chown=wso2carbon:wso2 ${KAFKA_INBOUND_URL} ${MI_HOME}/lib/
ADD --chown=wso2carbon:wso2 https://repo1.maven.org/maven2/org/apache/kafka/kafka-clients/${KAFKA_CLIENTS_VERSION}/kafka-clients-${KAFKA_CLIENTS_VERSION}.jar ${MI_HOME}/lib/

# Optional: CApps built from an MI project (VS Code MI extension / Maven) instead of the ConfigMap.
# COPY --chown=wso2carbon:wso2 carbonapps/*.car ${MI_HOME}/repository/deployment/server/carbonapps/

USER 10802
