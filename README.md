# eks-gitops-dr-drill

A GitOps-deployed service on EKS Fargate, backed by Aurora, with a real
disaster-recovery drill: kill the database mid-traffic, restore it, and
measure actual recovery time against a target RTO — not a claimed one.

**Status:** 🚧 In progress — built in one focused, cost-controlled session.
Phase 1 (networking + cluster) below; later phases append as they're built.

## Why this exists

Most portfolios stop at "I deployed a Kubernetes cluster." This project
tries to answer the harder question an SRE role actually asks: when
something breaks in production, what's your actual recovery time, and can
you show your work? The build order below mirrors real platform-engineering
sequencing — network, then cluster, then GitOps delivery, then the stateful
piece that makes a DR drill meaningful, then observability, then a cost pass.

## Architecture (Phase 1)

```
                         AWS (us-east-1)
                    ┌─────────────────────────────────────┐
                    │  VPC (10.0.0.0/16)                    │
                    │                                        │
  Internet ── IGW ──┤  ┌──────────┐      ┌──────────┐       │
                    │  │  Public  │      │  Public  │       │
                    │  │  Subnet  │      │  Subnet  │       │
                    │  │  AZ-a    │      │  AZ-b    │       │
                    │  └────┬─────┘      └────┬─────┘       │
                    │       │ NAT             │ NAT         │
                    │  ┌────▼─────┐      ┌────▼─────┐       │
                    │  │ Private  │      │ Private  │       │
                    │  │ Subnet   │      │ Subnet   │       │
                    │  │ (Fargate)│      │ (Fargate)│       │
                    │  └──────────┘      └──────────┘       │
                    │                                        │
                    │  EKS control plane (Fargate-only —     │
                    │  no managed node group, see ADR 001)   │
                    └─────────────────────────────────────┘
```

## Why Terragrunt, not just Terraform

The `terragrunt.hcl` root config bootstraps its own S3 state bucket and
DynamoDB lock table automatically on first `init` — the bucket name is
derived live from the AWS account ID (`get_aws_account_id()`), so there's
no placeholder bucket name to remember to edit before running. `live/dev/`
holds only what's actually different per environment; everything shared
(backend config, provider config, region) lives once in the root and is
included, not copied.

## Build log

- [x] Terraform modules: VPC (2 AZs, public/private subnets, one NAT per AZ)
- [x] Terraform module: EKS control plane, Fargate-only (profiles for
      `kube-system`, `argocd`, `apps` — see ADR 001 for why no node group)
- [x] Terragrunt wiring: `live/dev/vpc`, `live/dev/eks`, auto-bootstrapped
      remote state
- [ ] Deploy Phase 1, verify cluster reachable and CoreDNS actually running
      on Fargate (the real failure mode: CoreDNS stuck `Pending` with no
      matching profile)
- [ ] Argo CD installed via its own Fargate profile, GitOps-deploys a demo
      workload into `apps`
- [ ] Aurora (Postgres) provisioned, demo workload wired to it via IRSA —
      no password in a Secret
- [ ] **DR drill:** force-fail the primary during live traffic, restore,
      measure real recovery time against a stated RTO target
- [ ] Datadog: cluster + Aurora instrumented, one real dashboard, one real
      alert (Fargate needs its own integration path — no DaemonSet, see
      ADR 001)
- [ ] Cost pass: real spend for the session, what was rightsized and why
- [ ] Full teardown, verified at $0

## Cost (Phase 1)

| Resource | Rate | Notes |
|---|---|---|
| EKS control plane | $0.10/hr flat | Bills regardless of usage — the reason this is a one-session build |
| 2× NAT Gateway | ~$0.045/hr each + data processing | One per AZ for real HA, not a shortcut |
| Fargate pods | Per vCPU/memory-second requested | CoreDNS + Argo CD + demo app — a few cents for a session |

Everything here is destroyed (`terragrunt run-all destroy`) at the end of
the build session — see the cost pass entry in the build log for the actual
number.

## Repo layout

```
eks-gitops-dr-drill/
├── terraform/
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, NAT, routing — reusable
│   │   └── eks/          # EKS control plane, OIDC/IRSA, Fargate profiles
│   └── live/
│       └── dev/
│           ├── vpc/      # terragrunt.hcl — VPC inputs for dev
│           └── eks/      # terragrunt.hcl — EKS inputs for dev
├── terragrunt.hcl        # Root: backend bootstrap, provider, shared inputs
├── docs/
│   └── adr/               # Architecture decision records
└── README.md
```

## Deploying (Phase 1)

```bash
# 1. Set your own IP before applying — 0.0.0.0/0 is a real finding, not a demo one
curl ifconfig.me
# then edit terraform/live/dev/eks/terragrunt.hcl: allowed_cidr_blocks = ["YOUR_IP/32"]

cd terraform/live/dev/vpc
terragrunt init
terragrunt apply

cd ../eks
terragrunt init
terragrunt apply   # ~10-15 min for the EKS control plane

aws eks update-kubeconfig --name eks-gitops-dr-drill-dev --region us-east-1
kubectl get pods -n kube-system   # verify CoreDNS is Running, not Pending
```

## Teardown

```bash
cd terraform/live/dev/eks && terragrunt destroy
cd ../vpc && terragrunt destroy
```
