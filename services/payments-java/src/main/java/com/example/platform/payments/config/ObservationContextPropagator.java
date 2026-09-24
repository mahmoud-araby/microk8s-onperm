package com.example.platform.payments.config;

import java.util.Optional;
import java.util.function.Consumer;
import java.util.function.Supplier;

import io.github.resilience4j.core.ContextPropagator;
import io.micrometer.context.ContextSnapshot;
import io.micrometer.context.ContextSnapshotFactory;

/**
 * Carries the tracing context (and MDC-backed thread locals registered with Micrometer context-propagation)
 * into Resilience4j thread-pool bulkhead threads, so outbound calls stay in the same trace.
 */
public class ObservationContextPropagator implements ContextPropagator<ContextSnapshot> {

    private static final ContextSnapshotFactory FACTORY = ContextSnapshotFactory.builder().build();
    private static final ThreadLocal<ContextSnapshot.Scope> SCOPE = new ThreadLocal<>();

    @Override
    public Supplier<Optional<ContextSnapshot>> retrieve() {
        return () -> Optional.of(FACTORY.captureAll());
    }

    @Override
    public Consumer<Optional<ContextSnapshot>> copy() {
        return snapshot -> snapshot.ifPresent(s -> SCOPE.set(s.setThreadLocals()));
    }

    @Override
    public Consumer<Optional<ContextSnapshot>> clear() {
        return snapshot -> {
            ContextSnapshot.Scope scope = SCOPE.get();
            if (scope != null) {
                scope.close();
                SCOPE.remove();
            }
        };
    }
}
