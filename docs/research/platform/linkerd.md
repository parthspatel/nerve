# Linkerd

> Ultralight service mesh with zero-config mTLS for HIPAA-compliant encryption

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Linkerd |
| **Website** | [linkerd.io](https://linkerd.io) |
| **GitHub** | [linkerd/linkerd2](https://github.com/linkerd/linkerd2) (~10.5K stars) |
| **Latest Version** | Linkerd 2.16+ (2025) |
| **License** | Apache 2.0 |
| **Language** | Rust (data plane proxy), Go (control plane) |
| **CNCF Status** | CNCF Graduated project |
| **Nerve Role** | mTLS encryption for all pod-to-pod traffic — HIPAA encryption-in-transit compliance |

---

## What Is It?

Linkerd is an ultralight service mesh that provides mutual TLS (mTLS), observability, and reliability features for Kubernetes workloads. Its Rust-based data plane proxy adds minimal latency and memory overhead compared to Envoy-based meshes (Istio).

In Nerve, Linkerd provides **zero-config mTLS** — every pod-to-pod connection is automatically encrypted without any application changes. This directly satisfies HIPAA's encryption-in-transit requirement for clinical data.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     Linkerd on K8s                         │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │           Control Plane (linkerd namespace)        │    │
│  │                                                    │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐       │    │
│  │  │Destination│  │Identity  │  │Proxy     │       │    │
│  │  │(service   │  │(cert     │  │Injector  │       │    │
│  │  │ discovery)│  │ issuance)│  │(auto-    │       │    │
│  │  │          │  │          │  │ inject)  │       │    │
│  │  └──────────┘  └──────────┘  └──────────┘       │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │           Data Plane (every annotated pod)         │    │
│  │                                                    │    │
│  │  ┌──────────────────────────────────────────┐    │    │
│  │  │ Pod: mllp-listener-0                      │    │    │
│  │  │                                           │    │    │
│  │  │  ┌─────────────┐  ┌──────────────────┐  │    │    │
│  │  │  │ Application  │──│ linkerd-proxy    │  │    │    │
│  │  │  │ Container    │  │ (Rust sidecar)   │  │    │    │
│  │  │  │             │  │                   │  │    │    │
│  │  │  │ Plaintext   │  │ ◄── mTLS in ──▶ │  │    │    │
│  │  │  │ internally  │  │ ◄── mTLS out ──▶ │  │    │    │
│  │  │  └─────────────┘  └──────────────────┘  │    │    │
│  │  └──────────────────────────────────────────┘    │    │
│  │                                                    │    │
│  │  Every connection between meshed pods:             │    │
│  │  mllp-listener ◄──mTLS──▶ kafka-broker            │    │
│  │  flink-tm ◄──mTLS──▶ kafka-broker                 │    │
│  │  flink-tm ◄──mTLS──▶ postgresql                   │    │
│  │  trino-worker ◄──mTLS──▶ minio                    │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

---

## Performance: Linkerd vs. Istio

| Metric | Linkerd | Istio |
|--------|---------|-------|
| **Proxy Memory** | ~10-20 MB | ~50-100 MB (Envoy) |
| **P99 Latency Added** | < 1ms | 2-5ms |
| **P50 Latency Added** | < 0.5ms | 1-2ms |
| **Relative Latency Overhead** | Baseline | 40-400% more than Linkerd |
| **mTLS Setup** | Zero-config (auto at install) | Requires PeerAuthentication CRD |
| **Proxy Language** | Rust (linkerd2-proxy) | C++ (Envoy) |
| **Control Plane Size** | 3 pods | 5+ pods |
| **Certificate Rotation** | Automatic (24h default) | Automatic |

**Why Linkerd over Istio**: For real-time clinical message processing where every millisecond matters, Linkerd's Rust-based proxy adds minimal latency. The zero-config mTLS means HIPAA compliance is achieved at installation without additional configuration. Its minimalist design reduces risk of mesh-related outages in a clinical environment.

---

## HIPAA Compliance

### Encryption-in-Transit

Linkerd provides mTLS for all meshed pod-to-pod communication:
- TLS 1.3 with X.25519 key exchange
- Ed25519 certificate signatures
- Automatic certificate rotation (24-hour lifetime by default)
- No application code changes required

### How It Satisfies HIPAA

| HIPAA Requirement | Linkerd Feature |
|-------------------|----------------|
| §164.312(e)(1) Transmission Security | mTLS encrypts all PHI in transit |
| §164.312(e)(2)(ii) Encryption | TLS 1.3 between all pods |
| §164.312(d) Person Authentication | mTLS proves pod identity via certificates |
| §164.312(c)(1) Integrity | TLS integrity checks prevent tampering |

---

## Installation

```bash
# Install Linkerd CLI
curl -sL https://run.linkerd.io/install | sh

# Install CRDs
linkerd install --crds | kubectl apply -f -

# Install control plane
linkerd install | kubectl apply -f -

# Verify
linkerd check

# Enable auto-injection for clinical namespaces
kubectl annotate namespace clinical-ingestion linkerd.io/inject=enabled
kubectl annotate namespace clinical-processing linkerd.io/inject=enabled
kubectl annotate namespace clinical-serving linkerd.io/inject=enabled
kubectl annotate namespace platform-kafka linkerd.io/inject=enabled
kubectl annotate namespace platform-storage linkerd.io/inject=enabled
```

After annotation, every new pod in those namespaces automatically gets a Linkerd sidecar proxy with mTLS enabled.

---

## Observability

Linkerd provides built-in observability for all meshed traffic:

- **Golden metrics per route**: Request rate, success rate, latency distribution
- **TCP-level metrics**: Connection count, bytes transferred
- **mTLS status**: Which connections are encrypted/unencrypted
- **Service topology**: Live service dependency graph

Linkerd's metrics are Prometheus-compatible and integrate directly with Grafana dashboards.

---

## How to Leverage in Nerve

1. **Zero-Config mTLS**: HIPAA encryption-in-transit achieved at Linkerd installation
2. **Minimal Latency**: Rust proxy adds < 1ms — critical for MLLP ACK latency targets
3. **Service Observability**: Golden metrics for every clinical service without code instrumentation
4. **Traffic Splitting**: Support for Argo Rollouts canary deployments (traffic split at mesh level)
5. **Retry/Timeout Policies**: Automatic retries for transient failures between services
6. **Authorization Policies**: Restrict which services can talk to each other (defense in depth)

---

## Visual References

- **Linkerd Architecture**: [linkerd.io/2/reference/architecture](https://linkerd.io/2/reference/architecture/) — Architecture overview
- **Linkerd Dashboard**: [linkerd.io/2/features/dashboard](https://linkerd.io/2/features/dashboard/) — Built-in observability UI
- **mTLS Deep Dive**: [linkerd.io/2/features/automatic-mtls](https://linkerd.io/2/features/automatic-mtls/) — How zero-config mTLS works
