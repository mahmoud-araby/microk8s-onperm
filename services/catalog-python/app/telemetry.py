"""OpenTelemetry traces + metrics exported via OTLP to the platform collector."""

from fastapi import FastAPI
from opentelemetry import metrics, trace
from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

from app.config import Settings

_EXCLUDED = "health/live,health/ready,health/startup,metrics"


def _exporters(settings: Settings):
    if settings.otel_exporter_otlp_protocol.startswith("http"):
        from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

        # HTTP exporters read OTEL_EXPORTER_OTLP_ENDPOINT and append /v1/<signal> themselves.
        return OTLPSpanExporter(), OTLPMetricExporter()
    from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

    return OTLPSpanExporter(endpoint=settings.otel_exporter_otlp_endpoint), OTLPMetricExporter(
        endpoint=settings.otel_exporter_otlp_endpoint
    )


def setup_telemetry(app: FastAPI, settings: Settings) -> TracerProvider | None:
    """Called once per gunicorn worker (no preload), so each process owns its exporters.

    OTEL_RESOURCE_ATTRIBUTES (set by the chart) is merged automatically by Resource.create().
    """
    if not settings.otel_exporter_otlp_endpoint:
        FastAPIInstrumentor.instrument_app(app, excluded_urls=_EXCLUDED)
        return None

    resource = Resource.create(
        {
            "service.name": settings.service_name,
            "service.version": settings.app_version,
            "deployment.environment.name": settings.environment,
            "tenant.id": settings.tenant_id,
        }
    )
    span_exporter, metric_exporter = _exporters(settings)
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(BatchSpanProcessor(span_exporter))
    trace.set_tracer_provider(tracer_provider)
    metrics.set_meter_provider(
        MeterProvider(
            resource=resource,
            metric_readers=[PeriodicExportingMetricReader(metric_exporter, export_interval_millis=30_000)],
        )
    )

    FastAPIInstrumentor.instrument_app(app, excluded_urls=_EXCLUDED, tracer_provider=tracer_provider)
    AsyncPGInstrumentor().instrument(tracer_provider=tracer_provider)
    RedisInstrumentor().instrument(tracer_provider=tracer_provider)
    HTTPXClientInstrumentor().instrument(tracer_provider=tracer_provider)
    return tracer_provider


def shutdown_telemetry(provider: TracerProvider | None) -> None:
    if provider is not None:
        provider.shutdown()  # flush pending spans before the worker exits
    meter_provider = metrics.get_meter_provider()
    if isinstance(meter_provider, MeterProvider):
        meter_provider.shutdown()
