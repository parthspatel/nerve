# MinIO

> High-performance S3-compatible object storage for Kubernetes

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | MinIO |
| **Website** | [min.io](https://min.io) |
| **GitHub** | [minio/minio](https://github.com/minio/minio) (~48K stars) |
| **Latest Version** | Continuous release (2025) |
| **License** | AGPLv3 (server), Apache 2.0 (client SDKs) |
| **Language** | Go |
| **K8s Operator** | MinIO Operator v7.1+ |
| **Nerve Role** | S3-compatible object storage backing Delta Lake, Flink checkpoints, and document storage |

---

## What Is It?

MinIO is a high-performance, S3-compatible object storage system designed for large-scale data infrastructure. It is Kubernetes-native, supports erasure coding for data protection, and delivers enterprise-grade performance while remaining fully open-source.

In Nerve, MinIO provides the **storage substrate** for Delta Lake (Bronze/Silver/Gold tables), Flink checkpoint storage, DICOM image storage, and clinical document archival.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│               MinIO on Kubernetes                         │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │          MinIO Operator (v7.1+)                    │    │
│  │   Manages: Tenant CRDs, TLS, encryption            │    │
│  └──────────┬───────────────────────────────────────┘    │
│             │ manages                                     │
│  ┌──────────▼───────────────────────────────────────┐    │
│  │            MinIO Tenant: nerve-storage             │    │
│  │                                                    │    │
│  │  Pool 1 (StatefulSet)         Pool 2 (optional)   │    │
│  │  ┌──────┐┌──────┐┌──────┐  ┌──────┐┌──────┐     │    │
│  │  │Pod-0 ││Pod-1 ││Pod-2 │  │Pod-3 ││Pod-4 │     │    │
│  │  │4 disk││4 disk││4 disk│  │4 disk││4 disk│     │    │
│  │  └──────┘└──────┘└──────┘  └──────┘└──────┘     │    │
│  │                                                    │    │
│  │  Erasure Coding: EC:4 (4 data + 4 parity)        │    │
│  │  Survives: up to 4 disk failures                   │    │
│  │  Consistency: Strict read-after-write              │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  Buckets:                                                 │
│  ├── nerve-lakehouse/     ← Delta Lake tables            │
│  ├── nerve-checkpoints/   ← Flink checkpoint storage     │
│  ├── nerve-documents/     ← Clinical documents (OnBase)  │
│  ├── nerve-dicom/         ← DICOM image storage          │
│  └── nerve-backups/       ← PostgreSQL Barman backups    │
└──────────────────────────────────────────────────────────┘
```

---

## Performance

| Metric | Value | Notes |
|--------|-------|-------|
| **Read throughput** | 2.6+ Tbps | Multi-node benchmark |
| **Write throughput** | 1.5+ Tbps | Multi-node benchmark |
| **GET latency (P50)** | < 1ms | Small objects |
| **PUT latency (P50)** | < 5ms | Small objects |
| **Consistency** | Strict read-after-write | Required by Delta Lake |
| **Container size** | ~100 MB | Single Go binary |
| **Startup time** | < 5 seconds | Fast scaling |

### Why Read-After-Write Consistency Matters

Delta Lake's transaction log (`_delta_log/`) requires strict consistency — a writer must be able to read its own write immediately after completion. MinIO provides this natively, unlike eventually-consistent object stores.

---

## HIPAA Compliance Features

| Feature | Detail |
|---------|--------|
| **Encryption at rest** | AES-256 with KMS integration (Vault) |
| **Encryption in transit** | Auto-TLS via operator |
| **Object Locking** | WORM (Write-Once-Read-Many) for compliance |
| **Audit Logging** | S3 API audit log to webhook/Kafka |
| **Access Control** | IAM policies, bucket policies, STS |
| **Versioning** | Object versioning for additional audit trail |
| **Retention Policies** | Governance and compliance mode retention |
| **Erasure Coding** | Data durability without RAID dependency |

### WORM Mode for HIPAA

```bash
# Enable object locking on bucket (WORM)
mc mb --with-lock nerve-lakehouse/bronze

# Set compliance retention (cannot be shortened)
mc retention set --default COMPLIANCE 2190d nerve-lakehouse/bronze
# 2190 days = 6 years (HIPAA retention requirement)
```

---

## Kubernetes Deployment

```yaml
apiVersion: minio.min.io/v2
kind: Tenant
metadata:
  name: nerve-storage
  namespace: platform-storage
spec:
  image: minio/minio:latest
  pools:
    - servers: 4
      volumesPerServer: 4
      volumeClaimTemplate:
        spec:
          storageClassName: fast-ssd
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Ti
  requestAutoCert: true
  features:
    bucketDNS: true
  env:
    - name: MINIO_STORAGE_CLASS_STANDARD
      value: "EC:4"
  externalCertSecret:
    - name: nerve-minio-tls
      type: kubernetes.io/tls
```

---

## How to Leverage in Nerve

1. **Delta Lake Storage**: All Bronze/Silver/Gold Parquet files stored in MinIO buckets
2. **Flink Checkpoints**: Distributed snapshots for exactly-once recovery
3. **Document Storage**: OnBase-imported clinical documents (PDFs, TIFFs)
4. **DICOM Storage**: Radiology images proxied through Orthanc
5. **PostgreSQL Backups**: Barman backups from CloudNativePG
6. **WORM Compliance**: 6-year HIPAA retention on Bronze layer
7. **Lifecycle Policies**: Auto-tier cold data to cheaper storage classes

---

## MinIO vs. Alternatives

| Feature | MinIO | Ceph (RADOS Gateway) | SeaweedFS |
|---------|-------|---------------------|-----------|
| **S3 Compatibility** | Full | Good | Good |
| **Performance** | 2.6+ Tbps | Lower (more overhead) | Competitive |
| **K8s Operator** | Official (v7.1+) | Rook Operator | Helm chart |
| **Erasure Coding** | Built-in | Built-in | Built-in |
| **Operational Complexity** | Low | High | Medium |
| **WORM/Compliance** | Full | Limited | Limited |
| **License** | AGPLv3 | LGPL 2.1 | Apache 2.0 |
| **Community** | 48K stars | 14K stars | 22K stars |

---

## Visual References

- **MinIO Architecture**: [min.io/docs/minio/kubernetes/upstream](https://min.io/docs/minio/kubernetes/upstream/) — K8s deployment docs
- **Erasure Coding**: [min.io/docs/minio/linux/operations/concepts/erasure-coding.html](https://min.io/docs/minio/linux/operations/concepts/erasure-coding.html)
- **MinIO Console UI**: Web-based management console for bucket/user management
