package com.example.platform.payments.api;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import com.example.platform.payments.config.TenantContextFilter;
import com.example.platform.payments.domain.Payment;
import com.example.platform.payments.domain.PaymentRepository;

/** Read API; payments are created asynchronously from OrderCreated events. All queries are tenant scoped. */
@RestController
@RequestMapping("/payments")
public class PaymentController {

    public record PaymentView(UUID id, UUID orderId, BigDecimal amount, String currency, String status,
                              String providerReference, Instant createdAt, Instant updatedAt) {
        static PaymentView of(Payment p) {
            return new PaymentView(p.getId(), p.getOrderId(), p.getAmount(), p.getCurrency(), p.getStatus().name(),
                    p.getProviderReference(), p.getCreatedAt(), p.getUpdatedAt());
        }
    }

    private final PaymentRepository repository;

    public PaymentController(PaymentRepository repository) {
        this.repository = repository;
    }

    @GetMapping("/{id}")
    public PaymentView get(@RequestAttribute(TenantContextFilter.MDC_TENANT) String tenant, @PathVariable UUID id) {
        return repository.findByTenantIdAndId(tenant, id).map(PaymentView::of)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "payment not found"));
    }

    @GetMapping
    public List<PaymentView> list(@RequestAttribute(TenantContextFilter.MDC_TENANT) String tenant,
                                  @RequestParam(required = false) UUID orderId) {
        if (orderId != null) {
            return repository.findByTenantIdAndOrderId(tenant, orderId).map(PaymentView::of).stream().toList();
        }
        return repository.findTop100ByTenantIdOrderByCreatedAtDesc(tenant).stream().map(PaymentView::of).toList();
    }
}
