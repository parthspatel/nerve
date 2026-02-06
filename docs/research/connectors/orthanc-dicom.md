# Orthanc — Open-Source DICOM Server

> Lightweight DICOM server and DICOMweb proxy for medical imaging metadata

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Orthanc |
| **Website** | [orthanc-server.com](https://www.orthanc-server.com) |
| **GitHub** | [jodogne/OrthancMirror](https://github.com/jodogne/OrthancMirror) (~600 stars, official hg mirror) |
| **Latest Version** | Orthanc 1.12+ (2025) |
| **License** | GPLv3 (server), plugins have varied licenses |
| **Language** | C++ (server), Python/Lua (plugins) |
| **Docker Pulls** | 1M+ |
| **Nerve Role** | DICOM proxy for PACS metadata extraction and DICOMweb API exposure |

---

## What Is It?

Orthanc is a lightweight, standalone DICOM server designed for medical imaging. It receives DICOM studies from PACS/modalities via C-Store, provides DICOMweb APIs for modern access patterns, and supports extensibility through Python and Lua plugins.

In Nerve, Orthanc serves as the **DICOM proxy and metadata extraction layer** — receiving imaging studies from PACS, extracting study-level metadata (PatientID, StudyDate, Modality, AccessionNumber), and pushing it to the `dicom.metadata` Kafka topic for indexing.

---

## Architecture in Nerve

```
┌──────────────────────────────────────────────────────────┐
│                  DICOM Pipeline                            │
│                                                           │
│  PACS/Modality                                            │
│       │                                                   │
│       │ DICOM C-Store (port 4242)                        │
│       ▼                                                   │
│  ┌──────────────────────────────────────────────────┐    │
│  │            Orthanc Proxy Pods (K8s)                │    │
│  │                                                    │    │
│  │  ┌──────────────┐  ┌───────────────────────┐     │    │
│  │  │ DICOM Server  │  │ DICOMweb Plugin       │     │    │
│  │  │ (C-Store SCP) │  │ (WADO-RS, QIDO-RS,   │     │    │
│  │  │               │  │  STOW-RS)              │     │    │
│  │  └──────┬────────┘  └───────────────────────┘     │    │
│  │         │                                          │    │
│  │  ┌──────▼────────────────────────────────┐        │    │
│  │  │ Python Plugin                          │        │    │
│  │  │ (metadata extraction via pydicom)      │        │    │
│  │  │                                        │        │    │
│  │  │ Extract:                               │        │    │
│  │  │ • PatientID (link to MRN)             │        │    │
│  │  │ • StudyDate, StudyTime                │        │    │
│  │  │ • Modality (CT, MR, XR, US, etc.)    │        │    │
│  │  │ • AccessionNumber                      │        │    │
│  │  │ • BodyPartExamined                     │        │    │
│  │  │ • StudyDescription                     │        │    │
│  │  │ • ReferringPhysician                   │        │    │
│  │  │ • NumberOfSeries, NumberOfInstances    │        │    │
│  │  └──────┬─────────────────────────────────┘        │    │
│  │         │                                          │    │
│  │  ┌──────▼────────┐                                │    │
│  │  │ Kafka Producer │  → dicom.metadata topic       │    │
│  │  └───────────────┘                                │    │
│  │                                                    │    │
│  │  Backend: PostgreSQL (shared across Orthanc pods) │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  Downstream:                                              │
│  Kafka → Flink → Delta Lake (metadata)                   │
│                → OpenSearch (searchable studies)          │
└──────────────────────────────────────────────────────────┘
```

---

## DICOMweb APIs

| API | Method | Description |
|-----|--------|-------------|
| **QIDO-RS** | GET | Query for studies/series/instances |
| **WADO-RS** | GET | Retrieve DICOM objects/metadata/rendered images |
| **STOW-RS** | POST | Store DICOM objects via HTTP |

```bash
# Query studies for a patient
GET /dicom-web/studies?PatientID=MRN12345&StudyDate=20260205

# Retrieve study metadata
GET /dicom-web/studies/{studyUID}/metadata

# Retrieve rendered image (JPEG)
GET /dicom-web/studies/{studyUID}/series/{seriesUID}/instances/{instanceUID}/rendered
```

---

## Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orthanc
  namespace: clinical-ingestion
spec:
  replicas: 2  # Horizontal scaling with shared PostgreSQL
  template:
    spec:
      containers:
        - name: orthanc
          image: orthancteam/orthanc:latest
          ports:
            - containerPort: 4242  # DICOM
            - containerPort: 8042  # HTTP/DICOMweb
          env:
            - name: ORTHANC__POSTGRESQL__HOST
              value: postgresql.platform-storage
            - name: ORTHANC__DICOM_WEB__ENABLE
              value: "true"
          volumeMounts:
            - name: orthanc-config
              mountPath: /etc/orthanc
            - name: orthanc-plugins
              mountPath: /etc/orthanc/plugins
```

---

## Orthanc vs. Alternatives

| Feature | Orthanc | dcm4chee Archive 5 | Horos/OsiriX |
|---------|---------|-------------------|--------------|
| **Weight** | Lightweight (~20MB) | Heavy (WildFly+LDAP+Keycloak) | Desktop app |
| **DICOMweb** | Plugin (official) | Native | Limited |
| **K8s Scaling** | Horizontal (shared PG) | Complex | Not applicable |
| **Python Plugins** | Native | No | No |
| **IHE Profiles** | Basic | Comprehensive | Basic |
| **License** | GPLv3 | Various (MPL/LGPL) | LGPL |
| **Operational Complexity** | Low | High | Low (desktop) |
| **Healthcare Enterprise** | Growing | Mature | Research/small |

---

## How to Leverage in Nerve

1. **DICOM Proxy**: Receive studies from PACS without exposing internal storage
2. **Metadata Extraction**: Python plugin extracts study-level metadata for indexing
3. **Kafka Integration**: Metadata published to `dicom.metadata` topic for Flink processing
4. **DICOMweb APIs**: Modern HTTP access to imaging data for clinical applications
5. **Patient Linking**: PatientID from DICOM mapped to MRN for MPI linking
6. **OpenSearch Indexing**: Study metadata searchable alongside clinical notes and lab results

---

## Visual References

- **Orthanc Explorer**: [orthanc-server.com/static.php?page=demo](https://www.orthanc-server.com/static.php?page=demo) — Live demo instance
- **DICOMweb Plugin**: [orthanc.uclouvain.be/book/plugins/dicomweb.html](https://orthanc.uclouvain.be/book/plugins/dicomweb.html) — Plugin documentation
- **korthweb**: Kubernetes manifests with Istio ingress and Prometheus observability for Orthanc
