# KEDA — Kubernetes Event-Driven Autoscaling

> Scale workloads based on event sources like Kafka consumer lag

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | KEDA (Kubernetes Event-Driven Autoscaling) |
| **Website** | [keda.sh](https://keda.sh) |
| **GitHub** | [kedacore/keda](https://github.com/kedacore/keda) (~8.5K stars) |
| **Latest Version** | KEDA 2.16+ (2025) |
| **License** | Apache 2.0 |
| **CNCF Status** | CNCF Graduated project |
| **Nerve Role** | Event-driven autoscaling for all stream processing, ingestion, and query workloads |

---

## What Is It?

KEDA extends Kubernetes with event-driven autoscaling. While the standard Horizontal Pod Autoscaler (HPA) scales based on CPU/memory, KEDA scales based on **event sources** — Kafka consumer lag, Prometheus metrics, queue depth, cron schedules, and 60+ other scalers.

In Nerve, KEDA is the **cornerstone scaling mechanism** that ties autoscaling to actual clinical message load rather than proxy metrics like CPU usage.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      KEDA on K8s                           │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │              KEDA Operator                         │    │
│  │                                                    │    │
│  │  Watches: ScaledObject, ScaledJob CRDs            │    │
│  │  Manages: HPA creation/deletion                    │    │
│  │  Polls: External metrics (Kafka, Prometheus)       │    │
│  └──────────┬───────────────────────────────────────┘    │
│             │                                             │
│  ┌──────────▼───────────────────────────────────────┐    │
│  │          ScaledObject Definitions                  │    │
│  │                                                    │    │
│  │  ┌─────────────────────────────────────────────┐  │    │
│  │  │ MLLP Listeners                               │  │    │
│  │  │ Scaler: Prometheus                           │  │    │
│  │  │ Metric: mllp_messages_received_total rate    │  │    │
│  │  │ Min: 2 → Max: 16                            │  │    │
│  │  └─────────────────────────────────────────────┘  │    │
│  │                                                    │    │
│  │  ┌─────────────────────────────────────────────┐  │    │
│  │  │ Kafka Consumers (Flink/Spark)                │  │    │
│  │  │ Scaler: Kafka                                │  │    │
│  │  │ Metric: Consumer group lag                   │  │    │
│  │  │ Min: 2 → Max: partition count                │  │    │
│  │  └─────────────────────────────────────────────┘  │    │
│  │                                                    │    │
│  │  ┌─────────────────────────────────────────────┐  │    │
│  │  │ Trino Workers                                │  │    │
│  │  │ Scaler: Prometheus                           │  │    │
│  │  │ Metric: trino_queued_queries                 │  │    │
│  │  │ Min: 2 → Max: 20                            │  │    │
│  │  └─────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

---

## Nerve Scaling Configuration

### MLLP Listener Scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: mllp-listener-scaler
  namespace: clinical-ingestion
spec:
  scaleTargetRef:
    name: mllp-listener
  pollingInterval: 15
  cooldownPeriod: 300          # 5 min cooldown after scale-down
  minReplicaCount: 2           # HA minimum
  maxReplicaCount: 16          # Burst ceiling
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus.platform-observability:9090
        metricName: mllp_msg_rate
        query: sum(rate(mllp_messages_received_total[1m]))
        threshold: "5000"      # Scale per 5K msg/sec
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0   # Immediate scale-up
          policies:
            - type: Pods
              value: 4
              periodSeconds: 15
        scaleDown:
          stabilizationWindowSeconds: 300  # Wait 5 min before scale-down
```

### Kafka Consumer Scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: flink-consumer-scaler
  namespace: clinical-processing
spec:
  scaleTargetRef:
    name: flink-taskmanager
  pollingInterval: 15
  minReplicaCount: 4
  maxReplicaCount: 32
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: nerve-kafka-bootstrap.platform-kafka:9092
        consumerGroup: nerve-hl7-parser
        topic: hl7.raw.ingest
        lagThreshold: "1000"   # Scale per 1K message lag
```

---

## Scaling Scenarios

### 2M Message Burst

```
t=0    Normal load: 1K msg/sec
       MLLP: 2 pods, Flink: 4 TaskManagers

t=1    Burst begins: 50K msg/sec
       KEDA detects: mllp_msg_rate > 5K threshold
       → MLLP: scales to 10 pods (immediate, no stabilization window)

t=2    Kafka lag grows: 100K messages behind
       KEDA detects: consumer lag > 1K threshold
       → Flink: scales from 4 to 16 TaskManagers

t=5    Burst peak: 200K msg/sec
       → MLLP: scales to 16 pods (max)
       → Flink: scales to 32 TaskManagers (max)
       → Kafka buffers excess (durable)

t=30   Burst subsides: back to 1K msg/sec
       KEDA cooldown: 5 min wait before scale-down
       → Flink: catches up on lag, then scales down
       → MLLP: scales back to 2 pods

Total: All 2M messages processed. Zero data loss.
       Pipeline absorbed burst via Kafka buffering + KEDA scaling.
```

---

## Available Scalers (60+)

| Category | Scalers | Nerve Use |
|----------|---------|-----------|
| **Messaging** | Kafka, RabbitMQ, NATS, Redis Streams | Kafka consumer lag |
| **Metrics** | Prometheus, Datadog, New Relic | MLLP rate, Trino queue |
| **Database** | PostgreSQL, MySQL, MongoDB | Pending jobs |
| **HTTP** | HTTP request count | API load |
| **Cron** | Cron schedule | Scheduled batch jobs |
| **Custom** | External scaler gRPC API | Custom clinical metrics |

---

## How to Leverage in Nerve

1. **Kafka-Driven Scaling**: Flink TaskManagers scale based on consumer lag, not CPU
2. **Prometheus-Driven Scaling**: MLLP pods scale based on actual message rate
3. **Zero-to-N Scaling**: ScaledJobs can scale batch jobs (Splink) from 0 to N on trigger
4. **Burst Absorption**: Immediate scale-up (0s stabilization) for clinical data bursts
5. **Cost Optimization**: Scale down during low-traffic periods (nights, weekends)
6. **Trino Elasticity**: Query workers scale with queue depth during peak analytics hours

---

## Visual References

- **KEDA Architecture**: [keda.sh/docs/2.16/concepts](https://keda.sh/docs/2.16/concepts/) — Architecture diagram
- **Scalers Reference**: [keda.sh/docs/2.16/scalers](https://keda.sh/docs/2.16/scalers/) — All 60+ scalers
- **ScaledObject Spec**: [keda.sh/docs/2.16/concepts/scaling-deployments](https://keda.sh/docs/2.16/concepts/scaling-deployments/)
