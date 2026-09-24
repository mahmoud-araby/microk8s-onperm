package com.example.platform.payments.messaging;

import java.nio.charset.StandardCharsets;
import java.util.Optional;
import java.util.UUID;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.header.Header;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

import com.example.platform.payments.config.PaymentsProperties;
import com.example.platform.payments.config.TenantContextFilter;
import com.example.platform.payments.service.PaymentService;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import io.micrometer.core.instrument.MeterRegistry;

/**
 * Consumes the order event stream ({@code platform.orders-events}) to keep payments in sync with the order
 * lifecycle (e.g. cancel pending payments). Failures are retried and then sent to {@code <topic>.DLT}
 * (see {@link com.example.platform.payments.config.KafkaConfig}).
 */
@Component
public class OrderEventsKafkaListener {

    private static final Logger log = LoggerFactory.getLogger(OrderEventsKafkaListener.class);

    private final ObjectMapper objectMapper;
    private final PaymentService paymentService;
    private final MeterRegistry meterRegistry;
    private final String defaultTenant;

    public OrderEventsKafkaListener(ObjectMapper objectMapper, PaymentService paymentService,
                                    MeterRegistry meterRegistry, PaymentsProperties properties) {
        this.objectMapper = objectMapper;
        this.paymentService = paymentService;
        this.meterRegistry = meterRegistry;
        this.defaultTenant = properties.tenantId();
    }

    @KafkaListener(topics = "${payments.kafka.orders-topic}", groupId = "${payments.kafka.group-id}")
    public void onOrderEvent(ConsumerRecord<String, String> record) throws JsonProcessingException {
        JsonNode event = objectMapper.readTree(record.value());
        String type = event.path("eventType").asText("Unknown");
        String tenant = header(record, OrderCreatedListener.TENANT_HEADER)
                .or(() -> Optional.ofNullable(event.path("tenantId").textValue()))
                .orElse(defaultTenant);
        try (var t = MDC.putCloseable(TenantContextFilter.MDC_TENANT, tenant)) {
            meterRegistry.counter("payments_order_events_consumed", "event_type", type).increment();
            if ("OrderCancelled".equals(type)) {
                paymentService.cancel(tenant, UUID.fromString(event.path("orderId").asText()));
                log.info("Order {} cancelled; pending payment cancelled", event.path("orderId").asText());
            } else {
                log.debug("Order event {} for key {} at offset {}", type, record.key(), record.offset());
            }
        }
    }

    private static Optional<String> header(ConsumerRecord<?, ?> record, String name) {
        Header header = record.headers().lastHeader(name);
        return header == null ? Optional.empty() : Optional.of(new String(header.value(), StandardCharsets.UTF_8));
    }
}
