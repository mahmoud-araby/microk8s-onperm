package com.example.platform.payments.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeoutException;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import com.example.platform.payments.domain.Payment;
import com.example.platform.payments.domain.PaymentRepository;
import com.example.platform.payments.domain.PaymentStatus;
import com.example.platform.payments.messaging.OrderCreatedEvent;
import com.example.platform.payments.provider.ChargeResult;
import com.example.platform.payments.provider.PaymentDeclinedException;
import com.example.platform.payments.provider.PaymentProviderClient;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;

@ExtendWith(MockitoExtension.class)
class PaymentServiceTest {

    private static final String TENANT = "acme";

    @Mock
    PaymentRepository repository;
    @Mock
    PaymentProviderClient provider;

    SimpleMeterRegistry meters;
    PaymentService service;

    @BeforeEach
    void setUp() {
        meters = new SimpleMeterRegistry();
        service = new PaymentService(repository, provider, meters);
        lenient().when(repository.save(any(Payment.class))).thenAnswer(inv -> inv.getArgument(0));
    }

    @Test
    void capturesPaymentForNewOrder() {
        var event = event(UUID.randomUUID());
        when(repository.findByTenantIdAndOrderId(TENANT, event.orderId())).thenReturn(Optional.empty());
        when(provider.charge(any())).thenReturn(CompletableFuture.completedFuture(new ChargeResult("psp-1", "captured")));

        assertThat(service.process(TENANT, event)).isEqualTo(PaymentService.Outcome.CAPTURED);
        assertThat(meters.counter("payments_processed", "outcome", "captured").count()).isEqualTo(1.0);
    }

    @Test
    void declineIsRecordedAndNotRetried() {
        var event = event(UUID.randomUUID());
        when(repository.findByTenantIdAndOrderId(TENANT, event.orderId())).thenReturn(Optional.empty());
        when(provider.charge(any())).thenReturn(CompletableFuture.failedFuture(new PaymentDeclinedException("insufficient funds")));

        assertThat(service.process(TENANT, event)).isEqualTo(PaymentService.Outcome.DECLINED);
    }

    @Test
    void duplicateEventForFinalPaymentIsIgnored() {
        var orderId = UUID.randomUUID();
        var captured = Payment.pending(TENANT, orderId, BigDecimal.TEN, "EUR");
        captured.captured("psp-1");
        when(repository.findByTenantIdAndOrderId(TENANT, orderId)).thenReturn(Optional.of(captured));

        assertThat(service.process(TENANT, event(orderId))).isEqualTo(PaymentService.Outcome.DUPLICATE);
        verify(provider, never()).charge(any());
    }

    @Test
    void providerOutageIsTransient() {
        var event = event(UUID.randomUUID());
        when(repository.findByTenantIdAndOrderId(TENANT, event.orderId())).thenReturn(Optional.empty());
        when(provider.charge(any())).thenReturn(CompletableFuture.failedFuture(new TimeoutException("slow provider")));

        assertThatThrownBy(() -> service.process(TENANT, event))
                .isInstanceOf(TransientPaymentException.class)
                .hasCauseInstanceOf(TimeoutException.class);
    }

    @Test
    void invalidEventIsRejected() {
        var invalid = new OrderCreatedEvent(UUID.randomUUID(), "OrderCreated", Instant.now(), TENANT, "c-1",
                UUID.randomUUID(), "cust-1", BigDecimal.ZERO, "EUR", List.of());
        assertThatThrownBy(() -> service.process(TENANT, invalid)).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void cancelOnlyAffectsNonFinalPayments() {
        var orderId = UUID.randomUUID();
        var pending = Payment.pending(TENANT, orderId, BigDecimal.TEN, "EUR");
        when(repository.findByTenantIdAndOrderId(TENANT, orderId)).thenReturn(Optional.of(pending));

        service.cancel(TENANT, orderId);
        assertThat(pending.getStatus()).isEqualTo(PaymentStatus.CANCELLED);
    }

    private static OrderCreatedEvent event(UUID orderId) {
        return new OrderCreatedEvent(UUID.randomUUID(), "OrderCreated", Instant.now(), TENANT, "corr-1", orderId,
                "cust-1", new BigDecimal("42.50"), "EUR",
                List.of(new OrderCreatedEvent.Item("sku-1", 1, new BigDecimal("42.50"))));
    }
}
