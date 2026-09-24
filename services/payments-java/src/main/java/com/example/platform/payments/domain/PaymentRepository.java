package com.example.platform.payments.domain;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.data.jpa.repository.JpaRepository;

public interface PaymentRepository extends JpaRepository<Payment, UUID> {

    Optional<Payment> findByTenantIdAndOrderId(String tenantId, UUID orderId);

    Optional<Payment> findByTenantIdAndId(String tenantId, UUID id);

    List<Payment> findTop100ByTenantIdOrderByCreatedAtDesc(String tenantId);
}
