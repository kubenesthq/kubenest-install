# KubeNest Installer

Single-step installer for the KubeNest control plane. Sets up a complete management plane on a fresh VM.

## Quick Start

```bash
curl -sSL https://get.kubenest.io | sudo bash -s -- \
  --domain kn.acme.corp \
  --admin-email admin@acme.corp
```

## What It Does

1. Installs **k3s** (single-node, traefik disabled)
2. Installs **Helm**
3. Deploys **ingress-nginx** and **cert-manager**
4. Generates all secrets (JWT, encryption, DB passwords)
5. Deploys the KubeNest stack via Helm (backend, hub, UI, operator, PostgreSQL, Redis)
6. Runs database migrations (via init container)
7. Optionally deploys **Grafana**
8. Configures TLS (Let's Encrypt by default)
9. Prints dashboard URL and admin credentials

## Requirements

- Ubuntu 22.04+ (or similar Linux)
- 4GB+ RAM, 2+ vCPU
- Root access
- Ports 80, 443 open
- DNS records pointing to the VM:
  - `app.<domain>` — Dashboard
  - `api.<domain>` — Backend API
  - `hub.<domain>` — WebSocket hub
  - `grafana.<domain>` — Grafana (if enabled)

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--domain` | *required* | Ingress hostname |
| `--admin-email` | *required* | Let's Encrypt contact + admin account |
| `--admin-password` | auto-generated | Admin password |
| `--tls` | `letsencrypt` | `letsencrypt`, `selfsigned`, or `none` |
| `--version` | `latest` | Helm chart version to install |
| `--data-dir` | `/var/lib/kubenest` | Persistent data directory |
| `--external-db` | — | External PostgreSQL URL (skips bundled) |
| `--external-redis` | — | External Redis URL (skips bundled) |
| `--no-grafana` | — | Skip Grafana deployment |
| `--auth-provider` | `oidc` | `oidc`, `keycloak`, `clerk`, `azuread` |

## Idempotency

Re-running the installer is safe:
- k3s: skipped if already installed
- Helm releases: upgraded, not re-installed
- Secrets: existing K8s secrets are preserved
- Migrations: `alembic upgrade head` is idempotent
- TLS: cert-manager handles renewal automatically

## Uninstall

```bash
sudo ./uninstall.sh           # Remove KubeNest stack only
sudo ./uninstall.sh --all     # Remove everything including k3s and data
```

## Architecture

```
VM (Ubuntu 22.04+)
└── k3s (single-node cluster)
    └── kubenest-system namespace
        ├── kubenest-backend   (FastAPI)
        ├── kubenest-hub       (Go WebSocket relay)
        ├── kubenest-ui        (Next.js)
        ├── kubenest-operator  (Go, manages tenant clusters)
        ├── postgresql         (Bitnami)
        ├── redis              (Bitnami)
        └── grafana            (optional)
    └── ingress-nginx
    └── cert-manager
```

## Testing

See `test/` for Vagrant-based smoke tests.
