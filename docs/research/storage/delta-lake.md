# Delta Lake

> Open lakehouse storage format with ACID transactions and time travel for clinical data

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Delta Lake |
| **Organization** | Delta Lake Project (Linux Foundation) |
| **Website** | [delta.io](https://delta.io) |
| **GitHub** | [delta-io/delta](https://github.com/delta-io/delta) (~7.5K stars) |
| **Latest Version** | Delta Lake 3.2+ (2025) / Protocol: Reader v3, Writer v7 |
| **License** | Apache 2.0 |
| **Format** | Parquet files + JSON transaction log |
| **Nerve Role** | Analytical storage layer — Bronze/Silver/Gold medallion architecture for clinical data |

---

## What Is It?

Delta Lake is an open-source storage framework that brings ACID transactions, schema enforcement, time travel, and scalable metadata handling to data lakes. It stores data as Parquet files with a JSON-based transaction log (`_delta_log/`) that provides atomicity, consistency, isolation, and durability.

In Nerve, Delta Lake is the **analytical storage backbone** — raw HL7 messages are preserved in Bronze, parsed and validated data lives in Silver, and consumption-ready star-schema models in Gold.

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    Delta Lake on MinIO                       │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   MinIO (S3-compatible)                │   │
│  │                                                       │   │
│  │  s3://nerve-lakehouse/                               │   │
│  │  ├── bronze/                                         │   │
│  │  │   └── hl7_raw/                                    │   │
│  │  │       ├── _delta_log/          ◄─── Transaction   │   │
│  │  │       │   ├── 00000000000.json      log (ACID)    │   │
│  │  │       │   ├── 00000000001.json                    │   │
│  │  │       │   └── 00000000002.json                    │   │
│  │  │       ├── ingestion_date=2026-02-05/              │   │
│  │  │       │   └── source_system=epic-phoenix/         │   │
│  │  │       │       └── part-00001.parquet              │   │
│  │  │       └── ingestion_date=2026-02-06/              │   │
│  │  │           └── ...                                 │   │
│  │  ├── silver/                                         │   │
│  │  │   ├── patients/                                   │   │
│  │  │   ├── encounters/                                 │   │
│  │  │   ├── observations/                               │   │
│  │  │   └── charges/                                    │   │
│  │  └── gold/                                           │   │
│  │      ├── dim_patient/                                │   │
│  │      ├── fact_encounter/                             │   │
│  │      └── fact_claim/                                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Read by: Spark (ETL) │ Trino (queries) │ SQLMesh (xforms) │
│  Catalog: Hive Metastore (PostgreSQL-backed)                │
└────────────────────────────────────────────────────────────┘
```

### Transaction Log Mechanics

Every write operation (INSERT, UPDATE, DELETE, MERGE) creates a new JSON entry in `_delta_log/`:

```json
// _delta_log/00000000042.json
{
  "commitInfo": {
    "timestamp": 1707177600000,
    "operation": "MERGE",
    "operationParameters": {
      "predicate": "source_system = 'epic-phoenix' AND mrn = '12345'"
    }
  },
  "add": {
    "path": "silver/patients/part-00042.parquet",
    "size": 1048576,
    "modificationTime": 1707177600000,
    "dataChange": true
  },
  "remove": {
    "path": "silver/patients/part-00038.parquet",
    "deletionTimestamp": 1707177600000
  }
}
```

---

## Medallion Architecture for Clinical Data

### Bronze Layer (Raw Zone)

```
Purpose:   Preserve raw HL7 messages exactly as received
Format:    String columns (raw ER7), metadata columns
Mutability: Append-only, immutable
Partition: ingestion_date / source_system / message_type

Schema:
├── raw_message       STRING    -- Original HL7 ER7 text
├── message_type      STRING    -- ADT, ORM, ORU, DFT, MDM
├── trigger_event     STRING    -- A01, R01, O01, P03, T02
├── _source_system    STRING    -- epic-phoenix, epic-tucson
├── _facility_id      STRING    -- FAC-001, FAC-002
├── _ingestion_ts     TIMESTAMP -- When Nerve received it
├── _kafka_offset     BIGINT    -- Kafka offset for replay
└── _kafka_partition  INT       -- Kafka partition
```

### Silver Layer (Validated/Conformed)

```
Purpose:   Parsed, validated, deduplicated clinical data
Format:    Typed columns from HL7 segment parsing
Mutability: MERGE (upsert) for corrections, new records
Partition: source_system / facility_id
Clustering: Liquid Clustering on empi_id, encounter_id

Tables:
├── patients          -- PID segments → demographics
├── encounters        -- PV1 segments → visit data
├── observations      -- OBX segments → lab results, vitals
├── orders            -- OBR/ORC segments → clinical orders
├── diagnoses         -- DG1 segments → diagnosis codes (normalized)
├── charges           -- FT1 segments → financial transactions
├── documents         -- TXA/OBX segments → clinical notes metadata
└── insurance         -- IN1 segments → coverage data
```

### Gold Layer (Consumption-Ready)

```
Purpose:   Unified star schema for analytics and reporting
Format:    Denormalized, optimized for query performance
Mutability: Full rebuild (SQLMesh incremental)
Optimization: Z-ordering on high-cardinality join columns

Dimensions:
├── dim_patient       -- MPI golden record, SCD Type 2
├── dim_provider      -- Attending/ordering/referring
├── dim_facility      -- Facility master data
├── dim_diagnosis     -- ICD-10 code hierarchy
└── dim_procedure     -- CPT code hierarchy

Facts:
├── fact_encounter    -- Visit-level facts (LOS, charges, DRG)
├── fact_claim        -- Claim-level facts (charges, payments, denials)
├── fact_observation  -- Observation-level facts (lab values, vitals)
└── fact_order        -- Order-level facts (turnaround time, completion)

Reports:
├── rpt_denial_rates  -- Denial rate by payer, facility, diagnosis
├── rpt_ar_aging      -- Accounts receivable aging buckets
├── rpt_charge_capture-- Charge capture completeness by encounter type
└── rpt_quality       -- HEDIS measures, readmission rates
```

---

## Key Features for Healthcare

### Time Travel (HIPAA Audit)

```sql
-- Query patient data as it existed at a specific point in time
SELECT * FROM silver.patients
  VERSION AS OF 42;

-- Or by timestamp
SELECT * FROM silver.patients
  TIMESTAMP AS OF '2026-02-01 00:00:00';

-- Full audit history
DESCRIBE HISTORY silver.patients;
```

Time travel satisfies **HIPAA** and **21 CFR Part 11** requirements for reproducing clinical data states at any historical point.

### Change Data Feed (Row-Level Audit)

```sql
-- Enable CDC tracking
ALTER TABLE silver.patients
  SET TBLPROPERTIES (delta.enableChangeDataFeed = true);

-- Query changes between versions
SELECT * FROM table_changes('silver.patients', 40, 42);
-- Returns: _change_type (insert/update_preimage/update_postimage/delete)
```

### MERGE for Patient Record Updates

```sql
MERGE INTO silver.patients AS target
USING staging.new_patients AS source
ON target.source_system = source.source_system
   AND target.facility_id = source.facility_id
   AND target.mrn = source.mrn
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *;
```

### Schema Evolution

```sql
-- Add new column without rewriting data
ALTER TABLE silver.patients ADD COLUMN email STRING;

-- Auto-merge schema on write
spark.conf.set("spark.databricks.delta.schema.autoMerge.enabled", "true")
```

---

## Delta Lake vs. Alternatives

| Feature | Delta Lake | Apache Iceberg | Apache Hudi |
|---------|-----------|---------------|-------------|
| **ACID Transactions** | Yes | Yes | Yes |
| **Time Travel** | Yes (version + timestamp) | Yes (snapshot) | Yes (timeline) |
| **MERGE/Upsert** | Mature, performant | Mature | Native (MoR/CoW) |
| **Schema Evolution** | Yes | Yes (more flexible) | Yes |
| **Spark Integration** | Best (Databricks native) | Excellent | Good |
| **Trino Support** | Good (connector) | Excellent (native) | Good |
| **Flink Integration** | Preview (v0.7.0) | Better (native sink) | Good |
| **Healthcare Adoption** | High (Databricks reference) | Growing | Limited |
| **Community** | 7.5K stars | 6.5K stars | 5.5K stars |
| **License** | Apache 2.0 | Apache 2.0 | Apache 2.0 |
| **Liquid Clustering** | Yes (auto-optimize) | Sort orders | Clustering index |
| **Change Data Feed** | Yes | Yes (incremental reads) | Yes (CDC native) |

**Why Delta Lake for Nerve**: Superior Spark integration (production-proven for writes), mature MERGE operations for patient record updates, healthcare-specific reference architectures from Databricks, and time travel for HIPAA audit trails.

---

## How to Leverage in Nerve

1. **Immutable Bronze Archive**: Every HL7 message preserved in original wire format with time travel
2. **MERGE for Patient Updates**: ADT^A08 (update) messages merge into Silver patient records
3. **HIPAA Audit Trail**: Change Data Feed + time travel provides complete audit history
4. **Schema Evolution**: New HL7 fields (e.g., from system upgrades) added without rewriting data
5. **Cross-System Analytics**: Gold layer star schema enables unified queries across all facilities
6. **RCM Reporting**: Gold layer report tables power denial analysis, A/R aging, charge capture dashboards
7. **Data Quality**: Delta Lake's schema enforcement prevents corrupt data from entering Silver/Gold

---

## Visual References

- **Delta Lake Architecture**: [delta.io/learn](https://delta.io/learn/) — Architecture overview
- **Medallion Architecture**: [databricks.com/glossary/medallion-architecture](https://www.databricks.com/glossary/medallion-architecture) — Bronze/Silver/Gold pattern
- **Transaction Log Internals**: [delta.io/blog/delta-lake-transaction-log](https://delta.io/blog/2019-08-02-delta-lake-transaction-log/) — How the log works
- **Healthcare Reference**: Databricks Clinical Health Data Lake reference architecture
