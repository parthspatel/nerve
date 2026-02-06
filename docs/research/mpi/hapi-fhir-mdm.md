# HAPI FHIR JPA Server with MDM Module

> FHIR-native Master Patient Index with Golden Record management

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | HAPI FHIR |
| **Website** | [hapifhir.io](https://hapifhir.io) |
| **GitHub** | [hapifhir/hapi-fhir](https://github.com/hapifhir/hapi-fhir) (~2.1K stars) |
| **Latest Version** | HAPI FHIR 7.6+ (2025) |
| **License** | Apache 2.0 |
| **Language** | Java (Spring Boot) |
| **Nerve Role** | Real-time deterministic patient matching and Golden Record management |

---

## What Is It?

HAPI FHIR is the reference open-source Java implementation of the HL7 FHIR specification. The **JPA Server** is a complete FHIR server with a relational database backend (PostgreSQL, MySQL, H2). The **MDM (Master Data Management) module** adds patient matching, golden record management, and deduplication capabilities.

In Nerve, HAPI FHIR MDM serves as the **real-time component of the hybrid MPI** — processing every incoming ADT message for deterministic patient matching and maintaining canonical "Golden Patient" records.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│              HAPI FHIR JPA Server + MDM                    │
│                                                            │
│  ┌───────────────────────────────────────────────────┐    │
│  │                 FHIR REST API                       │    │
│  │   POST /Patient          (create new patient)       │    │
│  │   POST /$mdm-submit      (submit for matching)      │    │
│  │   POST /$mdm-merge       (merge golden records)     │    │
│  │   GET  /Patient?_mdm=true (MDM search expansion)   │    │
│  └──────────────────────┬────────────────────────────┘    │
│                         │                                  │
│  ┌──────────────────────▼────────────────────────────┐    │
│  │                 MDM Engine                           │    │
│  │                                                      │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │        Matching Rules (JSON config)          │    │    │
│  │  │                                              │    │    │
│  │  │  Candidate Search:                           │    │    │
│  │  │  • First name (Soundex)                      │    │    │
│  │  │  • Last name (Cologne phonetic)              │    │    │
│  │  │  • DOB (exact + fuzzy)                       │    │    │
│  │  │                                              │    │    │
│  │  │  Match Fields:                               │    │    │
│  │  │  • Name: Jaro-Winkler (threshold: 0.8)      │    │    │
│  │  │  • DOB: exact match                          │    │    │
│  │  │  • SSN: exact match (when available)         │    │    │
│  │  │  • Address: Levenshtein distance             │    │    │
│  │  │  • Phone: exact (normalized)                 │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  │                                                      │    │
│  │  Match Classification:                               │    │
│  │  ├── MATCH            → Auto-link to golden record  │    │
│  │  ├── POSSIBLE_MATCH   → Queue for manual review     │    │
│  │  ├── POSSIBLE_DUPLICATE → Flag existing records     │    │
│  │  └── NO_MATCH         → Create new golden record    │    │
│  └──────────────────────────────────────────────────┘    │
│                                                            │
│  ┌──────────────────────────────────────────────────┐    │
│  │           Golden Record Store                      │    │
│  │                                                    │    │
│  │  Golden Patient ◄─── Patient.link references       │    │
│  │  (GOLD-12345)        ├── Source: Epic-Phoenix      │    │
│  │                      ├── Source: Epic-Tucson        │    │
│  │                      └── Source: FHIR-Poller        │    │
│  └──────────────────────────────────────────────────┘    │
│                                                            │
│  Backend: PostgreSQL (via CloudNativePG)                   │
│  Deployment: Spring Boot on K8s (Helm chart)              │
└──────────────────────────────────────────────────────────┘
```

---

## Matching Algorithms

| Algorithm | Field | Description | Precision |
|-----------|-------|-------------|-----------|
| **Soundex** | First/Last name | Phonetic code (American English) | Moderate |
| **Cologne Phonetic** | Name | German-origin phonetic algorithm | Good for diverse names |
| **Jaro-Winkler** | Name, Address | String similarity (0-1 score) | High |
| **Levenshtein** | Address | Edit distance | High |
| **Exact** | DOB, SSN, MRN | Exact string comparison | Highest |
| **Normalized** | Phone, Email | Normalize then exact compare | High |

### Matching Rules Configuration

```json
{
  "candidateSearchParams": [
    {
      "resourceType": "Patient",
      "searchParams": ["given", "family", "birthdate"]
    }
  ],
  "candidateFilterParams": [],
  "matchFields": [
    {
      "name": "family-name",
      "resourceType": "Patient",
      "resourcePath": "name.family",
      "fhirPath": "name.family",
      "matcher": {
        "algorithm": "JARO_WINKLER",
        "exact": false
      },
      "similarity": {
        "matchThreshold": 0.8,
        "possibleMatchThreshold": 0.6
      }
    },
    {
      "name": "given-name",
      "resourceType": "Patient",
      "resourcePath": "name.given",
      "matcher": { "algorithm": "SOUNDEX" }
    },
    {
      "name": "birthdate",
      "resourceType": "Patient",
      "resourcePath": "birthDate",
      "matcher": { "algorithm": "STRING", "exact": true }
    }
  ],
  "matchResultAuthorization": {
    "MATCH": "link",
    "POSSIBLE_MATCH": "queue_for_review",
    "NO_MATCH": "create_new_golden"
  }
}
```

---

## Golden Record Management

### Patient.link References

```json
{
  "resourceType": "Patient",
  "id": "golden-12345",
  "meta": { "tag": [{ "system": "http://hapifhir.io/fhir/StructureDefinition/mdm-record-type", "code": "GOLDEN_RECORD" }] },
  "name": [{ "family": "Doe", "given": ["John"] }],
  "birthDate": "1980-01-01",
  "link": [
    {
      "other": { "reference": "Patient/epic-phoenix-mrn-12345" },
      "type": "seealso"
    },
    {
      "other": { "reference": "Patient/epic-tucson-mrn-67890" },
      "type": "seealso"
    }
  ]
}
```

### MDM Operations

| Operation | Endpoint | Description |
|-----------|----------|-------------|
| **Submit for matching** | `POST /$mdm-submit` | Process a new Patient through matching rules |
| **Query golden records** | `GET /Patient?_mdm=true` | Search across all linked patients |
| **Merge golden records** | `POST /$mdm-merge` | Merge two golden records into one |
| **Unmerge** | `POST /$mdm-unmerge` | Reverse a merge operation |
| **Review matches** | `GET /$mdm-query-links` | List POSSIBLE_MATCH records for review |
| **Update link** | `POST /$mdm-update-link` | Change match classification |

---

## Integration with Nerve Pipeline

```
ADT^A01 (Admission)
    │
    ▼
[Flink HL7 Parser]
    │
    ├── Extract PID segment → Patient demographics
    │
    ▼
[FHIR Converter]
    │
    ├── Convert PID → FHIR Patient resource
    │
    ▼
[HAPI FHIR MDM]
    │
    ├── POST /Patient → triggers MDM matching
    │
    ├── Result: MATCH → link to Golden Record GOLD-12345
    │           empi_id injected into downstream data
    │
    ├── Result: POSSIBLE_MATCH → queue for MPI Review UI
    │
    └── Result: NO_MATCH → create new Golden Record GOLD-99999
```

---

## Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hapi-fhir-server
  namespace: clinical-serving
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: hapi-fhir
          image: hapiproject/hapi:latest
          ports:
            - containerPort: 8080
          env:
            - name: SPRING_DATASOURCE_URL
              value: jdbc:postgresql://postgresql.platform-storage:5432/hapi_fhir
            - name: HAPI_FHIR_MDM_ENABLED
              value: "true"
          resources:
            requests:
              memory: 4Gi
              cpu: "2"
            limits:
              memory: 8Gi
              cpu: "4"
```

---

## How to Leverage in Nerve

1. **Real-Time Matching**: Every ADT message triggers immediate patient matching (< 100ms)
2. **Golden Record Unification**: Single canonical patient record across all facilities
3. **MDM Search Expansion**: Query for a patient and automatically get results across all linked records
4. **Manual Review Workflow**: POSSIBLE_MATCH records queued for clinical review in MPI Review UI
5. **Merge/Unmerge**: Support for merging confirmed duplicates and reversing incorrect merges
6. **FHIR-Native**: Standards-based API means interoperability with any FHIR-aware system
7. **Splink Integration**: Batch Splink results feed back into HAPI via `$mdm-submit`

---

## Visual References

- **HAPI FHIR Documentation**: [hapifhir.io/hapi-fhir/docs](https://hapifhir.io/hapi-fhir/docs/) — Complete documentation
- **MDM Module**: [hapifhir.io/hapi-fhir/docs/server_jpa_mdm](https://hapifhir.io/hapi-fhir/docs/server_jpa_mdm/) — MDM documentation
- **FHIR Patient.link**: [hl7.org/fhir/R4/patient.html](https://hl7.org/fhir/R4/patient.html) — Patient resource specification
