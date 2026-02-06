# HL7 v2.x Standard

> The dominant messaging standard for clinical healthcare data exchange

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Full Name** | Health Level Seven Version 2.x |
| **Organization** | HL7 International (ANSI-accredited) |
| **Website** | [hl7.org](https://www.hl7.org) |
| **Current Version** | v2.9.1 (2022), commonly deployed: v2.3-v2.5.1 |
| **Encoding** | ER7 (pipe-delimited) or XML |
| **Transport** | MLLP over TCP, HTTP, file-based |
| **License** | Free for implementation; spec requires HL7 membership to access |
| **Nerve Role** | Primary data format for all clinical messages from Epic and other EHR systems |

---

## What Is It?

HL7 v2.x is the most widely deployed healthcare messaging standard in the world. It defines the structure and semantics of clinical messages exchanged between healthcare systems — admissions, lab orders, results, charges, clinical notes, and scheduling events.

Despite being superseded by FHIR R4 for new API-based integrations, **HL7 v2.x remains the dominant interface protocol** for EHR-to-EHR communication. Epic, Cerner, MEDITECH, and virtually every hospital information system supports HL7 v2.x as its primary integration interface.

---

## Message Structure

### ER7 (Pipe-Delimited) Encoding

```
MSH|^~\&|EPIC|FAC001|NERVE|HIS|20260205120000||ADT^A01^ADT_A01|MSG00001|P|2.5.1|||AL|NE
EVN|A01|20260205115500
PID|1||MRN12345^^^FAC001^MR~987654321^^^SSA^SS||DOE^JOHN^Q||19800101|M|||123 MAIN ST^^PHOENIX^AZ^85001||602-555-1234
PV1|1|I|ICU^101^A^FAC001||||1234^SMITH^JAMES^L^^^MD|5678^JONES^MARY^A^^^MD||MED||||7||1234^SMITH^JAMES^L^^^MD|IP|V001||||||||||||||||||||||20260205115500
DG1|1||I10^Essential Hypertension^I10|||A
IN1|1||INS001^BLUE CROSS||||||GROUP001||||20250101|20261231
```

### Hierarchical Structure

```
Message (e.g., ADT^A01)
├── MSH  — Message Header (required in every message)
│   ├── Field Separator: |
│   ├── Encoding Characters: ^~\&
│   ├── Sending Application: EPIC
│   ├── Sending Facility: FAC001
│   ├── Message Type: ADT^A01
│   ├── Message Control ID: MSG00001
│   └── Version: 2.5.1
│
├── EVN  — Event Type (trigger event details)
├── PID  — Patient Identification
│   ├── Patient ID: MRN12345
│   ├── Patient Name: DOE^JOHN^Q
│   ├── DOB: 19800101
│   ├── Sex: M
│   └── Address, Phone, etc.
│
├── PV1  — Patient Visit
│   ├── Patient Class: I (Inpatient)
│   ├── Assigned Location: ICU^101^A
│   ├── Attending Doctor: SMITH, JAMES L, MD
│   └── Admission Date/Time
│
├── DG1  — Diagnosis (repeatable)
│   ├── Diagnosis Code: I10
│   ├── Description: Essential Hypertension
│   └── Coding System: ICD-10
│
└── IN1  — Insurance (repeatable)
    ├── Plan ID: INS001
    ├── Company Name: BLUE CROSS
    └── Effective Dates
```

### Data Type Hierarchy

```
Field (separated by |)
├── Component (separated by ^)
│   └── Sub-component (separated by &)
└── Repetition (separated by ~)

Example: PID-5 (Patient Name)
  DOE^JOHN^Q^^JR^MD
  │    │    │  │ │  └── Degree
  │    │    │  │ └──── Suffix
  │    │    │  └────── Prefix
  │    │    └────────── Middle Name
  │    └──────────────── Given Name
  └────────────────────── Family Name
```

---

## Key Message Types for Nerve

### ADT — Admit/Discharge/Transfer

The highest-volume message type. Tracks patient movement through the hospital.

| Trigger | Event | Description | Nerve Use |
|---------|-------|-------------|-----------|
| A01 | Admission | Patient admitted to inpatient | MPI registration, encounter creation |
| A02 | Transfer | Patient transferred between units | Location tracking |
| A03 | Discharge | Patient discharged | Encounter closure, billing trigger |
| A04 | Registration | Outpatient registration | MPI registration |
| A08 | Update | Demographics update | MPI update, golden record refresh |
| A11 | Cancel Admit | Admission cancelled | Encounter rollback |
| A13 | Cancel Discharge | Discharge cancelled | Encounter reopen |
| A28 | Add Person | New person (no visit) | MPI pre-registration |
| A31 | Update Person | Person demographics update | MPI update |
| A40 | Merge | Patient merge | MPI merge operation |

### ORM — Orders

| Trigger | Event | Description |
|---------|-------|-------------|
| O01 | Order | New order placed (lab, radiology, pharmacy) |
| O02 | Order Response | Filler response to order |

### ORU — Results

| Trigger | Event | Description |
|---------|-------|-------------|
| R01 | Unsolicited Result | Lab/radiology result available |

**ORU^R01 structure with OBX segments:**
```
MSH|...|ORU^R01|...
PID|...|Patient info...
OBR|1|ORD001||CBC^Complete Blood Count^L|||20260205100000
OBX|1|NM|WBC^White Blood Cell Count||7.5|10*3/uL|4.5-11.0|N|||F
OBX|2|NM|RBC^Red Blood Cell Count||4.8|10*6/uL|4.0-5.5|N|||F
OBX|3|NM|HGB^Hemoglobin||14.2|g/dL|12.0-16.0|N|||F
OBX|4|NM|HCT^Hematocrit||42.5|%|36.0-46.0|N|||F
OBX|5|NM|PLT^Platelets||250|10*3/uL|150-400|N|||F
```

### DFT — Financial Transactions

| Trigger | Event | Description |
|---------|-------|-------------|
| P03 | Post Detail Financial Transaction | Charge posting for billing/RCM |

Critical for Revenue Cycle Management — contains CPT codes, charge amounts, and billing details.

### MDM — Document Management

| Trigger | Event | Description |
|---------|-------|-------------|
| T01 | Original Document Notification | New clinical note available |
| T02 | Original Document with Content | Note text included as OBX segments |

### SIU — Scheduling

| Trigger | Event | Description |
|---------|-------|-------------|
| S12 | Notification of New Appointment | Appointment booked |
| S14 | Notification of Appointment Modification | Appointment changed |
| S15 | Notification of Appointment Cancellation | Appointment cancelled |

---

## Version History

| Version | Year | Key Changes |
|---------|------|-------------|
| v2.1 | 1990 | Original release |
| v2.2 | 1994 | Added segments, conformance |
| v2.3 | 1997 | **Most widely deployed version** — added many clinical segments |
| v2.3.1 | 1999 | Clarifications and fixes |
| v2.4 | 2000 | New segments, improved conformance |
| v2.5 | 2003 | Conformance profiles, new data types |
| v2.5.1 | 2007 | **Second most deployed** — used by Epic for most interfaces |
| v2.6 | 2007 | Additional segments for lab/pharmacy |
| v2.7 | 2011 | Expanded clinical content |
| v2.7.1 | 2012 | Corrections |
| v2.8 | 2014 | Expanded segments |
| v2.8.1 | 2016 | Minor corrections |
| v2.8.2 | 2017 | Minor corrections |
| v2.9 | 2019 | Latest major version |
| v2.9.1 | 2022 | Current latest |

**Practical reality**: Most Epic deployments use v2.3-v2.5.1. Nerve's Flink parser must handle the full v2.1-v2.9.1 range via HAPI HL7v2's backward-compatible parser.

---

## Code Systems in HL7 v2.x

| Code System | Field Examples | Description |
|-------------|---------------|-------------|
| ICD-10-CM | DG1-3, DG1-16 | Diagnosis codes |
| CPT-4 | FT1-7, PR1-3 | Procedure codes |
| SNOMED CT | OBX-3 | Clinical observations |
| LOINC | OBX-3 | Lab test identifiers |
| NDC | RXA-5 | Drug codes |
| HL7 Table 0001 | PID-8 | Administrative sex |
| HL7 Table 0002 | PID-10 | Race |
| HL7 Table 0004 | PV1-2 | Patient class |
| HL7 Table 0007 | PV1-18 | Admission type |

**Nerve's challenge**: Each hospital may use local codes that must be mapped to standard terminologies. This is the core function of the Transformation Layer (SQLMesh + Apache Hop + YAML mappings).

---

## HL7 v2.x vs. FHIR R4

| Aspect | HL7 v2.x | FHIR R4 |
|--------|----------|---------|
| **Transport** | MLLP/TCP (push) | REST/HTTP (pull/push) |
| **Encoding** | Pipe-delimited (ER7) or XML | JSON, XML, RDF |
| **Data Model** | Segments and fields | Resources with references |
| **Hospital Adoption** | >95% of US hospitals | Growing, ~60% for new APIs |
| **Real-time Events** | Native (trigger-based) | Subscriptions (emerging) |
| **Epic Support** | Primary interface method | 750+ read APIs, growing write |
| **Interface Count** | Millions globally | Thousands, growing rapidly |
| **Tooling** | HAPI HL7v2, Mirth, Camel | HAPI FHIR, .NET FHIR, etc. |

**Nerve's strategy**: HL7 v2.x via MLLP is the primary real-time data flow. FHIR R4 supplements with resources not available in v2.x feeds (CareTeam, Coverage, social determinants).

---

## Parsing with HAPI HL7v2

The HAPI HL7v2 library (Java) is the gold standard for parsing HL7 v2.x messages:

```java
// Maven: ca.uhn.hapi:hapi-structures-v25:2.5.1
PipeParser parser = new PipeParser();
Message msg = parser.parse(rawHL7String);

if (msg instanceof ADT_A01 adt) {
    PID pid = adt.getPID();
    String mrn = pid.getPatientIdentifierList(0).getIDNumber().getValue();
    String lastName = pid.getPatientName(0).getFamilyName().getSurname().getValue();
    String firstName = pid.getPatientName(0).getGivenName().getValue();

    PV1 pv1 = adt.getPV1();
    String location = pv1.getAssignedPatientLocation().getPointOfCare().getValue();
    String attendingMD = pv1.getAttendingDoctor(0).getIDNumber().getValue();
}
```

This is exactly how Nerve's Flink HL7 parser job processes messages — HAPI parses the raw ER7 into strongly-typed Java objects within Flink's `ProcessFunction` operators.

---

## Visual References

- **HL7 Message Structure**: See hierarchical diagram above
- **Segment Reference**: [hl7-definition.caristix.com](https://hl7-definition.caristix.com/v2/HL7v2.5.1) — Interactive segment browser
- **HAPI HL7v2 Documentation**: [hapifhir.github.io/hapi-hl7v2](https://hapifhir.github.io/hapi-hl7v2/) — Parser API reference
