# Nerve Tool Stack — Executive Summary

> A comprehensive evaluation of the 20+ open-source components powering the Nerve clinical data platform.

---

## Strategic Overview

Nerve is a **Kubernetes-native clinical data integration and Revenue Cycle Management (RCM) platform** designed to unify healthcare data from multiple source systems (Epic EHR, OnBase documents, PACS imaging) into a single queryable source of truth — in real-time.

The architecture processes **2M+ HL7 messages with sub-second ACK latency** using a five-layer design:

```
Ingestion → Streaming → Processing → Storage → Serving
```

Every component in the stack is **100% open-source** (Apache 2.0, MIT, or AGPL licensed), eliminating vendor lock-in and per-message pricing.

---

## Tool Stack at a Glance

### Tier 1: Core Data Pipeline

| Tool | Layer | Purpose | Maturity | Risk Level |
|------|-------|---------|----------|------------|
| **Go MLLP Service** | Ingestion | HL7 v2.x TCP listener | High (Google ref impl) | Low |
| **Apache Kafka (Strimzi)** | Streaming | Durable message backbone | Very High (CNCF) | Low |
| **Apache Flink** | Processing | Real-time HL7 parsing | Very High (ASF TLP) | Low |
| **HAPI HL7v2** | Processing | HL7 message parsing library | Very High (gold standard) | Very Low |
| **Delta Lake** | Storage | Analytical lakehouse (Bronze/Silver/Gold) | Very High (LF project) | Low |
| **MinIO** | Storage | S3-compatible object storage | Very High (48K stars) | Low |
| **PostgreSQL (CloudNativePG)** | Storage | Operational database | Very High (CNCF Sandbox) | Low |

### Tier 2: Transformation & Analytics

| Tool | Layer | Purpose | Maturity | Risk Level |
|------|-------|---------|----------|------------|
| **SQLMesh** | Transformation | SQL transforms on Delta Lake (~9x faster than dbt) | Medium-High | Medium |
| **Apache Hop** | Transformation | Visual drag-and-drop pipeline IDE | High (ASF TLP) | Low-Medium |
| **Trino** | Serving | Interactive SQL analytics | Very High (10K stars) | Low |
| **OpenSearch** | Serving | Clinical document search + NLP | Very High (LF project) | Low |

### Tier 3: Master Patient Index

| Tool | Layer | Purpose | Maturity | Risk Level |
|------|-------|---------|----------|------------|
| **HAPI FHIR MDM** | MPI | Real-time deterministic matching | High | Low |
| **Splink** | MPI | Batch probabilistic matching | High (200M+ proven) | Low |

### Tier 4: Platform Infrastructure

| Tool | Layer | Purpose | Maturity | Risk Level |
|------|-------|---------|----------|------------|
| **ArgoCD** | Deployment | GitOps continuous delivery | Very High (CNCF Graduated) | Very Low |
| **KEDA** | Scaling | Event-driven autoscaling | Very High (CNCF Graduated) | Very Low |
| **Linkerd** | Networking | mTLS service mesh | Very High (CNCF Graduated) | Low |
| **HashiCorp Vault** | Security | Secret management | Very High (31K stars) | Low |
| **Prometheus + Grafana** | Observability | Metrics, dashboards | Very High (CNCF) | Very Low |
| **Grafana Loki + Tempo** | Observability | Logs, traces | High | Low |
| **OpenTelemetry** | Observability | Telemetry collection | Very High (CNCF) | Very Low |

### Tier 5: Connectors

| Tool | Layer | Purpose | Maturity | Risk Level |
|------|-------|---------|----------|------------|
| **Orthanc** | Connector | DICOM proxy for PACS | High (1M+ Docker pulls) | Low |
| **Apicurio Registry** | Schema | Kafka schema management | Medium-High | Low-Medium |

---

## Key Architectural Decisions

### 1. Go MLLP over Rust/Java

**Decision**: Custom Go service modeled on Google's `GoogleCloudPlatform/mllp` adapter.

**Rationale**: Go's goroutine-per-connection model maps naturally to MLLP's long-lived TCP connections. 10K-50K msg/sec per pod with 20-50 MB containers. Rust's HL7 ecosystem is nascent. Java (Mirth Connect) doesn't scale horizontally on K8s.

**Impact**: Enables 2M+ message throughput at 40-200 pods with sub-5ms ACK latency.

### 2. Flink + Spark Dual-Engine Pattern

**Decision**: Flink for real-time stream parsing, Spark for Delta Lake writes.

**Rationale**: The Flink/Delta connector remains in preview (v0.7.0). Rather than risk production stability, the architecture uses each engine at its strength: Flink for sub-second event-at-a-time parsing, Spark for proven Delta Lake MERGE operations.

**Impact**: Exactly-once semantics end-to-end without depending on preview software.

### 3. HAPI FHIR MDM + Splink Hybrid MPI

**Decision**: Real-time deterministic matching (HAPI) + batch probabilistic matching (Splink).

**Rationale**: No single tool handles both operational speed and analytical accuracy. HAPI provides instant matching for clinical workflows. Splink provides deep probabilistic deduplication at 200M+ record scale, proven at the US Defense Health Agency.

**Impact**: Comprehensive patient unification across facilities — real-time for clinical use, batch for analytics.

### 4. SQLMesh over dbt-core

**Decision**: SQLMesh for SQL transformation management on Delta Lake.

**Rationale**: ~9x faster execution through incremental state tracking. Virtual environments for instant isolated development. Automatic breaking-change detection. Same SQL skills, better tooling.

**Impact**: Faster development cycles and production runs for the transformation pipeline.

### 5. Linkerd over Istio

**Decision**: Linkerd for service mesh with mTLS.

**Rationale**: 40-400% less latency than Istio at P99. Zero-config mTLS achieved at installation. Rust-based proxy with minimal resource footprint. HIPAA encryption-in-transit satisfied without application changes.

**Impact**: HIPAA compliance with minimal performance overhead in a latency-sensitive clinical pipeline.

---

## Risk Assessment

### Low Risk (Proven, widely adopted)
- Apache Kafka, Apache Flink, PostgreSQL, Prometheus/Grafana, ArgoCD, KEDA, Linkerd

### Medium Risk (Growing but less mature)
- **SQLMesh**: Smaller community than dbt (~2K vs ~10K stars). Mitigated by Apache 2.0 license, active development, and dbt compatibility mode for migration.
- **Apicurio Registry**: Less ecosystem support than Confluent Registry. Mitigated by Red Hat backing and broader format support.

### Managed Risk (License considerations)
- **HashiCorp Vault**: MPL 2.0 community edition covers all needed features. Enterprise BSL features not required.
- **MinIO**: AGPLv3 server license. Network use triggers copyleft. No modifications to MinIO itself are planned, so AGPL obligations are limited to making the unmodified source available.
- **Grafana/Loki/Tempo**: AGPL v3. Same considerations as MinIO.

---

## Cost Model

All components are open-source with zero licensing fees. Costs are infrastructure-only:

| Resource | Minimum (Dev) | Production (20-hospital) |
|----------|--------------|------------------------|
| Kubernetes nodes | 3 nodes (8 CPU, 32 GB each) | 20-40 nodes (16 CPU, 64 GB each) |
| Storage (MinIO) | 1 TB | 50-200 TB |
| Network | Standard | High-throughput (10 Gbps+) |
| **Monthly estimate** | ~$500-1,500 (cloud) | ~$15,000-40,000 (cloud) |

Compare with commercial alternatives (Mirth Connect Enterprise, Rhapsody, InterSystems): $100K-500K+ annual licensing plus per-message fees.

---

## Implementation Priority

Based on the project roadmap, recommended implementation order:

| Phase | Components | Timeline |
|-------|-----------|----------|
| **Phase 1** | Go MLLP + Kafka (Strimzi) + Flink HL7 parser | Foundation |
| **Phase 2** | Delta Lake medallion + PostgreSQL + Flink sinks | Storage layer |
| **Phase 3** | HAPI FHIR MDM + MPI integration | Patient matching |
| **Phase 4** | SQLMesh Gold transforms + Trino | Analytics layer |
| **Phase 5** | Apache Hop + Mapping Studio UI | Clinical user tools |
| **Phase 6** | Epic FHIR poller + OnBase + Orthanc connectors | Secondary sources |
| **Phase 7** | Splink batch MPI + OpenSearch NLP | Advanced capabilities |
| **Phase 8** | Argo Rollouts + HIPAA validation suite | Production hardening |

---

## Conclusion

The Nerve tool stack is deliberately composed of **battle-tested open-source components** — 14 of the 20+ tools are CNCF Graduated/Incubating or Apache Top-Level Projects. The architecture avoids single points of failure, scales horizontally at every layer, and satisfies HIPAA requirements through Linkerd mTLS, Vault dynamic credentials, and immutable audit logging.

The primary execution risk is **integration complexity** — connecting 20+ components into a cohesive pipeline requires careful orchestration. This is mitigated by the GitOps-driven deployment model (ArgoCD), comprehensive observability (Prometheus/Grafana/Loki/Tempo), and the phased implementation approach.
