package com.example.platform.payments.messaging;

import java.io.IOException;
import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageProperties;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;

import com.example.platform.payments.config.PaymentsProperties;
import com.example.platform.payments.config.TenantContextFilter;
import com.example.platform.payments.service.PaymentService;
import com.example.platform.payments.service.TransientPaymentException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.rabbitmq.client.Channel;

/**
 * Consumes {@code payments.order-created} with manual acknowledgements:
 * <ul>
 *   <li>success / business decline / duplicate → ack</li>
 *   <li>poison message (unparseable, invalid) → nack without requeue → dead-letter queue</li>
 *   <li>transient failure → nack with requeue; the quorum queue {@code x-delivery-limit} dead-letters it
 *       after too many attempts</li>
 * </ul>
 */
@Component
public class OrderCreatedListener {

    static final String TENANT_HEADER = "x-tenant-id";
    static final String CORRELATION_HEADER = "x-correlation-id";

    private static final Logger log = LoggerFactory.getLogger(OrderCreatedListener.class);

    private final ObjectMapper objectMapper;
    private final PaymentService paymentService;
    private final String defaultTenant;

    public OrderCreatedListener(ObjectMapper objectMapper, PaymentService paymentService, PaymentsProperties properties) {
        this.objectMapper = objectMapper;
        this.paymentService = paymentService;
        this.defaultTenant = properties.tenantId();
    }

    @RabbitListener(queues = "${payments.rabbit.queue}")
    public void onOrderCreated(Message message, Channel channel) throws IOException {
        MessageProperties props = message.getMessageProperties();
        long deliveryTag = props.getDeliveryTag();
        String correlationId = Optional.ofNullable(props.<Object>getHeader(CORRELATION_HEADER))
                .map(Object::toString).orElse(props.getCorrelationId());
        try (var c = MDC.putCloseable(TenantContextFilter.MDC_CORRELATION, correlationId)) {
            OrderCreatedEvent event = objectMapper.readValue(message.getBody(), OrderCreatedEvent.class);
            String tenant = Optional.ofNullable(props.<Object>getHeader(TENANT_HEADER)).map(Object::toString)
                    .or(() -> Optional.ofNullable(event.tenantId()))
                    .orElse(defaultTenant);
            try (var t = MDC.putCloseable(TenantContextFilter.MDC_TENANT, tenant)) {
                var outcome = paymentService.process(tenant, event);
                log.info("OrderCreated {} handled: {}", event.orderId(), outcome);
                channel.basicAck(deliveryTag, false);
            }
        } catch (JsonProcessingException | IllegalArgumentException poison) {
            log.error("Rejecting poison message {} to DLQ: {}", props.getMessageId(), poison.getMessage());
            channel.basicNack(deliveryTag, false, false);
        } catch (TransientPaymentException transientError) {
            log.warn("Transient failure for message {}, requeueing: {}", props.getMessageId(),
                    transientError.getCause() == null ? transientError.getMessage() : transientError.getCause().toString());
            channel.basicNack(deliveryTag, false, true);
        } catch (RuntimeException unexpected) {
            log.error("Unexpected failure for message {}, dead-lettering", props.getMessageId(), unexpected);
            channel.basicNack(deliveryTag, false, false);
        }
    }
}
