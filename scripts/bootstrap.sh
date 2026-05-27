#!/usr/bin/env bash
# bootstrap.sh — provision the iitc-todo-cluster and install all core addons
# Idempotent: safe to re-run after partial failures.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME="iitc-todo-cluster"
REGION="eu-west-1"
ACCOUNT_ID="050752632489"
NAMESPACE="kube-system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# 1. Create EKS cluster (skip if already exists)
# ---------------------------------------------------------------------------
log "Checking if cluster '${CLUSTER_NAME}' exists..."
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
     --query "cluster.status" --output text 2>/dev/null | grep -q "ACTIVE"; then
  log "Cluster already ACTIVE — skipping eksctl create."
else
  log "Creating cluster (this takes ~15 minutes)..."
  eksctl create cluster -f "${REPO_ROOT}/cluster/eksctl-cluster.yaml"
  log "Cluster created."
fi

# ---------------------------------------------------------------------------
# 2. Update local kubeconfig
# ---------------------------------------------------------------------------
log "Updating kubeconfig..."
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}"

# Sanity check
kubectl get nodes

# ---------------------------------------------------------------------------
# 3. Resolve VPC ID and patch alb-controller-values.yaml
# ---------------------------------------------------------------------------
log "Resolving VPC ID..."
VPC_ID=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
log "VPC ID: ${VPC_ID}"

VALUES_FILE="${REPO_ROOT}/addons/alb-controller-values.yaml"
# Replace the placeholder in a temp copy so the source file is not mutated
TMP_VALUES=$(mktemp /tmp/alb-values-XXXXXX.yaml)
sed "s|<VPC_ID>|${VPC_ID}|g" "${VALUES_FILE}" > "${TMP_VALUES}"

# ---------------------------------------------------------------------------
# 4. Install AWS Load Balancer Controller via Helm
# ---------------------------------------------------------------------------
log "Adding eks Helm repo..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

log "Installing / upgrading aws-load-balancer-controller..."
helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace "${NAMESPACE}" \
  --values "${TMP_VALUES}" \
  --wait \
  --timeout 5m

rm -f "${TMP_VALUES}"

log "Verifying ALB controller pods..."
kubectl rollout status deployment/aws-load-balancer-controller -n "${NAMESPACE}" --timeout=120s
kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=aws-load-balancer-controller"

# ---------------------------------------------------------------------------
# 5. Install metrics-server
# ---------------------------------------------------------------------------
log "Installing metrics-server..."
kubectl apply -f \
  https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl rollout status deployment/metrics-server -n "${NAMESPACE}" --timeout=120s
log "metrics-server ready."

# ---------------------------------------------------------------------------
# 6. Apply gp3 StorageClass and demote gp2
# ---------------------------------------------------------------------------
log "Applying gp3 StorageClass..."
kubectl apply -f "${REPO_ROOT}/addons/gp3-storageclass.yaml"

log "Removing default annotation from gp2 StorageClass..."
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  2>/dev/null || log "gp2 not found or already patched — skipping."

log "Current StorageClasses:"
kubectl get storageclass

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Bootstrap complete. Cluster '${CLUSTER_NAME}' is ready."
kubectl get nodes -o wide
