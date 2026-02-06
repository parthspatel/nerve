# SQLMesh

> Next-generation SQL transformation framework with state tracking and virtual environments

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | SQLMesh |
| **Company** | Tobiko Data |
| **Website** | [sqlmesh.com](https://sqlmesh.com) |
| **GitHub** | [TobikoData/sqlmesh](https://github.com/TobikoData/sqlmesh) (~2K stars) |
| **Latest Version** | 0.135+ (2025, rapid release cycle) |
| **License** | Apache 2.0 |
| **Language** | Python (CLI + engine), SQL (models) |
| **Nerve Role** | SQL transformation engine for Bronze → Silver → Gold medallion pipeline on Delta Lake |

---

## What Is It?

SQLMesh is an open-source data transformation framework that manages SQL-based transformations with built-in state tracking, virtual environments, and a plan/apply workflow. It is the successor-in-spirit to dbt-core, designed to address dbt's limitations around incremental processing, environment management, and execution efficiency.

In Nerve, SQLMesh manages the **Silver → Gold** transformation layer on Delta Lake, where clinical data is normalized, deduplicated, and shaped into star-schema models for Trino analytics.

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                       SQLMesh Engine                        │
│                                                             │
│  ┌─────────────────────┐   ┌──────────────────────────┐   │
│  │   SQL Models         │   │   SQLGlot Parser          │   │
│  │   (Git-backed)       │   │   (Column-level lineage)  │   │
│  │                      │   │                           │   │
│  │  models/             │   │  Parses SQL into AST      │   │
│  │  ├── bronze/         │   │  Detects breaking changes │   │
│  │  ├── silver/         │   │  Resolves dependencies    │   │
│  │  └── gold/           │   └──────────────────────────┘   │
│  └─────────────────────┘                                    │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                State Tracker                          │   │
│  │  Tracks: which models changed, which data changed,   │   │
│  │  which downstream models need rebuild                 │   │
│  │                                                       │   │
│  │  Result: Only rebuild affected models (9x faster)     │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Virtual Environments                     │   │
│  │  dev/  ─── points to same physical tables ───▶ prod/ │   │
│  │  Only modified models get new physical versions       │   │
│  │  Instant switch: no full rebuild needed               │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Execution Engines: Spark │ Trino │ DuckDB │ BigQuery      │
└────────────────────────────────────────────────────────────┘
```

---

## SQLMesh vs. dbt-core

| Feature | SQLMesh | dbt-core |
|---------|---------|----------|
| **Execution Speed** | ~9x faster (incremental state tracking) | Full graph evaluation every run |
| **Virtual Environments** | Instant (pointer swap, no physical rebuild) | Full clone or schema rebuild |
| **Breaking Change Detection** | Automatic (AST-based) | Manual (documentation-only) |
| **Column-Level Lineage** | Built-in (via SQLGlot) | Requires dbt Cloud (paid) |
| **Plan/Apply Workflow** | Native (like Terraform) | Run-based (imperative) |
| **State Management** | Built-in state store | dbt artifacts (JSON files) |
| **Incremental Models** | Smart (only changed data + affected models) | Rebuild all incremental models |
| **Python Models** | Supported | Supported |
| **Testing** | Built-in audits + unit tests | dbt tests |
| **License** | Apache 2.0 | Apache 2.0 |
| **Delta Lake Support** | Via Spark/Databricks engine | Via dbt-spark/dbt-databricks |
| **Community Size** | Growing (~2K stars) | Very large (~10K stars) |

### The 9x Speed Claim

SQLMesh's state tracker knows:
1. Which SQL model files changed since last run
2. Which columns in those models changed
3. Which downstream models depend on those columns
4. Which data partitions are new/modified

Result: On a typical run where 2 of 50 models changed, SQLMesh rebuilds only those 2 models and their direct dependents. dbt evaluates the entire DAG.

---

## Nerve-Specific SQLMesh Models

### Model Organization

```
transforms/sqlmesh/
├── config.yaml              # SQLMesh configuration
├── models/
│   ├── bronze/
│   │   └── stg_hl7_raw.sql            # Stage raw HL7 from Delta Bronze
│   ├── silver/
│   │   ├── patients.sql                # Parsed patient demographics
│   │   ├── encounters.sql              # Parsed visit/encounter data
│   │   ├── observations.sql            # Lab results and vitals
│   │   ├── orders.sql                  # Clinical orders
│   │   ├── diagnoses.sql               # Diagnosis codes (normalized)
│   │   ├── charges.sql                 # DFT financial transactions
│   │   └── documents.sql               # Clinical notes metadata
│   └── gold/
│       ├── dim_patient.sql             # Patient dimension (MPI-linked)
│       ├── dim_provider.sql            # Provider dimension
│       ├── dim_facility.sql            # Facility dimension
│       ├── fact_encounter.sql          # Encounter facts
│       ├── fact_claim.sql              # Claims/charges facts
│       ├── fact_observation.sql        # Observation facts
│       ├── rpt_denial_rates.sql        # RCM denial analysis
│       ├── rpt_ar_aging.sql            # Accounts receivable aging
│       └── rpt_charge_capture.sql      # Charge capture completeness
├── audits/
│   ├── patient_mrn_not_null.sql        # Data quality checks
│   ├── encounter_dates_valid.sql
│   └── diagnosis_code_valid.sql
├── tests/
│   └── test_patient_dedup.yaml         # Unit tests with fixtures
└── macros/
    ├── normalize_icd10.sql             # ICD-10 code normalization
    └── parse_hl7_datetime.sql          # HL7 datetime parsing
```

### Example Silver Model

```sql
-- models/silver/patients.sql
MODEL (
    name silver.patients,
    kind INCREMENTAL_BY_TIME_RANGE (
        time_column ingestion_ts,
        batch_size 1,
        batch_concurrency 4
    ),
    cron '@hourly',
    grain (source_system, facility_id, mrn),
    tags ['silver', 'clinical']
);

SELECT
    source_system,
    facility_id,
    pid_patient_id AS mrn,
    pid_family_name AS last_name,
    pid_given_name AS first_name,
    pid_middle_name AS middle_name,
    CAST(pid_dob AS DATE) AS date_of_birth,
    pid_sex AS sex,
    pid_race AS race,
    pid_address_street AS address_line1,
    pid_address_city AS city,
    pid_address_state AS state,
    pid_address_zip AS zip_code,
    pid_phone_home AS phone,
    pid_ssn AS ssn_hash,  -- hashed at ingestion
    empi_id,              -- from MPI lookup
    ingestion_ts,
    CURRENT_TIMESTAMP() AS processed_ts
FROM bronze.hl7_parsed_adt
WHERE
    message_type = 'ADT'
    AND trigger_event IN ('A01', 'A04', 'A08', 'A28', 'A31')
    AND ingestion_ts BETWEEN @start_ts AND @end_ts
```

### Example Gold Model

```sql
-- models/gold/dim_patient.sql
MODEL (
    name gold.dim_patient,
    kind SCD_TYPE_2 (
        unique_key empi_id,
        valid_from_name valid_from,
        valid_to_name valid_to,
        updated_at_name updated_at
    ),
    grain (empi_id),
    tags ['gold', 'dimension']
);

SELECT
    empi_id,
    FIRST_VALUE(mrn) OVER (PARTITION BY empi_id ORDER BY ingestion_ts) AS primary_mrn,
    last_name,
    first_name,
    middle_name,
    date_of_birth,
    sex,
    race,
    address_line1,
    city,
    state,
    zip_code,
    phone,
    COUNT(DISTINCT source_system) OVER (PARTITION BY empi_id) AS source_system_count,
    COLLECT_SET(source_system) OVER (PARTITION BY empi_id) AS source_systems,
    processed_ts AS updated_at
FROM silver.patients
```

---

## Plan/Apply Workflow

```bash
# Preview changes (like terraform plan)
$ sqlmesh plan dev
======= Summary =======
Models:
├── silver.patients (modified)
│   └── Column changes: +address_line2
├── gold.dim_patient (indirect modification)
└── gold.rpt_charge_capture (no change, skipped)

Backfill: 2 models, 24 hours of data
Breaking changes: None detected

Apply? [y/n]:

# Apply to production
$ sqlmesh plan prod --auto-apply
```

---

## How to Leverage in Nerve

1. **Medallion Pipeline**: Bronze → Silver parsing and normalization, Silver → Gold star schema modeling
2. **Incremental Processing**: Only process new/changed data each run (~9x faster than full rebuild)
3. **Virtual Environments**: Develop and test transformation changes without affecting production
4. **Schema Evolution**: Automatic detection of breaking vs. non-breaking changes before deployment
5. **Column-Level Lineage**: Track data flow from raw HL7 fields through to Gold layer columns
6. **Audit/Testing**: Built-in data quality assertions and unit test framework
7. **GitOps Integration**: SQL models in Git, PR-reviewed, CI-validated, ArgoCD-deployed

---

## Visual References

- **SQLMesh UI**: [sqlmesh.com/docs](https://sqlmesh.com/docs/) — Web UI for plan visualization
- **SQLMesh Lineage**: Column-level lineage visualization built into the web UI
- **Plan/Apply Workflow**: [sqlmesh.com/docs/concepts/plans](https://sqlmesh.com/docs/concepts/plans/) — Plan documentation
- **Virtual Environments**: [sqlmesh.com/docs/concepts/environments](https://sqlmesh.com/docs/concepts/environments/) — Environment docs

---

## Key Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Smaller community than dbt | Apache 2.0 license, growing adoption, active development |
| Learning curve for dbt-experienced teams | SQLMesh has dbt compatibility mode for migration |
| Spark engine complexity | SQLMesh abstracts Spark execution; DuckDB for local dev |
| State store corruption | PostgreSQL-backed state store with regular backups |
