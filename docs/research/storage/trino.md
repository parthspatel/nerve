# Trino

> Distributed SQL query engine for interactive analytics on Delta Lake

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Trino (formerly PrestoSQL) |
| **Website** | [trino.io](https://trino.io) |
| **GitHub** | [trinodb/trino](https://github.com/trinodb/trino) (~10K stars) |
| **Latest Version** | Trino 443+ (2025, weekly releases) |
| **License** | Apache 2.0 |
| **Language** | Java |
| **Nerve Role** | Interactive SQL analytics engine querying Gold layer Delta Lake tables |

---

## What Is It?

Trino is a distributed SQL query engine designed for fast interactive analytics against data sources of any size. It supports querying data from multiple sources (Delta Lake, PostgreSQL, OpenSearch, etc.) through a single SQL interface, without moving data.

In Nerve, Trino is the **query layer** that clinical analysts and RCM teams use to run SQL queries against Gold layer Delta Lake tables — denial rates, A/R aging, charge capture completeness, and clinical quality measures.

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    Trino Cluster                       │
│                                                       │
│  ┌──────────────────┐                                │
│  │   Coordinator     │  Query planning & optimization │
│  │   (1 pod)         │  SQL parsing → logical plan    │
│  │                   │  → physical plan → distribute  │
│  └────────┬──────────┘                                │
│           │ distribute tasks                          │
│  ┌────────▼──────────────────────────────────────┐   │
│  │              Workers (2-20 pods)                │   │
│  │                                                │   │
│  │  ┌────────┐  ┌────────┐  ┌────────┐          │   │
│  │  │Worker-0│  │Worker-1│  │ ... N  │          │   │
│  │  │        │  │        │  │        │          │   │
│  │  └────┬───┘  └────┬───┘  └────┬───┘          │   │
│  │       │           │           │               │   │
│  └───────┼───────────┼───────────┼───────────────┘   │
│          │           │           │                     │
│  ┌───────▼───────────▼───────────▼───────────────┐   │
│  │              Connectors                         │   │
│  │                                                 │   │
│  │  ┌───────────┐ ┌───────────┐ ┌──────────────┐ │   │
│  │  │Delta Lake │ │PostgreSQL │ │OpenSearch    │ │   │
│  │  │(via Hive  │ │(operational│ │(clinical    │ │   │
│  │  │ catalog)  │ │ queries)   │ │ search)     │ │   │
│  │  └───────────┘ └───────────┘ └──────────────┘ │   │
│  └─────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

---

## Performance Characteristics

| Metric | Value | Notes |
|--------|-------|-------|
| **Query latency** | Sub-second to minutes | Depends on data size/complexity |
| **Metadata cache hit rate** | 97-98% | Delta Lake connector optimization |
| **Concurrent queries** | 50-200 | With proper resource groups |
| **Data scanned** | Partition pruning reduces by 90%+ | With good partitioning strategy |
| **Memory per worker** | 8-32 GB recommended | In-memory processing |
| **Fault tolerance** | Query retry on worker failure | Task-level retry (Trino 400+) |

---

## Nerve-Specific Configuration

### Catalog Configuration

```properties
# /etc/trino/catalog/delta.properties
connector.name=delta_lake
hive.metastore.uri=thrift://hive-metastore:9083
hive.s3.endpoint=https://minio.platform-storage:9000
hive.s3.aws-access-key=${ENV:MINIO_ACCESS_KEY}
hive.s3.aws-secret-key=${ENV:MINIO_SECRET_KEY}
hive.s3.path-style-access=true
delta.enable-non-concurrent-writes=true

# Performance tuning
delta.metadata.cache-ttl=5m
delta.metadata.live-files.cache-ttl=5m
hive.s3.max-connections=500
```

### Example Queries

```sql
-- RCM: Denial rate by payer and facility
SELECT
    d.payer_name,
    f.facility_name,
    COUNT(*) AS total_claims,
    SUM(CASE WHEN c.denial_flag THEN 1 ELSE 0 END) AS denied_claims,
    ROUND(100.0 * SUM(CASE WHEN c.denial_flag THEN 1 ELSE 0 END) / COUNT(*), 2) AS denial_rate_pct
FROM gold.fact_claim c
JOIN gold.dim_patient p ON c.empi_id = p.empi_id
JOIN gold.dim_facility f ON c.facility_id = f.facility_id
LEFT JOIN gold.dim_payer d ON c.payer_id = d.payer_id
WHERE c.service_date >= DATE '2026-01-01'
GROUP BY d.payer_name, f.facility_name
ORDER BY denial_rate_pct DESC;

-- Clinical: Cross-facility patient encounter summary
SELECT
    p.empi_id,
    p.last_name,
    p.first_name,
    COUNT(DISTINCT e.encounter_id) AS total_encounters,
    COUNT(DISTINCT e.facility_id) AS facilities_visited,
    MAX(e.admission_date) AS last_admission,
    ARRAY_AGG(DISTINCT e.primary_diagnosis) AS diagnoses
FROM gold.fact_encounter e
JOIN gold.dim_patient p ON e.empi_id = p.empi_id
WHERE e.admission_date >= DATE '2025-01-01'
GROUP BY p.empi_id, p.last_name, p.first_name
HAVING COUNT(DISTINCT e.facility_id) > 1
ORDER BY total_encounters DESC;
```

---

## Kubernetes Deployment

```yaml
# Using trino/trino Helm chart
helm install trino trino/trino \
  --namespace clinical-serving \
  --set coordinator.resources.requests.memory=8Gi \
  --set coordinator.resources.requests.cpu=2 \
  --set worker.replicas=4 \
  --set worker.resources.requests.memory=16Gi \
  --set worker.resources.requests.cpu=4 \
  --values trino-values.yaml
```

### KEDA Autoscaling for Workers

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: trino-workers
  namespace: clinical-serving
spec:
  scaleTargetRef:
    name: trino-worker
  minReplicaCount: 2
  maxReplicaCount: 20
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus.platform-observability:9090
        metricName: trino_queued_queries
        query: trino_QueuedQueries{cluster="nerve-trino"}
        threshold: "5"
```

---

## How to Leverage in Nerve

1. **Interactive Analytics**: Sub-second queries on Gold layer for dashboards and ad-hoc analysis
2. **Cross-Source Queries**: Join Delta Lake tables with PostgreSQL operational data in a single query
3. **RCM Reporting**: Denial rates, A/R aging, charge capture — all queryable via standard SQL
4. **Clinical Quality**: HEDIS measures, readmission rates, patient safety indicators
5. **Data Exploration**: Analysts explore Silver layer data before defining Gold models in SQLMesh
6. **BI Tool Integration**: Trino's JDBC/ODBC drivers connect to Tableau, Power BI, Superset

---

## Trino vs. Alternatives

| Feature | Trino | Presto (Meta) | Spark SQL | DuckDB |
|---------|-------|--------------|-----------|--------|
| **Query Model** | Interactive SQL | Interactive SQL | Batch/Interactive | Embedded |
| **Latency** | Sub-second to minutes | Similar | Higher (overhead) | Milliseconds (single-node) |
| **Scalability** | Distributed | Distributed | Distributed | Single node |
| **Delta Lake** | Connector | Connector | Native | Read-only |
| **License** | Apache 2.0 | Apache 2.0 | Apache 2.0 | MIT |
| **K8s Deploy** | Helm chart | Helm chart | Operator | N/A |

---

## Visual References

- **Trino Architecture**: [trino.io/docs/current/overview/concepts.html](https://trino.io/docs/current/overview/concepts.html)
- **Delta Lake Connector**: [trino.io/docs/current/connector/delta-lake.html](https://trino.io/docs/current/connector/delta-lake.html)
- **Trino Web UI**: Built-in query monitoring dashboard at `http://coordinator:8080`
