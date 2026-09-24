package com.example.platform.payments.provider;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

@JsonIgnoreProperties(ignoreUnknown = true)
public record ChargeResult(String reference, String status) {
}
