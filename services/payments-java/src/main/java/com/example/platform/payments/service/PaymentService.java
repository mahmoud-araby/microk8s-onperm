package com.example.platform.payments.service;

import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletionException;
import java.util.concurrent.ExecutionException;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;

import com.example.platform.payments.domain.Payment;
import com.example.platform.payments.domain.PaymentRepository;
import com.example.platform.payments.messaging.OrderCreatedEvent;
import com.example.platform.payments.provider.ChargeRequest;
import com.example.platform.payments.provider.ChargeResult;
import com.example.platform.payments.provider.PaymentDeclinedException;
import com.example.platform.payments.provider.PaymentProviderClient;

import io.micrometer.core.instrument.MeterRegistry;

/**
 * Idempotent payment processing. No DB transaction is held open while calling the provider: the payment is
 * persisted as PENDING, the provider is called, and the outcome is stored.
 */
@Service
public class PaymentService {

    public enum Outcome { CAPTURED, DECLINED, DUPLICATE }

    private static final Logger log = LoggerFactory.getLogger(PaymentService.class);

    private final PaymentRepository repository;
    private final PaymentProviderClient provider;
    private final MeterRegistry meterRegistry;

    public PaymentService(PaymentRepository repository, PaymentProviderClient provider, MeterRegistry meterRegistry) {
        this.repository = repository;
        this.provider = provider;
        this.meterRegistry = meterRegistry;
    }

    public Outcome process(String tenantId, OrderCreatedEvent event) {
        event.validate();
        Optional<Payment> existing = repository.findByTenantIdAndOrderId(tenantId, event.orderId());
        if (existing.isPresent() && existing.get().isFinal()) {
            log.info("Duplicate OrderCreated for order {} ignored (payment {} is {})",
                    event.orderId(), existing.get().getId(), existing.get().getStatus());
            return record(Outcome.DUPLICATE);
        }

        Payment payment;
        try {
            payment = existing.orElseGet(() -> repository.save(
                    Payment.pending(tenantId, event.orderId(), event.totalAmount(), event.currency())));
        } catch (DataIntegrityViolationException race) {
            // Another consumer inserted the same (tenant, order) concurrently.
            return record(Outcome.DUPLICATE);
        }

        var request = new ChargeRequest(payment.getId(), event.orderId().toString(), payment.getAmount(),
                payment.getCurrency());
        try {
            ChargeResult result = provider.charge(request).get();
            payment.captured(result.reference());
            repository.save(payment);
            log.info("Payment {} captured for order {}", payment.getId(), event.orderId());
            return record(Outcome.CAPTURED);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new TransientPaymentException("Interrupted while charging", e);
        } catch (ExecutionException | RuntimeException e) {
            Throwable cause = unwrap(e);
            if (cause instanceof PaymentDeclinedException declined) {
                payment.declined(declined.getMessage());
                repository.save(payment);
                log.warn("Payment {} declined for order {}", payment.getId(), event.orderId());
                return record(Outcome.DECLINED);
            }
            payment.failed(cause.getClass().getSimpleName() + ": " + cause.getMessage());
            repository.save(payment);
            meterRegistry.counter("payments_processed", "outcome", "transient_failure").increment();
            throw new TransientPaymentException("Payment provider unavailable", cause);
        }
    }

    public void cancel(String tenantId, UUID orderId) {
        repository.findByTenantIdAndOrderId(tenantId, orderId).ifPresent(payment -> {
            payment.cancel();
            repository.save(payment);
        });
    }

    private Outcome record(Outcome outcome) {
        meterRegistry.counter("payments_processed", "outcome", outcome.name().toLowerCase()).increment();
        return outcome;
    }

    private static Throwable unwrap(Throwable e) {
        Throwable t = e;
        while ((t instanceof ExecutionException || t instanceof CompletionException) && t.getCause() != null) {
            t = t.getCause();
        }
        return t;
    }
}
