package com.example.platform.payments.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

/** Service specific configuration (prefix {@code payments}), bound from application.yml / env. */
@Validated
@ConfigurationProperties(prefix = "payments")
public record PaymentsProperties(
        @NotBlank String tenantId,
        Rabbit rabbit,
        Kafka kafka,
        Provider provider) {

    public record Rabbit(@NotBlank String exchange, @NotBlank String routingKey, @NotBlank String queue,
                         @NotBlank String deadLetterExchange, @NotBlank String deadLetterQueue) {
    }

    public record Kafka(@NotBlank String ordersTopic, @NotBlank String groupId) {
    }

    /** External payment provider reached through the Istio egress gateway (hybrid ServiceEntry). */
    public record Provider(@NotBlank String baseUrl, @NotNull Duration connectTimeout, @NotNull Duration readTimeout) {
    }
}
