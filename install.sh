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
VERSION="2.0.0"
DATA_DIR="/var/lib/kubenest"
EXTERNAL_DB=""
EXTERNAL_REDIS=""
AUTH_PROVIDER="oidc"
NAMESPACE="kubenest-system"
HELM_RELEASE="kubenest"
HELM_OCI="oci://ghcr.io/kubenesthq/kubenest"
K3S_VERSION="v1.35.1+k3s1"
INGRESS_NGINX_VERSION="4.15.1"
CERT_MANAGER_VERSION="v1.20.1"

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
            echo "  --version         Helm chart version (default: 2.0.0)"
            echo "  --data-dir        Persistent data directory (default: /var/lib/kubenest)"
            echo "  --external-db     postgres://... (skip bundled PostgreSQL)"
            echo "  --external-redis  redis://... (skip bundled Redis)"
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
# DNS check (informational — does not block installation)
# ---------------------------------------------------------------------------
info "Detecting public IP..."
MY_IP=$(curl -s --max-time 5 https://ifconfig.me || curl -s --max-time 5 https://icanhazip.com || true)
if [[ -n "$MY_IP" ]]; then
    ok "Public IP: ${MY_IP}"
else
    warn "Could not detect public IP"
fi

info "Checking DNS records..."
DNS_OK=true
for sub in app api hub; do
    FQDN="${sub}.${DOMAIN}"
    RESOLVED_IP=$(dig +short "$FQDN" A 2>/dev/null | tail -1)
    if [[ -z "$RESOLVED_IP" ]]; then
        warn "DNS not configured: ${FQDN} does not resolve"
        DNS_OK=false
    elif [[ -n "$MY_IP" && "$RESOLVED_IP" != "$MY_IP" ]]; then
        warn "${FQDN} resolves to ${RESOLVED_IP} but this machine is ${MY_IP}"
        DNS_OK=false
    else
        ok "${FQDN} -> ${RESOLVED_IP}"
    fi
done

if [[ "$DNS_OK" == "false" ]]; then
    echo ""
    warn "DNS records are not yet pointing to this machine."
    if [[ "$TLS" != "none" ]]; then
        warn "TLS certificates will issue automatically once DNS propagates."
        warn "No need to re-run — cert-manager retries in the background."
    fi
    warn ""
    warn "Add these DNS records:"
    warn "  ${DOMAIN}   -> A    -> ${MY_IP:-<this VM IP>}"
    warn "  *.${DOMAIN} -> CNAME -> ${DOMAIN}"
    echo ""
fi

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
    local length="${1:-32}"
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
    # Store admin password if not already present
    kubectl patch secret "$SECRET_NAME" -n "$NAMESPACE" \
        --type merge -p "{\"stringData\":{\"admin-password\":\"$ADMIN_PASSWORD\"}}" 2>/dev/null || true
else
    info "Generating secrets..."
    JWT_SECRET=$(generate_secret 32)
    ENCRYPTION_KEY=$(generate_fernet_key)
    CALLBACK_SECRET=$(generate_secret 32)
    PG_PASSWORD=$(generate_secret 16)

    kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
        --from-literal=jwt-secret="$JWT_SECRET" \
        --from-literal=encryption-key="$ENCRYPTION_KEY" \
        --from-literal=callback-secret="$CALLBACK_SECRET" \
        --from-literal=pg-password="$PG_PASSWORD" \
        --from-literal=admin-password="$ADMIN_PASSWORD"
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
        --version "$INGRESS_NGINX_VERSION" \
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
            --version "$CERT_MANAGER_VERSION" \
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
# 7. Deploy KubeNest via Helm
# ---------------------------------------------------------------------------
info "Deploying KubeNest stack..."

# Build Helm values
HELM_ARGS=(
    --namespace "$NAMESPACE"
    --set "domain=$DOMAIN"
    --set "jwtSecret=$JWT_SECRET"
    --set "backend.admin.email=$ADMIN_EMAIL"
    --set "backend.admin.password=$ADMIN_PASSWORD"
    --set "encryptionKey=$ENCRYPTION_KEY"
    --set "provisioningCallbackSecret=$CALLBACK_SECRET"
    --set "operator.enabled=false"
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
HELM_ARGS+=(--version "$VERSION")

# Deploy from OCI registry
helm upgrade --install "$HELM_RELEASE" "$HELM_OCI" \
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
if [[ "$TLS" == "none" ]]; then
    SCHEME="http"; WS_SCHEME="ws"
else
    SCHEME="https"; WS_SCHEME="wss"
fi

echo -e "  ${CYAN}Dashboard:${NC}  ${SCHEME}://app.${DOMAIN}"
echo -e "  ${CYAN}API:${NC}        ${SCHEME}://api.${DOMAIN}"
echo -e "  ${CYAN}API Docs:${NC}   ${SCHEME}://api.${DOMAIN}/docs"
echo -e "  ${CYAN}Hub:${NC}        ${WS_SCHEME}://hub.${DOMAIN}"

echo ""
echo -e "  ${CYAN}Admin Login:${NC}"
echo -e "    Email:    ${ADMIN_EMAIL}"
echo -e "    Password: kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.admin-password}' | base64 -d"
echo ""
echo -e "  ${CYAN}Namespace:${NC}  ${NAMESPACE}"
echo -e "  ${CYAN}Data Dir:${NC}   ${DATA_DIR}"
echo ""

echo -e "  Re-run this script to upgrade. Secrets and data are preserved."
echo ""
