#!/usr/bin/env bash
# KubeNest Control Plane Uninstaller
# Removes KubeNest stack, infrastructure components, and optionally k3s + data.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

NAMESPACE="kubenest-system"
HELM_RELEASE="kubenest"
DATA_DIR="/var/lib/kubenest"
REMOVE_K3S="false"
REMOVE_DATA="false"
FORCE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove-k3s)   REMOVE_K3S="true"; shift ;;
        --remove-data)  REMOVE_DATA="true"; shift ;;
        --force)        FORCE="true";       shift ;;
        --all)          REMOVE_K3S="true"; REMOVE_DATA="true"; shift ;;
        --help|-h)
            echo "Usage: uninstall.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --remove-k3s   Also uninstall k3s"
            echo "  --remove-data  Also remove ${DATA_DIR}"
            echo "  --all          Remove everything (k3s + data)"
            echo "  --force        Skip confirmation prompt"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo -e "${RED}============================================================${NC}"
echo -e "${RED}  KubeNest Uninstaller${NC}"
echo -e "${RED}============================================================${NC}"
echo ""
echo "This will remove:"
echo "  - Helm release: $HELM_RELEASE (namespace: $NAMESPACE)"
echo "  - Grafana (if installed)"
echo "  - cert-manager"
echo "  - ingress-nginx"
[[ "$REMOVE_K3S" == "true" ]]  && echo "  - k3s"
[[ "$REMOVE_DATA" == "true" ]] && echo "  - Data directory: $DATA_DIR"
echo ""

if [[ "$FORCE" != "true" ]]; then
    read -r -p "Continue? [y/N] " response
    [[ "$response" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }
fi

# Remove KubeNest Helm release
if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "$HELM_RELEASE"; then
    info "Removing KubeNest Helm release..."
    helm uninstall "$HELM_RELEASE" -n "$NAMESPACE"
    ok "KubeNest removed"
fi

# Remove Grafana
if helm list -n "$NAMESPACE" 2>/dev/null | grep -q grafana; then
    info "Removing Grafana..."
    helm uninstall grafana -n "$NAMESPACE"
    ok "Grafana removed"
fi

# Remove namespace
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    info "Removing namespace $NAMESPACE..."
    kubectl delete namespace "$NAMESPACE" --timeout=120s
    ok "Namespace removed"
fi

# Remove cert-manager
if helm list -n cert-manager 2>/dev/null | grep -q cert-manager; then
    info "Removing cert-manager..."
    helm uninstall cert-manager -n cert-manager
    kubectl delete namespace cert-manager --timeout=60s 2>/dev/null || true
    ok "cert-manager removed"
fi

# Remove ingress-nginx
if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
    info "Removing ingress-nginx..."
    helm uninstall ingress-nginx -n ingress-nginx
    kubectl delete namespace ingress-nginx --timeout=60s 2>/dev/null || true
    ok "ingress-nginx removed"
fi

# Remove k3s
if [[ "$REMOVE_K3S" == "true" ]]; then
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        info "Uninstalling k3s..."
        /usr/local/bin/k3s-uninstall.sh
        ok "k3s removed"
    else
        warn "k3s uninstall script not found"
    fi
fi

# Remove data directory
if [[ "$REMOVE_DATA" == "true" ]]; then
    if [[ -d "$DATA_DIR" ]]; then
        info "Removing data directory $DATA_DIR..."
        rm -rf "$DATA_DIR"
        ok "Data directory removed"
    fi
fi

echo ""
ok "KubeNest uninstall complete."
