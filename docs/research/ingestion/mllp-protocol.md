# MLLP — Minimal Lower Layer Protocol

> The TCP transport protocol for HL7 v2.x healthcare messaging

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Full Name** | Minimal Lower Layer Protocol (also: Minimum Lower Layer Protocol) |
| **Defined By** | HL7 International |
| **Transport** | TCP/IP |
| **Specification** | HL7 v2.x Implementation Guide, Appendix C |
| **Port** | Typically 2575 (IANA assigned for HL7) |
| **Nerve Role** | TCP transport layer for all HL7 v2.x ingestion from Epic and other EHR systems |

---

## What Is It?

MLLP is a simple framing protocol that wraps HL7 v2.x messages for transmission over TCP. Since HL7 v2.x messages are variable-length text (pipe-delimited "ER7" encoding), MLLP provides start and end markers so the receiver knows where each message begins and ends.

### Frame Structure

```
<SB> HL7 Message Data <EB><CR>

Where:
  <SB> = Start Block character (0x0B, vertical tab)
  <EB> = End Block character (0x1C, file separator)
  <CR> = Carriage Return (0x0D)
```

### Example MLLP Frame

```
\x0BMSH|^~\&|EPIC|FACILITY1|NERVE|HIS|20260205120000||ADT^A01|MSG00001|P|2.5.1\rPID|1||12345^^^FAC1^MR||DOE^JOHN||19800101|M\rPV1|1|I|ICU^101^A\x1C\x0D
```

### Connection Model

```
Sending System                           Receiving System (Nerve)
     │                                          │
     │────── TCP Connect ──────────────────────▶│
     │                                          │
     │──── <SB> HL7 Message <EB><CR> ─────────▶│
     │                                          │  Parse, validate
     │◀──── <SB> ACK Message <EB><CR> ─────────│  Send ACK/NAK
     │                                          │
     │──── <SB> Next Message <EB><CR> ────────▶│
     │◀──── <SB> ACK <EB><CR> ─────────────────│
     │                                          │
     │    ... (connection stays open) ...        │
     │                                          │
     │────── TCP Close ─────────────────────────│
```

**Key characteristics**:
- **Long-lived connections**: Each sending system maintains a persistent TCP connection. A 20-hospital Epic system might have 50-200 MLLP connections.
- **Synchronous ACK**: The sender blocks until it receives an ACK before sending the next message. This makes sub-millisecond ACK latency critical.
- **No multiplexing**: One message in-flight per connection at a time.
- **No built-in encryption**: TLS must be layered on top (TLS-wrapped MLLP, sometimes called "MLLPS" on port 2575).

---

## Go MLLP Implementation for Nerve

### Why Go?

| Feature | Go | Rust | Java (Camel) | Mirth Connect |
|---------|----|----|---------------|---------------|
| **Goroutine-per-connection** | Native (2 KB stack) | async/await (more complex) | Thread pool | Thread pool |
| **Throughput per pod** | 10K-50K msg/sec | 50K-100K+ msg/sec | 5K-20K msg/sec | 2K-5K msg/sec |
| **Container size** | 20-50 MB | 10-30 MB | 200-400 MB | 500+ MB |
| **Start time** | <1 second | <1 second | 5-15 seconds | 10-30 seconds |
| **HL7 ecosystem** | Mature (Google's mllp) | Nascent ("tokio play project") | Mature (Camel, HAPI) | Full integration engine |
| **K8s horizontal scaling** | Excellent | Excellent | Good | Poor (shared DB state) |
| **Production references** | Google Cloud Healthcare API | None in healthcare | Apache Camel production | Vertical only |

### Google's MLLP Adapter

**Repository**: [GoogleCloudPlatform/mllp](https://github.com/GoogleCloudPlatform/mllp)

Google's production-grade Go MLLP adapter is the reference implementation for Nerve's ingestion service. It:
- Handles MLLP frame parsing and ACK generation
- Integrates with Google Cloud Healthcare API (we replace this with Kafka)
- Supports TLS-wrapped connections
- Has been running in production on GKE for Google's healthcare customers
- Handles connection lifecycle management (reconnection, health checks)

### Nerve MLLP Listener Design

```
┌─────────────────────────────────────────────────┐
│                 Go MLLP Pod                       │
│                                                   │
│  ┌─────────┐                                     │
│  │ TCP     │◀── MLLP Connection from Epic        │
│  │ Listener│    (goroutine per connection)        │
│  └────┬────┘                                     │
│       │                                           │
│  ┌────▼────┐                                     │
│  │ Frame   │  Parse <SB>...<EB><CR>              │
│  │ Decoder │  Extract raw HL7 message            │
│  └────┬────┘                                     │
│       │                                           │
│  ┌────▼────────────────────┐                     │
│  │ Metadata Injection      │                     │
│  │ • source_system (from   │                     │
│  │   connection config)    │                     │
│  │ • facility_id           │                     │
│  │ • ingestion_timestamp   │                     │
│  │ • connection_id         │                     │
│  └────┬────────────────────┘                     │
│       │                                           │
│  ┌────▼────┐                                     │
│  │ Kafka   │  Produce to hl7.raw.ingest          │
│  │ Producer│  Key: facility_id + sending_app     │
│  └────┬────┘                                     │
│       │ success                                   │
│  ┌────▼────┐                                     │
│  │ ACK     │  Generate HL7 ACK (MSA segment)     │
│  │ Builder │  Return to sender via MLLP frame    │
│  └─────────┘                                     │
│                                                   │
│  ┌─────────┐                                     │
│  │Prometheus│  mllp_messages_received_total       │
│  │ Metrics  │  mllp_ack_latency_seconds          │
│  └─────────┘  mllp_connections_active            │
└─────────────────────────────────────────────────┘
```

### Scaling Pattern

```
                    ┌──────────────────────────┐
                    │   K8s TCP LoadBalancer     │
                    │   (MetalLB / Cloud LB)     │
                    └──────────┬───────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
        ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────┐
        │  MLLP     │  │  MLLP     │  │  MLLP     │
        │  Pod-0    │  │  Pod-1    │  │  Pod-N    │
        │  10K msg/s│  │  10K msg/s│  │  10K msg/s│
        └───────────┘  └───────────┘  └───────────┘
              │                │                │
              └────────────────┼────────────────┘
                               │
                        ┌──────▼──────┐
                        │   Kafka     │
                        │   Cluster   │
                        └─────────────┘

KEDA ScaledObject:
  triggers:
    - type: prometheus
      metadata:
        query: rate(mllp_messages_received_total[1m])
        threshold: "5000"     # Scale up when > 5K msg/sec per pod
  minReplicaCount: 2          # HA minimum
  maxReplicaCount: 16         # Burst ceiling
```

At 2M messages with conservative 10K msg/sec per pod: **200 pods** handle the load. At typical 50K msg/sec: **40 pods** suffice.

---

## HL7 ACK/NAK Protocol

When Nerve receives an HL7 message, it must respond with an acknowledgment:

### ACK (Positive Acknowledgment)
```
MSH|^~\&|NERVE|HIS|EPIC|FACILITY1|20260205120001||ACK^A01|ACK00001|P|2.5.1
MSA|AA|MSG00001
```

`MSA-1 = AA` (Application Accept): Message accepted and queued for processing.

### NAK (Negative Acknowledgment)
```
MSH|^~\&|NERVE|HIS|EPIC|FACILITY1|20260205120001||ACK^A01|ACK00001|P|2.5.1
MSA|AE|MSG00001
ERR|^^^207&Application internal error&HL70357
```

`MSA-1 = AE` (Application Error): Message rejected, sender should retry.

### Nerve ACK Strategy

Nerve sends ACK immediately after successful Kafka produce (before parsing). This means:
- ACK latency = TCP read + Kafka produce + ACK write = **< 5ms**
- If Kafka produce fails → NAK → sender retries
- Parsing/validation failures are handled asynchronously via DLQ (not via NAK)

---

## Security Considerations

### TLS-Wrapped MLLP (MLLPS)

```
Epic ──── TLS 1.3 ────▶ Go MLLP Pod
         (port 2575)

Certificate management:
  - cert-manager issues TLS certificates
  - Linkerd mTLS provides pod-to-pod encryption
  - VPN/private network for cross-datacenter MLLP connections
```

### HIPAA Requirements for MLLP

- **Encryption in transit**: TLS 1.2+ required for all MLLP connections carrying PHI
- **Access control**: IP allowlisting at the K8s NetworkPolicy level
- **Audit logging**: Every MLLP connection and message logged with timestamps
- **Integrity**: Kafka's CRC32 on message payload ensures no corruption

---

## Healthcare Context

### Typical MLLP Traffic Patterns

| Facility Type | Daily ADT Messages | Peak Rate | Connections |
|--------------|-------------------|-----------|-------------|
| Community Hospital (200 beds) | 5,000-15,000 | 50 msg/sec | 5-10 |
| Academic Medical Center (800 beds) | 30,000-80,000 | 200 msg/sec | 20-40 |
| Large Health System (20 hospitals) | 200,000-500,000 | 2,000 msg/sec | 100-200 |
| Mega Health System (50+ facilities) | 500,000-2,000,000 | 5,000+ msg/sec | 200-500 |

### Common HL7 Message Types Over MLLP

| Type | Trigger Event | Description | Volume |
|------|--------------|-------------|--------|
| ADT^A01 | Admission | Patient admitted | High |
| ADT^A04 | Registration | Outpatient registration | Very High |
| ADT^A08 | Update | Patient info update | Very High |
| ORM^O01 | Order | Lab/rad/pharmacy order | High |
| ORU^R01 | Result | Lab/rad results | Very High |
| DFT^P03 | Charge | Financial transaction | High |
| MDM^T02 | Document | Clinical note | Medium |
| SIU^S12 | Schedule | Appointment booking | Medium |

---

## Visual References

- **MLLP Frame Format**: See frame structure diagram above
- **Google MLLP Adapter**: [github.com/GoogleCloudPlatform/mllp](https://github.com/GoogleCloudPlatform/mllp) — Reference implementation
- **HL7 Connection Model**: [hl7.org/implement/standards](https://www.hl7.org/implement/standards/) — Official specification
