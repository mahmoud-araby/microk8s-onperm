package com.example.platform.payments.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.kafka.KafkaProperties;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.env.YamlPropertySourceLoader;
import org.springframework.core.env.MapPropertySource;
import org.springframework.core.env.StandardEnvironment;
import org.springframework.core.io.ClassPathResource;

/** Verifies application.yml maps the platform KAFKA_* env vars (no Spring context / broker needed). */
class KafkaSettingsTest {

    @Test
    void localDefaultsArePlaintextWithPlatformPrefix() throws IOException {
        Binder binder = binder(Map.of());
        Map<String, Object> props = binder.bind("spring.kafka", KafkaProperties.class).get().buildConsumerProperties(null);

        assertThat(props).containsEntry("security.protocol", "PLAINTEXT");
        assertThat(binder.bind("payments.kafka.orders-topic", String.class).get()).isEqualTo("platform.orders-events");
        assertThat(binder.bind("payments.kafka.group-id", String.class).get()).isEqualTo("platform.payments");
    }

    @Test
    void platformListenersUseScramAndTenantPrefix() throws IOException {
        Binder binder = binder(Map.of(
                "KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT",
                "KAFKA_SASL_MECHANISM", "SCRAM-SHA-512",
                "KAFKA_USERNAME", "acme-payments",
                "KAFKA_PASSWORD", "s3cr3t",
                "KAFKA_TOPIC_PREFIX", "acme.",
                "KAFKA_CONSUMER_GROUP", "acme.payments-v1"));
        Map<String, Object> props = binder.bind("spring.kafka", KafkaProperties.class).get().buildConsumerProperties(null);

        assertThat(props)
                .containsEntry("security.protocol", "SASL_PLAINTEXT")
                .containsEntry("sasl.mechanism", "SCRAM-SHA-512");
        assertThat((String) props.get("sasl.jaas.config"))
                .contains("ScramLoginModule required")
                .contains("username=\"acme-payments\"")
                .contains("password=\"s3cr3t\"");
        assertThat(binder.bind("payments.kafka.orders-topic", String.class).get()).isEqualTo("acme.orders-events");
        assertThat(binder.bind("payments.kafka.group-id", String.class).get()).isEqualTo("acme.payments-v1");
    }

    private static Binder binder(Map<String, Object> env) throws IOException {
        var environment = new StandardEnvironment();
        var sources = environment.getPropertySources();
        sources.remove(StandardEnvironment.SYSTEM_ENVIRONMENT_PROPERTY_SOURCE_NAME);
        sources.addFirst(new MapPropertySource("env", env));
        new YamlPropertySourceLoader().load("application", new ClassPathResource("application.yml"))
                .forEach(sources::addLast);
        return Binder.get(environment);
    }
}
