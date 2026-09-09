# Phase 17: Mapping a Custom Domain to an EKS Application Using AWS Route 53

*Part 17 of the SRE Observability on AWS EKS with Datadog series*

---

## Introduction

The EKS LoadBalancer gives you a hostname like:
```
a088aea33803f4c038ce5781a63dbbab-2089612467.us-east-1.elb.amazonaws.com
```

That works, but it's not something you'd put on a resume or share publicly. Phase 17 maps `sre.machindra.online` to the application — a clean, memorable URL backed by AWS Route 53.

This phase covers the full setup via the AWS Console — understanding each step before automating it in Phase 18.

---

## What Gets Built

```
sre.machindra.online
        ↓
  AWS Route 53 (CNAME record)
        ↓
  EKS LoadBalancer hostname
        ↓
  FastAPI application
```

---

## Prerequisites

- Domain registered at a registrar (BigRock in this case — `machindra.online`)
- EKS cluster running with LoadBalancer service assigned
- AWS Console access

---

## Step 1 — Create a Hosted Zone in Route 53

A hosted zone tells Route 53 how to handle DNS for your domain.

**Console:** Route 53 → Get started → **Create hosted zones** → Get started

**Configuration:**

| Field | Value |
|---|---|
| Domain name | `machindra.online` |
| Description | SRE Project domain |
| Type | Public hosted zone |

> **Note:** Use the root domain `machindra.online` — not the subdomain. One hosted zone manages all subdomains (`sre.`, `www.`, etc.).

Click **Create hosted zone**.

Route 53 auto-creates two records:
- **NS** — 4 nameserver addresses (you'll need these next)
- **SOA** — zone authority record (auto-managed)

---

## Step 2 — Update Nameservers at BigRock

Route 53 needs to be the authoritative DNS for your domain. This is done by pointing your registrar to Route 53's nameservers.

**Copy the 4 NS record values from Route 53:**
```
ns-1455.awsdns-53.org
ns-1000.awsdns-61.net
ns-110.awsdns-13.com
ns-2012.awsdns-59.co.uk
```

**At BigRock:**
1. Login → My Domains → `machindra.online`
2. DNS / Nameservers → Change Nameservers
3. Select **Custom Nameservers**
4. Enter all 4 NS values
5. Click **Update Name Servers**

> **Important:** AWS generates new NS records every time a hosted zone is created — even for the same domain. If you ever delete and recreate the hosted zone, you must update BigRock nameservers again.

DNS propagation takes 15 minutes to 48 hours. Typically resolves in 30 minutes.

---

## Step 3 — Create the CNAME Record

**Get your EKS LoadBalancer hostname:**
```bash
kubectl get svc sre-demo-api -n sre-demo
```
```
NAME           TYPE           CLUSTER-IP      EXTERNAL-IP
sre-demo-api   LoadBalancer   172.20.242.92   a088aea33803f4c038ce5781a63dbbab-2089612467.us-east-1.elb.amazonaws.com
```

**In Route 53 → Hosted zones → `machindra.online` → Create record:**

| Field | Value |
|---|---|
| Record name | `sre` |
| Record type | `CNAME` |
| Value | `a088aea33803f4c038ce5781a63dbbab-2089612467.us-east-1.elb.amazonaws.com` |
| TTL | `300` |

Click **Create records**.

> **Screenshot:** `docs/screenshots/phase-17/01-route53-cname-record.png`

---

## Step 4 — Verify DNS Propagation

Check propagation from outside your machine:
```
https://dnschecker.org/#CNAME/sre.machindra.online
```

Also verify NS records are updated globally:
```
https://dnschecker.org/#NS/machindra.online
```

Both should show Route 53 nameservers (awsdns) resolving correctly worldwide.

---

## Step 5 — Fix WSL2 DNS (Windows users only)

WSL2 auto-generates `/etc/resolv.conf` as a symlink pointing to Windows DNS — which returns `127.0.0.1` for custom domains.

**Check if it's a symlink:**
```bash
ls -la /etc/resolv.conf
```

**Fix:**
```bash
# Replace symlink with real file using Google DNS
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

**Make permanent across WSL2 restarts:**
```bash
echo "[network]
generateResolvConf = false" | sudo tee /etc/wsl.conf
```

---

## Step 6 — Test the Domain

```bash
# Confirm DNS resolves correctly
nslookup sre.machindra.online

# Test all app endpoints via custom domain
curl http://sre.machindra.online/api/health
curl http://sre.machindra.online/api/products
curl http://sre.machindra.online/api/error
curl http://sre.machindra.online/api/slow
```

Expected output for health:
```json
{"status":"healthy","version":"1.0.0","env":"dev"}
```

> **Screenshot:** `docs/screenshots/phase-17/02-domain-working-terminal.png`

---

## How DNS Resolution Works

```
curl http://sre.machindra.online/api/health
        ↓
  Local DNS (8.8.8.8 — Google)
        ↓
  Root DNS → .online TLD → machindra.online nameservers
        ↓
  Route 53 (ns-1455.awsdns-53.org)
        ↓
  CNAME: sre.machindra.online → ELB hostname
        ↓
  AWS internal DNS resolves ELB → 44.209.205.46
        ↓
  EKS LoadBalancer → App Pod → Response
```

---

## Other Route 53 Options (Not Used Here)

| Option | Use Case |
|---|---|
| Register a domain | Buy domain directly through AWS |
| Transfer domain | Move domain from another registrar to Route 53 |
| Configure health checks | Route away from unhealthy endpoints |
| Configure traffic flow | Weighted, geolocation, failover routing |
| Configure resolvers | DNS between AWS VPC and on-premise |

---

## Cost

| Resource | Cost |
|---|---|
| Route 53 Hosted Zone | **$0.50/month** |
| DNS queries (first 1B) | $0.40 per million |
| **Estimated** | **~$0.50/month** |

This is optional for the demo project — destroy the hosted zone when not needed to avoid the charge.

---

## Known Issues

**`nslookup` returns `127.0.0.1` in WSL2:**
WSL2 intercepts DNS before it reaches the internet. Fix: replace `/etc/resolv.conf` symlink with a real file pointing to `8.8.8.8`.

**CNAME hostname changes after `infra-down.sh` / `infra-up.sh`:**
EKS creates a new LoadBalancer with a different hostname on every deploy. The CNAME record must be manually updated in Route 53 each time — or automated via Terraform (Phase 18).

---

## Screenshots to Capture

```
docs/screenshots/phase-17/
├── 01-route53-hosted-zone-created.png
├── 02-bigrock-nameservers-updated.png
├── 03-route53-cname-record.png
├── 04-dnschecker-propagation.png
└── 05-domain-working-terminal.png
```

---

## Key Takeaways

- A hosted zone manages DNS for the root domain — subdomains are records within it
- Nameserver updates at the registrar are required once — unless the hosted zone is deleted
- WSL2 DNS interception is a common gotcha for Windows developers
- CNAME TTL of 300s means DNS changes propagate within 5 minutes

---

## What's Next — Phase 18: Terraform Import and DNS Automation

Phase 17 set everything up manually. Phase 18 imports those resources into Terraform and automates the CNAME update — so `terraform apply` after every `infra-up.sh` keeps the domain pointing to the correct LoadBalancer automatically.

---

*Repository: [github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)*