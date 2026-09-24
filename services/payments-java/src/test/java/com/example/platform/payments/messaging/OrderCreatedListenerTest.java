package com.example.platform.payments.messaging;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageProperties;

import com.example.platform.payments.config.PaymentsProperties;
import com.example.platform.payments.service.PaymentService;
import com.example.platform.payments.service.TransientPaymentException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.rabbitmq.client.Channel;

class OrderCreatedListenerTest {

    private static final long TAG = 7L;

    PaymentService paymentService;
    Channel channel;
    OrderCreatedListener listener;

    @BeforeEach
    void setUp() {
        paymentService = mock(PaymentService.class);
        channel = mock(Channel.class);
        var props = new PaymentsProperties("shared", null, null,
                new PaymentsProperties.Provider("http://psp", Duration.ofSeconds(1), Duration.ofSeconds(2)));
        listener = new OrderCreatedListener(new ObjectMapper().registerModule(new JavaTimeModule()), paymentService, props);
    }

    @Test
    void acksAfterSuccessfulProcessingUsingTenantHeader() throws Exception {
        when(paymentService.process(eq("acme"), any())).thenReturn(PaymentService.Outcome.CAPTURED);

        listener.onOrderCreated(message(validBody(), "acme"), channel);

        verify(paymentService).process(eq("acme"), any());
        verify(channel).basicAck(TAG, false);
    }

    @Test
    void poisonMessageIsDeadLettered() throws Exception {
        listener.onOrderCreated(message("{not-json", "acme"), channel);

        verifyNoInteractions(paymentService);
        verify(channel).basicNack(TAG, false, false);
    }

    @Test
    void transientFailureIsRequeued() throws Exception {
        when(paymentService.process(any(), any())).thenThrow(new TransientPaymentException("down", null));

        listener.onOrderCreated(message(validBody(), "acme"), channel);

        verify(channel).basicNack(TAG, false, true);
    }

    private static String validBody() {
        return """
                {"eventId":"%s","eventType":"OrderCreated","occurredAt":"2026-01-01T10:00:00Z","tenantId":"acme",
                 "orderId":"%s","customerId":"c-1","totalAmount":10.5,"currency":"EUR","items":[]}
                """.formatted(UUID.randomUUID(), UUID.randomUUID());
    }

    private static Message message(String body, String tenant) {
        var props = new MessageProperties();
        props.setDeliveryTag(TAG);
        props.setHeader(OrderCreatedListener.TENANT_HEADER, tenant);
        props.setHeader(OrderCreatedListener.CORRELATION_HEADER, "corr-1");
        return new Message(body.getBytes(StandardCharsets.UTF_8), props);
    }
}
