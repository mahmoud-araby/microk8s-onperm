package com.example.platform.payments.domain;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.PrePersist;
import jakarta.persistence.PreUpdate;
import jakarta.persistence.Table;
import jakarta.persistence.Version;

@Entity
@Table(name = "payments")
public class Payment {

    @Id
    private UUID id;

    @Column(name = "tenant_id", nullable = false, updatable = false)
    private String tenantId;

    @Column(name = "order_id", nullable = false, updatable = false)
    private UUID orderId;

    @Column(nullable = false, precision = 19, scale = 4)
    private BigDecimal amount;

    @Column(nullable = false, length = 3)
    private String currency;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 16)
    private PaymentStatus status;

    @Column(name = "provider_reference")
    private String providerReference;

    @Column(name = "failure_reason")
    private String failureReason;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Version
    private long version;

    protected Payment() {
        // JPA
    }

    public static Payment pending(String tenantId, UUID orderId, BigDecimal amount, String currency) {
        var p = new Payment();
        p.id = UUID.randomUUID();
        p.tenantId = tenantId;
        p.orderId = orderId;
        p.amount = amount;
        p.currency = currency;
        p.status = PaymentStatus.PENDING;
        return p;
    }

    @PrePersist
    void onCreate() {
        createdAt = updatedAt = Instant.now();
    }

    @PreUpdate
    void onUpdate() {
        updatedAt = Instant.now();
    }

    public void captured(String reference) {
        status = PaymentStatus.CAPTURED;
        providerReference = reference;
        failureReason = null;
    }

    public void declined(String reason) {
        status = PaymentStatus.DECLINED;
        failureReason = reason;
    }

    public void failed(String reason) {
        status = PaymentStatus.FAILED;
        failureReason = reason;
    }

    public void cancel() {
        if (status == PaymentStatus.PENDING || status == PaymentStatus.FAILED) {
            status = PaymentStatus.CANCELLED;
        }
    }

    public boolean isFinal() {
        return status == PaymentStatus.CAPTURED || status == PaymentStatus.DECLINED || status == PaymentStatus.CANCELLED;
    }

    public UUID getId() { return id; }
    public String getTenantId() { return tenantId; }
    public UUID getOrderId() { return orderId; }
    public BigDecimal getAmount() { return amount; }
    public String getCurrency() { return currency; }
    public PaymentStatus getStatus() { return status; }
    public String getProviderReference() { return providerReference; }
    public String getFailureReason() { return failureReason; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
}
