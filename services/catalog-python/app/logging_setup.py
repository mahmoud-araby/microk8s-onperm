"""JSON logging (structlog) with trace_id/span_id from OpenTelemetry and tenant_id/correlation_id from context."""

import logging
import logging.config
from typing import Any

import structlog
from opentelemetry import trace


def _add_otel_ids(_: Any, __: str, event_dict: dict[str, Any]) -> dict[str, Any]:
    ctx = trace.get_current_span().get_span_context()
    if ctx.is_valid:
        event_dict["trace_id"] = format(ctx.trace_id, "032x")
        event_dict["span_id"] = format(ctx.span_id, "016x")
    return event_dict


_shared_processors: list[Any] = [
    structlog.contextvars.merge_contextvars,  # tenant_id, correlation_id bound by the middleware
    structlog.stdlib.add_logger_name,
    structlog.stdlib.add_log_level,
    structlog.processors.TimeStamper(fmt="iso", utc=True, key="@timestamp"),
    _add_otel_ids,
]


def logging_config(level: str = "INFO") -> dict[str, Any]:
    """dictConfig shared by the app and gunicorn (logconfig_dict) so every log line is JSON."""
    return {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {
            "json": {
                "()": structlog.stdlib.ProcessorFormatter,
                "foreign_pre_chain": _shared_processors,
                "processors": [
                    structlog.stdlib.ProcessorFormatter.remove_processors_meta,
                    structlog.processors.format_exc_info,
                    structlog.processors.JSONRenderer(),
                ],
            }
        },
        "handlers": {"stdout": {"class": "logging.StreamHandler", "formatter": "json", "stream": "ext://sys.stdout"}},
        "root": {"handlers": ["stdout"], "level": level},
        "loggers": {
            "uvicorn.access": {"level": "WARNING"},  # access logs come from Istio/Kong
            "gunicorn.error": {"handlers": ["stdout"], "level": level, "propagate": False},
            "gunicorn.access": {"level": "WARNING"},
            "aiokafka": {"level": "WARNING"},
        },
    }


def configure_logging(level: str = "INFO", service: str = "catalog", version: str = "dev") -> None:
    logging.config.dictConfig(logging_config(level))
    structlog.configure(
        processors=[
            *_shared_processors,
            structlog.processors.StackInfoRenderer(),
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )
    structlog.contextvars.bind_contextvars(service=service, version=version)
