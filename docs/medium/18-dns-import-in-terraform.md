# Phase 18: Automating DNS with Terraform — Importing Route 53 Resources and Dynamic ELB Hostname Updates

*Part 18 of the SRE Observability on AWS EKS with Datadog series*

---

## Introduction

Phase 17 set up `sre.machindra.online` manually via the AWS Console. It works — but every time `infra-down.sh` / `infra-up.sh` runs, EKS creates a new LoadBalancer with a different hostname. That means manually updating the CNAME record in Route 53 every session.

Phase 18 solves both problems:
1. **Terraform import** — bring manually created resources under Terraform management without recreating them
2. **Dynamic ELB hostname** — Terraform reads the live LoadBalancer hostname from Kubernetes, so `terraform apply` always keeps DNS in sync

---

## What is `terraform import`?

Normally Terraform creates resources from scratch. But when a resource already exists (created manually), `terraform import` links it to a Terraform resource block without touching the real infrastructure.

```
Existing AWS resource  →  terraform import  →  Terraform state
                                                      ↓
                                         Terraform now manages it
```

The resource is not recreated, not modified — just tracked.

---

## Repository Structure

```
infrastructure/terraform/
├── aws/        # EKS, VPC, ECR — destroy freely with infra-down.sh
├── datadog/    # Monitors, SLOs, dashboard — separate state
└── dns/        # Route 53 — NEVER destroyed with infra-down.sh
    ├── providers.tf
    ├── variables.tf
    ├── route53.tf
    └── outputs.tf
```

DNS lives in its own directory with its own state — completely independent from the EKS infrastructure lifecycle.

---

## providers.tf

Two providers are needed — AWS for Route 53, Kubernetes to dynamically fetch the LoadBalancer hostname:

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Fetch EKS cluster details for Kubernetes provider auth
data "aws_eks_cluster" "main" {
  name = var.eks_cluster_name
}

data "aws_eks_cluster_auth" "main" {
  name = var.eks_cluster_name
}

# Kubernetes provider authenticates via EKS cluster token
provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}
```

> **Note on version constraints:**
> - `>= 1.5.0` — Terraform version 1.5.0 or higher
> - `~> 6.0` — AWS provider 6.x only (6.0, 6.1, 6.63... but NOT 7.0)
> - `~>` is the pessimistic constraint — allows minor/patch but locks major version

---

## variables.tf

```hcl
variable "domain_name" {
  default = "machindra.online"
}

variable "subdomain" {
  default = "sre"
}

# EKS cluster name — used to authenticate Kubernetes provider
variable "eks_cluster_name" {
  default = "sre-demo-dev-eks-cluster"
}

# Must match the Kubernetes service name and namespace
variable "k8s_service_name" {
  default = "sre-demo-api"
}

variable "k8s_namespace" {
  default = "sre-demo"
}
```

---

## route53.tf

The key change from Phase 17 — `records` is now fetched dynamically from the live Kubernetes service instead of hardcoded:

```hcl
# Read live LoadBalancer hostname from Kubernetes service
data "kubernetes_service" "app" {
  metadata {
    name      = var.k8s_service_name
    namespace = var.k8s_namespace
  }
}

resource "aws_route53_zone" "main" {
  name    = var.domain_name
  comment = "Managed by Terraform"

  tags = {
    Project   = "sre-observability"
    ManagedBy = "terraform"
  }
}

resource "aws_route53_record" "sre_cname" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "${var.subdomain}.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300

  # Dynamically fetched — no hardcoded ELB hostnames
  records = [data.kubernetes_service.app.status.0.load_balancer.0.ingress.0.hostname]
}
```

---

## Step-by-Step Import

### Step 1 — Init

```bash
cd infrastructure/terraform/dns
terraform init
```

Downloads AWS and Kubernetes providers.

### Step 2 — Get the hosted zone ID

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='machindra.online.'].Id" \
  --output text
```

Output: `/hostedzone/Z0074656I9NSZ0EWPP09`

Use only the ID part: `Z0074656I9NSZ0EWPP09`

### Step 3 — Import the hosted zone

The import command format is always:
```
terraform import <resource_type>.<resource_label> <aws_resource_id>
```

Where to find the correct import syntax → Terraform Registry docs for each resource → "Import" section at the bottom.

```bash
terraform import aws_route53_zone.main Z0074656I9NSZ0EWPP09
```

Output:
```
aws_route53_zone.main: Import prepared!
aws_route53_zone.main: Refreshing state... [id=Z0074656I9NSZ0EWPP09]
Import successful!
```

### Step 4 — Import the CNAME record

Route 53 record import ID format: `ZONE_ID_RECORD-NAME_TYPE`

```bash
terraform import aws_route53_record.sre_cname \
  Z0074656I9NSZ0EWPP09_sre.machindra.online_CNAME
```

Output:
```
aws_route53_record.sre_cname: Import prepared!
Import successful!
```

### Step 5 — Plan and apply

```bash
terraform plan
```

Expected output:
```
# aws_route53_zone.main will be updated in-place
~ tags = {
    + "ManagedBy" = "terraform"
    + "Project"   = "sre-observability"
  }

Plan: 0 to add, 1 to change, 0 to destroy.

Changes to Outputs:
  + app_url      = "http://sre.machindra.online/api/health"
  + elb_hostname = "a088aea33803f4c038ce5781a63dbbab-2089612467.us-east-1.elb.amazonaws.com"
```

Only tags are added — no destructive changes. Apply:

```bash
terraform apply
```

```
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

> **Screenshot:** `docs/screenshots/phase-18/01-terraform-apply-complete.png`

---

## The Automation Flow

After Phase 18, the workflow after every session is:

```
./scripts/infra-up.sh
        ↓
EKS + LoadBalancer created (new hostname)
        ↓
cd infrastructure/terraform/dns
terraform apply
        ↓
Kubernetes provider reads live sre-demo-api service
        ↓
Route 53 CNAME updated to new ELB hostname automatically
        ↓
curl http://sre.machindra.online/api/health → ✅
```

No manual hostname copy-paste ever again.

---

## What Happens if tfstate is Lost

| Situation | Solution |
|---|---|
| Lost `tfstate`, have `tfstate.backup` | `cp terraform.tfstate.backup terraform.tfstate` |
| Lost both files | Re-run `terraform import` for each resource |
| Want to stop using Terraform | Just delete `.tf` files — AWS resources keep running |

**Resources in AWS are never affected by losing tfstate** — it's only Terraform's local memory. Re-importing is straightforward and safe.

---

## Why DNS State is Separate from Infra State

| State file | Destroyed by `infra-down.sh` | Contains |
|---|---|---|
| `aws/terraform.tfstate` | ✅ Yes | EKS, VPC, ECR |
| `datadog/terraform.tfstate` | ❌ No | Monitors, SLOs, Dashboard |
| `dns/terraform.tfstate` | ❌ No | Route 53 zone + records |

If Route 53 were in the same state as EKS, running `infra-down.sh` would delete the hosted zone — requiring BigRock nameserver updates every session. Keeping it separate means the domain always works, even when EKS is down.

---

## Cost Reminder

| Resource | Cost |
|---|---|
| Route 53 Hosted Zone | $0.50/month |
| DNS queries | ~$0 (minimal traffic) |

The hosted zone keeps running even when EKS is destroyed — that's intentional. At $0.50/month it's negligible, but delete the hosted zone if you want zero DNS costs between sessions (requires BigRock nameserver reset on next use).

---

## Real Issues Encountered

**AWS provider version mismatch:**
The `.terraform.lock.hcl` had AWS provider `6.63.0` locked, but `providers.tf` specified `~> 5.0`. Fix: update constraint to `~> 6.0` matching the installed version, then `terraform init`.

**Resource already in state error on re-import:**
After changing `providers.tf` and re-running `terraform init`, the existing state was preserved — no re-import needed. Terraform correctly reused the existing state entries.

---

## Screenshots to Capture

```
docs/screenshots/phase-18/
├── 01-terraform-init-providers.png
├── 02-terraform-import-zone.png
├── 03-terraform-import-cname.png
├── 04-terraform-plan-no-destroy.png
└── 05-terraform-apply-complete.png
```

---

## Key Takeaways

- `terraform import` links existing resources to Terraform without recreating them — write the resource block first, then import
- Import ID format varies per resource — always check the Terraform Registry "Import" section
- `~>` version constraint locks the major version — `~> 6.0` allows 6.x but not 7.0
- DNS state must be kept separate from app infrastructure state — different lifecycles
- Dynamic ELB hostname via Kubernetes data source eliminates manual CNAME updates after every deploy

---

*Repository: [github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)*