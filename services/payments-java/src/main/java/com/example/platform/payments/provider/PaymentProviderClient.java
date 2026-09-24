package com.example.platform.payments.provider;

import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.util.StreamUtils;
import org.springframework.web.client.RestClient;

import io.github.resilience4j.bulkhead.annotation.Bulkhead;
import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import io.github.resilience4j.retry.annotation.Retry;
import io.github.resilience4j.timelimiter.annotation.TimeLimiter;

/**
 * Client for the external payment provider, reached through the Istio egress gateway (hybrid ServiceEntry).
 *
 * <p>Application-level resilience complements the mesh: Istio handles connection-level retries/outlier detection,
 * while here we apply business-aware policies (Resilience4j aspect order: Retry → CircuitBreaker → TimeLimiter →
 * Bulkhead). Declines (402/422) are excluded from retry and circuit-breaker accounting (see application.yml).
 */
@Component
public class PaymentProviderClient {

    public static final String RESILIENCE_NAME = "paymentProvider";

    private final RestClient restClient;

    public PaymentProviderClient(RestClient paymentProviderRestClient) {
        this.restClient = paymentProviderRestClient;
    }

    @Retry(name = RESILIENCE_NAME)
    @CircuitBreaker(name = RESILIENCE_NAME)
    @TimeLimiter(name = RESILIENCE_NAME)
    @Bulkhead(name = RESILIENCE_NAME, type = Bulkhead.Type.THREADPOOL)
    public CompletableFuture<ChargeResult> charge(ChargeRequest request) {
        ChargeResult result = restClient.post()
                .uri("/v1/charges")
                .header("Idempotency-Key", request.idempotencyKey().toString())
                .body(request)
                .retrieve()
                .onStatus(status -> status.value() == HttpStatus.PAYMENT_REQUIRED.value()
                                || status.value() == HttpStatus.UNPROCESSABLE_ENTITY.value(),
                        (req, res) -> {
                            throw new PaymentDeclinedException(
                                    StreamUtils.copyToString(res.getBody(), StandardCharsets.UTF_8));
                        })
                .body(ChargeResult.class);
        return CompletableFuture.completedFuture(result);
    }
}
