# Provisioning AWS EKS Infrastructure with Terraform: A Complete SRE Walkthrough

## Building production-style AWS infrastructure for Kubernetes observability — VPC, EKS, and ECR with Terraform

---

## Problem

Most Kubernetes tutorials skip the infrastructure layer entirely — they hand you a 
working cluster and jump straight to deploying applications. In real SRE work, 
provisioning and maintaining the infrastructure is half the job.

This article covers how I provisioned a complete AWS EKS environment using Terraform 
as Phase 2 of a larger SRE observability project. Every resource is reproducible, 
version-controlled, and destroyable — no manual console clicks.

---

## Architecture

```text
Terraform (Local WSL2)
         |
         v
    AWS Account
         |
    +----+----+
    |         |
   VPC       ECR
    |         |
  Public    Docker
  Subnets   Images
    |
   EKS
    |
  +--+--+
  |     |
Node   System
Group  Pods
(t3.small)
```

---

## Technology Stack

| Component | Choice | Reason |
|---|---|---|
| IaC | Terraform 1.15.8 | Industry standard, reproducible |
| AWS Provider | hashicorp/aws ~> 5.0 | Latest stable |
| VPC Module | terraform-aws-modules/vpc ~> 5.0 | Battle-tested, handles subnet tagging |
| EKS Module | terraform-aws-modules/eks ~> 20.0 | Manages cluster + node groups + IAM |
| Kubernetes | EKS 1.32 | Latest stable at time of writing |
| Node Type | t3.small | Cost-optimized for learning (upgradeable) |
| Region | us-east-1 | Lowest AWS pricing |

---

## Repository Structure

```text
infrastructure/
└── terraform/
    ├── versions.tf     # Provider version pins
    ├── variables.tf    # All configurable values
    ├── outputs.tf      # Exported values
    ├── vpc.tf          # VPC + subnets
    ├── eks.tf          # EKS cluster + node group
    ├── ecr.tf          # Container registry
    └── .terraform.lock.hcl  # Provider lock file (committed)
```

---

## Infrastructure Design Decisions

### VPC Design

```text
CIDR: 10.0.0.0/16

Public Subnets:
  10.0.101.0/24 (us-east-1a)
  10.0.102.0/24 (us-east-1b)

Private Subnets:
  10.0.1.0/24 (us-east-1a)
  10.0.2.0/24 (us-east-1b)
```

**No NAT Gateway** — saves ~$32/month for a learning environment. EKS nodes run 
in public subnets with public IPs. In production, nodes should be in private 
subnets behind a NAT Gateway.

**Two Availability Zones** — minimum for EKS. Provides resilience for the control 
plane and allows node group distribution.

**Required subnet tags for EKS:**
```hcl
public_subnet_tags = {
  "kubernetes.io/role/elb" = "1"
}
private_subnet_tags = {
  "kubernetes.io/role/internal-elb" = "1"
}
```
Without these tags, the AWS Load Balancer Controller cannot discover subnets.

### EKS Design

```hcl
cluster_name    = "sre-demo-dev-eks-cluster"
cluster_version = "1.32"

eks_managed_node_groups = {
  default = {
    instance_types = ["t3.small"]
    min_size       = 1
    max_size       = 2
    desired_size   = 1
  }
}
```

**Managed node groups** — AWS handles node provisioning, AMI updates, and 
replacement. Less operational overhead than self-managed nodes.

**`enable_cluster_creator_admin_permissions = true`** — grants the Terraform 
IAM user admin access to the cluster. Without this, even the user who created 
the cluster cannot run `kubectl` commands.

**Public endpoint access** — `cluster_endpoint_public_access = true` allows 
`kubectl` from local machine. In production, restrict to VPN/bastion IP ranges.

### ECR Design

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-${var.environment}-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
```

**Naming convention:** `sre-demo-dev-api` — includes project, environment, 
and purpose. Scales cleanly to `sre-demo-staging-api` and `sre-demo-prod-api`.

**`scan_on_push = true`** — AWS scans every pushed image for CVEs automatically. 
Free basic scanning included with ECR.

**`MUTABLE` tags** — allows overwriting tags. We use Git SHA tags for every 
deployment so overwriting isn't a concern. IMMUTABLE is safer for production.

**Lifecycle policy — keep last 10 images:**
```hcl
resource "aws_ecr_lifecycle_policy" "app" {
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
```
Without a lifecycle policy, ECR accumulates images indefinitely and storage 
costs grow over time.

---

## Implementation

### Step 1 — Provider Configuration

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```

Always pin provider versions. `~> 5.0` allows patch updates (5.0.1, 5.1.0) 
but prevents breaking major version changes.

### Step 2 — Initialize

```bash
terraform init
```

Downloads providers and modules. Generates `.terraform.lock.hcl` — commit 
this file to ensure everyone uses identical provider versions.

### Step 3 — Plan

```bash
terraform plan
```

Always review the plan before applying. Key things to verify:
- Resource count matches expectations
- No unexpected destroys
- Naming follows your convention

Our plan: **53 resources to add, 0 to change, 0 to destroy.**

### Step 4 — Apply

```bash
terraform apply
```

EKS control plane creation takes **10-15 minutes**. This is normal — AWS is 
provisioning the managed Kubernetes API server, etcd, and networking components.

---

## Troubleshooting Encountered

### Problem 1 — IAM Permissions

**Error:**
User: terraform-local-user is not authorized to perform:
ecr:CreateRepository
iam:CreateRole
logs:CreateLogGroup


**Root cause:** IAM user had no policies attached.

**Fix:** Attached `AdministratorAccess` policy to `terraform-local-user`.

**Production note:** Never use AdministratorAccess in production. Create a 
custom IAM policy scoped to exactly the permissions Terraform needs.

### Problem 2 — Partial Apply State

First apply failed mid-way due to IAM permissions. Terraform created 30 of 
53 resources before failing.

**What happened:** Terraform's state file recorded the 30 successfully created 
resources. Second apply only needed to create the remaining 23.

**Lesson:** Terraform state is your source of truth. Never manually delete 
state files. If resources exist in AWS but not in state, use `terraform import`.

### Problem 3 — Node Group Creation Failed

**Error:**
Ec2SubnetInvalidConfiguration: One or more Amazon EC2 Subnets
does not automatically assign public IP addresses


**Root cause:** Public subnets didn't have auto-assign public IP enabled. 
EC2 nodes launched without public IPs couldn't reach the EKS control plane.

**Fix:** Added `map_public_ip_on_launch = true` to VPC module:

```hcl
module "vpc" {
  ...
  map_public_ip_on_launch = true
}
```

**Lesson:** When running EKS nodes in public subnets without NAT Gateway, 
nodes must have public IPs to communicate with AWS services and the EKS 
control plane.

### Problem 4 — Wrong AWS Console Region

Resources weren't visible in the console. Root cause: console was set to 
a different region than `us-east-1` where Terraform deployed.

**Lesson:** Always verify your AWS Console region matches your Terraform 
`aws_region` variable before troubleshooting missing resources.

---

## Validation

```bash
# Connect kubectl to the new cluster
aws eks update-kubeconfig --region us-east-1 --name sre-demo-dev-eks-cluster

# Verify node is Ready
kubectl get nodes
# NAME                          STATUS   ROLES    AGE    VERSION
# ip-10-0-102-71.ec2.internal   Ready    <none>   4m6s   v1.32.13-eks-b3f9404

# Verify system pods are healthy
kubectl get pods -n kube-system
# NAME                       READY   STATUS    RESTARTS   AGE
# aws-node-sk877             2/2     Running   0          34m
# coredns-644996bf9c-blzh6   1/1     Running   0          42m
# coredns-644996bf9c-tnv7g   1/1     Running   0          42m
# kube-proxy-bwzmh           1/1     Running   0          34m

# Verify no Terraform drift
terraform plan
# No changes. Your infrastructure matches the configuration.
```

### System Pods Explained

| Pod | Purpose |
|---|---|
| `aws-node` | AWS VPC CNI plugin — assigns VPC IPs to pods |
| `coredns` | DNS resolution inside the cluster |
| `kube-proxy` | Maintains network rules on each node |

### Node Health Conditions

```bash
kubectl describe node ip-10-0-102-71.ec2.internal
```

```text
MemoryPressure   False   ← Sufficient memory available
DiskPressure     False   ← Sufficient disk available  
PIDPressure      False   ← Sufficient PIDs available
Ready            True    ← Node is healthy
```

**`InvalidDiskCapacity` warning in events** — harmless, known AWS EKS 
startup behavior. Kubelet briefly reports 0 disk capacity before filesystem 
initialization completes.

---

## Terraform State Management — Key Commands

```bash
# List all managed resources
terraform state list

# Inspect a specific resource
terraform state show module.eks.aws_eks_cluster.this[0]

# Remove from state without deleting from AWS
terraform state rm aws_ecr_repository.app

# Import existing AWS resource into state
terraform import aws_ecr_repository.app sre-demo-dev-api

# Target specific resource for apply or destroy
terraform apply -target=aws_ecr_repository.app
terraform destroy -target=module.eks.module.eks_managed_node_group["default"]

# Enable debug logging
export TF_LOG=DEBUG
terraform apply
```

---

## Cost Breakdown

| Resource | Cost | Notes |
|---|---|---|
| EKS Control Plane | ~$73/mo | Charged per hour, starts immediately |
| EC2 t3.small x1 | ~$15/mo | Worker node |
| ECR Storage | ~$0.10/GB/mo | Minimal for learning |
| VPC/Networking | ~$0 | No NAT Gateway |
| **Total** | **~$88/mo** | Destroy when not working |

**Cost control:**
```bash
# Run this at end of every session
terraform destroy
```

Recreating the cluster takes ~15 minutes but saves significant cost between 
learning sessions.

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| IAM | AdministratorAccess | Scoped custom policy |
| Node location | Public subnets | Private subnets + NAT Gateway |
| Endpoint access | Public | Restrict to VPN/office IPs |
| Node count | 1 desired, 2 max | 3+ across 3 AZs |
| Instance type | t3.small | m5.large or larger |
| State backend | Local | S3 + DynamoDB locking |
| Secrets | None yet | AWS Secrets Manager |
| Cluster logging | Disabled | Enable all control plane logs |
| ECR mutability | MUTABLE | IMMUTABLE |

**Remote state backend** is the most critical production change. Local state 
files cannot be shared across team members and have no locking mechanism. 
Add this to `versions.tf` for production:

```hcl
backend "s3" {
  bucket         = "your-terraform-state-bucket"
  key            = "sre-demo/dev/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "terraform-state-lock"
  encrypt        = true
}
```

---

## Lessons Learned

1. **Terraform modules hide complexity but not problems.** The AWS EKS module 
   handles dozens of IAM roles, security groups, and policies automatically. 
   When something fails, read the module source to understand what it's trying 
   to create.

2. **Partial applies are recoverable.** Terraform's state file tracked exactly 
   what was created before the permission failure. Re-running apply cleanly 
   created the remaining resources without duplicating anything.

3. **Public subnets need explicit IP assignment for EKS nodes.** This is not 
   obvious from the EKS documentation. Without `map_public_ip_on_launch = true`, 
   nodes silently fail to join the cluster.

4. **Always verify the AWS Console region.** A simple mistake that wastes 
   debugging time. Set a browser bookmark with the correct region in the URL.

5. **Commit `.terraform.lock.hcl`.** This file ensures reproducible provider 
   versions across machines and team members. It belongs in version control.

6. **t3.small is tight for EKS.** 2GB RAM with system pods already consuming 
   ~500MB leaves limited headroom. Datadog agent will add pressure — monitor 
   closely and upgrade to t3.medium if needed.

---

## What's Next

**Article 3: Building a GitHub Actions CI/CD Pipeline — From Git Push to EKS Deployment**

We'll containerize the FastAPI application, push it to ECR, and build a complete 
GitHub Actions pipeline that automatically deploys every commit to EKS.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*