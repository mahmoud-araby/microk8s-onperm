package com.example.platform.payments.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.server.observation.ServerRequestObservationContext;

import io.micrometer.observation.ObservationPredicate;

@Configuration
public class ObservabilityConfig {

    /** Kubelet probes and Prometheus scrapes must not create traces (noise + APM cost). */
    @Bean
    ObservationPredicate skipProbeAndScrapeObservations() {
        return (name, context) -> {
            if (context instanceof ServerRequestObservationContext server) {
                String uri = server.getCarrier().getRequestURI();
                return !(uri.startsWith("/health") || uri.equals("/metrics"));
            }
            return true;
        };
    }
}
