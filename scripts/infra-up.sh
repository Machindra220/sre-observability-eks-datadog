#!/bin/bash
# =============================================================================
# infra-up.sh
# Purpose: Provisions AWS infrastructure and deploys the application to EKS
# Usage:   ./scripts/infra-up.sh
# =============================================================================
set -e  # Exit immediately if any command fails

AWS_REGION="us-east-1"
CLUSTER_NAME="sre-demo-dev-eks-cluster"

# Get absolute paths regardless of where script is run from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo " SRE Demo - Infrastructure Up"
echo "========================================"

# -----------------------------------------------------------------------------
# Step 1: Terraform Apply
# Creates VPC, EKS cluster, and node group on AWS
# Takes 15-20 minutes on first run
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Provisioning AWS Infrastructure (Terraform) ==="
cd "$PROJECT_ROOT/infrastructure/terraform"
terraform apply -auto-approve

# -----------------------------------------------------------------------------
# Step 2: Update kubeconfig
# Adds the new EKS cluster credentials to ~/.kube/config
# Required before any kubectl commands can work
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Connecting kubectl to EKS cluster ==="
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# -----------------------------------------------------------------------------
# Step 3: Wait for node to be Ready
# EKS node takes a few minutes to join the cluster after creation
# kubectl wait blocks until node reports Ready status or timeout
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Waiting for EKS node to be Ready ==="
kubectl wait --for=condition=Ready nodes \
  --all \
  --timeout=300s

# -----------------------------------------------------------------------------
# Step 4: Apply Kubernetes manifests in correct order
# Order matters:
#   namespace first  → all other resources depend on it
#   configmap next   → deployment references it
#   deployment       → creates the app pods
#   service          → exposes the app via LoadBalancer
#   hpa              → enables auto-scaling
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Deploying application to Kubernetes ==="
cd "$PROJECT_ROOT/kubernetes"

# Creates the sre-demo namespace
kubectl apply -f namespace.yaml

# Creates environment configuration (APP_ENV, LOG_LEVEL etc)
kubectl apply -f configmap.yaml

# Deploys the FastAPI application pods
kubectl apply -f deployment.yaml

# Creates AWS LoadBalancer to expose app externally
kubectl apply -f service.yaml

# Enables auto-scaling based on CPU utilization
kubectl apply -f hpa.yaml

# -----------------------------------------------------------------------------
# Step 5: Wait for app pod to be Ready
# Ensures the application is fully started before we proceed
# Checks readinessProbe (/api/ready) is passing
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 5: Waiting for application pod to be Ready ==="
kubectl wait --for=condition=Ready pod \
  -l app=sre-demo-api \
  -n sre-demo \
  --timeout=120s

# -----------------------------------------------------------------------------
# Step 6: Show cluster and app status
# Gives a quick overview of what's running
# LoadBalancer EXTERNAL-IP may take 2-3 minutes to appear
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 6: Cluster Status ==="
echo "--- Nodes ---"
kubectl get nodes

echo ""
echo "--- Pods ---"
kubectl get pods -n sre-demo

echo ""
echo "--- Service (LoadBalancer URL) ---"
kubectl get svc sre-demo-api -n sre-demo

echo ""
echo "========================================"
echo " Infrastructure is UP"
echo " Wait 2-3 mins for LoadBalancer URL"
echo " Cost reminder: destroy when done!"
echo "========================================"
