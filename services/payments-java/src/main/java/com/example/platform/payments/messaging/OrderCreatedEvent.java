package com.example.platform.payments.messaging;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

/**
 * OrderCreated integration event (published by the orders service to RabbitMQ exchange {@code orders.events},
 * routing key {@code order.created}, and to Kafka topic {@code platform.orders-events}).
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record OrderCreatedEvent(
        UUID eventId,
        String eventType,
        Instant occurredAt,
        String tenantId,
        String correlationId,
        UUID orderId,
        String customerId,
        BigDecimal totalAmount,
        String currency,
        List<Item> items) {

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Item(String productId, int quantity, BigDecimal unitPrice) {
    }

    public void validate() {
        if (orderId == null || totalAmount == null || currency == null || currency.length() != 3) {
            throw new IllegalArgumentException("OrderCreated event is missing orderId/totalAmount/currency");
        }
        if (totalAmount.signum() <= 0) {
            throw new IllegalArgumentException("OrderCreated totalAmount must be positive");
        }
    }
}
