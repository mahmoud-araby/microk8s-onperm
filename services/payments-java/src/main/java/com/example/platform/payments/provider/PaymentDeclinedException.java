package com.example.platform.payments.provider;

/** Business rejection by the provider (HTTP 402/422). Never retried and never counted by the circuit breaker. */
public class PaymentDeclinedException extends RuntimeException {

    public PaymentDeclinedException(String message) {
        super(message);
    }
}
