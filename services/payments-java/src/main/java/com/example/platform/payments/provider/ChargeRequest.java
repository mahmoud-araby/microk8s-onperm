package com.example.platform.payments.provider;

import java.math.BigDecimal;
import java.util.UUID;

/** Request sent to the external payment provider. {@code idempotencyKey} makes provider-side retries safe. */
public record ChargeRequest(UUID idempotencyKey, String merchantReference, BigDecimal amount, String currency) {
}
