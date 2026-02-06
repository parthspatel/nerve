# Apache Hop

> Visual drag-and-drop data pipeline designer for non-technical clinical users

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Apache Hop (Hop Orchestration Platform) |
| **Website** | [hop.apache.org](https://hop.apache.org) |
| **GitHub** | [apache/hop](https://github.com/apache/hop) (~1K stars) |
| **Latest Version** | 2.10+ (2025) |
| **License** | Apache 2.0 |
| **Language** | Java |
| **ASF Status** | Apache Top-Level Project (since 2022) |
| **Origin** | Created by Matt Casters (original Pentaho Kettle/PDI creator) |
| **Nerve Role** | Visual pipeline IDE for non-technical clinical users to design data transformations |

---

## What Is It?

Apache Hop is a data orchestration platform that provides a **visual drag-and-drop IDE** for designing data integration pipelines and workflows. It is the spiritual successor to Pentaho Data Integration (Kettle), created by the same original developer, but rewritten with a modern, metadata-driven architecture.

In Nerve, Apache Hop serves the **clinician-facing transformation layer** — enabling RCM analysts, coders, and clinical informaticists to design data mappings without writing code.

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                     Apache Hop Platform                      │
│                                                              │
│  ┌────────────────────────────┐                             │
│  │       Hop GUI              │  Desktop IDE                 │
│  │   (Visual Designer)        │  Drag-and-drop pipeline      │
│  │                            │  design with live preview     │
│  │  ┌──────┐  ┌──────────┐  │                               │
│  │  │Input │──▶│Transform │──▶│──▶ Output                   │
│  │  │      │  │          │  │                               │
│  │  └──────┘  └──────────┘  │                               │
│  └────────────────────────────┘                             │
│                                                              │
│  ┌────────────────────────────┐                             │
│  │       Hop Server           │  Headless execution server   │
│  │   (K8s Container)          │  REST API for job submission │
│  │                            │  Runs pipelines + workflows  │
│  │   Container: ~200MB        │                              │
│  │   Startup: 1-2 seconds     │                              │
│  └────────────────────────────┘                             │
│                                                              │
│  ┌────────────────────────────────────────────────────┐     │
│  │              Execution Engines                       │     │
│  │                                                      │     │
│  │  ┌──────┐  ┌───────┐  ┌───────┐  ┌─────────────┐  │     │
│  │  │Local │  │Apache │  │Apache │  │Apache       │  │     │
│  │  │Engine│  │Spark  │  │Flink  │  │Beam (GCP,   │  │     │
│  │  │      │  │       │  │       │  │ AWS, Azure) │  │     │
│  │  └──────┘  └───────┘  └───────┘  └─────────────┘  │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  Metadata-driven: Pipelines stored as XML/JSON in Git        │
│  400+ built-in plugins (transforms, inputs, outputs)         │
└────────────────────────────────────────────────────────────┘
```

---

## Key Features

### 400+ Built-In Plugins

| Category | Examples | Nerve Use |
|----------|---------|-----------|
| **Input** | Kafka Consumer, JDBC, CSV, JSON, XML, FHIR | Read from Delta Lake, Kafka |
| **Transform** | Field Mapper, Calculator, Filter, Lookup, Merge Join | HL7 field mapping, code translation |
| **Output** | Kafka Producer, JDBC, Delta Lake, JSON, Avro | Write to Silver/Gold tables |
| **Lookup** | Database Lookup, REST Lookup, Cache Lookup | MPI lookup, code table lookup |
| **Flow** | Switch/Case, Filter Rows, Abort | Conditional routing by message type |
| **Scripting** | JavaScript, Python, Groovy (for complex transforms) | Custom clinical logic |
| **Utility** | Logging, Metrics, Checksum, Execute Process | Audit trail, validation |

### Visual Pipeline Example

```
┌─────────────┐    ┌──────────────┐    ┌─────────────────┐
│ Kafka       │───▶│ JSON Parser  │───▶│ Field Selector  │
│ Consumer    │    │              │    │ (extract PID,   │
│ (hl7.parsed)│    │              │    │  PV1, OBX)      │
└─────────────┘    └──────────────┘    └────────┬────────┘
                                                │
                                   ┌────────────┴────────────┐
                                   │                         │
                          ┌────────▼────────┐    ┌──────────▼──────────┐
                          │ Code Lookup     │    │ MPI Lookup          │
                          │ (Local → ICD-10)│    │ (patient_id →       │
                          │                 │    │  empi_golden_id)    │
                          └────────┬────────┘    └──────────┬──────────┘
                                   │                         │
                                   └────────────┬────────────┘
                                                │
                                   ┌────────────▼────────────┐
                                   │ Merge / Enrich          │
                                   │ (combine fields)        │
                                   └────────────┬────────────┘
                                                │
                                   ┌────────────▼────────────┐
                                   │ Delta Lake Writer       │
                                   │ (Silver layer)          │
                                   └─────────────────────────┘
```

### Git-Native Project Structure

```
hop-pipelines/
├── projects/
│   └── nerve/
│       ├── project-config.json      # Project metadata
│       ├── pipelines/
│       │   ├── adt-to-patient.hpl   # ADT → Patient transform
│       │   ├── oru-to-results.hpl   # ORU → Lab results transform
│       │   ├── dft-to-charges.hpl   # DFT → Financial charges
│       │   └── code-normalize.hpl   # Code system normalization
│       ├── workflows/
│       │   ├── daily-transform.hwf  # Orchestrate pipeline sequence
│       │   └── mpi-refresh.hwf      # MPI batch refresh workflow
│       └── metadata/
│           ├── databases/
│           │   ├── delta-lake.json   # Delta Lake connection
│           │   └── postgresql.json   # PostgreSQL connection
│           └── run-configs/
│               ├── local.json        # Local execution config
│               └── flink.json        # Flink execution config
└── environments/
    ├── dev.json                      # Development environment
    ├── staging.json                  # Staging environment
    └── prod.json                     # Production environment
```

### Apache Beam Integration

Hop pipelines can execute on Apache Beam runners, bridging the visual design experience with production-grade distributed processing:

```
Hop Pipeline (visual design)
    ↓ compile
Apache Beam Pipeline (code)
    ↓ execute on
┌─────────┐  ┌───────────┐  ┌──────────┐
│ Flink   │  │ Spark     │  │ Direct   │
│ Runner  │  │ Runner    │  │ Runner   │
└─────────┘  └───────────┘  └──────────┘
```

This means clinicians design pipelines visually, and the same pipeline runs on Flink or Spark at scale.

---

## Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hop-server
  namespace: clinical-transforms
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: hop-server
          image: apache/hop:latest
          ports:
            - containerPort: 8080
          env:
            - name: HOP_SERVER_USER
              valueFrom:
                secretKeyRef:
                  name: hop-credentials
                  key: username
            - name: HOP_SERVER_PASS
              valueFrom:
                secretKeyRef:
                  name: hop-credentials
                  key: password
            - name: HOP_PROJECT_DIRECTORY
              value: /opt/hop/projects/nerve
          volumeMounts:
            - name: hop-projects
              mountPath: /opt/hop/projects
      volumes:
        - name: hop-projects
          configMap:
            name: hop-pipeline-configs  # Git-synced via ArgoCD
```

---

## Apache Hop vs. Alternatives

| Feature | Apache Hop | Pentaho PDI | NiFi | Airbyte |
|---------|-----------|-------------|------|---------|
| **Visual IDE** | Full drag-and-drop | Full drag-and-drop | Flow-based UI | Config-based |
| **Plugins** | 400+ | 300+ | 300+ | 350+ connectors |
| **Beam Integration** | Native (Flink/Spark) | No | No | No |
| **Git-Native** | Yes (metadata-driven) | Limited | No (XML templates) | Yes |
| **K8s Deployment** | Container + REST API | Limited | Native | Native |
| **License** | Apache 2.0 | Apache 2.0 / Comm. | Apache 2.0 | ELv2 (not OSS) |
| **Healthcare Focus** | General (extensible) | General | Common in healthcare | General |
| **Coding Required** | No (visual) | No (visual) | No (flow-based) | No (config) |
| **Execution Engines** | Local/Beam/Spark/Flink | Local/Carte | NiFi cluster | Cloud/K8s |

**Why Hop for Nerve**: Hop's Apache Beam integration means visual pipelines designed by clinicians can execute on the same Flink/Spark engines already in the architecture. Its Git-native metadata model aligns with the GitOps workflow. And its 400+ plugins cover the full range of clinical data transformations.

---

## How to Leverage in Nerve

1. **Clinician-Facing IDE**: Non-technical users (coders, RCM analysts) design data mappings visually
2. **Code Table Lookups**: Visual lookup transforms for local code → ICD-10/SNOMED/CPT translation
3. **Field Mapping**: Drag-and-drop mapping of source HL7 fields to target schema columns
4. **Workflow Orchestration**: Schedule and chain pipelines (daily transforms, MPI refresh, etc.)
5. **Beam Execution**: Run visual pipelines on Flink or Spark for production-scale processing
6. **Git Integration**: Pipeline definitions stored as Git-backed files with PR-based review
7. **Environment Management**: Separate dev/staging/prod configs without changing pipeline logic

---

## Visual References

- **Hop GUI**: [hop.apache.org/manual/latest/hop-gui/index.html](https://hop.apache.org/manual/latest/hop-gui/index.html) — Visual IDE screenshots
- **Pipeline Designer**: [hop.apache.org/manual/latest/pipeline/pipeline-editor.html](https://hop.apache.org/manual/latest/pipeline/pipeline-editor.html)
- **Transform Reference**: [hop.apache.org/manual/latest/pipeline/transforms.html](https://hop.apache.org/manual/latest/pipeline/transforms.html) — 400+ transform catalog
- **Beam Integration**: [hop.apache.org/manual/latest/pipeline/pipeline-run-configurations/beam-runner.html](https://hop.apache.org/manual/latest/pipeline/pipeline-run-configurations/beam-runner.html)

---

## Key Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Smaller community than NiFi/Airflow | Apache TLP status, active development, original Kettle community |
| Visual pipelines can become complex | Modular pipeline design, reusable sub-pipelines |
| Beam runner maturity | Start with local engine, migrate to Beam when proven |
| Clinical user training | Visual metaphor is intuitive; provide starter templates |
