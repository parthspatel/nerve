# PostgreSQL with CloudNativePG

> Kubernetes-native PostgreSQL operator for operational clinical data

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Database** | PostgreSQL 16+ |
| **Operator** | CloudNativePG |
| **Website** | [cloudnative-pg.io](https://cloudnative-pg.io) |
| **GitHub** | [cloudnative-pg/cloudnative-pg](https://github.com/cloudnative-pg/cloudnative-pg) (~4.5K stars) |
| **Latest Version** | CloudNativePG 1.24+ (2025) |
| **License** | Apache 2.0 (operator), PostgreSQL License (database) |
| **CNCF Status** | CNCF Sandbox project |
| **Nerve Role** | Operational database for transactional clinical data, HAPI FHIR backend, Hive Metastore |

---

## What Is It?

CloudNativePG is a Kubernetes operator that manages the full lifecycle of PostgreSQL clusters. Unlike Patroni-based operators (Zalando, CrunchyData), CloudNativePG is **uniquely Kubernetes-native** — it manages HA internally using K8s primitives (leader election, PodDisruptionBudgets) rather than external tools.

In Nerve, PostgreSQL serves as the **operational database** for:
- Transactional patient/encounter/order data (queried by clinical applications)
- HAPI FHIR JPA Server backend (golden records, FHIR resources)
- Hive Metastore catalog (shared between Trino and Spark)
- OpenSearch reference data
- Apicurio Registry storage

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│              CloudNativePG Cluster                         │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │       CloudNativePG Operator                       │    │
│  │  Manages: Cluster CRD, Pooler CRD, Backup CRD    │    │
│  └────────────┬─────────────────────────────────────┘    │
│               │ manages                                   │
│  ┌────────────▼─────────────────────────────────────┐    │
│  │            PostgreSQL Cluster                      │    │
│  │                                                    │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐       │    │
│  │  │Primary   │──▶│Replica-1 │  │Replica-2 │       │    │
│  │  │(read/    │  │(read-only│  │(read-only│       │    │
│  │  │ write)   │  │ standby) │  │ standby) │       │    │
│  │  └──────────┘  └──────────┘  └──────────┘       │    │
│  │       │                                           │    │
│  │  Failover: automatic (< 30s)                      │    │
│  │  Replication: synchronous (configurable)          │    │
│  │  Backups: Barman → MinIO (scheduled)              │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │       PgBouncer Pooler (Pooler CRD)               │    │
│  │  Connection pooling for high-concurrency apps      │    │
│  │  Separate read/write and read-only poolers         │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  Databases:                                               │
│  ├── nerve_clinical   (operational patient/encounter)    │
│  ├── hapi_fhir        (HAPI FHIR JPA / MDM)             │
│  ├── hive_metastore   (Trino/Spark catalog)              │
│  ├── apicurio         (schema registry)                  │
│  └── orthanc          (DICOM index)                      │
└──────────────────────────────────────────────────────────┘
```

---

## Key Features

### Automated Failover
CloudNativePG detects primary failure and promotes a replica in **< 30 seconds**. No external consensus system (no etcd, no Raft addon). Uses Kubernetes leader election natively.

### PgBouncer via Pooler CRD
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: nerve-clinical-rw
spec:
  cluster:
    name: nerve-postgresql
  instances: 3
  type: rw  # or 'ro' for read replicas
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "1000"
      default_pool_size: "50"
```

### Barman Backups to MinIO
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: nerve-postgresql
spec:
  instances: 3
  storage:
    size: 100Gi
    storageClass: fast-ssd
  backup:
    barmanObjectStore:
      destinationPath: s3://nerve-backups/postgresql
      endpointURL: https://minio.platform-storage:9000
      s3Credentials:
        accessKeyId:
          name: minio-credentials
          key: access-key
        secretAccessKey:
          name: minio-credentials
          key: secret-key
    retentionPolicy: "30d"
  postgresql:
    parameters:
      shared_buffers: "2GB"
      effective_cache_size: "6GB"
      max_connections: "200"
```

### Row-Level Security for Data Isolation

```sql
-- Create policy for facility-level data isolation
ALTER TABLE patients ENABLE ROW LEVEL SECURITY;

CREATE POLICY facility_isolation ON patients
  USING (facility_id = current_setting('app.facility_id'));

-- Application sets the facility context per connection
SET app.facility_id = 'FAC-001';
SELECT * FROM patients;  -- Only sees FAC-001 patients
```

---

## Healthcare Data Patterns

### Composite Unique Constraints
```sql
-- Prevent cross-system duplicates
CREATE UNIQUE INDEX idx_patient_unique
  ON patients (source_system, facility_id, mrn);

-- MPI golden record linkage
ALTER TABLE patients ADD COLUMN empi_id UUID REFERENCES mpi_golden_records(id);
CREATE INDEX idx_patient_empi ON patients (empi_id);
```

---

## CloudNativePG vs. Alternatives

| Feature | CloudNativePG | Zalando Postgres Operator | CrunchyData PGO |
|---------|--------------|--------------------------|-----------------|
| **HA Mechanism** | K8s-native (no Patroni) | Patroni | Patroni |
| **Failover Time** | < 30s | < 30s | < 30s |
| **PgBouncer** | Built-in (Pooler CRD) | Built-in | Built-in |
| **Backup** | Barman (to S3/MinIO) | WAL-G | pgBackRest |
| **License** | Apache 2.0 | MIT | Apache 2.0 |
| **CNCF** | Sandbox | No | No |
| **Stars** | 4.5K | 4.3K | 3.8K |
| **Philosophy** | K8s-native, no external deps | Patroni-based, battle-tested | Enterprise-focused |

**Why CloudNativePG for Nerve**: Its K8s-native HA approach (no Patroni dependency) aligns with the architecture's preference for Kubernetes primitives. Built-in PgBouncer via CRD simplifies pooling. Fastest-growing PG K8s operator.

---

## How to Leverage in Nerve

1. **Operational Queries**: Low-latency transactional queries for clinical applications
2. **HAPI FHIR Backend**: JPA store for FHIR resources and golden records
3. **Hive Metastore**: Shared catalog enabling Trino and Spark to query the same Delta tables
4. **Data Isolation**: Row-Level Security enforces facility-level access control
5. **HIPAA Audit**: Connection logging, query logging, change tracking via triggers
6. **High Availability**: Automatic failover ensures clinical applications stay online

---

## Visual References

- **CloudNativePG Architecture**: [cloudnative-pg.io/documentation](https://cloudnative-pg.io/documentation/) — Operator architecture
- **Pooler CRD**: [cloudnative-pg.io/documentation/current/connection_pooling](https://cloudnative-pg.io/documentation/current/connection_pooling/)
- **Backup/Recovery**: [cloudnative-pg.io/documentation/current/backup](https://cloudnative-pg.io/documentation/current/backup/)
