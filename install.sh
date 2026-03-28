#!/usr/bin/env bash
# KubeNest Control Plane Installer
# Usage: curl -sSL https://get.kubenest.io | bash -s -- --domain kn.acme.corp --admin-email admin@acme.corp
#
# Idempotent: safe to re-run. Existing secrets are preserved, helm releases are upgraded.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DOMAIN=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
TLS="letsencrypt"
VERSION="latest"
DATA_DIR="/var/lib/kubenest"
EXTERNAL_DB=""
EXTERNAL_REDIS=""
GRAFANA="true"
AUTH_PROVIDER="oidc"
NAMESPACE="kubenest-system"
HELM_RELEASE="kubenest"
HELM_REPO="https://kubenesthq.github.io/kubenest-helm"
K3S_VERSION="v1.31.4+k3s1"

# ---------------------------------------------------------------------------
# Colors / helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)          DOMAIN="$2";          shift 2 ;;
        --admin-email)     ADMIN_EMAIL="$2";     shift 2 ;;
        --admin-password)  ADMIN_PASSWORD="$2";  shift 2 ;;
        --tls)             TLS="$2";             shift 2 ;;
        --version)         VERSION="$2";         shift 2 ;;
        --data-dir)        DATA_DIR="$2";        shift 2 ;;
        --external-db)     EXTERNAL_DB="$2";     shift 2 ;;
        --external-redis)  EXTERNAL_REDIS="$2";  shift 2 ;;
        --no-grafana)      GRAFANA="false";      shift   ;;
        --grafana)         GRAFANA="true";       shift   ;;
        --auth-provider)   AUTH_PROVIDER="$2";   shift 2 ;;
        --help|-h)
            echo "Usage: install.sh --domain <domain> --admin-email <email> [OPTIONS]"
            echo ""
            echo "Required:"
            echo "  --domain          Ingress hostname (e.g. kn.acme.corp)"
            echo "  --admin-email     Let's Encrypt contact + initial admin account"
            echo ""
            echo "Optional:"
            echo "  --admin-password  Admin password (auto-generated if omitted)"
            echo "  --tls             letsencrypt (default), selfsigned, none"
            echo "  --version         Helm chart version: latest (default), or pinned (v2.0.0)"
            echo "  --data-dir        Persistent data directory (default: /var/lib/kubenest)"
            echo "  --external-db     postgres://... (skip bundled PostgreSQL)"
            echo "  --external-redis  redis://... (skip bundled Redis)"
            echo "  --no-grafana      Skip Grafana deployment"
            echo "  --auth-provider   oidc (default), keycloak, clerk, azuread"
            exit 0
            ;;
        *) die "Unknown option: $1. Use --help for usage." ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate required params
# ---------------------------------------------------------------------------
[[ -z "$DOMAIN" ]]      && die "--domain is required"
[[ -z "$ADMIN_EMAIL" ]] && die "--admin-email is required"

# Auto-generate admin password if not provided
if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
info "KubeNest Control Plane Installer"
info "Domain: $DOMAIN | Admin: $ADMIN_EMAIL | TLS: $TLS"
echo ""

if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (or with sudo)"
fi

for cmd in curl openssl; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ---------------------------------------------------------------------------
# 1. Install k3s
# ---------------------------------------------------------------------------
if command -v k3s &>/dev/null; then
    CURRENT_K3S=$(k3s --version 2>/dev/null | head -1 || true)
    ok "k3s already installed: $CURRENT_K3S"
else
    info "Installing k3s ${K3S_VERSION}..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
        --disable traefik \
        --write-kubeconfig-mode 644 \
        --data-dir "${DATA_DIR}/k3s"
    ok "k3s installed"
fi

# Wait for k3s to be ready
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
info "Waiting for k3s node to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s
ok "k3s node ready"

# ---------------------------------------------------------------------------
# 2. Install Helm
# ---------------------------------------------------------------------------
if command -v helm &>/dev/null; then
    ok "Helm already installed: $(helm version --short 2>/dev/null)"
else
    info "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    ok "Helm installed"
fi

# ---------------------------------------------------------------------------
# 3. Create namespace
# ---------------------------------------------------------------------------
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"
ok "Namespace $NAMESPACE ready"

# ---------------------------------------------------------------------------
# 4. Generate and persist secrets (idempotent — keep existing)
# ---------------------------------------------------------------------------
SECRET_NAME="${HELM_RELEASE}-installer-secrets"

generate_secret() {
    local key="$1" length="${2:-32}"
    openssl rand -hex "$length"
}

generate_fernet_key() {
    python3 -c "
import base64, os
key = base64.urlsafe_b64encode(os.urandom(32))
print(key.decode())
" 2>/dev/null || openssl rand -base64 32
}

if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    ok "Installer secrets already exist — preserving"
    JWT_SECRET=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.jwt-secret}' | base64 -d)
    ENCRYPTION_KEY=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.encryption-key}' | base64 -d)
    CALLBACK_SECRET=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.callback-secret}' | base64 -d)
    PG_PASSWORD=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.pg-password}' | base64 -d)
else
    info "Generating secrets..."
    JWT_SECRET=$(generate_secret jwt 32)
    ENCRYPTION_KEY=$(generate_fernet_key)
    CALLBACK_SECRET=$(generate_secret callback 32)
    PG_PASSWORD=$(generate_secret pg 16)

    kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
        --from-literal=jwt-secret="$JWT_SECRET" \
        --from-literal=encryption-key="$ENCRYPTION_KEY" \
        --from-literal=callback-secret="$CALLBACK_SECRET" \
        --from-literal=pg-password="$PG_PASSWORD"
    ok "Secrets generated and stored"
fi

# ---------------------------------------------------------------------------
# 5. Install ingress-nginx
# ---------------------------------------------------------------------------
if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
    ok "ingress-nginx already installed"
else
    info "Installing ingress-nginx..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --set controller.publishService.enabled=true \
        --wait --timeout 120s
    ok "ingress-nginx installed"
fi

# ---------------------------------------------------------------------------
# 6. Install cert-manager (if TLS != none)
# ---------------------------------------------------------------------------
if [[ "$TLS" != "none" ]]; then
    if helm list -n cert-manager 2>/dev/null | grep -q cert-manager; then
        ok "cert-manager already installed"
    else
        info "Installing cert-manager..."
        helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
        helm repo update jetstack
        helm upgrade --install cert-manager jetstack/cert-manager \
            --namespace cert-manager --create-namespace \
            --set crds.enabled=true \
            --wait --timeout 120s
        ok "cert-manager installed"
    fi

    # Create ClusterIssuer
    if [[ "$TLS" == "letsencrypt" ]]; then
        info "Creating Let's Encrypt ClusterIssuer..."
        kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
        ok "Let's Encrypt ClusterIssuer created"
    elif [[ "$TLS" == "selfsigned" ]]; then
        info "Creating self-signed ClusterIssuer..."
        kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF
        ok "Self-signed ClusterIssuer created"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Install Grafana (optional)
# ---------------------------------------------------------------------------
if [[ "$GRAFANA" == "true" ]]; then
    if helm list -n "$NAMESPACE" 2>/dev/null | grep -q grafana; then
        ok "Grafana already installed"
    else
        info "Installing Grafana..."
        helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
        helm repo update grafana

        GRAFANA_ADMIN_PASS=$(generate_secret grafana 12)

        helm upgrade --install grafana grafana/grafana \
            --namespace "$NAMESPACE" \
            --set adminPassword="$GRAFANA_ADMIN_PASS" \
            --set persistence.enabled=true \
            --set persistence.size=2Gi \
            --set "ingress.enabled=true" \
            --set "ingress.ingressClassName=nginx" \
            --set "ingress.hosts[0]=grafana.${DOMAIN}" \
            --wait --timeout 120s

        # Store Grafana password in installer secrets
        kubectl patch secret "$SECRET_NAME" -n "$NAMESPACE" \
            --type merge -p "{\"stringData\":{\"grafana-password\":\"$GRAFANA_ADMIN_PASS\"}}"

        ok "Grafana installed"
    fi
fi

# ---------------------------------------------------------------------------
# 8. Deploy KubeNest via Helm
# ---------------------------------------------------------------------------
info "Deploying KubeNest stack..."

# Build Helm values
HELM_ARGS=(
    --namespace "$NAMESPACE"
    --set "domain=$DOMAIN"
    --set "jwtSecret=$JWT_SECRET"
    --set "backend.admin.email=$ADMIN_EMAIL"
    --set "backend.admin.password=$ADMIN_PASSWORD"
)

# TLS annotations for ingresses
if [[ "$TLS" == "letsencrypt" ]]; then
    HELM_ARGS+=(
        --set "backend.ingress.annotations.cert-manager\\.io/cluster-issuer=letsencrypt-prod"
        --set "hub.ingress.annotations.cert-manager\\.io/cluster-issuer=letsencrypt-prod"
        --set "ui.ingress.annotations.cert-manager\\.io/cluster-issuer=letsencrypt-prod"
    )
elif [[ "$TLS" == "selfsigned" ]]; then
    HELM_ARGS+=(
        --set "backend.ingress.annotations.cert-manager\\.io/cluster-issuer=selfsigned"
        --set "hub.ingress.annotations.cert-manager\\.io/cluster-issuer=selfsigned"
        --set "ui.ingress.annotations.cert-manager\\.io/cluster-issuer=selfsigned"
    )
fi

# External DB
if [[ -n "$EXTERNAL_DB" ]]; then
    HELM_ARGS+=(
        --set "postgresql.enabled=false"
    )
    # Parse and inject external DB connection
    warn "External DB configured — you must set DATABASE_URL in the backend deployment manually"
else
    HELM_ARGS+=(
        --set "postgresql.enabled=true"
        --set "postgresql.auth.password=$PG_PASSWORD"
        --set "postgresql.primary.persistence.existingClaim="
    )
fi

# External Redis
if [[ -n "$EXTERNAL_REDIS" ]]; then
    HELM_ARGS+=(
        --set "redis.enabled=false"
    )
    warn "External Redis configured — you must set REDIS_* env vars in the backend deployment manually"
else
    HELM_ARGS+=(
        --set "redis.enabled=true"
    )
fi

# Chart version
if [[ "$VERSION" != "latest" ]]; then
    HELM_ARGS+=(--version "$VERSION")
fi

# Add Helm repo and deploy
helm repo add kubenest "$HELM_REPO" 2>/dev/null || true
helm repo update kubenest

helm upgrade --install "$HELM_RELEASE" kubenest/kubenest \
    "${HELM_ARGS[@]}" \
    --wait --timeout 300s

ok "KubeNest stack deployed"

# ---------------------------------------------------------------------------
# 9. Wait for all pods to be ready
# ---------------------------------------------------------------------------
info "Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n "$NAMESPACE" --timeout=300s 2>/dev/null || {
    warn "Some pods may still be starting. Check with: kubectl get pods -n $NAMESPACE"
}

# ---------------------------------------------------------------------------
# 10. Print summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  KubeNest Control Plane Installed Successfully!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${CYAN}Dashboard:${NC}  https://app.${DOMAIN}"
echo -e "  ${CYAN}API:${NC}        https://api.${DOMAIN}"
echo -e "  ${CYAN}API Docs:${NC}   https://api.${DOMAIN}/docs"
echo -e "  ${CYAN}Hub:${NC}        wss://hub.${DOMAIN}"

if [[ "$GRAFANA" == "true" ]]; then
    GRAFANA_PASS=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.grafana-password}' 2>/dev/null | base64 -d || echo "(check secret)")
    echo -e "  ${CYAN}Grafana:${NC}    https://grafana.${DOMAIN}"
    echo -e "  ${CYAN}Grafana:${NC}    admin / ${GRAFANA_PASS}"
fi

echo ""
echo -e "  ${CYAN}Admin Login:${NC}"
echo -e "    Email:    ${ADMIN_EMAIL}"
echo -e "    Password: ${ADMIN_PASSWORD}"
echo ""
echo -e "  ${CYAN}Namespace:${NC}  ${NAMESPACE}"
echo -e "  ${CYAN}Data Dir:${NC}   ${DATA_DIR}"
echo ""

if [[ "$TLS" == "none" ]]; then
    warn "TLS is disabled. Replace https:// with http:// in URLs above."
fi

echo -e "  Re-run this script to upgrade. Secrets and data are preserved."
echo ""
