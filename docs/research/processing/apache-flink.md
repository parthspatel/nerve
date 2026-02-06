# Apache Flink

> Stateful stream processing framework for real-time clinical data parsing

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Apache Flink |
| **Website** | [flink.apache.org](https://flink.apache.org) |
| **GitHub** | [apache/flink](https://github.com/apache/flink) (~24K stars) |
| **Latest Version** | Flink 1.20.x (2025), K8s Operator v1.13.0 |
| **License** | Apache 2.0 |
| **Language** | Java/Scala (JVM-based) |
| **ASF Status** | Apache Top-Level Project |
| **Nerve Role** | Real-time HL7 v2.x parsing, validation, enrichment, and routing with exactly-once semantics |

---

## What Is It?

Apache Flink is a distributed stream processing framework designed for stateful computations over unbounded (streaming) and bounded (batch) data. It processes data with true event-time semantics, exactly-once state consistency, and sub-second latency.

In Nerve, Flink is the **core processing engine** that sits between Kafka and the storage layers. It parses raw HL7 messages using HAPI HL7v2, validates them, enriches with metadata, and routes to typed Kafka topics.

---

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│                    Flink on Kubernetes                      │
│                                                            │
│  ┌────────────────────┐                                   │
│  │   JobManager       │  Coordinates execution             │
│  │   (1 pod, HA)      │  Triggers checkpoints              │
│  │                    │  Manages job graph                  │
│  └────────┬───────────┘                                   │
│           │ distributes work                               │
│  ┌────────▼───────────────────────────────────────────┐   │
│  │              TaskManagers (4-32 pods)                │   │
│  │                                                      │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           Flink Job Graph                    │    │   │
│  │  │                                              │    │   │
│  │  │  [KafkaSource]                              │    │   │
│  │  │       │                                      │    │   │
│  │  │  [MLLP Frame Decoder]                       │    │   │
│  │  │       │                                      │    │   │
│  │  │  [HAPI HL7 Parser]  ◄── PipeParser          │    │   │
│  │  │       │                  GenericMessage      │    │   │
│  │  │       │                  ADT_A01, ORU_R01    │    │   │
│  │  │  [Validator]                                 │    │   │
│  │  │       │                                      │    │   │
│  │  │  [Enrichment]  ◄── source_system,            │    │   │
│  │  │       │             facility_id,              │    │   │
│  │  │       │             ingestion_ts              │    │   │
│  │  │  [Router]  ── by MSH-9 message type          │    │   │
│  │  │    │  │  │                                   │    │   │
│  │  │  [KafkaSink: adt] [oru] [orm] [dft] [dlq]   │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                      │   │
│  │  State Backend: RocksDB (keyed by patient MRN)      │   │
│  │  Checkpoints: Every 60s → MinIO/S3                  │   │
│  └──────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────┘
```

### Key Components

- **JobManager**: Coordinates distributed execution, triggers checkpoints, manages job lifecycle. Runs as a K8s Deployment with HA via leader election.
- **TaskManagers**: Execute the actual data processing tasks. Each TaskManager has multiple task slots (typically 1-4 per pod). KEDA scales TaskManagers from 4 to 32 based on backpressure and consumer lag.
- **RocksDB State Backend**: Embedded key-value store for stateful operations (keyed by patient MRN). Supports state larger than available memory via spillover to disk.
- **Checkpoints**: Periodic distributed snapshots (every 60s) persisted to MinIO/S3. Enables exactly-once recovery — if a TaskManager fails, the job restarts from the last checkpoint.

---

## Performance Benchmarks

| Metric | Value | Notes |
|--------|-------|-------|
| **Event latency** | Sub-second (10-100ms typical) | True event-at-a-time processing |
| **Throughput** | Millions of events/sec per cluster | Scales with TaskManagers |
| **Exactly-once overhead** | < 5% throughput reduction | Async checkpointing |
| **Checkpoint duration** | 100ms-10s (depends on state size) | Async, non-blocking |
| **Recovery time** | 1-30s from checkpoint | Depends on state size |
| **State size** | Up to TBs per key group | RocksDB incremental checkpoints |

### Flink vs. Alternatives

| Feature | Apache Flink | Kafka Streams | Spark Structured Streaming |
|---------|-------------|---------------|---------------------------|
| **Processing Model** | True streaming (event-at-a-time) | True streaming (library) | Micro-batch (100ms+ default) |
| **Latency** | 10-100ms | 10-100ms | 100ms-seconds |
| **Exactly-Once** | Distributed snapshots | Kafka transactions | Checkpoint + WAL |
| **Stateful Processing** | RocksDB, large state | In-memory / RocksDB | In-memory |
| **Parallelism** | Independent of Kafka partitions | Capped at partition count | Independent |
| **CEP / Windowing** | Advanced (CEP library, session windows) | Basic | Watermark-based |
| **HAPI HL7v2 Integration** | Native (JVM) | Native (JVM library) | Possible but awkward |
| **K8s Deployment** | Flink K8s Operator (ASF) | Just a library (no cluster) | Kubeflow Spark Operator |
| **Operational Complexity** | Medium (operator manages) | Low (embedded in app) | High (driver + executors) |

**Why Flink for Nerve**: Flink's independent parallelism (not capped at partition count), advanced CEP for cross-message HL7 correlation, and mature K8s operator make it the right choice. Kafka Streams was considered but its partition-capped parallelism limits scaling.

---

## HAPI HL7v2 Integration

Flink's JVM runtime enables direct use of the HAPI HL7v2 library:

```java
// Within Flink ProcessFunction
public class HL7ParserFunction extends ProcessFunction<String, ParsedHL7Message> {
    private transient PipeParser parser;

    @Override
    public void open(Configuration parameters) {
        parser = new PipeParser();
        parser.getParserConfiguration()
              .setValidating(false); // Parse even non-conformant messages
    }

    @Override
    public void processElement(String rawHL7, Context ctx, Collector<ParsedHL7Message> out) {
        try {
            Message msg = parser.parse(rawHL7);
            MSH msh = (MSH) msg.get("MSH");

            String messageType = msh.getMessageType().getMessageCode().getValue();
            String triggerEvent = msh.getMessageType().getTriggerEvent().getValue();
            String version = msh.getVersionID().getVersionID().getValue();

            ParsedHL7Message parsed = new ParsedHL7Message();
            parsed.setMessageType(messageType + "^" + triggerEvent);
            parsed.setVersion(version);

            // Extract segments based on message type
            switch (messageType) {
                case "ADT" -> extractADT(msg, parsed);
                case "ORU" -> extractORU(msg, parsed);
                case "ORM" -> extractORM(msg, parsed);
                case "DFT" -> extractDFT(msg, parsed);
                case "MDM" -> extractMDM(msg, parsed);
            }

            out.collect(parsed);
        } catch (Exception e) {
            // Route to DLQ via side output
            ctx.output(dlqTag, new DLQRecord(rawHL7, e.getMessage()));
        }
    }
}
```

---

## Flink Kubernetes Operator

**Repository**: [apache/flink-kubernetes-operator](https://github.com/apache/flink-kubernetes-operator)

The operator manages Flink jobs as K8s custom resources:

```yaml
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: nerve-hl7-parser
  namespace: clinical-processing
spec:
  image: nerve/flink-hl7-parser:latest
  flinkVersion: v1_20
  flinkConfiguration:
    taskmanager.numberOfTaskSlots: "2"
    state.backend: rocksdb
    state.checkpoints.dir: s3://nerve-checkpoints/hl7-parser
    execution.checkpointing.interval: "60000"
    execution.checkpointing.mode: EXACTLY_ONCE
    restart-strategy.type: exponential-delay
  serviceAccount: flink
  jobManager:
    resource:
      memory: "2048m"
      cpu: 1
  taskManager:
    resource:
      memory: "4096m"
      cpu: 2
    replicas: 4  # KEDA scales 4-32
  job:
    jarURI: local:///opt/flink/usrlib/hl7-parser.jar
    entryClass: com.nerve.flink.HL7ParserJob
    parallelism: 8
    upgradeMode: savepoint
```

### Autoscaling with Flink Autoscaler

The Flink K8s Operator includes a built-in autoscaler that adjusts parallelism based on:
- **Backpressure ratio**: How much time operators spend waiting for downstream
- **Source lag**: Kafka consumer lag (messages behind)
- **Busy time ratio**: CPU utilization of operators

```yaml
flinkConfiguration:
  job.autoscaler.enabled: "true"
  job.autoscaler.stabilization.interval: "1m"
  job.autoscaler.metrics.window: "5m"
  job.autoscaler.target.utilization: "0.7"
  job.autoscaler.scale-up.grace-period: "15s"
  job.autoscaler.scale-down.grace-period: "5m"
```

---

## Stateful Processing for Clinical Data

### Patient Event Correlation

Flink's keyed state (by patient MRN) enables cross-message correlation:

```
Patient MRN: 12345
──────────────────────────────────────────────────
t=0   ADT^A01 (Admission)     → State: { admitted: true, location: ICU }
t=5   ORM^O01 (Lab Order)     → State: { ..., pendingOrders: [CBC] }
t=30  ORU^R01 (Lab Result)    → Correlate with order, complete cycle
t=60  DFT^P03 (Charge)        → Link to encounter, RCM processing
```

### Event-Time Processing

HL7 messages can arrive out of order (network delays, system backlogs). Flink's watermark mechanism handles this:

```java
env.fromSource(kafkaSource, WatermarkStrategy
    .<String>forBoundedOutOfOrderness(Duration.ofMinutes(5))
    .withTimestampAssigner((msg, ts) -> extractHL7Timestamp(msg)),
    "hl7-source");
```

---

## How to Leverage in Nerve

1. **Real-Time HL7 Parsing**: Convert raw ER7 messages to structured data at sub-second latency
2. **Per-Patient State**: Maintain patient context across messages for clinical event correlation
3. **Dead Letter Queue**: Route unparseable messages to `hl7.dlq` without blocking the pipeline
4. **Multi-Sink Fan-Out**: Single Flink job writes to multiple Kafka topics based on message type
5. **Exactly-Once to Delta Lake**: Flink → Kafka → Spark pipeline ensures no duplicates in the lakehouse
6. **CEP for Clinical Alerts**: Detect patterns like "admission without lab order within 2 hours"
7. **Schema Validation**: Validate parsed messages against registered schemas before downstream delivery

---

## Visual References

- **Flink Architecture**: [flink.apache.org/what-is-flink/flink-architecture](https://nightlies.apache.org/flink/flink-docs-stable/docs/concepts/flink-architecture/) — Official architecture diagram
- **Flink K8s Operator**: [nightlies.apache.org/flink/flink-kubernetes-operator-docs-stable](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-stable/) — Operator documentation
- **Checkpoint Mechanism**: [flink.apache.org/docs/stable/concepts/stateful-stream-processing](https://nightlies.apache.org/flink/flink-docs-stable/docs/concepts/stateful-stream-processing/) — Distributed snapshots
- **AWS Healthcare + Flink**: AWS reference architecture for HL7 processing with Flink

---

## Key Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| TaskManager OOM on large HL7 messages | RocksDB state backend with disk spillover |
| Checkpoint failures under high load | Async checkpointing, incremental checkpoints |
| HAPI parser exceptions on malformed HL7 | Try-catch with DLQ side output, no pipeline halt |
| Job upgrade requires restart | Savepoint-based upgrades preserve state |
| Kafka consumer lag growing | Flink Autoscaler scales TaskManagers in 15s |
