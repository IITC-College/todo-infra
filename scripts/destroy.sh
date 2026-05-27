#!/usr/bin/env bash
# destroy.sh — tear down iitc-todo-cluster and all associated resources
# Order matters: ALB must be deprovisioned before the cluster is deleted,
# otherwise the VPC ENIs block CloudFormation stack deletion.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME="iitc-todo-cluster"
REGION="eu-west-1"
NAMESPACE="kube-system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

confirm() {
  read -r -p "$1 [y/N] " ans
  [[ "${ans,,}" == "y" ]] || { log "Aborted."; exit 0; }
}

# ---------------------------------------------------------------------------
# Guard
# ---------------------------------------------------------------------------
confirm "This will DELETE cluster '${CLUSTER_NAME}' and ALL its resources. Continue?"

# ---------------------------------------------------------------------------
# 1. Ensure kubeconfig is current
# ---------------------------------------------------------------------------
log "Updating kubeconfig..."
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" 2>/dev/null || {
  log "Could not reach cluster — it may already be deleted. Exiting."
  exit 0
}

# ---------------------------------------------------------------------------
# 2. Delete all Ingress objects (forces ALB deprovisioning)
# ---------------------------------------------------------------------------
log "Deleting all Ingress objects across all namespaces..."
kubectl delete ingress --all --all-namespaces --ignore-not-found=true

log "Waiting 30s for ALB controller to deprovision load balancers..."
sleep 30

# ---------------------------------------------------------------------------
# 3. Uninstall ALB controller Helm release
# ---------------------------------------------------------------------------
log "Uninstalling aws-load-balancer-controller Helm release..."
helm uninstall aws-load-balancer-controller -n "${NAMESPACE}" 2>/dev/null \
  || log "Helm release not found — skipping."

# ---------------------------------------------------------------------------
# 4. Delete application workloads (Services, Deployments, etc.)
# ---------------------------------------------------------------------------
log "Deleting all user-namespace resources..."
# Remove every non-system namespace's deployments/services/configmaps.
# Adjust the label selector or namespaces to match your app namespaces.
for NS in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" \
            | grep -Ev "^(kube-system|kube-public|kube-node-lease|default)$"); do
  log "  Deleting resources in namespace: ${NS}..."
  kubectl delete all --all -n "${NS}" --ignore-not-found=true
  kubectl delete ingress --all -n "${NS}" --ignore-not-found=true
  kubectl delete configmap --all -n "${NS}" --ignore-not-found=true
  kubectl delete secret --all -n "${NS}" --ignore-not-found=true
done

# ---------------------------------------------------------------------------
# 5. Delete PVCs (this triggers EBS volume deletion if reclaimPolicy=Delete)
# ---------------------------------------------------------------------------
log "Deleting all PersistentVolumeClaims across all namespaces..."
kubectl delete pvc --all --all-namespaces --ignore-not-found=true

log "Waiting 20s for PV reclaim to complete..."
sleep 20

# Delete any remaining Released/Failed PVs
log "Deleting any remaining PersistentVolumes..."
kubectl delete pv --all --ignore-not-found=true

# ---------------------------------------------------------------------------
# 6. Remove gp3 StorageClass
# ---------------------------------------------------------------------------
log "Removing gp3 StorageClass..."
kubectl delete -f "${REPO_ROOT}/addons/gp3-storageclass.yaml" --ignore-not-found=true

# ---------------------------------------------------------------------------
# 7. Delete the EKS cluster via eksctl
# ---------------------------------------------------------------------------
log "Deleting EKS cluster '${CLUSTER_NAME}' (this takes ~10 minutes)..."
eksctl delete cluster \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --wait

log "Cluster '${CLUSTER_NAME}' deleted successfully."
