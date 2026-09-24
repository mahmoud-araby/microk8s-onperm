package com.example.platform.payments.config;

import java.io.IOException;
import java.util.UUID;

import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * Puts {@code tenant_id} and {@code correlation_id} into the logging MDC and echoes X-Correlation-ID.
 * Tenant comes from the X-Tenant-ID header (set by Kong from the JWT claim) or falls back to env TENANT_ID.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class TenantContextFilter extends OncePerRequestFilter {

    public static final String TENANT_HEADER = "X-Tenant-ID";
    public static final String CORRELATION_HEADER = "X-Correlation-ID";
    public static final String MDC_TENANT = "tenant_id";
    public static final String MDC_CORRELATION = "correlation_id";

    private final PaymentsProperties properties;

    public TenantContextFilter(PaymentsProperties properties) {
        this.properties = properties;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String tenant = headerOr(request, TENANT_HEADER, properties.tenantId());
        String correlationId = headerOr(request, CORRELATION_HEADER, UUID.randomUUID().toString());
        request.setAttribute(MDC_TENANT, tenant);
        response.setHeader(CORRELATION_HEADER, correlationId);
        try (var t = MDC.putCloseable(MDC_TENANT, tenant);
             var c = MDC.putCloseable(MDC_CORRELATION, correlationId)) {
            chain.doFilter(request, response);
        }
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        return path.startsWith("/health") || path.equals("/metrics");
    }

    private static String headerOr(HttpServletRequest request, String name, String fallback) {
        String value = request.getHeader(name);
        return value == null || value.isBlank() ? fallback : value;
    }
}
