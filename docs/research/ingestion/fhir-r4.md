# FHIR R4 — Fast Healthcare Interoperability Resources

> The modern REST-based standard for healthcare data exchange

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Full Name** | Fast Healthcare Interoperability Resources, Release 4 |
| **Organization** | HL7 International |
| **Website** | [hl7.org/fhir](https://hl7.org/fhir/) |
| **Specification** | [hl7.org/fhir/R4](https://hl7.org/fhir/R4/) |
| **Status** | Normative (stable, no breaking changes) |
| **Release Date** | January 2019 (R4), R4B: May 2022 |
| **API Style** | RESTful (JSON/XML over HTTP) |
| **License** | Creative Commons (spec), implementations vary |
| **Nerve Role** | Enrichment data source — supplements HL7 v2.x with 750+ FHIR resources from Epic |

---

## What Is It?

FHIR (pronounced "fire") is HL7's modern standard for healthcare data exchange. Unlike HL7 v2.x's push-based messaging model, FHIR uses a RESTful API approach where resources (Patient, Encounter, Observation, etc.) are accessed via standard HTTP methods (GET, POST, PUT, DELETE).

FHIR R4 is the **first normative release**, meaning the core resource specifications are stable and will not have breaking changes in future versions. This makes R4 the target version for production systems.

---

## Resource Model

FHIR organizes healthcare data into **Resources** — self-contained units of exchangeable data. Each resource has a defined structure, data types, and relationships.

### Core Clinical Resources

```
┌──────────────────────────────────────────────────────┐
│                 FHIR R4 Resource Model                │
│                                                       │
│  ┌─────────┐    ┌───────────┐    ┌──────────────┐   │
│  │ Patient  │───▶│ Encounter  │───▶│ Condition    │   │
│  │          │    │            │    │ (Diagnosis)  │   │
│  └─────────┘    └───────────┘    └──────────────┘   │
│       │              │                               │
│       │         ┌────┴─────┐                         │
│       │         │          │                         │
│  ┌────▼────┐  ┌─▼────┐  ┌─▼──────────┐             │
│  │Coverage │  │Claim  │  │Observation │             │
│  │(Insur.) │  │       │  │(Lab/Vital) │             │
│  └─────────┘  └──────┘  └────────────┘             │
│                                                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐       │
│  │CareTeam  │  │CarePlan  │  │DocumentRef   │       │
│  └──────────┘  └──────────┘  └──────────────┘       │
│                                                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐       │
│  │Medication│  │Procedure │  │DiagnosticRpt │       │
│  │Request   │  │          │  │              │       │
│  └──────────┘  └──────────┘  └──────────────┘       │
└──────────────────────────────────────────────────────┘
```

### Resource Example (Patient)

```json
{
  "resourceType": "Patient",
  "id": "12345",
  "identifier": [
    {
      "use": "usual",
      "type": { "coding": [{ "system": "http://terminology.hl7.org/CodeSystem/v2-0203", "code": "MR" }] },
      "system": "urn:oid:1.2.3.4.5.6",
      "value": "MRN12345"
    }
  ],
  "name": [
    {
      "use": "official",
      "family": "Doe",
      "given": ["John", "Q"]
    }
  ],
  "gender": "male",
  "birthDate": "1980-01-01",
  "address": [
    {
      "line": ["123 Main St"],
      "city": "Phoenix",
      "state": "AZ",
      "postalCode": "85001"
    }
  ]
}
```

---

## Epic FHIR R4 APIs

Epic provides **750+ no-cost FHIR R4 APIs** for data retrieval. These are critical for Nerve because they provide data types not available in HL7 v2.x feeds.

### Resources Only Available via FHIR (Not in HL7 v2.x)

| Resource | What It Provides | Why Nerve Needs It |
|----------|-----------------|-------------------|
| CareTeam | Full care team assignments | Understand which providers touch the patient |
| CarePlan | Treatment plans | Clinical context for orders/results |
| Coverage | Insurance details (richer than IN1) | RCM: payer identification, eligibility |
| ExplanationOfBenefit | EOB/claim adjudication | RCM: denial analysis, payment details |
| Goal | Patient goals | Clinical quality measures |
| Consent | Patient consent documents | HIPAA compliance |
| FamilyMemberHistory | Family health history | Risk assessment |
| QuestionnaireResponse | Patient-reported data | SDOH screening results |
| Observation (SDOH) | Social determinants | Risk stratification |

### Epic FHIR Authentication: Backend Systems OAuth2

```
┌──────────────┐                     ┌─────────────────┐
│ Nerve FHIR   │                     │ Epic FHIR       │
│ Poller Pod   │                     │ Server          │
└──────┬───────┘                     └────────┬────────┘
       │                                      │
       │  1. POST /oauth2/token               │
       │     grant_type=client_credentials    │
       │     client_assertion=JWT             │
       │     (signed with RSA private key)    │
       │─────────────────────────────────────▶│
       │                                      │
       │  2. { access_token: "..." }          │
       │◀─────────────────────────────────────│
       │                                      │
       │  3. GET /Patient?identifier=MRN123   │
       │     Authorization: Bearer <token>    │
       │─────────────────────────────────────▶│
       │                                      │
       │  4. FHIR Bundle (JSON)               │
       │◀─────────────────────────────────────│
       │                                      │
       │  5. Produce to Kafka: fhir.ingest    │
       │                                      │
```

### Bulk FHIR Export

For large-scale data retrieval (backfill, analytics), Epic supports FHIR Bulk Data Export:

```
POST /Group/{id}/$export
Accept: application/fhir+json
Prefer: respond-async

Response: 202 Accepted
Content-Location: /bulk-status/job123

# Poll for completion
GET /bulk-status/job123

# When complete, download NDJSON files:
GET /bulk-output/Patient.ndjson
GET /bulk-output/Encounter.ndjson
GET /bulk-output/Observation.ndjson
```

**Epic recommendation**: Limit batches to ~1,000 patients for system stability.

---

## FHIR vs. HL7 v2.x in Nerve

| Aspect | HL7 v2.x (Primary) | FHIR R4 (Enrichment) |
|--------|--------------------|-----------------------|
| **Delivery** | Push (Epic sends via MLLP) | Pull (Nerve polls Epic APIs) |
| **Latency** | Real-time (~seconds) | Near-real-time (~minutes) |
| **Volume** | Very high (50K-500K msg/day) | Moderate (API rate-limited) |
| **Data Coverage** | ADT, orders, results, charges | 750+ resource types |
| **RCM Data** | DFT charges, basic insurance | ExplanationOfBenefit, detailed Coverage |
| **Clinical Notes** | MDM (limited) | DocumentReference + Binary (full text) |
| **Nerve Kafka Topic** | `hl7.raw.ingest` | `fhir.ingest` |

### Nerve's Dual-Path Strategy

```
                    Real-time (HL7 v2.x)
Epic ──── MLLP ────────────────────────────▶ Kafka ──▶ Flink ──▶ Delta Lake
  │
  │       Near-real-time (FHIR R4)
  └──── REST API ─── FHIR Poller Pod ─────▶ Kafka ──▶ Flink ──▶ Delta Lake
         (enrich)    (Go service)                                PostgreSQL
```

---

## FHIR Terminology and Code Systems

FHIR uses standard code systems for clinical concepts:

| Code System | URI | Used For |
|------------|-----|----------|
| SNOMED CT | `http://snomed.info/sct` | Clinical findings, procedures |
| LOINC | `http://loinc.org` | Lab tests, observations |
| ICD-10-CM | `http://hl7.org/fhir/sid/icd-10-cm` | Diagnoses |
| CPT | `http://www.ama-assn.org/go/cpt` | Procedures (billing) |
| RxNorm | `http://www.nlm.nih.gov/research/umls/rxnorm` | Medications |
| NDC | `http://hl7.org/fhir/sid/ndc` | Drug products |

---

## HAPI FHIR (Java Library & Server)

**Repository**: [hapifhir/hapi-fhir](https://github.com/hapifhir/hapi-fhir) (~2.1K stars)

HAPI FHIR is the reference Java implementation of the FHIR specification:

| Component | Purpose | Nerve Use |
|-----------|---------|-----------|
| **hapi-fhir-client** | FHIR client library | FHIR Poller Pod |
| **hapi-fhir-structures-r4** | R4 data model | FHIR resource parsing |
| **hapi-fhir-jpaserver** | Full FHIR server with JPA | MPI (HAPI FHIR MDM) |
| **hapi-fhir-validation** | Resource validation | Input validation |

---

## Visual References

- **FHIR Resource Index**: [hl7.org/fhir/R4/resourcelist.html](https://hl7.org/fhir/R4/resourcelist.html) — Complete resource listing
- **Epic FHIR Docs**: [fhir.epic.com](https://fhir.epic.com) — Epic's FHIR API documentation
- **SMART on FHIR**: [smarthealthit.org](https://smarthealthit.org) — App authorization framework
- **Bulk FHIR**: [hl7.org/fhir/uv/bulkdata](https://hl7.org/fhir/uv/bulkdata/) — Bulk Data Export spec
