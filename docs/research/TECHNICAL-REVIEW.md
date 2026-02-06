# Nerve Tool Stack — Technical Review

> Deep technical analysis of architecture trade-offs, integration patterns, failure modes, and production readiness.

---

## 1. Data Pipeline: End-to-End Exactly-Once Analysis

### The Guarantee Chain

For clinical data, exactly-once processing is not optional — duplicate lab results or missed admission events directly impact patient care and billing accuracy.

```
Go MLLP           Kafka              Flink              Spark/Delta
──────────         ─────              ─────              ──────────
Idempotent    →   Idempotent    →   Distributed    →   Transactional
Kafka produce      producers         snapshots           Delta MERGE
(PID + seqno)     (acks=all)        (Chandy-Lamport)    (ACID commits)
```

**Analysis of each hop:**

1. **MLLP → Kafka**: Go producer uses `enable.idempotence=true` with `acks=all`. Kafka deduplicates via producer ID + sequence number. If the Go pod crashes after produce but before ACK, the sending system retries (MLLP behavior) → idempotent produce ensures no duplicate.

2. **Kafka → Flink**: Flink's Kafka connector uses exactly-once mode with distributed snapshots. Offsets are committed as part of the Flink checkpoint — if a TaskManager fails, it recovers from the last checkpoint and reprocesses from the committed offset. No duplicates, no data loss.

3. **Flink → Kafka (parsed topics)**: Flink's transactional Kafka producer ensures atomic produce-and-checkpoint. Either both the Kafka write and checkpoint succeed, or neither does.

4. **Kafka → Spark → Delta Lake**: Spark Structured Streaming with `trigger(availableNow=true)` or continuous processing reads from Kafka with checkpointed offsets. Delta Lake's ACID transactions ensure the write is atomic. If Spark fails mid-write, the transaction is rolled back and reprocessed from Kafka.

**Verdict**: End-to-end exactly-once is achievable. The weakest link is the Flink → Kafka → Spark handoff (two engines), but both independently guarantee exactly-once to Kafka. The alternative (Flink directly to Delta Lake) is not production-ready (connector in preview).

### Failure Modes and Recovery

| Failure Scenario | Detection | Recovery | Data Impact |
|-----------------|-----------|----------|-------------|
| MLLP pod crash | K8s restart + KEDA | New pod starts, sender reconnects | No loss (sender retries un-ACK'd) |
| Kafka broker failure | ISR replication | Automatic leader election | No loss (3-replica ISR) |
| Flink TaskManager crash | Flink JobManager | Restore from last checkpoint | No loss, reprocess from checkpoint |
| Spark executor crash | Spark driver | Restart executor, reprocess batch | No loss, Delta txn rollback |
| PostgreSQL primary failure | CloudNativePG | Promote replica (< 30s) | No loss (sync replication) |
| MinIO node failure | Erasure coding | Automatic rebuild | No loss (4+4 EC) |
| OpenSearch node failure | Replica shards | Automatic rebalance | No loss (replica shards) |

---

## 2. Throughput Analysis: 2M Messages

### Capacity Planning

```
Target: 2,000,000 messages total (burst scenario)
Assume: 30-minute burst window
Rate:   ~1,111 msg/sec sustained, 5,000+ msg/sec peak

Layer-by-layer capacity:

MLLP Layer:
  Per-pod: 10,000-50,000 msg/sec (Go goroutines)
  Pods needed: 2 (even conservative estimate exceeds target)
  With KEDA headroom: 2-4 pods active, scale to 16 max

Kafka Layer:
  Per-broker: 800K-1M msg/sec writes
  Brokers: 3 (far exceeds 5K msg/sec peak)
  Bottleneck: None — Kafka handles 2M+ msg/sec on 3 nodes

Flink Layer:
  Per-TaskManager slot: ~5,000-10,000 msg/sec (with HAPI parsing)
  HAPI parsing: ~45ms per message (complex ADT)
  With 4 TaskManagers × 2 slots = 8 parallel parsers
  Throughput: 8 × 5,000 = 40,000 msg/sec capacity
  For sustained 1,111 msg/sec: 1 TaskManager suffices
  For burst 5,000 msg/sec: 2 TaskManagers suffice
  KEDA scales to 32 TaskManagers for extreme scenarios

Spark → Delta Lake:
  Micro-batch: processes accumulated Kafka messages every 10-30s
  Delta MERGE: handles 10,000-50,000 rows/batch on 4 executors
  Not a bottleneck for this throughput

Verdict: The pipeline handles 2M messages comfortably.
         The 2M/s claim in the design doc refers to Kafka's raw capacity.
         Practical clinical throughput is lower (limited by HAPI parsing)
         but still far exceeds real-world hospital loads.
```

### Realistic Clinical Volumes

| Scenario | Daily Messages | Peak msg/sec | MLLP Pods | Flink TMs |
|----------|---------------|-------------|-----------|-----------|
| Single hospital (200 beds) | 15,000 | 50 | 2 | 1 |
| Academic medical center (800 beds) | 80,000 | 200 | 2 | 2 |
| 20-hospital health system | 500,000 | 2,000 | 2-4 | 4 |
| 50-hospital mega system | 2,000,000 | 5,000 | 4-8 | 4-8 |
| Epic interface event (upgrade/migration) | 10,000,000+ | 50,000+ | 8-16 | 8-32 |

The architecture is significantly over-provisioned for typical clinical loads, which provides headroom for Epic interface events (system upgrades, bulk migrations) that can generate order-of-magnitude traffic spikes.

---

## 3. HL7 Parsing Performance Deep Dive

### HAPI HL7v2 Parsing Benchmarks

| Message Type | Segments | Parse Time (HAPI) | Including Validation |
|-------------|----------|-------------------|---------------------|
| ADT^A01 (simple) | 5-8 | ~10ms | ~15ms |
| ADT^A01 (complex, full demographics) | 15-25 | ~25ms | ~40ms |
| ORU^R01 (10 OBX results) | 20-30 | ~30ms | ~50ms |
| ORU^R01 (100 OBX results) | 110+ | ~100ms | ~150ms |
| DFT^P03 (financial) | 10-15 | ~15ms | ~25ms |
| MDM^T02 (document with embedded content) | 5-10 + blob | ~20ms | ~30ms |

**Critical insight**: Large ORU messages with 100+ OBX segments (e.g., microbiology culture results, pathology reports) are the parsing bottleneck. These should be identified early in the pipeline and routed to dedicated Flink task slots with higher memory allocation.

### Flink Parallelism Strategy

```
hl7.raw.ingest (48 partitions)
    │
    ▼
Flink HL7 Parser Job
    │
    ├── KeyBy: facility_id + sending_app (matches Kafka partition key)
    │
    ├── Parallelism: 8 (default)
    │   Each parallel instance handles ~6 partitions
    │
    ├── TaskManager resources:
    │   Memory: 4 GB (2 GB JVM heap + 2 GB managed/network)
    │   CPU: 2 cores
    │
    └── RocksDB state:
        Per-key (patient MRN) state: ~1 KB per active patient
        Total state: ~1 GB for 1M active patients
```

---

## 4. Transformation Layer Assessment

### SQLMesh: Technical Strengths and Concerns

**Strengths:**
- SQLGlot-based SQL parsing enables genuine column-level lineage (not heuristic)
- Virtual environments use pointer-based table references — O(1) environment creation vs. O(n) physical copy
- State tracker persists model hash + data intervals → only rebuild what changed
- Plan/apply with automatic breaking-change detection prevents production incidents

**Concerns:**
- Spark engine integration is the primary execution path for Delta Lake. SQLMesh's Spark integration requires careful Spark session management in K8s.
- Documentation is good but less comprehensive than dbt's ecosystem
- Fewer community-contributed packages/macros than dbt-packages

**Recommendation**: Start with SQLMesh for new development. Consider dbt compatibility mode if migrating from existing dbt projects.

### Apache Hop: Technical Strengths and Concerns

**Strengths:**
- 400+ transforms cover virtually every data integration pattern
- Apache Beam runner enables pipeline execution on Flink/Spark
- Git-native project structure = first-class version control
- Visual pipeline design genuinely accessible to non-engineers

**Concerns:**
- Beam integration, while functional, adds a compilation step and potential version compatibility issues
- Fewer production K8s deployment references than NiFi
- Plugin quality varies — core transforms are solid, community transforms less so

**Recommendation**: Use Hop for clinician-facing mapping pipelines. Use SQLMesh for engineer-managed SQL transforms. Clear boundary reduces complexity.

---

## 5. Master Patient Index: Hybrid Architecture Analysis

### Matching Accuracy Expectations

| Scenario | HAPI MDM (Deterministic) | Splink (Probabilistic) | Combined |
|----------|------------------------|----------------------|----------|
| Same name, same DOB, same SSN | 99.9% match | 99.99% match | 99.99% |
| Misspelled name, same DOB | POSSIBLE_MATCH | 95%+ match | 95%+ |
| Maiden → married name change | NO_MATCH | 70-85% match | 70-85% |
| Different facilities, no shared ID | NO_MATCH | 80-90% match | 80-90% |
| Transposed digits in DOB | POSSIBLE_MATCH | 90%+ match | 90%+ |

**Key insight**: The hybrid approach covers the spectrum. HAPI MDM catches the easy matches instantly (same-name, same-DOB). Splink's Fellegi-Sunter model catches the hard matches (name changes, typos, cross-facility) in batch. The `POSSIBLE_MATCH` queue catches the ambiguous middle ground for human review.

### MPI Scale Projections

| Patient Corpus Size | Splink Backend | Batch Runtime | Memory |
|-------------------|---------------|---------------|--------|
| 100,000 patients | DuckDB | ~2 min | 4 GB |
| 1,000,000 patients | DuckDB | ~20 min | 16 GB |
| 10,000,000 patients | Spark (4 executors) | ~2 hours | 64 GB total |
| 100,000,000 patients | Spark (16 executors) | ~12 hours | 256 GB total |
| 200,000,000 patients | Spark (32 executors) | ~24 hours | 512 GB total |

DuckDB is sufficient for development and small deployments (< 5M patients). Spark is required for health system scale (> 10M patients). The nightly Splink batch job runs on Spark executors scaled by KEDA.

---

## 6. Storage Layer Performance

### Delta Lake Query Performance (Trino)

| Query Type | Data Size | Expected Latency | Notes |
|-----------|-----------|-------------------|-------|
| Point lookup (single patient) | 100M rows | < 1 second | Partition pruning + Z-order |
| Aggregation (denial rate by payer) | 10M claims | 2-5 seconds | 4 Trino workers |
| Full table scan (all patients) | 100M rows | 30-120 seconds | Avoid in production queries |
| Join (fact_encounter × dim_patient) | 50M × 10M | 5-15 seconds | Broadcast join on dim |
| Time travel query (point-in-time) | 100M rows | Same as above | Snapshot isolation |

### MinIO I/O Patterns

| Operation | Pattern | Performance |
|-----------|---------|-------------|
| Delta write (Spark) | Sequential large writes | 500+ MB/sec per node |
| Delta read (Trino) | Random reads (Parquet row groups) | Metadata cache: 97-98% hit |
| Flink checkpoints | Sequential writes (60s interval) | ~100 MB per checkpoint |
| Barman backups | Sequential large writes | 200+ MB/sec |

---

## 7. Security Architecture Review

### HIPAA Controls Mapping

| HIPAA §164.312 | Control | Implementation |
|----------------|---------|----------------|
| (a)(1) Access Control | Unique user identification | Vault-issued dynamic credentials |
| (a)(2)(i) Unique User ID | Per-service identity | K8s ServiceAccounts + Vault roles |
| (a)(2)(iv) Encryption | Data encryption | Linkerd mTLS (transit) + MinIO AES-256 (rest) |
| (b) Audit Controls | Record access logging | Vault audit log + K8s audit log → Loki |
| (c)(1) Integrity | PHI integrity protection | Delta Lake ACID + CRC32 checksums |
| (d) Authentication | Entity authentication | Vault + Linkerd mTLS certificates |
| (e)(1) Transmission Security | Network encryption | Linkerd mTLS (zero-config) |
| (e)(2)(ii) Encryption | Transmission encryption | TLS 1.3 everywhere |

### Attack Surface Assessment

| Vector | Exposure | Mitigation |
|--------|----------|-----------|
| MLLP listener (external TCP) | Internet-facing (through LB) | NetworkPolicy, IP allowlisting, TLS |
| Kafka brokers | Internal only | mTLS (Strimzi + Linkerd), SASL/SCRAM |
| PostgreSQL | Internal only | Dynamic credentials (Vault), RLS, mTLS |
| MinIO | Internal only | IAM policies, bucket policies, mTLS |
| Trino | Internal only | RBAC, Linkerd mTLS |
| ArgoCD UI | Team-facing | RBAC, SSO integration, Linkerd mTLS |
| FHIR API (outbound to Epic) | Outbound HTTPS | JWT assertion auth, TLS 1.2+ |

### Key Security Gaps to Address

1. **No WAF**: MLLP listener is TCP-based (not HTTP), so traditional WAFs don't apply. Mitigation: NetworkPolicy + IP allowlisting + Falco runtime detection.
2. **PHI in Kafka**: Messages contain PHI in transit through Kafka topics. Mitigation: Linkerd mTLS encrypts pod-to-pod, Strimzi TLS encrypts broker connections, Vault transit engine for field-level encryption if needed.
3. **MinIO AGPL**: If Nerve modifies MinIO source code, AGPL requires sharing modifications. Mitigation: Don't modify MinIO; use it as-is.

---

## 8. Operational Complexity Assessment

### Component Count

```
Platform Layer:     7 operators/systems (Strimzi, Flink, MinIO, CNPG, Vault, Linkerd, KEDA)
Application Layer:  6 services (MLLP, Flink jobs, Spark jobs, HAPI FHIR, Hop, Trino)
Observability:      5 systems (Prometheus, Grafana, Loki, Tempo, OTel)
GitOps:             2 systems (ArgoCD, Argo Rollouts)
Total:              ~20 distinct systems
```

This is a complex stack. Mitigation strategies:

1. **ArgoCD App-of-Apps**: Single entry point manages all 20 systems
2. **Helm charts**: Every component has an official Helm chart
3. **Operator pattern**: 7 of 20 systems are managed by K8s operators (self-healing)
4. **Observability**: Comprehensive monitoring of all systems through a single Grafana instance
5. **Phased rollout**: 8-phase implementation plan avoids big-bang deployment

### Team Skills Required

| Skill | Components | Team Role |
|-------|-----------|-----------|
| Go development | MLLP listener, connectors | Platform engineer |
| Java/JVM | Flink jobs, HAPI HL7v2 | Data engineer |
| Python | Splink, SQLMesh, pydicom | Data scientist / analyst |
| TypeScript/React | Mapping Studio, MPI Review | Frontend developer |
| SQL | SQLMesh models, Trino queries | Clinical analyst / RCM team |
| Kubernetes/Helm | All deployment | DevOps / SRE |
| Kafka administration | Strimzi, topic management | Platform engineer |

Minimum team: 3-4 engineers (1 platform, 1 data, 1 frontend, 1 DevOps). Recommended for production: 6-8 engineers plus clinical analyst support.

---

## 9. Recommendations

### Immediate Priorities

1. **Invest in integration testing**: The weakest point in any multi-component architecture is the interfaces. Build end-to-end integration tests that replay HL7 fixtures through the full pipeline and verify Delta Lake output.

2. **Start with DuckDB**: For local development, Splink on DuckDB + SQLMesh on DuckDB eliminates the need for Spark clusters. Only move to Spark when data volume requires it.

3. **Establish HL7 fixture library early**: Collect real (de-identified) HL7 messages from target source systems. The parser's correctness depends entirely on handling real-world message variations.

### Architecture Refinements

1. **Consider Flink SQL for simple transforms**: Some Silver layer transforms may be expressible as Flink SQL, eliminating the Spark dependency for those specific paths.

2. **Evaluate Delta Lake UniForm**: UniForm (Delta Lake 3.1+) writes Iceberg-compatible metadata alongside Delta logs. This provides an escape hatch if Iceberg's Flink connector proves more production-ready than Delta's.

3. **Monitor Redpanda's license evolution**: If Redpanda moves to a truly open-source license, its operational simplicity (no JVM, single binary) makes it worth re-evaluating vs. Kafka.

---

## 10. Production Readiness Scorecard

| Component | Code Maturity | K8s Maturity | Healthcare Proven | Overall |
|-----------|:------------:|:------------:|:-----------------:|:-------:|
| Go MLLP (custom) | N/A (to build) | N/A | Google ref impl | Build |
| Kafka (Strimzi) | 10/10 | 10/10 | 9/10 | Ready |
| Flink (K8s Operator) | 9/10 | 9/10 | 7/10 | Ready |
| HAPI HL7v2 | 10/10 | N/A (library) | 10/10 | Ready |
| Delta Lake | 9/10 | 8/10 | 8/10 | Ready |
| MinIO | 10/10 | 10/10 | 8/10 | Ready |
| PostgreSQL (CNPG) | 10/10 | 9/10 | 10/10 | Ready |
| SQLMesh | 7/10 | 6/10 | 4/10 | Evaluate |
| Apache Hop | 8/10 | 7/10 | 5/10 | Evaluate |
| Trino | 9/10 | 9/10 | 7/10 | Ready |
| OpenSearch | 9/10 | 8/10 | 7/10 | Ready |
| HAPI FHIR MDM | 8/10 | 7/10 | 8/10 | Ready |
| Splink | 8/10 | 5/10 | 9/10 | Ready (batch) |
| Orthanc | 8/10 | 6/10 | 9/10 | Ready |
| ArgoCD | 10/10 | 10/10 | 7/10 | Ready |
| KEDA | 9/10 | 10/10 | 6/10 | Ready |
| Linkerd | 9/10 | 10/10 | 6/10 | Ready |
| Vault | 10/10 | 9/10 | 8/10 | Ready |
| Observability Stack | 10/10 | 10/10 | 8/10 | Ready |

**Overall Assessment**: 15 of 19 components are production-ready. The Go MLLP service needs to be built. SQLMesh and Apache Hop need evaluation in the specific clinical context but carry low technical risk.
