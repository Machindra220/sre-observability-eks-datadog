# Datadog Agent Installation

## Prerequisites
- EKS cluster running
- kubectl connected to cluster
- Helm installed
- Datadog account with API key and APP key

## Installation

```bash
export DD_API_KEY=<your-datadog-api-key>
export DD_APP_KEY=<your-datadog-app-key>
cd datadog/agent
./install.sh
```

## Verify

```bash
kubectl get pods -n datadog
kubectl logs -n datadog -l app=datadog-agent --tail=50
```

## Uninstall

```bash
helm uninstall datadog-agent -n datadog
kubectl delete namespace datadog
```