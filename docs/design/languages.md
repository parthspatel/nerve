# Nerve — Language Strategy and Codebase Design

> Defines the primary languages, their roles in the architecture, and rationale for selection.

---

## Language Map

| Layer | Language | Runtime | Rationale |
|-------|----------|---------|-----------|
| **MLLP Ingestion** | Go 1.22+ | Native binary | Goroutine-per-connection model, sub-ms ACK latency, 20-50 MB container, Google mllp reference |
| **Stream Processing** | Java 21 (LTS) | JVM (Flink) | HAPI HL7v2 library requires JVM, Flink native, sbt + Maven Central for healthcare libs |
| **Batch ETL / MPI** | Python 3.12+ | CPython | Splink (probabilistic MPI), PySpark, SQLMesh CLI, data science tooling |
| **SQL Transforms** | SQL (ANSI + Spark dialect) | SQLMesh / Trino / Spark | Declarative transforms on Delta Lake, accessible to clinical analysts |
| **Clinical Mapping UI** | TypeScript 5.x | Node.js 22 (LTS) | React mapping studio, MPI review UI, modern frontend toolchain |
| **Visual Pipelines** | Apache Hop XML/JSON | Hop Engine / Beam | No-code visual definitions, 400+ plugins, executed on Flink/Spark via Beam |
| **Infrastructure** | Nix + YAML + HCL | devenv / Helm / Terraform | Reproducible dev environments, K8s manifests, GitOps declarations |
| **Connectors** | Go / Python | Native / CPython | Go for high-throughput connectors (FHIR poller, OnBase adapter), Python for DICOM metadata |
| **Schema Definitions** | Avro / JSON Schema | Apicurio Registry | Kafka topic schemas, backwards-compatible evolution |
| **Scripts & Glue** | Bash / Python | Shell | CI/CD scripts, one-off data utilities, devenv hooks |

---

## Primary Languages — Detailed Rationale

### Go (Ingestion + High-Throughput Connectors)

**Version**: Go 1.22+ (latest stable)

Go is the primary language for all network-facing ingestion services:

- **MLLP Listener Service** (`ingestion/`): The core HL7 v2.x TCP listener. Go's goroutine-per-connection model maps directly to MLLP's pattern of few long-lived TCP connections from sending systems. Each goroutine costs ~2 KB of stack memory vs. OS threads at 1-8 MB, allowing a single pod to handle thousands of concurrent connections.
- **Epic FHIR Poller** (`connectors/epic-fhir-poller/`): HTTP client polling Epic's FHIR R4 APIs with Backend Systems OAuth2.
- **Generic MLLP Connector** (`connectors/generic-mllp/`): Fallback connector for non-Epic HL7 v2.x sources.

**Why Go over Rust**: Go's HL7 ecosystem is production-proven (Google's `GoogleCloudPlatform/mllp`). Rust's `hl7-mllp-codec` is experimental. Go delivers 10,000-50,000 msg/sec per pod — more than sufficient. The team velocity advantage of Go's simpler concurrency model and faster compilation outweighs Rust's theoretical throughput edge.

**Key dependencies**: `segmentio/kafka-go` or `confluent-kafka-go` for Kafka production, `prometheus/client_golang` for metrics, standard `net` for TCP.

### Java 21 (Stream Processing)

**Version**: Java 21 LTS (latest long-term support)

Java is required for the Flink processing layer due to the HAPI HL7v2 library:

- **HL7 Parser Job** (`processing/hl7-parser/`): Flink `ProcessFunction` operators wrapping HAPI HL7v2's `PipeParser` for parsing raw HL7 into typed Java objects.
- **Enrichment Job** (`processing/enrichment/`): Code normalization (local → ICD-10/SNOMED CT), MPI lookup integration, metadata enrichment.
- **Document Processor** (`processing/document-processor/`): Clinical note and PDF text extraction for OpenSearch indexing.

**Why Java over Kotlin**: While Kotlin offers syntactic improvements, Java 21 with records, sealed classes, and pattern matching closes the gap. The HAPI library and Flink documentation are Java-first. Staying with Java reduces context-switching cost for contributors from the healthcare informatics community (heavily Java-oriented).

**Build system**: sbt 1.x with the Flink Kubernetes Operator for job deployment.

### Python 3.12 (Batch MPI, Analytics, Data Science)

**Version**: Python 3.12+ (latest stable)

Python serves three critical roles:

- **Splink MPI Jobs** (`mpi/splink-jobs/`): Batch probabilistic patient matching using the Fellegi-Sunter model. Splink runs on DuckDB (development) or PySpark (production at scale).
- **SQLMesh CLI** (`transforms/sqlmesh/`): SQLMesh is a Python package that manages SQL transformation models on Delta Lake. Clinical analysts author SQL; SQLMesh handles dependency resolution, incremental execution, and virtual environments.
- **DICOM Metadata Extraction** (`connectors/dicom-proxy/`): Orthanc's Python plugin triggers `pydicom`/`highdicom` for study-level metadata extraction.

**Package management**: `uv` (Astral, Rust-based, 10-100x faster than pip) for dependency resolution. Virtual environments managed per-component.

### TypeScript 5.x (Frontend UIs)

**Version**: TypeScript 5.x on Node.js 22 LTS

TypeScript powers all user-facing clinical interfaces:

- **Mapping Studio** (`ui/mapping-studio/`): React application for visual field mapping. Drag-and-drop interface where clinical analysts map source HL7 fields to target schemas. Generates YAML mapping configurations committed to Git.
- **MPI Review UI** (`ui/mpi-review/`): Match adjudication interface for POSSIBLE_MATCH records from HAPI FHIR MDM. Clinical users review candidate matches and confirm/reject.

**Toolchain**: pnpm (workspace management), Vite (build), Vitest (unit tests), Playwright (E2E).

### SQL (Transformation Layer)

SQL is the lingua franca of the clinical transformation layer:

- **SQLMesh Models** (`transforms/sqlmesh/`): Bronze → Silver → Gold transformations expressed as SQL SELECT statements with SQLMesh macros for incremental logic.
- **Trino Queries**: Ad-hoc analytical queries against Gold layer Delta tables.
- **PostgreSQL DDL**: Operational database schema definitions with RLS policies.

SQL is chosen as the transformation language because it's the one language RCM analysts and clinical informaticists already know.

---

## Secondary Languages

### Nix (Development Environment)

The `devenv.nix` configuration defines the reproducible development environment for all contributors. Nix ensures every developer gets identical toolchains regardless of host OS.

### YAML / JSON (Configuration)

- Kubernetes manifests and Helm values
- ArgoCD Application definitions
- Clinical mapping configurations (`transforms/mappings/`)
- HAPI FHIR MDM matching rules
- Apache Hop pipeline/workflow definitions (XML/JSON)

### HCL (Infrastructure)

Terraform HCL for cloud infrastructure provisioning (VPC, load balancers, DNS) when deploying to managed Kubernetes services.

---

## Monorepo Structure by Language

```
nerve/
├── ingestion/          # Go 1.22+
│   ├── go.mod
│   ├── go.sum
│   ├── cmd/mllp-listener/
│   └── internal/
├── connectors/
│   ├── epic-fhir-poller/       # Go
│   │   └── go.mod
│   ├── onbase-adapter/         # Go
│   │   └── go.mod
│   ├── dicom-proxy/            # Python (Orthanc plugin)
│   │   └── pyproject.toml
│   └── generic-mllp/           # Go
│       └── go.mod
├── processing/         # Java 21
│   ├── build.sbt
│   ├── hl7-parser/
│   ├── enrichment/
│   └── document-processor/
├── transforms/
│   ├── sqlmesh/                # SQL + Python (SQLMesh)
│   │   └── pyproject.toml
│   ├── hop-pipelines/          # Apache Hop XML/JSON
│   ├── mappings/               # YAML
│   └── code-tables/            # CSV/YAML
├── mpi/
│   ├── hapi-fhir-config/      # YAML/JSON (HAPI config)
│   └── splink-jobs/            # Python
│       └── pyproject.toml
├── serving/
│   ├── trino/                  # SQL + YAML (config)
│   └── api/                    # Go or TypeScript
├── ui/                 # TypeScript 5.x
│   ├── mapping-studio/
│   │   └── package.json
│   └── mpi-review/
│       └── package.json
├── schemas/            # Avro / JSON Schema
├── deploy/             # YAML (Helm/K8s) + HCL (Terraform)
├── tests/              # Multi-language integration tests
├── devenv.nix          # Nix
├── devenv.yaml         # YAML
└── .envrc              # Bash
```

---

## Language Version Pinning Strategy

All language versions are pinned in `devenv.nix` for reproducibility:

| Language | Pin Location | Version Strategy |
|----------|-------------|-----------------|
| Go | `languages.go.package` | Latest stable (1.22+) |
| Java | `languages.java.jdk.package` | LTS only (21) |
| sbt | `pkgs.sbt` in `packages` | Latest stable (1.x) |
| Python | `languages.python.package` | Latest stable (3.12+) |
| Node.js | `languages.javascript.package` | LTS only (22) |
| Rust | `languages.rust.channel` | Stable (for tooling only) |

The `devenv.yaml` includes `rust-overlay` and `nixpkgs-python` inputs to provide version flexibility for Rust tooling and Python builds.

---

## Testing Strategy by Language

| Language | Unit Tests | Integration | E2E |
|----------|-----------|------------|-----|
| Go | `go test` | testcontainers-go (Kafka, PostgreSQL) | Pipeline smoke tests |
| Java | JUnit 5 + Flink MiniCluster | testcontainers (Kafka, Flink) | HL7 fixture replay |
| Python | pytest | pytest + DuckDB (Splink) | SQLMesh plan --dry-run |
| TypeScript | Vitest | Playwright component tests | Playwright E2E |
| SQL | SQLMesh audits | SQLMesh test fixtures | Gold layer assertion queries |
