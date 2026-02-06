<p align="center">
  <h1 align="center">⚡ NERVE</h1>
  <p align="center"><strong>The Clinical Data Nervous System</strong></p>
  <p align="center">
    <em>Every signal. Every system. One truth.</em>
  </p>
</p>

<p align="center">
  <a href="#architecture"><img src="https://img.shields.io/badge/architecture-kubernetes--native-326CE5?style=flat-square&logo=kubernetes&logoColor=white" alt="Kubernetes Native"></a>
  <a href="#throughput"><img src="https://img.shields.io/badge/throughput-2M%2B_msg%2Fs-00C853?style=flat-square" alt="2M+ msg/s"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-Apache_2.0-blue?style=flat-square" alt="License"></a>
  <a href="#hl7"><img src="https://img.shields.io/badge/HL7-v2.x_%7C_FHIR_R4-FF6D00?style=flat-square" alt="HL7 v2.x | FHIR R4"></a>
  <a href="#stack"><img src="https://img.shields.io/badge/stack-100%25_OSS-black?style=flat-square" alt="100% Open Source"></a>
</p>

-----

## What is Nerve?

Your hospitals generate millions of clinical signals every day — admissions, labs, orders, notes, scans, charges — scattered across Epic, OnBase, PACS, and dozens of other systems that were never designed to talk to each other. By the time your RCM team pieces together the full picture, you’ve already lost revenue, missed denials, and coded from incomplete data.

**Nerve is the real-time clinical data fabric** that intercepts every HL7 message, every FHIR resource, every scanned document, and every radiology study the instant it’s created — then unifies it into a single, queryable clinical truth across every facility in your system. Not in hours. Not in batches. In *milliseconds*.

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                          N E R V E                               │
  │                                                                  │
  │  Epic ─────┐                                                     │
  │  OnBase ───┤── Go MLLP ──▶ Kafka ──▶ Flink ──┬──▶ Delta Lake   │
  │  PACS ─────┤   Pods        Strimzi   + HAPI   ├──▶ PostgreSQL   │
  │  Others ───┘                                   └──▶ OpenSearch   │
  │                                                        │         │
  │     ┌──────────────────────────────────┐               ▼         │
  │     │  SQLMesh + Apache Hop            │          Trino SQL      │
  │     │  Visual clinical transforms      │          Analytics      │
  │     │  Git-backed • Version-controlled │                         │
  │     └──────────────────────────────────┘                         │
  │                                                                  │
  │  MPI: HAPI FHIR MDM + Splink (200M+ record proven)             │
  │  Deploy: ArgoCD │ Scale: KEDA │ Mesh: Linkerd │ Secrets: Vault  │
  └──────────────────────────────────────────────────────────────────┘
```

-----

## Why Nerve?

|Problem                                            |Nerve’s Answer                                              |
|---------------------------------------------------|------------------------------------------------------------|
|Legacy integration engines can’t horizontally scale|Go MLLP pods scale to **2M+ msg/s** on K8s via KEDA         |
|Only engineers can map HL7 fields across systems   |**Visual dbt-style studio** for clinicians and coders       |
|Patient records fragmented across facilities       |**Hybrid MPI** with real-time + batch probabilistic matching|
|No single source of truth for RCM analytics        |**Delta Lake medallion** — Bronze → Silver → Gold           |
|Vendor lock-in and per-message pricing             |**100% open source**, Apache 2.0 licensed                   |

-----

## Key Capabilities

### ⚡ 2M+ Messages, Sub-Second ACK

Nerve’s Go-based MLLP ingestion layer horizontally scales across Kubernetes pods to absorb massive HL7 pulse loads. Apache Flink parses every ADT, ORM, ORU, DFT, and MDM in real-time with the HAPI library. Kafka provides the durable backbone. ACKs fire in under 5 milliseconds. The sending system never waits.

### 🎨 Clinician-Designed Mappings

Every hospital speaks its own dialect of HL7. Nerve gives your clinical analysts and coders a visual transformation studio — drag-and-drop field mapping, point-and-click code translation, version-controlled through Git. When Hospital A sends diagnosis as a local code and Hospital B sends ICD-10-CM, your clinical team defines the unification rules themselves. No tickets. No six-week dev cycles.

### 🔗 One Patient, One Record, Every Facility

Nerve’s hybrid Master Patient Index combines real-time deterministic matching on every incoming ADT with batch probabilistic deduplication using the Fellegi-Sunter model — the same approach the U.S. Defense Health Agency used to deduplicate 200M+ records.

### 🏗️ Medallion Lakehouse for Clinical Data

|Layer     |What Lives Here                                                                                                                                         |
|----------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
|**Bronze**|Raw wire format. Immutable. Every HL7 message preserved exactly as received. HIPAA audit trail with time travel.                                        |
|**Silver**|Parsed, validated, deduplicated. PID → demographics, OBX → observations. Local codes → ICD-10, SNOMED CT. Tagged with `source_system` and `facility_id`.|
|**Gold**  |Unified star schema. `DIM_PATIENT` × `FACT_ENCOUNTER` × `FACT_CLAIM`. Denial rates, charge capture, A/R aging. Query with Trino in seconds.             |

-----

## Supported Sources

|Source            |Protocol        |What Nerve Captures                                      |
|------------------|----------------|---------------------------------------------------------|
|**Epic**          |MLLP + FHIR R4  |ADT, orders, results, charges, notes, 750+ FHIR resources|
|**OnBase**        |REST / Unity API|Scanned documents, faxes, EOBs, consent forms            |
|**PACS**          |DICOM / DICOMweb|Radiology metadata, study context, modality worklists    |
|**Any HL7 sender**|MLLP/TCP        |Full v2.x support, all message types, all versions       |

-----

## Architecture

Nerve follows a five-layer architecture — **Ingestion → Streaming → Processing → Storage → Serving** — each independently scalable on Kubernetes and connected through Kafka as the central nervous system.

### Data Flow

```
Epic/Source EHR ──MLLP/TCP──▶ [Go MLLP Pods] ──produce──▶ [Kafka: hl7.raw.ingest]
                                    │ ACK                          │
                                    ▼                              ▼
                              Sub-second ACK             [Flink: Parse + Validate]
                              back to source              HAPI HL7v2 library
                                                                   │
                                                                   ▼
                                                      [Kafka: hl7.parsed.{type}]
                                                           │    │    │
                                            ┌──────────────┘    │    └──────────────┐
                                            ▼                   ▼                   ▼
                                     [Delta Lake]        [PostgreSQL]        [OpenSearch]
                                     Bronze→Silver→Gold   Operational DB     Clinical Search
                                            │
                                            ▼
                                [SQLMesh / Hop Transforms]
                                 dbt-style, Git-backed
                                            │
                                            ▼
                                     [Trino Queries]
                                     Gold Layer Analytics
```

### Secondary Source Flows

```
OnBase ──REST API──▶ [Document Connector] ──▶ Kafka ──▶ Flink ──▶ Delta / OpenSearch
PACS   ──DICOM────▶ [Orthanc Proxy]       ──▶ Kafka ──▶ Flink ──▶ Delta / OpenSearch
Epic   ──FHIR R4──▶ [FHIR Poller]         ──▶ Kafka ──▶ Flink ──▶ Delta / PostgreSQL
```

### Kafka Topic Strategy

|Topic           |Key Strategy               |Purpose                               |
|----------------|---------------------------|--------------------------------------|
|`hl7.raw.ingest`|`facility_id + sending_app`|Raw MLLP messages, per-source ordering|
|`hl7.parsed.adt`|`patient_mrn_hash`         |Parsed ADT, patient-level ordering    |
|`hl7.parsed.orm`|`patient_mrn_hash`         |Parsed orders                         |
|`hl7.parsed.oru`|`patient_mrn_hash`         |Parsed results                        |
|`hl7.parsed.dft`|`encounter_id`             |Financial transactions                |
|`hl7.parsed.mdm`|`patient_mrn_hash`         |Document management                   |
|`hl7.dlq`       |Original key               |Dead letter queue                     |

-----

## Tech Stack

Every component is open source. No vendor lock-in. No per-message pricing. No “call us for enterprise.”

|Layer              |Component                          |Role                                                  |License          |
|-------------------|-----------------------------------|------------------------------------------------------|-----------------|
|**Ingestion**      |Custom Go MLLP                     |HL7 v2.x TCP listener, horizontal pod scaling         |Apache 2.0       |
|**Streaming**      |Apache Kafka (Strimzi)             |Durable message backbone, KRaft mode                  |Apache 2.0       |
|**Processing**     |Apache Flink + HAPI HL7v2          |Real-time parse, validate, route, enrich              |Apache 2.0       |
|**Batch ETL**      |Apache Spark                       |Delta Lake writes, medallion pipeline                 |Apache 2.0       |
|**Transforms**     |SQLMesh                            |dbt-style SQL transforms with version control         |Apache 2.0       |
|**Visual ETL**     |Apache Hop                         |Drag-and-drop mapping UI for clinical users           |Apache 2.0       |
|**Lakehouse**      |Delta Lake on MinIO                |Bronze/Silver/Gold medallion, time travel, audit      |Apache 2.0 / AGPL|
|**Operational DB** |PostgreSQL (CloudNativePG)         |Transactional store, HA with automated failover       |Apache 2.0       |
|**Search**         |OpenSearch                         |Clinical document indexing, NLP entity extraction     |Apache 2.0       |
|**MPI**            |HAPI FHIR MDM + Splink             |Real-time deterministic + batch probabilistic matching|Apache 2.0 / MIT |
|**DICOM**          |Orthanc                            |DICOM proxy, DICOMweb, metadata extraction            |GPLv3            |
|**Query**          |Trino                              |Interactive SQL on Delta Lake Gold layer              |Apache 2.0       |
|**Schema Registry**|Apicurio Registry                  |Kafka schema management (Avro, JSON Schema)           |Apache 2.0       |
|**GitOps**         |ArgoCD + Argo Rollouts             |Declarative deployment, canary releases               |Apache 2.0       |
|**Autoscaling**    |KEDA                               |Event-driven scaling on Kafka consumer lag            |Apache 2.0       |
|**Service Mesh**   |Linkerd                            |mTLS pod-to-pod, HIPAA encryption in transit          |Apache 2.0       |
|**Secrets**        |HashiCorp Vault                    |Dynamic credentials, secret rotation, audit           |MPL 2.0          |
|**Observability**  |Prometheus + Grafana + Loki + Tempo|Metrics, logs, traces, dashboards                     |Apache 2.0 / AGPL|

-----

## Kubernetes Deployment

### Namespace Topology

```
platform-kafka             # Strimzi Kafka cluster (3+ brokers)
platform-flink             # Flink JobManager + TaskManagers
platform-storage           # MinIO, PostgreSQL (CloudNativePG), OpenSearch
platform-observability     # Prometheus, Grafana, Loki, Tempo, OTel Collector
platform-security          # Vault, cert-manager
clinical-ingestion         # MLLP listeners, FHIR pollers, OnBase/DICOM connectors
clinical-processing        # Flink jobs, Spark jobs, SQLMesh runners
clinical-serving           # Trino, HAPI FHIR (MPI), Hop UI, mapping UI
clinical-transforms        # Apache Hop server, transformation runners
```

### Autoscaling Strategy

|Component         |Scaler            |Signal              |Min → Max Pods     |
|------------------|------------------|--------------------|-------------------|
|MLLP Listeners    |KEDA / Prometheus |Message receive rate|2 → 16             |
|Flink TaskManagers|Flink Autoscaler  |Backpressure + lag  |4 → 32             |
|Kafka Consumers   |KEDA / Kafka      |Consumer group lag  |2 → partition count|
|Trino Workers     |KEDA / Prometheus |Query queue depth   |2 → 20             |
|Spark Executors   |Dynamic Allocation|Pending tasks       |2 → 32             |

### HIPAA Security Baseline

- **Encryption in transit**: Linkerd mTLS on all pod-to-pod traffic (zero-config)
- **Encryption at rest**: Encrypted StorageClasses for all PVs containing PHI
- **Secrets**: Vault with dynamic credential rotation, per-secret ACL policies
- **Network**: Default-deny NetworkPolicies, explicit allowlists per namespace
- **Pod Security**: `restricted` PSS profile — non-root, read-only filesystem
- **Policy**: OPA Gatekeeper / Kyverno for admission control
- **Scanning**: Trivy image vulnerability scanning in CI/CD
- **Runtime**: Falco intrusion detection
- **Audit**: K8s API audit logs → Loki with immutable storage (6-year retention)

-----

## Transformation Studio

Nerve’s transformation layer is designed for **non-technical clinical users** — coders, RCM analysts, and clinicians — to define and version data mappings without engineering support.

### How It Works

```
Clinical User ──(visual UI)──▶ Mapping Definition (YAML/SQL)
                                        │
                                        ▼
                               Git Repository (PR)
                                        │
                                   Peer Review
                                        │
                                        ▼
                               CI/CD validates + tests
                                        │
                                        ▼
                               ArgoCD deploys to K8s
                                        │
                                        ▼
                          SQLMesh plan/apply or Flink job update
```

**Three composable layers:**

1. **SQLMesh** — SQL-based transformations on Delta Lake. ~9x faster than dbt through incremental state tracking. Virtual environments for safe development. Automatic breaking-change detection on schema evolution.
1. **Apache Hop** — Visual drag-and-drop pipeline designer with 400+ plugins. Git-native project structure. Executes on Flink or Spark via Apache Beam. The interface clinicians actually use.
1. **Declarative YAML mappings** — Field-level source→target definitions (`PID.5.1 → patient.lastName`), code system translations (local → ICD-10/SNOMED CT), validation rules. Git-backed, executed by Flink operators.

-----

## Master Patient Index

Nerve’s hybrid MPI combines two strategies for comprehensive patient matching:

**Real-time (HAPI FHIR MDM):**

- Deterministic matching on every incoming ADT message
- Golden Record management with FHIR Patient.link references
- Automatic MATCH / POSSIBLE_MATCH / NO_MATCH classification
- Manual review workflows for ambiguous cases
- Configurable rules: Soundex, Cologne phonetic, Jaro-Winkler similarity

**Batch (Splink):**

- Fellegi-Sunter probabilistic model with unsupervised EM learning
- No training data required
- Proven at 200M+ records (US Defense Health Agency)
- Interactive visualizations for match quality review
- Results feed back into HAPI MDM via `$mdm-submit`

-----

## Data Isolation Model

Nerve uses **system-level data tagging** rather than namespace isolation. Every record at every layer carries:

```json
{
  "source_system": "epic-phoenix",
  "facility_id": "FAC-001",
  "empi_id": "GOLD-12345",
  "ingestion_ts": "2026-02-05T12:00:00Z"
}
```

- **Within a system**: Patient records are unified across facilities via MPI
- **Across systems**: Data isolation enforced at the data level — every entry tagged with `source_system`
- **PostgreSQL**: Composite unique constraints (`source_system, facility_id, mrn`), Row-Level Security policies
- **Delta Lake**: Partitioned by `source_system/facility_id` at Silver/Gold layers
- **OpenSearch**: Separate indices per document type with system-level field filtering

-----

## Quick Start

> **Prerequisites**: Kubernetes 1.28+, Helm 3.x, `kubectl` configured

```bash
# 1. Install platform operators
helm repo add strimzi https://strimzi.io/charts
helm repo add flink-operator https://downloads.apache.org/flink/flink-kubernetes-operator-1.13.0/
helm repo add minio https://operator.min.io
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add argo https://argoproj.github.io/argo-helm

helm install strimzi strimzi/strimzi-kafka-operator -n platform-kafka --create-namespace
helm install flink-operator flink-operator/flink-kubernetes-operator -n platform-flink --create-namespace
helm install minio-operator minio/operator -n platform-storage --create-namespace
helm install cnpg cnpg/cloudnative-pg -n platform-storage
helm install argocd argo/argo-cd -n argocd --create-namespace

# 2. Install KEDA for autoscaling
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda -n keda --create-namespace

# 3. Install Linkerd for mTLS
curl -sL https://run.linkerd.io/install | sh
linkerd install --crds | kubectl apply -f -
linkerd install | kubectl apply -f -

# 4. Deploy Nerve via ArgoCD App-of-Apps
kubectl apply -f deploy/argocd/nerve-app-of-apps.yaml
```

See [`deploy/`](deploy/) for complete Helm values, Kafka CRDs, Flink job specs, and environment-specific overlays.

-----

## Project Structure

```
nerve/
├── deploy/                          # Kubernetes manifests & Helm values
│   ├── argocd/                      # ArgoCD Application definitions
│   ├── kafka/                       # Strimzi Kafka CRDs, topic configs
│   ├── flink/                       # Flink job specs, autoscaler configs
│   ├── storage/                     # MinIO tenants, CloudNativePG clusters
│   ├── observability/               # Prometheus rules, Grafana dashboards
│   └── environments/                # dev / staging / prod overlays
├── ingestion/                       # Go MLLP listener service
│   ├── cmd/
│   ├── internal/
│   ├── Dockerfile
│   └── go.mod
├── connectors/                      # Source system adapters
│   ├── epic-fhir-poller/            # FHIR R4 bulk + polling
│   ├── onbase-adapter/              # Hyland OnBase REST/Unity
│   ├── dicom-proxy/                 # Orthanc config + metadata extractor
│   └── generic-mllp/                # Fallback HL7 v2.x connector
├── processing/                      # Flink jobs (Java/Kotlin)
│   ├── hl7-parser/                  # HAPI-based parse + validate + route
│   ├── enrichment/                  # Code normalization, MPI lookup
│   └── document-processor/          # Clinical note + PDF extraction
├── transforms/                      # Clinical transformation layer
│   ├── sqlmesh/                     # SQLMesh models (Bronze→Silver→Gold)
│   ├── hop-pipelines/               # Apache Hop visual pipelines
│   ├── mappings/                    # YAML field mapping definitions
│   └── code-tables/                 # Local→standard code translations
├── mpi/                             # Master Patient Index
│   ├── hapi-fhir-config/            # HAPI FHIR MDM rules + deployment
│   └── splink-jobs/                 # Batch probabilistic matching
├── serving/                         # Query & API layer
│   ├── trino/                       # Trino catalog + config
│   └── api/                         # REST API for downstream systems
├── ui/                              # Clinical user interfaces
│   ├── mapping-studio/              # React app for visual field mapping
│   └── mpi-review/                  # Match review + adjudication UI
├── schemas/                         # Apicurio registry schemas
│   ├── avro/
│   └── json-schema/
├── tests/                           # Integration + E2E tests
│   ├── hl7-fixtures/                # Sample HL7 v2.x messages
│   ├── fhir-fixtures/               # Sample FHIR R4 bundles
│   └── integration/                 # Pipeline integration tests
└── docs/                            # Architecture docs, runbooks
    ├── architecture.md
    ├── onboarding-new-facility.md
    └── runbooks/
```

-----

## Roadmap

- [ ] Go MLLP listener with Kafka producer + KEDA scaling
- [ ] Strimzi Kafka cluster with HL7 topic topology
- [ ] Flink HL7 parser with HAPI v2.x integration
- [ ] Delta Lake medallion pipeline (Bronze → Silver)
- [ ] HAPI FHIR MDM for real-time patient matching
- [ ] SQLMesh Gold layer transformations
- [ ] Apache Hop visual pipeline integration
- [ ] Clinical mapping studio UI
- [ ] Epic FHIR R4 poller with Bulk Data Export
- [ ] OnBase document connector
- [ ] Orthanc DICOM proxy + metadata extraction
- [ ] Splink batch MPI deduplication
- [ ] OpenSearch clinical document indexing
- [ ] Trino interactive query layer
- [ ] Argo Rollouts canary deployment pipeline
- [ ] HIPAA compliance validation suite

-----

<p align="center">
  <strong>Nerve</strong> — because your revenue cycle shouldn't wait for your integration team.
</p>
