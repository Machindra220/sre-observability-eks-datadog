#!/bin/bash
# Datadog Agent installation script for EKS
set -e

echo "=== Installing Datadog Agent on EKS ==="

# Step 1 - Add Datadog Helm repository
echo "Adding Datadog Helm repo..."
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Step 2 - Create namespace for Datadog
echo "Creating datadog namespace..."
kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -

# Step 3 - Create Kubernetes secret with API keys
# Keys passed as environment variables - never hardcoded
echo "Creating Datadog secret..."
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --from-literal=app-key=$DD_APP_KEY \
  --namespace datadog \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 4 - Install Datadog agent via Helm
echo "Installing Datadog Helm chart..."
helm upgrade --install datadog-agent datadog/datadog \
  --namespace datadog \
  --values values.yaml \
  --wait \
  --timeout 5m

echo "=== Datadog Agent installed successfully ==="
echo "Verify with: kubectl get pods -n datadog"
