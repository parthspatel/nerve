# Apache Kafka with Strimzi Operator

> Distributed event streaming platform with Kubernetes-native operator management

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Apache Kafka |
| **Operator** | Strimzi |
| **Website** | [kafka.apache.org](https://kafka.apache.org) / [strimzi.io](https://strimzi.io) |
| **GitHub** | [apache/kafka](https://github.com/apache/kafka) (~28K stars) / [strimzi/strimzi-kafka-operator](https://github.com/strimzi/strimzi-kafka-operator) (~4.8K stars) |
| **Latest Version** | Kafka 3.8.x / Strimzi 0.44+ |
| **License** | Apache 2.0 |
| **CNCF Status** | Strimzi: CNCF Incubating project |
| **Nerve Role** | Durable message streaming backbone — central nervous system connecting all layers |

---

## What Is It?

Apache Kafka is a distributed event streaming platform originally developed at LinkedIn, designed for high-throughput, fault-tolerant, real-time data pipelines. It serves as a durable, ordered, replayable log of records organized into topics and partitions.

**Strimzi** is the Kubernetes-native operator for Apache Kafka that provides:
- Custom Resource Definitions (CRDs) for Kafka clusters, topics, users, connectors, and mirrors
- Automated rolling upgrades with zero downtime
- Declarative TLS/mTLS and OAuth 2.0 authentication
- Cruise Control integration for automatic partition rebalancing
- KRaft mode (no ZooKeeper from Strimzi 0.46+)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                     │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │            Strimzi Kafka Operator                  │   │
│  │   Watches: Kafka, KafkaTopic, KafkaUser,         │   │
│  │            KafkaConnect, KafkaMirrorMaker2        │   │
│  └──────────┬───────────────────────────────────────┘   │
│             │ manages                                    │
│  ┌──────────▼───────────────────────────────────────┐   │
│  │           Kafka Cluster (KRaft mode)              │   │
│  │                                                    │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐          │   │
│  │  │Broker-0 │  │Broker-1 │  │Broker-2 │  (3+ )   │   │
│  │  │Controller│  │Controller│  │Controller│          │   │
│  │  │+ Broker  │  │+ Broker  │  │+ Broker  │          │   │
│  │  └─────────┘  └─────────┘  └─────────┘          │   │
│  │                                                    │   │
│  │  Topics: hl7.raw.ingest (32-48 partitions)        │   │
│  │          hl7.parsed.adt (24 partitions)            │   │
│  │          hl7.parsed.oru (24 partitions)            │   │
│  │          hl7.dlq (8 partitions)                    │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐                     │
│  │  Producers   │  │  Consumers   │                     │
│  │  (Go MLLP)   │  │  (Flink)     │                     │
│  └──────────────┘  └──────────────┘                     │
└─────────────────────────────────────────────────────────┘
```

### Key Architectural Concepts

- **Topics**: Named channels for message streams. Each HL7 message type gets its own topic.
- **Partitions**: Parallel units within a topic. Patient MRN hash as partition key ensures per-patient ordering.
- **Consumer Groups**: Independent consumers reading from the same topics. Flink, Spark, and OpenSearch each have their own consumer group.
- **KRaft Mode**: Kafka's Raft-based consensus replacing ZooKeeper. Reduces operational complexity and improves startup time.
- **Exactly-Once Semantics (EOS)**: Idempotent producers + transactional APIs ensure no duplicates or data loss.

---

## Performance Benchmarks

| Metric | Value | Source |
|--------|-------|--------|
| Peak throughput (3 nodes) | **2M+ writes/second** | LinkedIn benchmark |
| Throughput per broker | ~800K-1M msg/sec | Production benchmarks |
| P99 latency | 15-25ms | Under load |
| P50 latency | 2-5ms | Typical |
| Storage efficiency | ~1 byte overhead per message | Log-structured |
| Replication (3x) | ~50% throughput reduction | Expected |
| Consumer throughput | Matches producer at scale | Partition-parallel |

### Kafka vs. Alternatives

| Feature | Apache Kafka | Redpanda | Apache Pulsar |
|---------|-------------|----------|---------------|
| **Throughput** | 2M+ msg/sec (3 nodes) | ~1.5M msg/sec (claimed higher) | ~1M msg/sec |
| **P99 Latency** | 15-25ms | 8-15ms | 20-40ms |
| **License** | Apache 2.0 | BSL (not OSS) | Apache 2.0 |
| **K8s Operator** | Strimzi (CNCF Incubating) | Redpanda Operator | StreamNative Operator |
| **Ecosystem** | Largest (Flink, Spark, Connect) | Growing | Smaller |
| **Healthcare Adoption** | Extensive | Limited | Limited |
| **Operational Complexity** | Medium (KRaft simplifies) | Low (single binary) | High (Brokers+BookKeeper+ZK) |
| **Multi-tenancy** | Topic-level | Topic-level | Native namespace-level |
| **Job postings** | ~4,300 | ~200 | ~23 |

**Verdict**: Kafka wins on throughput proof, ecosystem maturity, healthcare adoption, and true open-source licensing. Redpanda's BSL is a risk for regulated healthcare organizations.

---

## Nerve-Specific Configuration

### Topic and Partitioning Strategy

```yaml
# Strimzi KafkaTopic CRD example
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: hl7.raw.ingest
  labels:
    strimzi.io/cluster: nerve-kafka
spec:
  partitions: 48
  replicas: 3
  config:
    retention.ms: 604800000       # 7 days
    cleanup.policy: delete
    min.insync.replicas: 2
    compression.type: lz4
    max.message.bytes: 1048576    # 1 MB (HL7 messages)
```

### Partitioning Keys

| Topic | Key | Purpose |
|-------|-----|---------|
| `hl7.raw.ingest` | `facility_id + sending_app` | Per-source ordering |
| `hl7.parsed.adt` | `patient_mrn_hash` | Per-patient ordering (critical for ADT sequences) |
| `hl7.parsed.orm` | `patient_mrn_hash` | Per-patient ordering for orders |
| `hl7.parsed.oru` | `patient_mrn_hash` | Per-patient ordering for results |
| `hl7.parsed.dft` | `encounter_id` | Per-encounter ordering for charges |
| `hl7.dlq` | Original key | Preserve original ordering for replay |

### Exactly-Once Semantics

```properties
# Producer configuration (Go MLLP listener)
enable.idempotence=true          # PID + sequence dedup (negligible overhead)
acks=all                         # Wait for all ISR replicas
max.in.flight.requests.per.connection=5  # Safe with idempotence

# Consumer configuration (Flink)
isolation.level=read_committed   # Only see committed transactions
auto.offset.reset=earliest       # Process all messages on new consumer
```

---

## Kubernetes Deployment Pattern

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: nerve-kafka
  namespace: platform-kafka
spec:
  kafka:
    version: 3.8.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
      inter.broker.protocol.version: "3.8"
    storage:
      type: jbod
      volumes:
        - id: 0
          type: persistent-claim
          size: 500Gi
          class: fast-ssd
    resources:
      requests:
        memory: 8Gi
        cpu: "2"
      limits:
        memory: 12Gi
        cpu: "4"
    jvmOptions:
      -Xms: 4096m
      -Xmx: 4096m
  cruiseControl:
    brokerCapacity:
      disk: 500Gi
```

---

## How to Leverage in Nerve

1. **Ingestion Buffering**: Kafka absorbs burst loads from MLLP listeners, decoupling ingestion speed from processing speed. During a 2M-message burst, Kafka buffers while Flink scales up.
2. **Fan-Out to Multiple Consumers**: One raw topic feeds Flink (parsing), Spark (Delta writes), and OpenSearch (indexing) independently through separate consumer groups.
3. **Dead Letter Queue**: Failed messages route to `hl7.dlq` with original headers preserved for debugging and replay.
4. **Schema Evolution**: Apicurio Registry enforces FULL compatibility on parsed topics, ensuring schema changes don't break downstream consumers.
5. **Cross-Facility Isolation**: `facility_id` in the partition key ensures messages from different facilities land on different partitions, enabling facility-specific consumer scaling.
6. **Audit Trail**: Kafka's immutable log provides a 7-day replay window for re-processing and audit purposes.

---

## Healthcare Adoption

- **Epic Systems**: Documented HL7 integration patterns with Kafka for message routing
- **Cerner/Oracle Health**: Kafka-based clinical event streaming
- **Intermountain Healthcare**: Real-time clinical data pipelines on Kafka
- **CMS (Centers for Medicare & Medicaid Services)**: Claims processing pipelines
- **Multiple Health Information Exchanges (HIEs)**: Kafka as the backbone for cross-organization data sharing

---

## Visual References

- **Strimzi Architecture**: [strimzi.io/docs/operators/latest/overview](https://strimzi.io/docs/operators/latest/overview) — Operator overview diagram
- **Kafka Architecture**: [kafka.apache.org/documentation/#design](https://kafka.apache.org/documentation/#design) — Core design documentation
- **KRaft Architecture**: [kafka.apache.org/documentation/#kraft](https://kafka.apache.org/documentation/#kraft) — ZooKeeper-free consensus

---

## Key Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Broker failure during clinical load | 3-replica ISR with `min.insync.replicas=2` |
| Partition hotspots (one facility dominates) | Hash-based partitioning distributes load |
| Consumer lag growing | KEDA scales Flink TaskManagers on lag metric |
| Schema breaking change | Apicurio FULL compatibility mode rejects incompatible changes |
| Storage exhaustion | Retention policies + Cruise Control rebalancing |
