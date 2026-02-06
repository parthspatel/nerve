# Nerve Tool Stack — Research Directory

> Comprehensive research on every tool in the Nerve clinical data platform architecture.

---

## Quick Navigation

### Summary Documents

| Document | Description |
|----------|-------------|
| [Executive Summary](./EXECUTIVE-SUMMARY.md) | Strategic overview, risk assessment, cost model, implementation priority |
| [Technical Review](./TECHNICAL-REVIEW.md) | Deep technical analysis of trade-offs, failure modes, production readiness |

---

### Ingestion Layer

| Tool | File | Purpose |
|------|------|---------|
| Apache Kafka + Strimzi | [ingestion/apache-kafka-strimzi.md](./ingestion/apache-kafka-strimzi.md) | Durable message streaming backbone |
| MLLP Protocol | [ingestion/mllp-protocol.md](./ingestion/mllp-protocol.md) | TCP transport for HL7 v2.x |
| HL7 v2.x Standard | [ingestion/hl7v2-standard.md](./ingestion/hl7v2-standard.md) | Clinical messaging standard |
| FHIR R4 | [ingestion/fhir-r4.md](./ingestion/fhir-r4.md) | Modern REST-based healthcare API |

### Processing Layer

| Tool | File | Purpose |
|------|------|---------|
| Apache Flink | [processing/apache-flink.md](./processing/apache-flink.md) | Real-time stream processing |

### Transformation Layer

| Tool | File | Purpose |
|------|------|---------|
| SQLMesh | [transformation/sqlmesh.md](./transformation/sqlmesh.md) | SQL transformation engine (~9x faster than dbt) |
| Apache Hop | [transformation/apache-hop.md](./transformation/apache-hop.md) | Visual drag-and-drop pipeline IDE |

### Storage Layer

| Tool | File | Purpose |
|------|------|---------|
| Delta Lake | [storage/delta-lake.md](./storage/delta-lake.md) | Analytical lakehouse (Bronze/Silver/Gold) |
| MinIO | [storage/minio.md](./storage/minio.md) | S3-compatible object storage |
| Trino | [storage/trino.md](./storage/trino.md) | Interactive SQL analytics engine |
| PostgreSQL + CloudNativePG | [storage/postgresql-cloudnativepg.md](./storage/postgresql-cloudnativepg.md) | Operational database |
| OpenSearch | [storage/opensearch.md](./storage/opensearch.md) | Clinical document search + NLP |

### Master Patient Index

| Tool | File | Purpose |
|------|------|---------|
| HAPI FHIR MDM | [mpi/hapi-fhir-mdm.md](./mpi/hapi-fhir-mdm.md) | Real-time deterministic matching |
| Splink | [mpi/splink.md](./mpi/splink.md) | Batch probabilistic matching (200M+ proven) |

### Connectors

| Tool | File | Purpose |
|------|------|---------|
| Orthanc | [connectors/orthanc-dicom.md](./connectors/orthanc-dicom.md) | DICOM proxy for medical imaging |

### Platform Infrastructure

| Tool | File | Purpose |
|------|------|---------|
| ArgoCD + Argo Rollouts | [platform/argocd.md](./platform/argocd.md) | GitOps deployment + canary releases |
| KEDA | [platform/keda.md](./platform/keda.md) | Event-driven autoscaling |
| Linkerd | [platform/linkerd.md](./platform/linkerd.md) | mTLS service mesh |
| HashiCorp Vault | [platform/hashicorp-vault.md](./platform/hashicorp-vault.md) | Secret management |

### Observability

| Tool | File | Purpose |
|------|------|---------|
| Full Stack (Prometheus/Grafana/Loki/Tempo/OTel) | [observability/observability-stack.md](./observability/observability-stack.md) | Metrics, logs, traces, dashboards |

---

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────┐
│                                                              │
│   INGESTION         STREAMING       PROCESSING               │
│   ──────────        ─────────       ──────────               │
│   Go MLLP ────────▶ Kafka ────────▶ Flink                   │
│   FHIR Poller ────▶ (Strimzi)      + HAPI HL7v2             │
│   Orthanc ────────▶                                          │
│                                                              │
│   STORAGE                           SERVING                  │
│   ───────                           ───────                  │
│   Delta Lake (MinIO) ◄──────────── Trino (SQL Analytics)    │
│   PostgreSQL (CNPG)  ◄──────────── HAPI FHIR (MPI)         │
│   OpenSearch         ◄──────────── Apache Hop (Visual ETL)  │
│                                     SQLMesh (SQL Transforms) │
│                                                              │
│   PLATFORM                                                   │
│   ────────                                                   │
│   ArgoCD │ KEDA │ Linkerd │ Vault │ Prometheus/Grafana      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Research Methodology

Each tool research file includes:

1. **Overview table** — Project, website, GitHub, version, license, Nerve role
2. **Architecture diagram** — ASCII art showing component relationships
3. **Performance benchmarks** — Throughput, latency, scale numbers
4. **Nerve-specific configuration** — How the tool is configured for clinical data
5. **Comparison with alternatives** — Why this tool was selected over others
6. **How to leverage** — Specific use cases within the Nerve architecture
7. **Visual references** — Links to official documentation, screenshots, diagrams
8. **Risk assessment** — Known risks and mitigation strategies
