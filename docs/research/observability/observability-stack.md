# Observability Stack — Prometheus + Grafana + Loki + Tempo + OpenTelemetry

> Full-stack observability for clinical data pipelines

---

## Overview

| Component | Role | GitHub Stars | License |
|-----------|------|-------------|---------|
| **Prometheus** | Metrics collection and alerting | ~56K | Apache 2.0 |
| **Grafana** | Visualization and dashboards | ~65K | AGPL v3 |
| **Grafana Loki** | Log aggregation | ~24K | AGPL v3 |
| **Grafana Tempo** | Distributed tracing | ~4K | AGPL v3 |
| **OpenTelemetry** | Telemetry collection and routing | ~5K (collector) | Apache 2.0 |

**Nerve Role**: Complete observability across all 5 architecture layers — metrics, logs, and traces with cross-signal correlation for real-time clinical pipeline monitoring.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Observability Stack                         │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │    OpenTelemetry Collectors (DaemonSet + Deployment)    │    │
│  │                                                        │    │
│  │  DaemonSet: Collects logs from every node             │    │
│  │  Deployment: Receives metrics/traces from apps         │    │
│  │                                                        │    │
│  │  Enriches with: k8s.pod.name, service.name,           │    │
│  │                 facility_id, source_system             │    │
│  └────────┬──────────────┬──────────────┬────────────────┘    │
│           │              │              │                      │
│     ┌─────▼─────┐  ┌────▼────┐  ┌─────▼─────┐              │
│     │Prometheus  │  │  Loki   │  │  Tempo    │              │
│     │(metrics)   │  │ (logs)  │  │ (traces)  │              │
│     │            │  │         │  │           │              │
│     │ TSDB       │  │ Chunks  │  │ MinIO     │              │
│     │ (15d local)│  │→ MinIO  │  │ backend   │              │
│     │            │  │         │  │           │              │
│     └─────┬──────┘  └────┬────┘  └─────┬─────┘              │
│           │              │              │                      │
│     ┌─────▼──────────────▼──────────────▼─────┐              │
│     │              Grafana                      │              │
│     │                                           │              │
│     │  Dashboards:                              │              │
│     │  ├── HL7 Pipeline Overview                │              │
│     │  │   • Messages/sec per facility          │              │
│     │  │   • End-to-end latency heatmap         │              │
│     │  │   • Parse error rate                   │              │
│     │  │   • Kafka consumer lag                 │              │
│     │  │                                        │              │
│     │  ├── MLLP Ingestion                       │              │
│     │  │   • Active connections per source      │              │
│     │  │   • ACK latency P50/P99               │              │
│     │  │   • Messages received/sec              │              │
│     │  │                                        │              │
│     │  ├── Flink Processing                     │              │
│     │  │   • Records processed/sec              │              │
│     │  │   • Checkpoint duration                │              │
│     │  │   • Backpressure ratio                 │              │
│     │  │                                        │              │
│     │  ├── MPI Matching                         │              │
│     │  │   • Matches/sec                        │              │
│     │  │   • POSSIBLE_MATCH queue depth         │              │
│     │  │   • Golden record count                │              │
│     │  │                                        │              │
│     │  └── Infrastructure                       │              │
│     │      • Pod CPU/memory                     │              │
│     │      • Disk usage (MinIO, PG)             │              │
│     │      • Network traffic                    │              │
│     └───────────────────────────────────────────┘              │
│                                                               │
│  Alerting:                                                    │
│  ├── Parse error rate > 1%  → PagerDuty/Slack               │
│  ├── Consumer lag growing   → Auto-scale + alert             │
│  ├── Zero messages for 10m  → Pipeline down alert            │
│  ├── ACK latency P99 > 5ms → Performance degradation        │
│  └── Disk usage > 80%      → Capacity alert                 │
└──────────────────────────────────────────────────────────────┘
```

---

## Component Details

### Prometheus — Metrics

```yaml
# Example alert rules for clinical pipeline
groups:
  - name: nerve-pipeline
    rules:
      - alert: HL7ParseErrorRateHigh
        expr: |
          sum(rate(flink_hl7_parse_errors_total[5m])) /
          sum(rate(flink_hl7_messages_processed_total[5m])) > 0.01
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "HL7 parse error rate > 1% — possible format change from source"

      - alert: KafkaConsumerLagGrowing
        expr: |
          sum(kafka_consumer_group_lag{group="nerve-hl7-parser"}) > 10000
          and
          deriv(sum(kafka_consumer_group_lag{group="nerve-hl7-parser"})[10m:]) > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Kafka consumer lag growing — processing falling behind"

      - alert: NoMessagesReceived
        expr: |
          sum(rate(mllp_messages_received_total[10m])) == 0
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "No HL7 messages received for 10 minutes — pipeline may be down"
```

### Grafana Loki — Logs

Loki aggregates logs from all pods via the OTel Collector DaemonSet:
- **Structured logging**: JSON logs with `facility_id`, `message_type`, `patient_mrn_hash`
- **LogQL queries**: `{namespace="clinical-processing"} |= "parse error" | json | facility_id="FAC-001"`
- **Log-to-trace correlation**: Click from a log line to the distributed trace
- **Immutable storage**: Logs stored in MinIO with WORM for HIPAA 6-year retention

### Grafana Tempo — Distributed Traces

Traces follow a clinical message through the entire pipeline:

```
Trace: msg-12345 (total: 245ms)
├── mllp-listener (12ms)
│   ├── tcp_read (2ms)
│   ├── frame_decode (1ms)
│   ├── kafka_produce (8ms)
│   └── ack_send (1ms)
├── flink-hl7-parser (180ms)
│   ├── hapi_parse (45ms)
│   ├── validate (10ms)
│   ├── enrich (25ms)
│   └── kafka_produce (100ms)
├── spark-delta-writer (50ms)
│   └── delta_merge (50ms)
└── opensearch-indexer (3ms)
    └── index_document (3ms)
```

### OpenTelemetry Collector

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: nerve-otel
  namespace: platform-observability
spec:
  mode: daemonset  # Logs: one per node
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      filelog:
        include:
          - /var/log/pods/**/*.log

    processors:
      k8sattributes:
        extract:
          metadata:
            - k8s.pod.name
            - k8s.namespace.name
            - k8s.deployment.name
      attributes:
        actions:
          - key: facility_id
            from_attribute: k8s.pod.labels.facility_id
            action: insert

    exporters:
      prometheus:
        endpoint: 0.0.0.0:8889
      loki:
        endpoint: http://loki.platform-observability:3100/loki/api/v1/push
      otlp/tempo:
        endpoint: tempo.platform-observability:4317
        tls:
          insecure: true

    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [k8sattributes, attributes]
          exporters: [prometheus]
        logs:
          receivers: [filelog]
          processors: [k8sattributes, attributes]
          exporters: [loki]
        traces:
          receivers: [otlp]
          processors: [k8sattributes, attributes]
          exporters: [otlp/tempo]
```

---

## Clinical-Specific Dashboards

### HL7 Pipeline Overview Dashboard

| Panel | Metric | Visualization |
|-------|--------|--------------|
| Messages/sec by facility | `sum(rate(mllp_messages_received_total[1m])) by (facility_id)` | Time series |
| E2E latency heatmap | `histogram_quantile(0.99, ...)` | Heatmap |
| Parse error rate | `parse_errors / messages_total` | Stat + threshold |
| Kafka consumer lag | `kafka_consumer_group_lag` | Gauge |
| Active MLLP connections | `mllp_connections_active` | Stat |
| Flink checkpoint duration | `flink_checkpoint_duration_seconds` | Time series |
| MPI matches today | `increase(mpi_matches_total[24h])` | Stat |
| DLQ depth | `kafka_topic_messages{topic="hl7.dlq"}` | Gauge (alert) |

---

## How to Leverage in Nerve

1. **Pipeline Monitoring**: Real-time visibility into HL7 message flow across all 5 layers
2. **Clinical Alerting**: Alerts for parse errors, lag, pipeline down, latency degradation
3. **Distributed Tracing**: Follow a single clinical message from MLLP to Delta Lake
4. **HIPAA Audit Logs**: Immutable log storage in MinIO with 6-year retention
5. **Capacity Planning**: Historical metrics for scaling decisions
6. **Incident Response**: Cross-signal correlation (metrics → logs → traces) for rapid root cause analysis
7. **Compliance Dashboards**: Real-time HIPAA compliance status across all security controls

---

## Visual References

- **Grafana Dashboards**: [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards/) — Dashboard gallery
- **Prometheus Documentation**: [prometheus.io/docs](https://prometheus.io/docs/) — Metrics and alerting
- **Loki Documentation**: [grafana.com/docs/loki](https://grafana.com/docs/loki/latest/) — Log aggregation
- **Tempo Documentation**: [grafana.com/docs/tempo](https://grafana.com/docs/tempo/latest/) — Distributed tracing
- **OpenTelemetry**: [opentelemetry.io](https://opentelemetry.io) — Observability framework
