# HashiCorp Vault

> Secret management and dynamic credential generation for HIPAA-compliant infrastructure

---

## Overview

| Attribute | Detail |
|-----------|--------|
| **Project** | HashiCorp Vault |
| **Website** | [vaultproject.io](https://www.vaultproject.io) |
| **GitHub** | [hashicorp/vault](https://github.com/hashicorp/vault) (~31K stars) |
| **Latest Version** | Vault 1.18+ (2025) |
| **License** | MPL 2.0 (community) / BSL 1.1 (enterprise features) |
| **Language** | Go |
| **Nerve Role** | Central secret management — dynamic database credentials, encryption keys, TLS certificates, API tokens |

---

## What Is It?

HashiCorp Vault is a secret management and data protection tool that provides a unified interface to manage secrets (passwords, API keys, certificates, encryption keys). It can dynamically generate short-lived credentials for databases and cloud services, removing the need for static passwords.

In Nerve, Vault is the **central secret authority** — managing credentials for PostgreSQL, Kafka, MinIO, and every service that handles PHI. Dynamic credentials auto-rotate, and every secret access is audit-logged for HIPAA compliance.

---

## Architecture in Nerve

```
┌──────────────────────────────────────────────────────────┐
│                  Vault HA Cluster                          │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │       Vault Pods (3+ for HA, Raft consensus)       │    │
│  │                                                    │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐       │    │
│  │  │ Active   │──│ Standby  │──│ Standby  │       │    │
│  │  │ (leader) │  │ (follower)│  │ (follower)│       │    │
│  │  └──────────┘  └──────────┘  └──────────┘       │    │
│  │                                                    │    │
│  │  Raft Storage (integrated, no external backend)   │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  Secret Engines:                                          │
│  ├── database/        Dynamic PostgreSQL credentials     │
│  ├── kv/v2/           Static secrets (API keys, configs) │
│  ├── pki/             TLS certificate issuance           │
│  ├── transit/         Encryption-as-a-service            │
│  └── kubernetes/      K8s service account auth           │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │       Vault Agent Sidecar Injector                 │    │
│  │                                                    │    │
│  │  Auto-injects secrets into pods via annotations:  │    │
│  │                                                    │    │
│  │  vault.hashicorp.com/agent-inject: "true"         │    │
│  │  vault.hashicorp.com/role: "mllp-listener"        │    │
│  │  vault.hashicorp.com/agent-inject-secret-db:      │    │
│  │    "database/creds/mllp-reader"                    │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

---

## Dynamic Database Credentials

```hcl
# Configure PostgreSQL secret engine
vault write database/config/nerve-postgresql \
  plugin_name=postgresql-database-plugin \
  allowed_roles="mllp-reader,flink-writer,trino-reader" \
  connection_url="postgresql://{{username}}:{{password}}@postgresql.platform-storage:5432/nerve_clinical" \
  username="vault-admin" \
  password="<root-password>"

# Create role with time-limited credentials
vault write database/roles/mllp-reader \
  db_name=nerve-postgresql \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
```

When a pod requests credentials:
```bash
$ vault read database/creds/mllp-reader
Key             Value
---             -----
lease_id        database/creds/mllp-reader/abcd1234
lease_duration  1h
username        v-mllp-reader-abcd1234-1707177600
password        A1B2C3D4E5F6G7H8I9J0
```

**Credentials auto-expire after 1 hour**. The pod requests new ones before expiry. If compromised, damage is limited to the TTL window.

---

## HIPAA Compliance Features

| Requirement | Vault Feature |
|-------------|--------------|
| §164.312(a)(1) Access Control | Per-secret ACL policies |
| §164.312(a)(2)(iv) Encryption | Transit engine for PHI encryption |
| §164.312(b) Audit Controls | Every secret access audit-logged |
| §164.312(d) Authentication | K8s service account auth + policies |
| §164.308(a)(5)(ii)(D) Password Management | Dynamic credentials, no static passwords |

### Audit Logging

```json
{
  "time": "2026-02-05T12:00:00Z",
  "type": "response",
  "auth": {
    "client_token": "hmac-sha256:...",
    "accessor": "hmac-sha256:...",
    "policies": ["mllp-listener"],
    "metadata": {
      "role": "mllp-listener",
      "service_account_name": "mllp-sa"
    }
  },
  "request": {
    "id": "req-12345",
    "operation": "read",
    "path": "database/creds/mllp-reader",
    "namespace": { "id": "root" }
  }
}
```

Every secret read, write, and lease renewal is logged and forwarded to Loki for immutable 6-year retention.

---

## Kubernetes Deployment

```yaml
# Vault Helm chart
helm install vault hashicorp/vault \
  --namespace platform-security \
  --set server.ha.enabled=true \
  --set server.ha.replicas=3 \
  --set server.ha.raft.enabled=true \
  --set injector.enabled=true \
  --set server.dataStorage.size=10Gi \
  --set server.dataStorage.storageClass=fast-ssd \
  --set server.auditStorage.enabled=true \
  --set server.auditStorage.size=50Gi
```

---

## How to Leverage in Nerve

1. **Dynamic DB Credentials**: PostgreSQL credentials rotate every hour — no static passwords
2. **Kafka Credentials**: SASL/SCRAM credentials for Kafka producers/consumers
3. **MinIO Credentials**: Dynamic S3 access keys for Flink, Spark, Trino
4. **TLS Certificates**: PKI engine issues short-lived TLS certs for internal services
5. **Transit Encryption**: Encrypt PHI fields at the application level before writing to storage
6. **Audit Trail**: Every secret access logged for HIPAA compliance audits
7. **Sidecar Injection**: Vault Agent auto-injects secrets into pods — no secrets in K8s Secrets

---

## License Considerations

Vault's community edition (MPL 2.0) covers all features Nerve needs:
- HA with Raft consensus
- Dynamic secret engines (database, KV, PKI, transit)
- Kubernetes auth method
- Audit logging
- Agent Sidecar Injector

Enterprise features (HSM auto-unseal, namespaces, Sentinel policies) are BSL-licensed and not required for Nerve.

---

## Visual References

- **Vault Architecture**: [developer.hashicorp.com/vault/docs/internals/architecture](https://developer.hashicorp.com/vault/docs/internals/architecture)
- **K8s Integration**: [developer.hashicorp.com/vault/docs/platform/k8s](https://developer.hashicorp.com/vault/docs/platform/k8s)
- **Dynamic Secrets**: [developer.hashicorp.com/vault/docs/secrets/databases](https://developer.hashicorp.com/vault/docs/secrets/databases)
