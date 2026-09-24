package com.example.platform.payments.service;

/** The payment could not be processed now (provider down, circuit open, timeout); the message should be retried. */
public class TransientPaymentException extends RuntimeException {

    public TransientPaymentException(String message, Throwable cause) {
        super(message, cause);
    }
}
