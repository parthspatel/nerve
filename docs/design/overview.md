# Kubernetes-native clinical data integration and RCM platform architecture

A fully open-source, production-grade architecture for clinical data integration and Revenue Cycle Management can be built on Kubernetes using a layered design: **Go-based MLLP listeners** for HL7 v2.x ingestion, **Apache Kafka (Strimzi)** for durable message streaming, **Apache Flink** for real-time parsing with HAPI HL7, a **medallion Delta Lake** on MinIO for analytics, and a composable transformation layer combining **SQLMesh** with **Apache Hop** to serve non-technical clinical users. This architecture handles 2M+ messages with sub-second ACK latency by scaling horizontally at every layer through KEDA-driven autoscaling tied to Kafka consumer lag.

The design addresses every requirement — from Epic HL7/FHIR integration and OnBase document management to DICOM imaging, Master Patient Index, and HIPAA-compliant K8s deployment — using exclusively open-source components under Apache 2.0, MIT, or AGPL licenses. What follows is a detailed component-by-component breakdown with selection rationale, data flow paths, and scaling strategies.

---

## Architecture overview and data flow topology

The platform follows a **five-layer architecture**: Ingestion → Streaming → Processing → Storage → Serving. Each layer is independently scalable on Kubernetes and connected through Kafka as the central nervous system.

**End-to-end data flow for an HL7 v2.x message:**

```
Epic/Source EHR ──MLLP/TCP──▶ [Go MLLP Pods] ──produce──▶ [Kafka: hl7.raw.ingest]
                                    │ ACK                        │
                                    ▼                            ▼
                              Sub-second ACK           [Flink: Parse + Validate]
                              back to source                     │
                                                                 ▼
                                                    [Kafka: hl7.parsed.{type}]
                                                         │    │    │
                                          ┌──────────────┘    │    └──────────────┐
                                          ▼                   ▼                   ▼
                                   [Delta Lake]        [PostgreSQL]        [OpenSearch]
                                   Bronze→Silver→Gold   Operational DB     Clinical Search
                                          │
                                          ▼
                              [SQLMesh/Hop Transforms]
                              (dbt-style, Git-backed)
                                          │
                                          ▼
                                   [Trino Queries]
                                   Gold Layer Analytics
```

**Parallel data flows for secondary sources:**

```
OnBase ──REST API──▶ [Document Connector Pod] ──▶ [Kafka: docs.ingest] ──▶ [Flink] ──▶ Delta/OpenSearch
PACS   ──DICOM───▶ [Orthanc Proxy Pods]       ──▶ [Kafka: dicom.meta] ──▶ [Flink] ──▶ Delta/OpenSearch
Epic   ──FHIR R4──▶ [FHIR Poller Pods]        ──▶ [Kafka: fhir.ingest] ──▶ [Flink] ──▶ Delta/PostgreSQL
```

Every record at every layer carries **`source_system`** and **`facility_id`** fields, injected at the MLLP listener level from the TCP connection metadata (each sending system maps to a known facility). This enables cross-system data isolation without full multi-tenancy.

---

## HL7 v2.x MLLP ingestion layer

The ingestion layer must handle **2M+ HL7 v2.x messages** with sub-second ACK latency while scaling horizontally on K8s pods. After evaluating five approaches — custom Go, custom Rust, Apache Camel, Mirth Connect, and HAPI-based services — the clear winner is a **custom Go MLLP service** modeled on Google's production-grade `GoogleCloudPlatform/mllp` adapter.

**Why Go over alternatives:** Go's goroutine-per-connection model aligns perfectly with MLLP's connection pattern (few long-lived TCP connections, one per sending system). A single Go pod achieves **10,000–50,000 messages/second** with sub-millisecond ACK generation, containers start in under 1 second with a **20–50 MB footprint**, and Google's reference implementation has proven production viability on GKE. Rust theoretically offers higher raw throughput (50,000–100,000+ msg/sec) but the HL7 ecosystem is nascent — the `hl7-mllp-codec` crate is self-described as a "tokio play project" with no known healthcare deployments.

**Mirth Connect is explicitly not recommended** for this horizontal-scaling pattern. Despite being the most widely deployed open-source healthcare integration engine, GitHub discussions confirm that even with the commercial Advanced Clustering Extension, multiple K8s replicas fail to work properly. Mirth was architecturally designed as a monolithic engine with shared database state — it scales vertically, not horizontally.

**Apache Camel (camel-mllp)** serves as the secondary choice for teams with Java expertise who need Camel's broader integration framework (200+ connectors, dead letter channels, content-based routing). Running on Spring Boot or Quarkus, Camel achieves 5,000–20,000 msg/sec per pod with production maturity spanning 10+ years in healthcare.

**Scaling design:** Go MLLP pods sit behind a Kubernetes TCP LoadBalancer (MetalLB for bare-metal or cloud LB). KEDA scales pods based on a Prometheus metric (`mllp_messages_received_total` rate), with a minimum of 2 replicas for HA. At the target throughput, **40–200 pods** handle 2M messages comfortably even assuming conservative per-pod throughput. The listener immediately produces the raw message to Kafka and returns an HL7 ACK — no parsing or validation occurs at this layer, keeping ACK latency under 5ms.

---

## Kafka streaming backbone with Strimzi

**Apache Kafka with the Strimzi operator** is the recommended message broker, selected over Redpanda and Apache Pulsar based on three decisive factors: proven throughput at **2M+ writes/second** (LinkedIn's benchmark on 3 nodes), the most mature K8s operator as a **CNCF Incubating project**, and the largest healthcare adoption with documented HL7/FHIR integration patterns.

Redpanda's C++ architecture offers lower tail latency (8–15ms P99 vs Kafka's 15–25ms) and simpler operations (no JVM, single binary), but its **Business Source License** creates risk for regulated healthcare organizations, and independent benchmarks by Confluent's principal technologist show throughput differences are smaller than Redpanda claims. Apache Pulsar's native multi-tenancy is compelling but its higher operational complexity (brokers + BookKeeper + ZooKeeper), **~50% lower throughput**, and significantly smaller community (23 job postings vs Kafka's 4,293) make it a weaker choice.

**Strimzi deployment** uses KRaft mode (no ZooKeeper from Strimzi 0.46+), with declarative CRD-based management, automated rolling upgrades, TLS/mTLS encryption, OAuth 2.0 authentication, and Cruise Control integration for automatic partition rebalancing. The Strimzi Helm chart (`strimzi/strimzi-kafka-operator`) provides GitOps-compatible deployment.

**Topic and partitioning strategy for HL7:**

| Topic | Key Strategy | Partitions | Purpose |
|-------|-------------|------------|---------|
| `hl7.raw.ingest` | `facility_id + sending_app` | 32–48 | Raw MLLP messages, per-source ordering |
| `hl7.parsed.adt` | `patient_mrn_hash` | 24 | Parsed ADT messages, patient-level ordering |
| `hl7.parsed.orm` | `patient_mrn_hash` | 24 | Parsed order messages |
| `hl7.parsed.oru` | `patient_mrn_hash` | 24 | Parsed result messages |
| `hl7.parsed.dft` | `encounter_id` | 16 | Financial transactions |
| `hl7.parsed.mdm` | `patient_mrn_hash` | 16 | Document management messages |
| `hl7.dlq` | Original key | 8 | Dead letter queue for failed messages |
| `fhir.ingest` | `resource_type + patient_id` | 16 | FHIR R4 resources from Epic API |
| `docs.ingest` | `document_id` | 12 | OnBase documents |
| `dicom.metadata` | `study_instance_uid` | 12 | DICOM study metadata |

Partitioning by `patient_mrn_hash` on parsed topics ensures **per-patient message ordering** — critical for clinical correctness when processing sequences like admission → lab order → lab result for the same patient. The 24–48 partition count enables sufficient consumer parallelism for KEDA-driven scaling.

**Exactly-once semantics:** Kafka's idempotent producers (PID + sequence number deduplication) have **negligible throughput impact** and are enabled by default in modern Kafka. Transactional APIs enable atomic produce-and-consume patterns through the Flink-Kafka integration.

---

## Apache Flink for real-time HL7 parsing and normalization

**Apache Flink** is the recommended stream processing framework, outperforming Kafka Streams and Spark Structured Streaming for this use case. Flink delivers **sub-second latency (tens of milliseconds)**, guaranteed exactly-once semantics via distributed snapshots, and best-in-class stateful processing for patient record correlation — all running natively on K8s via the mature Flink Kubernetes Operator (v1.13.0, under the ASF umbrella).

**Why not Kafka Streams?** While simpler to deploy (no separate cluster, just a Java library), Kafka Streams' parallelism is capped at the number of Kafka partitions, and it lacks Flink's advanced windowing, Complex Event Processing (CEP), and temporal joins needed for cross-message HL7 correlation. **Why not Spark Structured Streaming?** Its micro-batch default mode adds 100ms+ latency. Project Lightspeed improvements achieve sub-100ms for stateless workloads, but Spark's batch-oriented architecture is less natural for record-by-record HL7 parsing. However, Spark remains essential in this architecture for the Delta Lake ETL pipeline (see below).

**HAPI HL7v2 integration** is seamless. Flink is JVM-based, and the HAPI HL7v2 library (the "gold standard" for HL7 processing, Apache 2.0 licensed) integrates as a standard Maven dependency. Within Flink's `ProcessFunction` operators, raw HL7 messages are parsed into strongly-typed Java objects covering all v2.x message types (ADT, DFT, ORU, ORM, MDM) and all versions (v2.1–v2.8.1). The AWS healthcare reference architecture explicitly demonstrates this Flink + HAPI pattern processing ~4,000 HL7 messages/minute.

**Flink job architecture:**

```
Kafka Source (hl7.raw.ingest)
    │
    ▼
[MLLP Frame Decoder] ── Strip MLLP envelope
    │
    ▼
[HAPI HL7 Parser] ── Parse ER7 into typed objects
    │                  Extract: MSH (header), PID (patient), PV1 (visit),
    │                  OBX (observations), OBR (orders), DG1 (diagnosis)
    ▼
[Validator] ── Schema validation, required field checks
    │           Route failures to DLQ
    ▼
[Enrichment] ── Inject source_system, facility_id, ingestion_ts
    │            Normalize date formats, code systems
    ▼
[Router] ── Route by MSH-9 (message type) to typed Kafka topics
    │
    ├──▶ Kafka Sink: hl7.parsed.adt (ADT messages)
    ├──▶ Kafka Sink: hl7.parsed.orm (Order messages)
    ├──▶ Kafka Sink: hl7.parsed.oru (Result messages)
    ├──▶ Kafka Sink: hl7.parsed.dft (Financial transactions)
    └──▶ Kafka Sink: hl7.parsed.mdm (Documents)
```

**Stateful processing** uses Flink's RocksDB state backend, keyed by patient MRN, to correlate cross-message events (e.g., matching an ADT admission with subsequent ORU lab results). Event-time processing with watermarks handles late-arriving HL7 messages correctly. Asynchronous checkpointing to MinIO/S3 provides state durability without impacting latency.

**Delta Lake sink strategy:** The Flink/Delta connector (v0.7.0) provides exactly-once writes but remains in preview. The production-proven pattern is **Flink → Kafka → Spark Structured Streaming → Delta Lake**, where Spark's native Delta integration handles the final write with full MERGE, schema evolution, and compaction support. This two-stage approach uses each engine's strength: Flink for low-latency parsing, Spark for reliable Delta writes.

---

## Transformation layer for non-technical clinical users

This is the most challenging requirement: enabling clinicians, coders, and RCM analysts to define data transformations without writing code, while maintaining Git-backed version control and schema evolution. **No single OSS tool fully satisfies all requirements.** The recommended approach is a composable three-layer architecture.

**Layer 1 — SQL transformation engine: SQLMesh on Delta Lake.** SQLMesh (by Tobiko Data, open-source) is preferred over dbt-core for three reasons: built-in state tracking that makes execution **~9x faster** than dbt by only rebuilding affected models; virtual data environments that allow instant isolated development without physically rebuilding tables; and a plan/apply paradigm (like Terraform) that automatically detects breaking vs. non-breaking schema changes. SQLMesh works with Delta Lake via Spark/Databricks engines and provides column-level lineage via its SQLGlot SQL parser. All transformation SQL models are Git-native files with PR-based review workflows.

**Layer 2 — Visual mapping UI: Apache Hop.** Apache Hop (Apache Top-Level Project since 2022, successor to Pentaho Kettle created by the original Kettle creator) provides a **full visual drag-and-drop IDE** with 400+ built-in plugins. Non-technical clinical users design data mappings visually without writing code. Hop's projects and environments integrate natively with Git for version control, and it runs on K8s with container images that start in 1–2 seconds. Critically, Hop can execute pipelines on Flink or Spark via Apache Beam integration, bridging the visual design experience with the high-performance processing engines already in the architecture.

**Layer 3 — Clinical mapping configuration: YAML/JSON mapping files + custom UI.** For the specific use case of mapping disparate HL7 source formats to a standardized specification, a custom React/Streamlit UI generates declarative YAML mapping configurations. These configurations define field-level mappings (e.g., `source: PID.5.1 → target: patient.lastName`), code system translations (local codes to standard terminologies), and validation rules. Mappings are stored as Git-backed files and executed by Flink operators or SQLMesh models. **AtlasMap** (Red Hat, open-source) provides a web-based drag-and-drop field mapping interface for JSON/XML formats that can serve as a visual component in this layer.

**Version control and GitOps flow:**

```
Clinical User ──(visual UI)──▶ Mapping Definition (YAML/SQL)
                                        │
                                        ▼
                               Git Repository (PR)
                                        │
                                   Code Review
                                        │
                                        ▼
                               CI/CD (validate, test)
                                        │
                                        ▼
                               ArgoCD deploys to K8s
                                        │
                                        ▼
                          SQLMesh plan/apply or Flink job update
```

Schema evolution is handled at multiple levels: Delta Lake's native schema evolution (`mergeSchema=true`), SQLMesh's automatic breaking-change detection, and the schema registry (Apicurio) enforcing backwards compatibility on Kafka topics.

---

## Delta Lake medallion architecture on MinIO

The analytical storage layer uses **Delta Lake** deployed on **MinIO** (AGPLv3, K8s operator) for S3-compatible object storage. Delta Lake is selected over Apache Iceberg and Apache Hudi for its superior Spark integration, mature MERGE operations for patient record updates, proven healthcare adoption (Databricks' clinical health data lake reference architecture), and time travel capabilities essential for HIPAA audit trails.

**Bronze layer (raw zone):** Raw HL7 v2 messages stored as strings preserving the original wire format. Raw FHIR JSON bundles, raw clinical documents, and raw EDI 837/835 claims files. Every record gets metadata columns: `_source_system`, `_facility_id`, `_ingestion_timestamp`, `_message_type`. Append-only, immutable — no transformations beyond metadata enrichment. Partitioned by `ingestion_date/source_system/message_type`.

**Silver layer (validated/conformed):** Parsed HL7 segments exploded into structured columns (PID → patient demographics, PV1 → visit details, OBX → observations). FHIR resources flattened into typed Delta tables (Patient, Encounter, Observation). Deduplication via MPI golden record linkage. Data cleaning, null handling, format standardization. Code system normalization (local codes → ICD-10, CPT, SNOMED CT). Partitioned by `source_system/facility_id` with Liquid Clustering on frequently-queried columns.

**Gold layer (consumption-ready):** Unified patient longitudinal views across systems. Star schema models: `DIM_PATIENT`, `DIM_PROVIDER`, `DIM_FACILITY`, `FACT_ENCOUNTER`, `FACT_CLAIM`, `FACT_OBSERVATION`. RCM analytics tables: denial rates, A/R aging, claim status, charge capture completeness. Quality metrics: HEDIS measures, readmission rates, patient safety indicators. Optimized for Trino queries with Z-ordering on high-cardinality join columns.

**Time travel and audit:** Every Delta operation creates an immutable version in the transaction log. `DESCRIBE HISTORY` provides full audit trails. Historical queries via `VERSION AS OF` or `TIMESTAMP AS OF` satisfy HIPAA and 21 CFR Part 11 requirements for reproducing clinical data states at any point. Change Data Feed enabled on all silver/gold tables for row-level audit: `ALTER TABLE SET TBLPROPERTIES (delta.enableChangeDataFeed = true)`.

**MinIO deployment:** The MinIO Kubernetes Operator (v7.1+) deploys isolated Tenant StatefulSets with erasure-coded storage, automatic TLS, and object locking (WORM mode for compliance). MinIO delivers **2.6+ Tbps read throughput** at scale with strict read-after-write consistency required by Delta Lake's transaction log. Storage lifecycle policies manage retention, and active-active replication provides DR.

**Query engines:** **Trino** (via Helm chart `trino/trino`) for interactive SQL analytics on silver/gold tables — its low-latency distributed SQL engine with a production-ready Delta Lake connector achieves **97–98% metadata cache hit rates**. **Apache Spark** (via Kubeflow Spark Operator) for heavy ETL batch processing in the medallion pipeline. Both coexist reading from the same Delta tables, connected through a **Hive Metastore** (backed by PostgreSQL) as the shared catalog.

---

## Master Patient Index with HAPI FHIR MDM and Splink

Patient unification across facilities requires both real-time deterministic matching and batch probabilistic deduplication. The recommended hybrid approach uses **HAPI FHIR JPA Server with its MDM (Master Data Management) module** as the MPI backbone, augmented by **Splink** for advanced probabilistic matching at scale.

**HAPI FHIR MDM** (Apache 2.0, actively maintained) provides FHIR-native Golden Record management, creating and maintaining canonical "Golden Patient" resources linked to source records via Patient.link references. It supports automatic match classification (MATCH, POSSIBLE_MATCH, POSSIBLE_DUPLICATE, NO_MATCH), manual review workflows for ambiguous matches, merge/unmerge operations, and MDM Search Expansion that queries across all linked patients in a single request. Matching rules are configurable via JSON, supporting Soundex, Cologne phonetic, and Jaro-Winkler similarity algorithms. HAPI runs on Spring Boot with available Docker images and Helm charts for K8s.

**Splink** (UK Ministry of Justice, MIT license, **14M+ downloads**) implements the Fellegi-Sunter probabilistic model with unsupervised learning via the EM algorithm — no training data required. It has successfully linked **100+ million records** and was used by the US Defense Health Agency to deduplicate **200+ million hospital records**. Splink runs on DuckDB (local) or Apache Spark (distributed) and provides rich interactive visualizations for match quality assurance.

**Integration pattern:** ADT messages feed patient demographics into HAPI FHIR as Patient resources → HAPI MDM performs real-time deterministic matching (instant, on every new patient) → Splink batch jobs run periodically (nightly or weekly) for deeper probabilistic deduplication across the full patient corpus → Splink results feed back into HAPI MDM via `$mdm-submit` operations, creating or confirming golden record links. This gives real-time matching for operational needs plus high-accuracy batch matching for analytics.

OpenEMPI was evaluated and **rejected** — its last open-source commit was ~11 years ago, and the architecture (Java EAR on Tomcat/JBoss) is not K8s-ready.

---

## Source system connectors and adapters

**Epic HL7 v2.x (primary):** Epic Bridges, Epic's native interface engine, sends HL7 v2.x messages over MLLP/TCP. Supported message types include ADT (A01–A60+, patient demographics and visit events), ORM (lab, radiology, pharmacy orders), ORU (lab and radiology results), DFT (detailed financial transactions for RCM), SIU (scheduling), and MDM (clinical notes, transcriptions as RTF/PDF). Large health systems generate **50,000–100,000+ ADT messages/day** across a 20-hospital system. Connections typically use VPN or TLS encryption with ACK/NAK handshake and sequence numbering.

**Epic FHIR R4 (enrichment):** Epic provides **750+ no-cost FHIR R4 APIs** with near-real-time access to production data. A dedicated FHIR Poller service authenticates via Backend Systems OAuth2 (JWT assertions with RSA keys) and retrieves resources not available in HL7 v2 feeds: CareTeam, CarePlan, Coverage/ExplanationOfBenefit, social determinants observations, consent documents, and FamilyMemberHistory. Bulk FHIR Export (`Group/$export`) provides NDJSON backfill, though Epic recommends limiting batches to ~1,000 patients for system stability.

**Hyland OnBase (documents):** OnBase exposes two APIs: the legacy **Unity API** (SOAP, most feature-complete, requires Hyland DLLs) and the modern **REST API** (HTTP-only, no client components needed, growing feature set). There are **no open-source connectors** for OnBase — integration requires building a custom adapter pod that authenticates via the Hyland Identity Service, queries documents by patient MRN/encounter/document type, and retrieves content (PDF, TIFF). The adapter produces to the `docs.ingest` Kafka topic. For Epic-integrated deployments, OnBase's **SMART on FHIR integration** (tested across 450+ test cases) provides a standards-based alternative for document retrieval.

**PACS/DICOM (imaging):** **Orthanc** (GPLv3, 1M+ Docker pulls) serves as the DICOM proxy and metadata extraction layer. It receives DICOM studies via C-Store from PACS/modalities, exposes full DICOMweb APIs (WADO-RS, QIDO-RS, STOW-RS) via its official plugin, and supports horizontal scaling on K8s through shared PostgreSQL backends (multiple Orthanc pods behind an HTTP load balancer). The `korthweb` project provides production-ready K8s manifests with Istio ingress and Prometheus observability. Orthanc's Python plugin triggers metadata extraction via **pydicom/highdicom**, pushing study-level JSON metadata (PatientID, StudyDate, Modality, AccessionNumber, BodyPartExamined) to the `dicom.metadata` Kafka topic for indexing in OpenSearch and Delta Lake. dcm4chee Archive 5 is the alternative for organizations needing a full enterprise PACS with IHE profile compliance, though its multi-component architecture (WildFly + LDAP + Keycloak) adds significant operational complexity.

---

## Operational database and clinical document search

**PostgreSQL via CloudNativePG** (Apache 2.0, fastest-growing PG K8s operator with 5K+ GitHub stars) serves the operational database layer. CloudNativePG is uniquely Kubernetes-native — it manages HA internally using K8s primitives rather than Patroni, with automated failover, synchronous replication, built-in PgBouncer pooling via its `Pooler` CRD, and scheduled Barman backups to MinIO. Every table includes `source_system` and `facility_id` columns with composite unique constraints (`source_system, facility_id, mrn`) preventing cross-system duplicates. An `empi_id` foreign key links to the MPI golden record. Row-Level Security policies can enforce facility-based data isolation for application-level access control.

**OpenSearch** (Apache 2.0, now under the OpenSearch Software Foundation at Linux Foundation) handles clinical document search and indexing. OpenSearch is selected over Elasticsearch for its truly open-source license and **free built-in security** (RBAC, field-level security, audit logging) essential for HIPAA compliance without paid tiers. Separate time-based indices (`clinical-notes-{YYYY.MM}`, `lab-reports-{YYYY.MM}`, `radiology-reports-{YYYY.MM}`) enable efficient retention management. Custom analyzers with medical synonym lists (SNOMED CT, ICD-10) enable clinical terminology search. The OpenSearch ML Commons plugin supports deploying NER models (ClinicalBERT, BioBERT) for entity extraction at index time, turning unstructured clinical narratives into searchable structured fields.

**Apicurio Registry** (Apache 2.0, Red Hat-backed) manages schemas for all Kafka topics. It supports Avro, JSON Schema, Protobuf, OpenAPI, and XML Schema — broader format coverage than Confluent's community-licensed registry. A dedicated K8s operator (v1.1.3) deploys it as a CRD, backed by PostgreSQL for production storage. HL7 message schemas are registered as JSON Schema artifacts with subject naming `{system}.{message_type}-value` and FULL compatibility mode enforced, ensuring both backwards and forwards compatibility as HL7 schemas evolve.

---

## Kubernetes deployment topology and scaling

**Namespace organization** follows a hybrid functional-layer model. Since data isolation uses system-level tagging (not namespace boundaries), services are grouped by function to avoid duplication:

```
platform-kafka           # Strimzi Kafka cluster (3+ brokers)
platform-flink           # Flink cluster (JobManager + TaskManagers)
platform-storage         # MinIO tenants, PostgreSQL (CloudNativePG), OpenSearch
platform-observability   # Prometheus, Grafana, Loki, Tempo, OTel Collector
platform-security        # HashiCorp Vault, cert-manager
clinical-ingestion       # MLLP listeners, FHIR pollers, OnBase/DICOM connectors
clinical-processing      # Flink jobs, Spark jobs, SQLMesh runners
clinical-serving         # Trino, HAPI FHIR Server (MPI), Hop UI, mapping UI
clinical-transforms      # Apache Hop server, transformation job runners
```

**NetworkPolicies** enforce default-deny-ingress on all clinical namespaces with explicit allowlists (e.g., `clinical-processing` accepts traffic only from `clinical-ingestion` and `platform-kafka`).

**KEDA-driven autoscaling** is the cornerstone scaling mechanism, using Kafka consumer lag as the primary signal for stream processors:

| Component | Scaler | Metric | Min | Max | Scale-Up | Scale-Down |
|-----------|--------|--------|-----|-----|----------|------------|
| MLLP Listeners | KEDA/Prometheus | `mllp_messages_received_total` rate | 2 | 16 | Immediate | 5min cooldown |
| Flink TaskManagers | Flink Autoscaler | Job backpressure + lag | 4 | 32 | 15s window | 5min window |
| Kafka Consumers | KEDA/Kafka | Consumer group lag | 2 | partition count | Immediate | 5min cooldown |
| Trino Workers | KEDA/Prometheus | Query queue depth | 2 | 20 | 30s window | 10min window |
| Spark Executors | Spark Dynamic Alloc | Pending tasks | 2 | 32 | Per-batch | Per-batch |

For the MLLP burst scenario (2M+ messages), the pipeline absorbs load through Kafka's durability buffer. KEDA detects rising consumer lag and scales Flink TaskManagers from baseline (4) up to 32 within seconds, using the `scaleUp.stabilizationWindowSeconds: 0` policy for immediate response. The Cooperative Sticky Assignor partition strategy minimizes Kafka consumer rebalancing overhead during scale events.

**GitOps with ArgoCD** (CNCF Graduated, 17,800+ GitHub stars) manages all deployments. ArgoCD is selected over Flux for its built-in web UI (critical for clinical operations teams), team RBAC for facility-specific access controls, and strong commercial backing after Weaveworks' 2024 shutdown created uncertainty for Flux's ecosystem. The **App-of-Apps pattern** or **ApplicationSets** auto-generate Application definitions from a Git repository structure covering all environments (dev/staging/production). **Argo Rollouts** provides canary deployments for clinical services — gradually shifting traffic (5% → 25% → 50% → 100%) with automated Prometheus-based analysis that auto-rollbacks if error rates or ACK latency exceed thresholds.

**Linkerd service mesh** (CNCF Graduated) provides mTLS for all pod-to-pod communication **enabled by default** at installation — directly satisfying HIPAA encryption-in-transit requirements with zero configuration. Linkerd's Rust-based proxy adds **40–400% less latency** than Istio's Envoy proxy at P99, which matters for real-time clinical message processing. Its minimalist design reduces the risk of mesh-related outages in a clinical environment where uptime is non-negotiable.

---

## Observability and security for HIPAA compliance

The observability stack follows the **PLG + Tempo + OpenTelemetry** pattern: Prometheus for metrics, Grafana Loki for logs, Grafana Tempo for distributed traces, and the OpenTelemetry Collector as the unified telemetry pipeline. OTel Collectors deploy as DaemonSets (logs) and Deployments (metrics/traces), enriching all telemetry with consistent attributes (`k8s.pod.name`, `service.name`, `facility_id`) for cross-signal correlation. Grafana provides unified dashboards showing real-time HL7 message rates per facility, end-to-end pipeline latency heatmaps, Kafka consumer lag gauges, and parse error rates — with critical alerts for scenarios like parse error rate exceeding 1% (possible HL7 format change), growing consumer lag (processing falling behind), or zero message receipt for 10 minutes (pipeline down).

**HIPAA-compliant K8s security** centers on **HashiCorp Vault** (deployed in HA mode with Raft storage) for secret management — providing dynamic database credentials that auto-rotate, fine-grained per-secret ACL policies, and audit logging of every secret access. The Vault Agent Sidecar Injector automatically provisions secrets to pods via annotations. Additional security layers include etcd encryption for K8s Secrets, encrypted StorageClasses for all PersistentVolumes containing PHI, Pod Security Standards enforcing the `restricted` profile (non-root, read-only filesystem, no privilege escalation), OPA/Gatekeeper or Kyverno for policy enforcement, Trivy for image vulnerability scanning, and Falco for runtime intrusion detection. Kubernetes API audit logs forward to Loki with immutable storage, retained for the HIPAA-mandated 6-year minimum.

---

## Conclusion: a composable architecture built on proven components

This architecture achieves its ambitious requirements through deliberate component selection at each layer. The **Go MLLP → Kafka → Flink → Delta Lake** pipeline provides the real-time throughput backbone, handling 2M+ messages with sub-second latency by leveraging each component's architectural strength rather than forcing any single tool to do everything. The transformation challenge — making clinical data mapping accessible to non-technical users — is addressed through composition rather than compromise: SQLMesh handles SQL-based transformations with superior version control, Apache Hop provides the visual IDE that clinicians can actually use, and Git-backed YAML mappings bridge the two worlds.

Three architectural decisions merit emphasis. First, the **Flink + Spark dual-engine pattern** — Flink for low-latency stream parsing, Spark for reliable Delta Lake writes — avoids the Flink/Delta connector's preview status while using each engine optimally. Second, the **HAPI FHIR MDM + Splink hybrid MPI** combines real-time deterministic matching for operational speed with batch probabilistic matching for analytical accuracy, a pattern proven at the US Defense Health Agency's scale of 200M+ records. Third, **system-level data tagging rather than namespace-level isolation** keeps the K8s topology manageable (no service duplication per facility) while maintaining strict data separation through the `source_system` and `facility_id` fields that propagate from MLLP ingestion through every storage layer.

The entire stack runs on open-source components (Apache 2.0, MIT, AGPLv3, GPLv3) with no vendor lock-in, deployable on any Kubernetes distribution via ArgoCD-managed Helm charts, and scalable from a single-facility pilot to a multi-system enterprise through KEDA-driven horizontal autoscaling tied to actual clinical message load.
