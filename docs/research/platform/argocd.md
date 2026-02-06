# ArgoCD + Argo Rollouts

> GitOps continuous delivery and progressive deployment for Kubernetes

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | Argo CD / Argo Rollouts |
| **Website** | [argoproj.github.io](https://argoproj.github.io) |
| **GitHub** | [argoproj/argo-cd](https://github.com/argoproj/argo-cd) (~18K stars) / [argoproj/argo-rollouts](https://github.com/argoproj/argo-rollouts) (~2.7K stars) |
| **Latest Version** | ArgoCD 2.13+ / Argo Rollouts 1.7+ (2025) |
| **License** | Apache 2.0 |
| **CNCF Status** | CNCF Graduated project |
| **Nerve Role** | GitOps deployment of all Kubernetes manifests with canary releases for clinical services |

---

## What Is It?

**ArgoCD** is a declarative GitOps continuous delivery tool for Kubernetes. It continuously monitors Git repositories and ensures the cluster state matches the desired state declared in Git. When someone pushes a change to the Git repo, ArgoCD automatically syncs it to the cluster.

**Argo Rollouts** provides advanced deployment strategies (canary, blue-green) with automatic analysis and rollback based on Prometheus metrics.

In Nerve, ArgoCD manages **all deployments** across 9 namespaces — from Kafka clusters to Flink jobs to clinical UIs. Argo Rollouts provides canary deployments for clinical services where rolling updates could impact patient care.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      ArgoCD on K8s                         │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │              ArgoCD Server                         │    │
│  │                                                    │    │
│  │  ┌─────────────────┐  ┌────────────────────────┐ │    │
│  │  │   Web UI         │  │   API Server            │ │    │
│  │  │   (port 443)     │  │   (gRPC + REST)         │ │    │
│  │  │                  │  │                          │ │    │
│  │  │   Team RBAC:     │  │   ApplicationSets:      │ │    │
│  │  │   • admin        │  │   Auto-generate apps    │ │    │
│  │  │   • ops-team     │  │   from Git repo dirs    │ │    │
│  │  │   • dev-team     │  │                          │ │    │
│  │  └─────────────────┘  └────────────────────────┘ │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │     App-of-Apps (root application)                 │    │
│  │                                                    │    │
│  │     nerve-app-of-apps                              │    │
│  │     ├── platform-kafka (Strimzi CRDs)             │    │
│  │     ├── platform-flink (Flink Operator)           │    │
│  │     ├── platform-storage (MinIO, CNPG, OpenSearch)│    │
│  │     ├── platform-observability (Prometheus stack)  │    │
│  │     ├── platform-security (Vault, cert-manager)   │    │
│  │     ├── clinical-ingestion (MLLP, FHIR poller)   │    │
│  │     ├── clinical-processing (Flink jobs, Spark)   │    │
│  │     ├── clinical-serving (Trino, HAPI FHIR, UIs) │    │
│  │     └── clinical-transforms (Hop, SQLMesh)        │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  Git Repository (single source of truth):                 │
│  deploy/                                                  │
│  ├── argocd/nerve-app-of-apps.yaml                       │
│  ├── kafka/       ← Strimzi Kafka CRDs                   │
│  ├── flink/       ← FlinkDeployment specs                │
│  ├── storage/     ← MinIO Tenant, CNPG Cluster           │
│  ├── observability/ ← Prometheus rules, Grafana dashboards│
│  └── environments/                                        │
│      ├── dev/     ← Dev overlay values                    │
│      ├── staging/ ← Staging overlay values                │
│      └── prod/    ← Production overlay values             │
└──────────────────────────────────────────────────────────┘
```

---

## Argo Rollouts for Clinical Services

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: mllp-listener
  namespace: clinical-ingestion
spec:
  replicas: 4
  strategy:
    canary:
      steps:
        - setWeight: 5          # 5% traffic to new version
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: mllp-health-check
        - setWeight: 25
        - pause: { duration: 10m }
        - analysis:
            templates:
              - templateName: mllp-health-check
        - setWeight: 50
        - pause: { duration: 15m }
        - setWeight: 100
      analysis:
        templates:
          - templateName: mllp-health-check
        args:
          - name: service-name
            value: mllp-listener
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: mllp-health-check
spec:
  metrics:
    - name: ack-latency
      provider:
        prometheus:
          address: http://prometheus.platform-observability:9090
          query: |
            histogram_quantile(0.99,
              sum(rate(mllp_ack_latency_seconds_bucket{service="{{args.service-name}}"}[5m]))
              by (le))
      successCondition: result[0] < 0.005  # P99 < 5ms
      failureLimit: 3
    - name: error-rate
      provider:
        prometheus:
          address: http://prometheus.platform-observability:9090
          query: |
            sum(rate(mllp_errors_total{service="{{args.service-name}}"}[5m])) /
            sum(rate(mllp_messages_received_total{service="{{args.service-name}}"}[5m]))
      successCondition: result[0] < 0.01  # Error rate < 1%
      failureLimit: 2
```

---

## ArgoCD vs. Flux

| Feature | ArgoCD | Flux |
|---------|--------|------|
| **Web UI** | Built-in (critical for clinical ops) | No built-in UI |
| **RBAC** | Team-based, project scoping | K8s RBAC only |
| **App-of-Apps** | Native pattern | Kustomization dependencies |
| **ApplicationSets** | Generate apps from Git dirs | Similar via Kustomization |
| **Rollouts** | Argo Rollouts (canary/blue-green) | Flagger (third-party) |
| **Community** | 18K stars, CNCF Graduated | 6K stars, CNCF Graduated |
| **Commercial Backing** | Akuity (strong) | Weaveworks (shutdown 2024) |
| **Drift Detection** | Built-in, visual | Event-based |
| **Multi-Cluster** | Native | Native |

**Why ArgoCD for Nerve**: Built-in Web UI is critical for clinical operations teams who need visual deployment status. Team RBAC enables facility-specific access controls. Strong commercial backing after Weaveworks' 2024 shutdown created Flux ecosystem uncertainty.

---

## How to Leverage in Nerve

1. **Single Source of Truth**: All K8s manifests in Git — every deployment change is auditable
2. **App-of-Apps**: Single root application manages all 9 namespaces
3. **Canary Deployments**: Argo Rollouts gradually shifts traffic with Prometheus-based analysis
4. **Auto-Rollback**: If ACK latency or error rate exceeds thresholds, automatic rollback
5. **Environment Promotion**: dev → staging → prod via Git branch/directory strategy
6. **Team RBAC**: Different teams see/manage only their namespaces
7. **Drift Detection**: Alerts when cluster state diverges from Git (someone manually changed something)

---

## Visual References

- **ArgoCD UI**: [argo-cd.readthedocs.io/en/stable](https://argo-cd.readthedocs.io/en/stable/) — Web UI screenshots showing application tree, sync status, resource health
- **Argo Rollouts Dashboard**: Built-in UI showing canary progression, traffic weights, analysis results
- **App-of-Apps**: [argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) — Pattern documentation
