# Phase 15: Turning Observability into Code — Datadog Monitors, SLOs, and Dashboards with Terraform

*Part 15 of 16 in the SRE Observability on AWS EKS with Datadog series*

---

## Introduction

Every monitor, SLO, and dashboard built across phases 9–11 was created manually through the Datadog UI. That works fine for one environment — but it doesn't scale. If you need to recreate the same setup in a staging environment, onboard a new service, or recover from accidental deletion, you're clicking through the same screens again.

Phase 15 converts all of that into Terraform code using the Datadog provider. The result: the entire observability configuration is version-controlled, peer-reviewable, and reproducible with a single `terraform apply`.

---

## What Gets Converted

| Resource | Phase Created | Terraform Resource |
|---|---|---|
| Golden Signals dashboard | Phase 9 | `datadog_dashboard` |
| Availability SLO | Phase 10 | `datadog_service_level_objective` |
| Latency SLO | Phase 10 | `datadog_service_level_objective` |
| P1 API Availability monitor | Phase 11 | `datadog_monitor` |
| P2 High Error Rate monitor | Phase 11 | `datadog_monitor` |
| P2 Pod Restart Rate monitor | Phase 11 | `datadog_monitor` |
| P2 SLO Burn Rate monitor | Phase 11 | `datadog_monitor` |
| P3 High Latency monitor | Phase 11 | `datadog_monitor` |

**8 resources total — 1 dashboard, 2 SLOs, 5 monitors.**

---

## Repository Structure

All Datadog Terraform code lives in its own directory, separate from the AWS infrastructure Terraform:

```
infrastructure/
└── terraform/
    ├── vpc.tf              # AWS VPC (Phase 2)
    ├── eks.tf              # AWS EKS (Phase 2)
    ├── ecr.tf              # AWS ECR (Phase 2)
    └── datadog/            # ← Phase 15 — Datadog as Code
        ├── providers.tf
        ├── variables.tf
        ├── monitors.tf
        ├── slos.tf
        ├── dashboard.tf
        ├── outputs.tf
        └── terraform.tfvars.example
```

Keeping Datadog state separate from AWS state means `terraform destroy` on AWS infra never touches Datadog resources.

---

## Provider Configuration

The Datadog Terraform provider needs an API key and APP key to authenticate. Rather than hardcoding them or exporting environment variables, we fetch them directly from AWS Secrets Manager — where they were already stored in Phase 5.

```hcl
# providers.tf

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.39"
    }
    # AWS provider — only used to read secrets
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local state — terraform.tfstate stored in this directory
}

provider "aws" {
  region = "us-east-1"
}

# Fetch keys from AWS Secrets Manager (secret: sre-demo/datadog2)
data "aws_secretsmanager_secret" "datadog" {
  name = "sre-demo/datadog2"
}

data "aws_secretsmanager_secret_version" "datadog" {
  secret_id = data.aws_secretsmanager_secret.datadog.id
}

locals {
  datadog_secrets = jsondecode(
    data.aws_secretsmanager_secret_version.datadog.secret_string
  )
}

provider "datadog" {
  api_key = local.datadog_secrets["DD_API_KEY"]
  app_key = local.datadog_secrets["DD_APP_KEY"]
  api_url = "https://api.datadoghq.com/"
}
```

No manual key exports before `terraform apply` — the AWS credentials already on the machine handle secret retrieval.

---

## Variables

All resource-specific values are parameterized so the same Terraform can target any service or environment:

```hcl
# variables.tf

variable "env"            { default = "dev" }
variable "service"        { default = "sre-demo-api" }
variable "kube_namespace" { default = "sre-demo" }
variable "team"           { default = "sre" }
```

Every metric query uses `${var.service}` and `${var.env}` — changing these two values re-targets the entire configuration.

---

## Monitors

All five monitors from Phase 11 are defined in `monitors.tf`. Each monitor name ends with `- created-using-terraform-code` to distinguish Terraform-managed resources from manually created ones in the UI.

### P1 — API Availability

```hcl
resource "datadog_monitor" "api_availability" {
  name     = "[sre-demo-api] API Availability - No Traffic - created-using-terraform-code"
  type     = "metric alert"
  priority = 1

  # Alert when request count drops to zero in last 5 minutes
  query = "sum(last_5m):count:trace.fastapi.request{service:${var.service},env:${var.env}} < 1"

  monitor_thresholds {
    critical = 1
    warning  = 5
  }

  # @workflow handle triggers Phase 12 incident automation
  message = <<-EOT
    {{#is_alert}}🔴 No traffic on sre-demo-api.{{/is_alert}}
    @workflow-sre-create-incident
  EOT

  tags = ["team:${var.team}"]
}
```

### P2 — High Error Rate

```hcl
resource "datadog_monitor" "high_error_rate" {
  name     = "[sre-demo-api] High Error Rate - created-using-terraform-code"
  type     = "metric alert"
  priority = 2

  query = "sum(last_5m):sum:trace.fastapi.request.errors{service:${var.service},env:${var.env}} > 10"

  monitor_thresholds {
    critical = 10
    warning  = 5
  }

  tags = ["team:${var.team}"]
}
```

### P2 — Pod Restart Rate

```hcl
resource "datadog_monitor" "pod_restart_rate" {
  name     = "[sre-demo-api] Pod Restart Rate - created-using-terraform-code"
  type     = "metric alert"
  priority = 2

  # kubernetes_state metrics from the Datadog K8s integration
  query = "sum(last_15m):sum:kubernetes_state.container.restarts{kube_namespace:${var.kube_namespace},kube_deployment:${var.service}}.as_count() > 3"

  monitor_thresholds {
    critical = 3
    warning  = 1
  }

  tags = ["team:${var.team}"]
}
```

### P2 — SLO Burn Rate (Error Rate Proxy)

```hcl
resource "datadog_monitor" "slo_burn_rate" {
  name     = "[sre-demo-api] SLO Error Budget Burn Rate - created-using-terraform-code"
  type     = "metric alert"
  priority = 2

  # Error rate % as a proxy for SLO budget pressure
  query = "sum(last_5m):sum:trace.fastapi.request.errors{service:${var.service},env:${var.env}}.as_count() / sum:trace.fastapi.request.hits{service:${var.service},env:${var.env}}.as_count() * 100 > 1"

  monitor_thresholds {
    critical = 1
    warning  = 0.5
  }

  tags = ["team:${var.team}"]
}
```

### P3 — High p99 Latency

```hcl
resource "datadog_monitor" "high_latency" {
  name     = "[sre-demo-api] High p99 Latency - created-using-terraform-code"
  type     = "metric alert"
  priority = 3

  query = "percentile(last_5m):p99:trace.fastapi.request{service:${var.service},env:${var.env}} > 2"

  monitor_thresholds {
    critical = 2
    warning  = 1
  }

  tags = ["team:${var.team}"]
}
```

---

## SLOs

Both SLOs from Phase 10 — availability and latency — are defined as ratio-based metric SLOs:

```hcl
# slos.tf

resource "datadog_service_level_objective" "availability" {
  name = "sre-demo-api Availability"
  type = "metric"

  query {
    numerator   = "sum:trace.fastapi.request.hits{...,!http.status_class:5xx}.as_count()"
    denominator = "sum:trace.fastapi.request.hits{...}.as_count()"
  }

  thresholds {
    timeframe = "30d"
    target    = 99.0
    warning   = 99.5
  }

  tags = ["team:${var.team}"]
}

resource "datadog_service_level_objective" "latency" {
  name = "sre-demo-api p99 Latency"
  type = "metric"

  query {
    numerator   = "sum:trace.fastapi.request.hits{...,http.status_class:2xx}.as_count()"
    denominator = "sum:trace.fastapi.request.hits{...}.as_count()"
  }

  thresholds {
    timeframe = "30d"
    target    = 90.0
    warning   = 95.0
  }

  tags = ["team:${var.team}"]
}
```

---

## Dashboard

The Golden Signals dashboard is defined with four widget groups — Traffic, Latency, Errors, Saturation:

```hcl
# dashboard.tf

resource "datadog_dashboard" "golden_signals" {
  title       = "SRE — Golden Signals"
  layout_type = "ordered"

  widget {
    group_definition {
      title = "Traffic"
      widget {
        timeseries_definition {
          request {
            q = "sum:trace.fastapi.request.hits{service:${var.service}}.as_rate()"
          }
        }
      }
    }
  }

  # ... Latency (p50/p95/p99), Errors (rate + % query value), Saturation (CPU + memory)

  tags = ["team:${var.team}"]
}
```

---

## Applying

```bash
cd infrastructure/terraform/datadog

# Init — downloads Datadog and AWS providers
terraform init

# Plan — shows all 8 resources to be created
terraform plan

# Apply
terraform apply
```

After apply, outputs show all resource IDs:

```
Apply complete! Resources: 2 added, 6 changed, 0 destroyed.

Outputs:

dashboard_url = "https://app.datadoghq.com/dashboard/kru-n54-vsq"
monitor_ids = {
  "api_availability" = "320136106"
  "high_error_rate"  = "320136105"
  "high_latency"     = "320136096"
  "pod_restart_rate" = "320136097"
  "slo_burn_rate"    = "320136955"
}
slo_ids = {
  "availability" = "0b62df234d3e5eef96b96c17b3aee808"
  "latency"      = "8d5aa1b5a2a0556e8cffbb04f5e1b866"
}
```

---

## Real Issues Encountered

### 1 — APP key missing API scope (401 on monitors)

The initial APP key was created in Datadog without enabling the **Monitors** scope. Dashboard and SLO creation passed; monitor validation returned 401 Unauthorized.

Fix: delete and recreate the APP key in Datadog with all required scopes enabled — `monitors_read`, `monitors_write`, `dashboards_read`, `dashboards_write`, `slos_read`, `slos_write`. Update the secret in AWS Secrets Manager:

```bash
aws secretsmanager update-secret \
  --secret-id sre-demo/datadog2 \
  --secret-string '{"DD_API_KEY":"...","DD_APP_KEY":"<new-key>"}'
```

### 2 — burn_rate() query not supported on plan

The SLO burn rate monitor initially used the `burn_rate()` function:

```hcl
# This failed — burn_rate() requires a higher Datadog plan
query = "burn_rate(\"${slo_id}\").over(\"1h\")... > 14.4"
```

Replaced with an equivalent error rate percentage query that works on all plans:

```hcl
query = "sum(last_5m):sum:trace.fastapi.request.errors{...}.as_count() / sum:trace.fastapi.request.hits{...}.as_count() * 100 > 1"
```

### 3 — Tag keys restricted by org policy

The Datadog organisation only allows `team` and `ai` as tag keys. Using `env:dev` or `service:sre-demo-api` as tags caused a 400 Bad Request on dashboard creation:

```
Invalid tag format. Valid tag keys are: team, ai.
```

All resource tags updated to `["team:${var.team}"]` only. Service and env scoping is handled inside metric queries, not tags.

---

## .gitignore

The following are already covered by the existing `.gitignore`:

```
*.tfstate          # local state file — never commit
*.tfstate.backup   # state backups
*.tfvars           # contains sensitive variable values
**/.terraform/     # provider binaries
```

`terraform.tfvars.example` is safe to commit — it contains no secrets.

---

## Screenshots to Capture

```
docs/screenshots/phase-15/
├── 01-terraform-plan-8-resources.png
├── 02-terraform-apply-complete.png
├── 03-monitors-in-datadog-ui.png
├── 04-slos-in-datadog-ui.png
└── 05-golden-signals-dashboard.png
```

---

## Key Takeaways

- **Observability config is infrastructure.** It deserves version control, code review, and the same deployment discipline as application code.
- **Parameterize everything.** Using `var.service` and `var.env` in every query means the same Terraform can manage multiple services with a single variable change.
- **APP key scopes matter.** Create the key with all required scopes upfront — Datadog does not show the key value again after creation.
- **Separate Datadog state from AWS state.** Independent state files mean independent lifecycles — destroying EKS never risks destroying monitors.
- **Tag policies are org-level.** Check your Datadog org's allowed tag keys before writing Terraform — undocumented restrictions surface only at apply time.

---

## What's Next — Phase 16: Complete SRE Platform Summary

Phase 15 closes the infrastructure-as-code loop. Everything — AWS, Kubernetes, and now Datadog — is defined in code.

Phase 16 is the final phase: a complete end-to-end summary of the 16-phase SRE observability platform, the full architecture, lessons learned, and what a production hardening roadmap looks like from here.

---

*All code: [github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)*

*Next: [Phase 16 — Building a Complete SRE Observability Pipeline](#)*