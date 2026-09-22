# eks-gitops-dr-drill

A GitOps-deployed service on EKS Fargate, backed by Aurora, with a real
disaster-recovery drill: kill the database mid-traffic, restore it, and
measure actual recovery time against a target RTO — not a claimed one.

**Status:** 🚧 In progress — the DR drill itself is done: **target RTO 2
minutes, measured 39.032 seconds, MET.** Full results in
[`docs/dr-drill-001-results.md`](docs/dr-drill-001-results.md). Only
Datadog is left — see the build log below.

## Why this exists

Most portfolios stop at "I deployed a Kubernetes cluster." This project
tries to answer the harder question an SRE role actually asks: when
something breaks in production, what's your actual recovery time, and can
you show your work? The build order below mirrors real platform-engineering
sequencing — network, then cluster, then GitOps delivery, then the stateful
piece that makes a DR drill meaningful, then observability, then a cost pass.

## A real snag: region

The first `terragrunt apply` failed — not on our code, on AWS's default
account limit of 5 VPCs per region. `us-east-1` was already at 5 (three
leftover VPCs from an earlier course exercise, a `main-vpc`, and the
account's default VPC). Rather than delete anything without checking what
depended on it first, or wait on a quota increase, this project deploys to
**`us-east-2`** instead — the Terraform state bucket stays in `us-east-1`
(already bootstrapped, and a state bucket's region never has to match its
resources' region), only the actual VPC/EKS/NAT move.

## A real snag: CoreDNS stuck Pending

After the cluster and all three Fargate profiles finished applying,
`kubectl get pods -n kube-system` showed both CoreDNS pods `0/1 Pending`,
`PodScheduled: False`, and — the telling detail — **zero scheduling events**.
Not "no node available," just nothing, ever.

**Why:** EKS auto-deploys the CoreDNS addon the moment the cluster control
plane comes up — before Terraform had finished creating the `kube-system`
Fargate profile a few seconds later. Fargate scheduling isn't the normal
kube-scheduler; it's a mutating webhook that only fires at pod *creation*
time. A pod born before its namespace had a matching profile never gets
retried — there's no EC2 fallback for it to land on either, so it just sits
Pending forever with nothing to report.

**Fix:** `kubectl delete pod -n kube-system -l k8s-app=kube-dns` — the
Deployment recreates them, and this time, with the profile already `ACTIVE`,
the webhook claims them correctly. Confirmed `1/1 Running` on real Fargate
nodes (`fargate-ip-10-0-...`) within about a minute, stable across 2+ minutes
of checks.

## Architecture (Phase 1)

```
                         AWS (us-east-2)
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

## What's in this repo vs. what isn't

Everything under `terraform/`, `gitops/`, `docs/` is this project's own —
written here, committed here, and it's the actual source of truth for what
the VPC, EKS cluster, and demo app look like. `gitops/argocd/application.yaml`
in particular is the thing that makes GitOps real: it's how Argo CD knows to
watch *this* repo's `gitops/k8s` path at all.

**Argo CD's own installation is deliberately not in here.** It was installed
by running `kubectl apply` straight against Argo CD's official upstream
manifest (`raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`)
— the standard way to install it, maintained by the Argo project itself, the
same pattern any cluster add-on (cert-manager, ingress-nginx, etc.) uses.
Vendoring an upstream tool's own internals into a project repo would mean
manually tracking its upstream releases instead of letting `kubectl apply`
against their URL do that job. What *is* tracked here is the decision to
install it, and everything it's pointed at managing.

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
- [x] Deploy Phase 1, verify cluster reachable and CoreDNS actually running
      on Fargate — hit a real CoreDNS-stuck-Pending bug along the way (see
      above), not the one originally anticipated, fixed and verified
- [x] Argo CD installed via its own Fargate profile, GitOps-deploys a demo
      workload into `apps` — all 7 Argo CD components came up `Running` on
      the first try (unlike CoreDNS, their Fargate profile already existed
      before they did); the CoreDNS race from Phase 1 recurred identically
      on this redeploy, confirming it's a deterministic pattern on a
      Fargate-only cluster, not a one-off fluke — same fix applied. Verified
      past "Synced/Healthy" by actually curling the app through a real
      `kubectl port-forward` tunnel: real `HTTP 200`, not just a reported
      status. Argo CD's synced revision matched the exact git commit pushed.
- [x] Aurora PostgreSQL Serverless v2 (0.5-2 ACU) provisioned, IAM database
      auth enabled, demo app (`app/`) wired to it via IRSA — no password in
      a Secret, ever. Three real bugs hit and fixed in this phase alone:
      - `engine_version = "16.6"` doesn't exist for aurora-postgresql (only
        `16.6-limitless` does) — checked real available versions via
        `aws rds describe-db-engine-versions` before picking `16.9`
      - Every GitHub Actions run failed OIDC auth with a generic "Not
        authorized" error — root cause was this repo having GitHub's
        *immutable* OIDC subject claims enabled, which embeds numeric
        owner/repo IDs into the `sub` claim instead of the plain
        `owner/repo` form. Confirmed via `gh api .../actions/oidc/
        customization/sub`, fixed by matching the trust policy to the real
        claim — not by disabling a real security feature
      - The Service's `targetPort` was left at `80` (correct for the
        original `nginxdemos/hello` placeholder) after the image swap to
        the real app, which listens on `8080` — pods were `Running` and
        `Ready`, but nothing could actually reach them until this was caught
      - The master password never touched a human or this project's own
        logs: a short-lived, IRSA-scoped bootstrap pod read it directly
        from Secrets Manager to create the IAM-mapped database user, and
        that bootstrap role was deleted immediately after — least-duration,
        not just least-privilege
      - Verified past "Running" with real reads and writes: `GET /visits`
        returned `{"id":1,...,"total_visits":1}`, then `{"id":2,...,
        "total_visits":2}` on the next call — actual inserts against
        Aurora, not a mocked response
- [x] **DR drill:** added a second Aurora instance (a reader — a failover
      needs somewhere real to promote to) and forced a genuine
      `aws rds failover-db-cluster` during live traffic, not a reboot or a
      simulation. **Target RTO 2 minutes (set before the drill), measured
      39.032 seconds — MET.** ~10.5s of grace before impact, 5 failed
      requests over ~16s of real downtime (clean `503`s from the app's own
      `/readyz` check, not hangs), confirmed-stable after 5 consecutive
      successful checks. Verified the writer/reader roles actually swapped
      via `aws rds describe-db-clusters` — not just trusting the app's own
      recovery signal. Full breakdown, timestamps, and the honest reading
      of what each number means in
      [`docs/dr-drill-001-results.md`](docs/dr-drill-001-results.md).
- [ ] Datadog: cluster + Aurora instrumented, one real dashboard, one real
      alert (Fargate needs its own integration path — no DaemonSet, see
      ADR 001)
- [x] Cost pass (Phase 1): ~$0.30-0.35, calculated from published us-east-2
      rates × measured resource lifetime (Cost Explorer lags real time by
      up to 24h, so this isn't the billed figure yet — see the Cost table)
- [x] Phase 1 teardown, verified at $0 — `terragrunt destroy` exit code
      alone isn't proof; confirmed separately via `aws eks list-clusters`,
      `describe-vpcs`, `describe-nat-gateways`, and `describe-addresses`,
      all tagged `Project=eks-gitops-dr-drill`, all empty

**Phases 1-4 (VPC/EKS, Argo CD, Aurora + a real IAM-authenticated app, and
the DR drill itself) are complete and verified.** Only Datadog → final cost
pass are left, picking up in a future session — each one gets its own
deploy → verify → document →
(destroy or hand off to the next phase) cycle, same as the rest of this
project.

## Cost (Phase 1) — actual, not estimated

| Resource | Rate | Ran for | Cost |
|---|---|---|---|
| EKS control plane | $0.10/hr flat | ~1.0 hr | ~$0.10 |
| 2× NAT Gateway | ~$0.045/hr each | ~2.1 hr | ~$0.19 |
| Fargate (2× CoreDNS pod) | Per vCPU/memory-second | ~1.0 hr | ~$0.03 |
| **Total** | | | **~$0.30-0.35** |

Calculated from AWS's published `us-east-2` rates against each resource's
actual creation/destruction timestamps (pulled via `aws eks describe-cluster`
and `aws ec2 describe-nat-gateways`) — not yet reflected in Cost Explorer,
which lags real time by up to 24h. Fully destroyed and independently
verified at $0 (see the build log) at the end of this session.

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
# 1. Set your own IP before applying — passed via env var, never committed
export EKS_ALLOWED_CIDR="$(curl -4 -s ifconfig.me)/32"
# a Terraform variable validation hard-fails the apply if this is left at
# 0.0.0.0/0 — see terraform/modules/eks/variables.tf

cd terraform/live/dev/vpc
terragrunt init
terragrunt apply

cd ../eks
terragrunt init
terragrunt apply   # ~10-15 min for the EKS control plane

aws eks update-kubeconfig --name eks-gitops-dr-drill-dev --region us-east-2
kubectl get pods -n kube-system   # verify CoreDNS is Running, not Pending
```

## Teardown

```bash
cd terraform/live/dev/eks && terragrunt destroy
cd ../vpc && terragrunt destroy
```
