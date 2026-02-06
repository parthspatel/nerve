# OpenSearch

> Distributed search and analytics engine for clinical document indexing

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | OpenSearch |
| **Organization** | OpenSearch Software Foundation (Linux Foundation) |
| **Website** | [opensearch.org](https://opensearch.org) |
| **GitHub** | [opensearch-project/OpenSearch](https://github.com/opensearch-project/OpenSearch) (~9.5K stars) |
| **Latest Version** | OpenSearch 2.17+ (2025) |
| **License** | Apache 2.0 |
| **Language** | Java |
| **Nerve Role** | Clinical document search, NLP entity extraction, full-text search across clinical narratives |

---

## What Is It?

OpenSearch is a community-driven, Apache 2.0 licensed search and analytics engine forked from Elasticsearch 7.10 in 2021. It provides full-text search, structured search, analytics, and machine learning capabilities — with built-in security features that are free (unlike Elasticsearch's paid security tier).

In Nerve, OpenSearch handles **clinical document search and indexing** — enabling clinicians to search across clinical notes, lab reports, and radiology reports using medical terminology, with NLP entity extraction at index time.

---

## Architecture in Nerve

```
┌──────────────────────────────────────────────────────────┐
│                   OpenSearch Cluster                       │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │         Data Nodes (3+ pods)                       │    │
│  │                                                    │    │
│  │  Indices (time-based):                            │    │
│  │  ├── clinical-notes-2026.02                       │    │
│  │  ├── clinical-notes-2026.01                       │    │
│  │  ├── lab-reports-2026.02                          │    │
│  │  ├── radiology-reports-2026.02                    │    │
│  │  └── dicom-metadata-2026.02                       │    │
│  │                                                    │    │
│  │  Aliases:                                          │    │
│  │  ├── clinical-notes-current → latest month        │    │
│  │  └── clinical-notes-all → all months              │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │         ML Commons Plugin                          │    │
│  │                                                    │    │
│  │  NER Models:                                       │    │
│  │  ├── ClinicalBERT (entity extraction)             │    │
│  │  ├── BioBERT (biomedical text)                    │    │
│  │  └── Custom medical NER                            │    │
│  │                                                    │    │
│  │  Extracted entities indexed as structured fields:  │    │
│  │  ├── conditions: ["hypertension", "diabetes"]     │    │
│  │  ├── medications: ["metformin", "lisinopril"]     │    │
│  │  ├── procedures: ["echocardiogram", "CT scan"]    │    │
│  │  └── lab_values: [{"test": "HbA1c", "value": 7.2}]│   │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  Security (free, built-in):                               │
│  ├── RBAC (role-based access control)                    │
│  ├── Field-level security (hide PHI from certain roles)  │
│  ├── Document-level security (facility_id filtering)     │
│  └── Audit logging (HIPAA compliance)                    │
└──────────────────────────────────────────────────────────┘
```

---

## Clinical Search Features

### Medical Synonym Analyzers

```json
{
  "settings": {
    "analysis": {
      "filter": {
        "medical_synonyms": {
          "type": "synonym_graph",
          "synonyms": [
            "MI, myocardial infarction, heart attack",
            "HTN, hypertension, high blood pressure",
            "DM, diabetes mellitus, diabetes",
            "COPD, chronic obstructive pulmonary disease",
            "CHF, congestive heart failure, heart failure"
          ]
        },
        "snomed_synonyms": {
          "type": "synonym_graph",
          "synonyms_path": "analysis/snomed_synonyms.txt"
        }
      },
      "analyzer": {
        "clinical_text": {
          "tokenizer": "standard",
          "filter": ["lowercase", "medical_synonyms", "snomed_synonyms"]
        }
      }
    }
  }
}
```

### Example Search Queries

```json
// Search for patients with heart failure mentions
POST /clinical-notes-all/_search
{
  "query": {
    "bool": {
      "must": [
        { "match": { "note_text": { "query": "heart failure", "analyzer": "clinical_text" } } }
      ],
      "filter": [
        { "term": { "facility_id": "FAC-001" } },
        { "range": { "note_date": { "gte": "2026-01-01" } } }
      ]
    }
  },
  "highlight": {
    "fields": { "note_text": {} }
  }
}
```

### NLP Entity Extraction Pipeline

```
Clinical Note (raw text)
    │
    ▼
[OpenSearch Ingest Pipeline]
    │
    ├── [ML Inference Processor]
    │   Deploy ClinicalBERT via ML Commons
    │   Extract: conditions, medications, procedures
    │
    ├── [Script Processor]
    │   Normalize extracted entities to SNOMED CT codes
    │
    └── [Set Processor]
        Add source_system, facility_id metadata
    │
    ▼
[Indexed Document]
{
  "note_text": "Patient presents with uncontrolled HTN...",
  "note_date": "2026-02-05",
  "facility_id": "FAC-001",
  "source_system": "epic-phoenix",
  "entities": {
    "conditions": [
      { "text": "HTN", "code": "38341003", "system": "SNOMED CT" }
    ],
    "medications": [
      { "text": "lisinopril", "code": "29046", "system": "RxNorm" }
    ]
  }
}
```

---

## HIPAA Security Features (Free)

| Feature | Description |
|---------|-------------|
| **RBAC** | Role-based access with backend roles, index permissions |
| **Field-Level Security** | Hide SSN, DOB fields from certain roles |
| **Document-Level Security** | Filter results by facility_id per role |
| **Audit Logging** | Log all search queries and document access |
| **TLS** | Encryption in transit (node-to-node, client-to-node) |
| **Authentication** | LDAP, SAML, OpenID Connect |
| **IP Allowlisting** | Restrict access by source IP |

---

## OpenSearch vs. Elasticsearch

| Feature | OpenSearch | Elasticsearch |
|---------|-----------|---------------|
| **License** | Apache 2.0 | SSPL + Elastic License |
| **Security** | Free, built-in | Paid (requires subscription) |
| **ML Plugins** | ML Commons (free) | ML (paid) |
| **Governance** | Linux Foundation | Elastic NV (single vendor) |
| **API Compatibility** | ~95% compatible | N/A |
| **NLP Integration** | Built-in inference | Paid feature |
| **HIPAA Audit Logging** | Free | Paid (Gold/Platinum) |

**Why OpenSearch for Nerve**: Free built-in security (RBAC, field-level security, audit logging) essential for HIPAA without paid tiers. Truly open-source under Apache 2.0. ML Commons enables NLP entity extraction at index time.

---

## How to Leverage in Nerve

1. **Clinical Note Search**: Full-text search with medical synonyms across all clinical narratives
2. **NLP Entity Extraction**: ClinicalBERT extracts conditions, medications, procedures at index time
3. **Lab Result Search**: Searchable lab reports with structured lab value fields
4. **Radiology Report Search**: Radiology reports searchable by findings, modality, body part
5. **DICOM Metadata Search**: Study-level imaging metadata searchable alongside clinical data
6. **HIPAA Compliance**: Free audit logging, field-level security, document-level access control
7. **Cross-Facility Search**: Document-level security filters by facility_id per user role

---

## Visual References

- **OpenSearch Documentation**: [opensearch.org/docs](https://opensearch.org/docs/latest/) — Complete documentation
- **OpenSearch Dashboards**: [opensearch.org/docs/latest/dashboards](https://opensearch.org/docs/latest/dashboards/) — Visualization layer
- **ML Commons**: [opensearch.org/docs/latest/ml-commons-plugin](https://opensearch.org/docs/latest/ml-commons-plugin/) — ML plugin docs
